import Foundation
import Synchronization

/// Serves requests for routed hosts over `PinnedTLSClient`; every other request is left to the system.
/// Experimental: no redirects, no request headers or body forwarded, the whole body is delivered at once.
public final class PinnedRoutingURLProtocol: URLProtocol {
    public static let routeHeader = "X-Eros-Route"

    private static let routes = Mutex<[String: String]>([:])

    /// Replaces the route table (host → IP). Hosts match exactly, ignoring case.
    public static func setRoutes(_ routes: [String: String]) {
        let normalized = Dictionary(routes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.routes.withLock { $0 = normalized }
    }

    static func route(for url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return nil }
        return routes.withLock { $0[host] }
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        route(for: request.url) != nil
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private let loading = Mutex<Task<Void, Never>?>(nil)
    private let stopped = Mutex(false)

    override public func startLoading() {
        // Client callbacks must happen on the thread (and run loop) that called startLoading.
        let clientLoop = ClientRunLoop.current()
        guard let url = request.url, let ip = Self.route(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        // The instance itself is only touched on the client loop; the task merely carries the reference there.
        let instance = ClientLoopReference(value: self)
        let task = Task {
            let outcome = await Self.fetch(url, via: ip)
            clientLoop.perform { instance.value.deliver(outcome) }
        }
        loading.withLock { $0 = task }
    }

    private static func fetch(_ url: URL, via ip: String) async -> Result<(HTTPURLResponse, Data), any Error> {
        do {
            let raw = try await PinnedTLSClient().get(url, connectingTo: ip)
            guard let response = httpResponse(for: url, raw: raw) else { return .failure(URLError(.cannotParseResponse)) }
            return .success((response, raw.body))
        } catch {
            return .failure(error)
        }
    }

    /// Runs on the client run loop.
    private func deliver(_ outcome: Result<(HTTPURLResponse, Data), any Error>) {
        guard !stopped.withLock({ $0 }) else { return }
        switch outcome {
        case .success(let (response, body)):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override public func stopLoading() {
        stopped.withLock { $0 = true }
        let task = loading.withLock { current -> Task<Void, Never>? in
            defer { current = nil }
            return current
        }
        task?.cancel()
    }

    static func httpResponse(for url: URL, raw: RawHTTPResponse) -> HTTPURLResponse? {
        // The body is already de-chunked and complete, so framing headers are rewritten.
        let dropped: Set<String> = ["transfer-encoding", "content-length", "connection"]
        var fields = raw.headers.filter { !dropped.contains($0.key.lowercased()) }
        fields["Content-Length"] = String(raw.body.count)
        fields[routeHeader] = "pinned"
        return HTTPURLResponse(url: url, statusCode: raw.status, httpVersion: "HTTP/1.1", headerFields: fields)
    }
}

/// A reference that is only dereferenced on the client run loop.
private struct ClientLoopReference<Value: AnyObject>: @unchecked Sendable {
    let value: Value
}

/// The run loop that called `startLoading`, so results can be delivered back on it.
private struct ClientRunLoop: @unchecked Sendable {
    let runLoop: CFRunLoop
    let modes: CFArray

    static func current() -> ClientRunLoop {
        let runLoop = CFRunLoopGetCurrent()!
        let current = CFRunLoopCopyCurrentMode(runLoop) ?? CFRunLoopMode.defaultMode
        let modes = [CFRunLoopMode.commonModes, current].compactMap { $0?.rawValue } as CFArray
        return ClientRunLoop(runLoop: runLoop, modes: modes)
    }

    func perform(_ body: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, modes, body)
        CFRunLoopWakeUp(runLoop)
    }
}
