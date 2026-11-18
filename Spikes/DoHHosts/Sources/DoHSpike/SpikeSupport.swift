import EHNetwork
import Foundation
import Network
import Synchronization

/// Process-wide state shared by every spike component.
public enum SpikeEnvironment {
    /// The one limiter every outbound request in this package goes through.
    public static let rateLimiter = RateLimiter()

    /// Ephemeral configuration with no cookies and no cache, for anonymous requests.
    public static func anonymousSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        return configuration
    }

    static let queue = DispatchQueue(label: "proj.eros.swifte.doh-spike")
}

public enum SpikeError: Error, CustomStringConvertible {
    case timedOut(Duration)
    case badStatus(Int)
    case dnsFailure(host: String, status: Int)
    case noAddress(String)
    case invalidAddress(String)
    case unsupportedURL(URL)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .timedOut(let limit): "timed out after \(limit)"
        case .badStatus(let status): "unexpected HTTP status \(status)"
        case .dnsFailure(let host, let status): "DNS lookup for \(host) failed with rcode \(status)"
        case .noAddress(let host): "no A record for \(host)"
        case .invalidAddress(let address): "not an IP address: \(address)"
        case .unsupportedURL(let url): "unsupported URL: \(url)"
        case .malformedResponse(let reason): "malformed response: \(reason)"
        }
    }
}

/// Runs `operation`, cancelling it once `limit` elapses. The operation must react to cancellation.
func withTimeout<T: Sendable>(
    _ limit: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw SpikeError.timedOut(limit)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}

/// Resumes a continuation at most once; later calls are ignored.
final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, any Error>?>

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<Value, any Error>) {
        let pending = continuation.withLock { current -> CheckedContinuation<Value, any Error>? in
            defer { current = nil }
            return current
        }
        pending?.resume(with: result)
    }
}

/// Cancels a connection the first time `close()` is called; later calls do nothing.
final class ConnectionCloser: Sendable {
    private let connection: NWConnection
    private let closed = Mutex(false)

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func close() {
        let first = closed.withLock { closed -> Bool in
            defer { closed = true }
            return !closed
        }
        if first { connection.cancel() }
    }
}

/// One `receive` callback.
struct ReceivedChunk: Sendable {
    let data: Data?
    let isComplete: Bool
    let error: NWError?
}

extension NWConnection {
    /// Starts the connection and waits for `.ready`. `.waiting` counts as failure so the spike never hangs
    /// (Network.framework parks a connection in `.waiting` on some TLS and DNS errors instead of failing it).
    /// Runs `operation` under a deadline. The connection is cancelled exactly once: when the deadline or
    /// task cancellation interrupts the operation (which resumes its pending callbacks), or when it ends.
    func run<T: Sendable>(
        within limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let closer = ConnectionCloser(self)
        defer { closer.close() }
        return try await withTimeout(limit) {
            try await withTaskCancellationHandler(operation: operation, onCancel: { closer.close() })
        }
    }

    /// Starts the connection and waits for `.ready`. `.waiting` counts as failure so the spike never hangs
    /// (Network.framework parks a connection in `.waiting` on some TLS and DNS errors instead of failing it).
    /// Call inside `run(within:_:)`, which handles cancellation.
    func startAndWaitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(continuation)
            stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(with: .success(()))
                case .waiting(let error), .failed(let error): once.resume(with: .failure(error))
                case .cancelled: once.resume(with: .failure(CancellationError()))
                default: break
                }
            }
            if Task.isCancelled {
                once.resume(with: .failure(CancellationError()))
            } else {
                start(queue: SpikeEnvironment.queue)
            }
        }
    }

    func sendAll(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receiveChunk(maximumLength: Int = 64 * 1024) async -> ReceivedChunk {
        await withCheckedContinuation { (continuation: CheckedContinuation<ReceivedChunk, Never>) in
            receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                continuation.resume(returning: ReceivedChunk(data: data, isComplete: isComplete, error: error))
            }
        }
    }

    func establishmentReport() async -> EstablishmentReport? {
        await withCheckedContinuation { continuation in
            requestEstablishmentReport(queue: SpikeEnvironment.queue) { report in
                continuation.resume(returning: report)
            }
        }
    }
}

extension NWConnection.EstablishmentReport.Resolution.DNSProtocol {
    var label: String {
        switch self {
        case .unknown: "unknown"
        case .udp: "udp"
        case .tcp: "tcp"
        case .tls: "tls"
        case .https: "https"
        @unknown default: "other"
        }
    }
}

extension NWConnection.EstablishmentReport.Resolution.Source {
    var label: String {
        switch self {
        case .query: "query"
        case .cache: "cache"
        case .expiredCache: "expiredCache"
        @unknown default: "other"
        }
    }
}

// MARK: - Plain URLSession probe

/// Outcome of one plain `URLSession` GET, with the transport details from its task metrics.
public struct SessionProbeResult: Sendable {
    public let status: Int
    public let body: Data
    public let elapsed: Duration
    /// `domainResolutionProtocol` per network transaction (udp, tcp, tls, https, unknown).
    public let resolutionProtocols: [String]
    public let remoteAddresses: [String]
    public let networkProtocols: [String]
    public let proxied: Bool
}

public enum SessionProbe {
    /// Anonymous GET on a fresh ephemeral session (no pooled connection). Throttled before the clock starts.
    public static func get(_ url: URL, timeout: TimeInterval = 20) async throws -> SessionProbeResult {
        try await SpikeEnvironment.rateLimiter.acquire(host: url.host() ?? "")
        let configuration = SpikeEnvironment.anonymousSessionConfiguration()
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(RequestDefaults.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        let collector = MetricsCollector()
        let start = ContinuousClock.now
        let (data, response) = try await session.data(for: request, delegate: collector)
        let elapsed = ContinuousClock.now - start
        let summary = collector.summary
        return SessionProbeResult(
            status: (response as? HTTPURLResponse)?.statusCode ?? -1,
            body: data,
            elapsed: elapsed,
            resolutionProtocols: summary?.resolutionProtocols ?? [],
            remoteAddresses: summary?.remoteAddresses ?? [],
            networkProtocols: summary?.networkProtocols ?? [],
            proxied: summary?.proxied ?? false
        )
    }
}

struct MetricsSummary: Sendable {
    let resolutionProtocols: [String]
    let remoteAddresses: [String]
    let networkProtocols: [String]
    let proxied: Bool

    init(_ metrics: URLSessionTaskMetrics) {
        let transactions = metrics.transactionMetrics.filter { $0.resourceFetchType == .networkLoad }
        resolutionProtocols = transactions.map { transaction in
            switch transaction.domainResolutionProtocol {
            case .unknown: "unknown"
            case .udp: "udp"
            case .tcp: "tcp"
            case .tls: "tls"
            case .https: "https"
            @unknown default: "other"
            }
        }
        remoteAddresses = transactions.map { $0.remoteAddress ?? "-" }
        networkProtocols = transactions.map { $0.networkProtocolName ?? "-" }
        proxied = transactions.contains { $0.isProxyConnection }
    }
}

final class MetricsCollector: NSObject, URLSessionTaskDelegate, Sendable {
    private let stored = Mutex<MetricsSummary?>(nil)

    var summary: MetricsSummary? { stored.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let summary = MetricsSummary(metrics)
        stored.withLock { $0 = summary }
    }
}
