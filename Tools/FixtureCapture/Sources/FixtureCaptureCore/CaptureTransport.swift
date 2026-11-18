import EHNetwork
import Foundation
import Synchronization

/// Sends one capture request. `Capturer` waits for each answer before sending the next.
public protocol CaptureTransport: Sendable {
    func send(_ request: CaptureRequest) async throws -> CaptureResponse
}

/// Sends capture requests with `URLSession`, waiting for `rateLimiter` before each one and before each redirect it
/// follows.
///
/// The session keeps nothing between requests and adds nothing of its own: an ephemeral configuration with no
/// cookie storage (cookies come only from the request's `Cookie` header), no cache and no credential storage. TLS
/// uses the system's default trust evaluation; there is no challenge handler. A request with
/// `followRedirects == false` gets the 3xx answer itself; otherwise redirects are vetted one by one (see
/// `redirectDelegate`), so the login cookies never travel to another host and every hop is rate-limited and
/// read-only.
public struct URLSessionCaptureTransport: CaptureTransport {
    /// Most redirects followed for one request; the next one is handed back as the 3xx answer.
    public static let maximumRedirects = 3

    private let rateLimiter: RateLimiter
    private let session: URLSession

    public init(rateLimiter: RateLimiter) {
        self.rateLimiter = rateLimiter
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: CaptureRequest) async throws -> CaptureResponse {
        guard let host = request.url.host(), !host.isEmpty else { throw URLError(.badURL) }
        try await rateLimiter.acquire(host: host)

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let (seconds, attoseconds) = request.timeout.components
        urlRequest.timeoutInterval = Double(seconds) + Double(attoseconds) / 1e18
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let limiter = rateLimiter
        let delegate = Self.redirectDelegate(host: host, followRedirects: request.followRedirects) { host in
            try await limiter.acquire(host: host)
        }
        let (data, response) = try await session.data(for: urlRequest, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String { headers[name] = "\(value)" }
        }
        return CaptureResponse(status: http.statusCode, headers: headers, body: data, url: http.url ?? request.url)
    }

    /// The task delegate `send` gives one request to `host`. For each redirect it returns nil (hand back the 3xx
    /// answer) unless all of these hold, in order: `followRedirects` is true; it is at most the
    /// `maximumRedirects`-th redirect of this request; `acquire` for the new host returns (it waits for the rate
    /// limiter; an error or a cancellation refuses the redirect); the new request is https on `host`, a GET, and
    /// passes the same read-only check as every request (`CapturePlan.isReadOnly`, so nothing mentioning
    /// `inline_set`). 307 and 308 keep the method, so a redirected POST is refused.
    /// - Parameter acquire: `send` passes `RateLimiter.acquire(host:)`.
    public static func redirectDelegate(
        host: String,
        followRedirects: Bool,
        acquire: @escaping @Sendable (String) async throws -> Void
    ) -> any URLSessionTaskDelegate & Sendable {
        RedirectPolicy(follow: followRedirects, host: host.lowercased(), acquire: acquire)
    }
}

/// Decides each redirect of one task; see `URLSessionCaptureTransport.redirectDelegate`.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    private let follow: Bool
    private let host: String
    private let acquire: @Sendable (String) async throws -> Void
    private let redirects = Mutex(0)

    init(follow: Bool, host: String, acquire: @escaping @Sendable (String) async throws -> Void) {
        self.follow = follow
        self.host = host
        self.acquire = acquire
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard follow else { return nil }
        let count = redirects.withLock { count in
            count += 1
            return count
        }
        guard count <= URLSessionCaptureTransport.maximumRedirects,
              let url = request.url, let newHost = url.host()?.lowercased() else { return nil }
        do {
            try await acquire(newHost)
        } catch {
            return nil
        }
        let method = request.httpMethod ?? "GET"
        guard url.scheme?.lowercased() == "https", newHost == host, method == "GET",
              CapturePlan.readOnly(method: method, url: url, body: request.httpBody, site: nil) else { return nil }
        return request
    }
}
