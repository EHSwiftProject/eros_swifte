import FixtureCaptureCore
import Foundation
import Synchronization
import Testing

/// Records the hosts the redirect delegate waits for, and can fail the wait like a cancelled rate limiter.
private final class AcquireRecorder: Sendable {
    private let hosts = Mutex<[String]>([])
    private let fails: Bool

    init(fails: Bool = false) {
        self.fails = fails
    }

    func acquire(_ host: String) async throws {
        hosts.withLock { $0.append(host) }
        if fails { throw CancellationError() }
    }

    var recorded: [String] { hosts.withLock { $0 } }
}

private func delegate(follow: Bool = true, recorder: AcquireRecorder) -> any URLSessionTaskDelegate & Sendable {
    URLSessionCaptureTransport.redirectDelegate(host: "e-hentai.org", followRedirects: follow) { host in
        try await recorder.acquire(host)
    }
}

/// Asks `delegate` about a redirect from https://e-hentai.org/start to `location`, the way URLSession does. The
/// task is never resumed, so nothing is sent.
private func redirect(
    _ delegate: any URLSessionTaskDelegate & Sendable,
    to location: String,
    method: String = "GET",
    status: Int = 302
) async throws -> URLRequest? {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let start = try #require(URL(string: "https://e-hentai.org/start"))
    let task = session.dataTask(with: start)
    let response = try #require(HTTPURLResponse(
        url: start, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": location]
    ))
    var request = URLRequest(url: try #require(URL(string: location)))
    request.httpMethod = method
    return await withCheckedContinuation { continuation in
        // The completion-handler form of the delegate method; nil when the delegate does not implement it.
        let implemented: Void? = delegate.urlSession?(
            session, task: task, willPerformHTTPRedirection: response, newRequest: request
        ) { decision in
            continuation.resume(returning: decision)
        }
        if implemented == nil { continuation.resume(returning: nil) }
    }
}

@Suite struct CaptureTransportTests {
    @Test func followsSameHostHTTPSRedirectsAfterTheRateLimiter() async throws {
        let recorder = AcquireRecorder()
        let followed = try await redirect(delegate(recorder: recorder), to: "https://e-hentai.org/?page=2")
        #expect(followed?.url == URL(string: "https://e-hentai.org/?page=2"))
        #expect(recorder.recorded == ["e-hentai.org"])
        // Host names compare ignoring case.
        let upper = try await redirect(delegate(recorder: AcquireRecorder()), to: "https://E-Hentai.org/next")
        #expect(upper != nil)
    }

    @Test func refusesRedirectsItMayNotFollow() async throws {
        let refused: [(location: String, method: String, status: Int)] = [
            ("https://example.org/", "GET", 302),
            ("https://forums.e-hentai.org/", "GET", 302),
            ("https://exhentai.org/", "GET", 302),
            ("http://e-hentai.org/", "GET", 301),
            ("https://e-hentai.org/api.php", "POST", 307),
            ("https://e-hentai.org/uconfig.php", "POST", 308),
            ("https://e-hentai.org/?inline_set=dm_t", "GET", 302),
            ("https://e-hentai.org/?inline%5Fset=dm_t", "GET", 302),
            ("https://e-hentai.org/?INLINE.SET=dm_t", "GET", 302),
        ]
        for case let (location, method, status) in refused {
            let decision = try await redirect(delegate(recorder: AcquireRecorder()), to: location, method: method, status: status)
            #expect(decision == nil, "\(method) \(location) (\(status)) was followed")
        }
    }

    @Test func followsAtMostThreeRedirectsPerRequest() async throws {
        let recorder = AcquireRecorder()
        let policy = delegate(recorder: recorder)
        var decisions: [Bool] = []
        for hop in 1...4 {
            decisions.append(try await redirect(policy, to: "https://e-hentai.org/hop\(hop)") != nil)
        }
        #expect(decisions == [true, true, true, false])
        #expect(URLSessionCaptureTransport.maximumRedirects == 3)
        // The fourth is refused before waiting for the rate limiter.
        #expect(recorder.recorded.count == 3)
        // Each request starts counting afresh.
        #expect(try await redirect(delegate(recorder: AcquireRecorder()), to: "https://e-hentai.org/hop1") != nil)
    }

    @Test func neverFollowsWhenTheRequestSaysSo() async throws {
        let recorder = AcquireRecorder()
        let decision = try await redirect(delegate(follow: false, recorder: recorder), to: "https://e-hentai.org/next")
        #expect(decision == nil)
        #expect(recorder.recorded.isEmpty)
    }

    @Test func aFailedRateLimiterWaitRefusesTheRedirect() async throws {
        let recorder = AcquireRecorder(fails: true)
        let decision = try await redirect(delegate(recorder: recorder), to: "https://e-hentai.org/next")
        #expect(decision == nil)
        #expect(recorder.recorded == ["e-hentai.org"])
    }
}
