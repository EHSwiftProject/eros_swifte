import EHNetwork
import Foundation
import Synchronization
import Testing
import WebKit

@testable import Eros

// Test doubles of ErosTests. A slim copy of EHNetworkTesting's MockURLProtocol lives here instead of a dependency on
// that product: ErosTests resolves EHNetwork against the host app (link: false), and linking EHNetworkTesting would
// load a second copy of EHNetwork's classes ("Class … is implemented in both").

/// What `StubURLProtocol` answers to one request.
struct StubResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
    /// Offers this response (a 3xx) as a redirect to this URL; the session decides whether to follow it.
    let redirectTo: URL?

    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data(), redirectTo: URL? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.redirectTo = redirectTo
    }
}

/// A URL protocol that answers from registered responders and never touches the network (EHNetworkTesting's
/// `MockURLProtocol`, without what these tests do not use).
///
/// A `StubSession`'s configurator installs it first in a session's `protocolClasses` and adds the `X-Eros-Stub` header
/// naming the registration; a request without a registered id fails with `URLError(.unsupportedURL)`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let headerName = "X-Eros-Stub"

    /// How long an offered redirect waits to be followed before the stub takes it as refused and finishes with the
    /// 3xx (finishing at once would race the session's decision; see `MockURLProtocol.refusalDelay`).
    static let refusalDelay: Duration = .seconds(1)

    fileprivate typealias Responder = @Sendable (URLRequest) throws -> StubResponse

    fileprivate struct Registration {
        let responder: Responder
        var requests: [URLRequest] = []
    }

    fileprivate static let registry = Mutex<[String: Registration]>([:])

    private let isStopped = Mutex(false)

    static func install(_ responder: @escaping @Sendable (URLRequest) throws -> StubResponse) -> StubSession {
        let id = UUID().uuidString
        registry.withLock { $0[id] = Registration(responder: responder) }
        return StubSession(id: id)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let responder: Responder? = request.value(forHTTPHeaderField: Self.headerName).flatMap { id in
            Self.registry.withLock { registrations in
                guard registrations[id] != nil else { return nil }
                registrations[id]!.requests.append(request)
                return registrations[id]!.responder
            }
        }
        guard let responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            deliver(try responder(request), for: request)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        isStopped.withLock { $0 = true }
    }

    private func deliver(_ stub: StubResponse, for request: URLRequest) {
        guard let client, let url = request.url else { return }
        var headers = stub.headers
        if let target = stub.redirectTo { headers["Location"] = target.absoluteString }
        guard let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: headers)
        else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        guard let target = stub.redirectTo else {
            finish(with: response, body: stub.body)
            return
        }
        var next = request
        next.url = target
        client.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        let delay = DispatchTimeInterval.milliseconds(Int(Self.refusalDelay / .milliseconds(1)))
        let body = stub.body
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard !isStopped.withLock({ $0 }) else { return }
            finish(with: response, body: body)
        }
    }

    private func finish(with response: HTTPURLResponse, body: Data) {
        guard let client else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }
}

/// One `StubURLProtocol` registration: the configurator that routes a session to it, and what it received.
struct StubSession: Sendable {
    let configurator: SessionConfigurator
    private let id: String

    fileprivate init(id: String) {
        self.id = id
        configurator = SessionConfigurator(usesCustomProxy: false) { configuration in
            configuration.protocolClasses = [StubURLProtocol.self as AnyClass] + (configuration.protocolClasses ?? [])
            var headers = configuration.httpAdditionalHeaders ?? [:]
            headers[StubURLProtocol.headerName] = id
            configuration.httpAdditionalHeaders = headers
        }
    }

    /// The requests received so far, oldest first.
    func requests() -> [URLRequest] {
        StubURLProtocol.registry.withLock { $0[id]?.requests ?? [] }
    }

    func remove() {
        _ = StubURLProtocol.registry.withLock { $0.removeValue(forKey: id) }
    }
}

/// A throttle that never waits and records every URL it is asked for; it refuses (throws) for the hosts in `refusing`,
/// and for every call from the `refusingFrom`-th on (counting from 1).
actor ThrottleRecorder: RequestThrottle {
    struct Refused: Error {}

    private(set) var urls: [URL] = []
    private let refusing: Set<String>
    private let refusingFrom: Int?

    init(refusing: Set<String> = [], refusingFrom: Int? = nil) {
        self.refusing = refusing
        self.refusingFrom = refusingFrom
    }

    func acquire(for url: URL) async throws {
        try Task.checkCancellation()
        urls.append(url)
        if refusing.contains(url.host() ?? "") { throw Refused() }
        if let refusingFrom, urls.count >= refusingFrom { throw Refused() }
    }
}

/// A throttle that records every URL and holds every request until `open()`.
actor GatedThrottle: RequestThrottle {
    private(set) var urls: [URL] = []
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire(for url: URL) async throws {
        urls.append(url)
        if !isOpen {
            await withCheckedContinuation { waiting.append($0) }
        }
        try Task.checkCancellation()
    }

    /// Lets the held requests and every later one through.
    func open() {
        isOpen = true
        let held = waiting
        waiting = []
        for continuation in held { continuation.resume() }
    }
}

/// A throttle that never lets a request through: `acquire` waits until the task it runs in is cancelled, then throws
/// `CancellationError`. `waiting` counts the calls waiting now, `cancellations` those that ended by cancellation.
actor SuspendingThrottle: RequestThrottle {
    private(set) var waiting = 0
    private(set) var cancellations = 0

    func acquire(for url: URL) async throws {
        waiting += 1
        defer { waiting -= 1 }
        do {
            while true { try await Task.sleep(for: .seconds(3_600)) }
        } catch {
            cancellations += 1
            throw CancellationError()
        }
    }
}

/// Counts calls across threads (a stub's responder runs on the session's loading thread).
final class CallCounter: Sendable {
    private let count = Mutex(0)

    /// The number of this call, from 1.
    func next() -> Int {
        count.withLock { value in
            value += 1
            return value
        }
    }
}

/// One answer of `ForumPageHandler`: a status, headers besides the HTML Content-Type, and the page. `before` runs
/// first (awaited) with the WebView that asked; the tests write what the forum would set into its cookie store there
/// (WebKit does not store a custom scheme's `Set-Cookie`). `setCookies` go into that store only when the answer is
/// delivered, as a real answer's `Set-Cookie` would: not for a request WebKit stopped meanwhile, nor for one whose
/// WebView is gone (its page closed, so its loads are over). With `gate`, the answer waits for it to open first,
/// without holding the WebView (a late answer).
@MainActor struct PageAnswer {
    var status: Int
    var headers: [String: String]
    var body: String
    var setCookies: [HTTPCookie]
    var gate: Gate?
    var before: (@MainActor (WKWebView) async -> Void)?
    /// The load fails with this error instead of being answered.
    var failure: URLError.Code?

    init(
        status: Int = 200, headers: [String: String] = [:], body: String, setCookies: [HTTPCookie] = [],
        gate: Gate? = nil, before: (@MainActor (WKWebView) async -> Void)? = nil, failure: URLError.Code? = nil
    ) {
        self.failure = failure
        self.status = status
        self.headers = headers
        self.body = body
        self.setCookies = setCookies
        self.gate = gate
        self.before = before
    }

    /// A made-up Cloudflare challenge: 403 with `cf-mitigated: challenge`. With `reloads`, the page's own script
    /// reloads it after 100 ms, as a challenge does once it is solved; otherwise it never moves.
    static func challenge(reloads: Bool) -> PageAnswer {
        let script = reloads ? "<script>setTimeout(function () { location.reload() }, 100)</script>" : ""
        return PageAnswer(
            status: 403, headers: ["cf-mitigated": "challenge"],
            body: "<html><head><title>Just a moment...</title></head><body>Fake challenge\(script)</body></html>"
        )
    }
}

/// Serves the forum pages from the custom scheme `eros-test://forums/…`: the profile page, the login page and the
/// login form. `respond(request)` gives the answer; nil leaves the request unanswered (for timeouts).
///
/// WebKit hands a custom scheme's answer to the navigation delegate without its status and headers, so the handler
/// tells `BackgroundPage` the HTTP answer it gave (`HTTPAnswerReporting`, for tests only).
@MainActor final class ForumPageHandler: NSObject, WKURLSchemeHandler, HTTPAnswerReporting {
    nonisolated static let scheme = "eros-test"
    nonisolated static let loginPage = URL(string: "eros-test://forums/index.php?act=Login&CODE=00")!
    nonisolated static let form = URL(string: "eros-test://forums/index.php?act=Login&CODE=01")!

    nonisolated static func profile(_ memberID: Int) -> URL {
        URL(string: "eros-test://forums/index.php?showuser=\(memberID)")!
    }

    /// What the WebView that asked looked like at the time.
    struct Facts {
        let customUserAgent: String?
        let applicationName: String?
        let userScriptCount: Int
        let dataStore: WKWebsiteDataStore
    }

    /// The requests received, oldest first (method, headers and body as WebKit handed them over).
    private(set) var received: [URLRequest] = []
    private(set) var facts: [Facts] = []
    /// The WebView of the latest request, weakly.
    private(set) weak var webView: WKWebView?
    var respond: @MainActor (URLRequest) -> PageAnswer?
    private var answers: [URL: HTTPURLResponse] = [:]
    private var stoppedTasks: Set<ObjectIdentifier> = []

    /// The URLs received, oldest first.
    var requests: [URL] { received.compactMap(\.url) }

    init(respond: @escaping @MainActor (URLRequest) -> PageAnswer?) {
        self.respond = respond
    }

    func httpAnswer(for url: URL) -> HTTPURLResponse? {
        answers[url]
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard let url = request.url else { return }
        received.append(request)
        self.webView = webView
        facts.append(Facts(
            customUserAgent: webView.customUserAgent,
            applicationName: webView.configuration.applicationNameForUserAgent,
            userScriptCount: webView.configuration.userContentController.userScripts.count,
            dataStore: webView.configuration.websiteDataStore
        ))
        guard let answer = respond(request) else { return }
        if let failure = answer.failure {
            urlSchemeTask.didFailWithError(URLError(failure))
            return
        }
        guard answer.before != nil || !answer.setCookies.isEmpty || answer.gate != nil else {
            send(answer, for: url, to: urlSchemeTask)
            return
        }
        let store = webView.configuration.websiteDataStore
        Task { [weak webView] in
            if let gate = answer.gate { await gate.wait() }
            if let before = answer.before, let webView { await before(webView) }
            // WebKit raises an exception for a task answered after it was stopped. It does not tell the handler when
            // the WebView goes right after `stopLoading()` (measured): a released WebView counts as stopped too.
            guard webView != nil, !stoppedTasks.contains(ObjectIdentifier(urlSchemeTask)) else { return }
            if !answer.setCookies.isEmpty { await store.httpCookieStore.setCookies(answer.setCookies) }
            guard webView != nil, !stoppedTasks.contains(ObjectIdentifier(urlSchemeTask)) else { return }
            send(answer, for: url, to: urlSchemeTask)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        stoppedTasks.insert(ObjectIdentifier(urlSchemeTask))
    }

    private func send(_ answer: PageAnswer, for url: URL, to task: any WKURLSchemeTask) {
        let headers = ["Content-Type": "text/html; charset=utf-8"].merging(answer.headers) { $1 }
        guard let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers
        ) else { return }
        answers[url] = response
        task.didReceive(response)
        task.didReceive(Data(answer.body.utf8))
        task.didFinish()
    }
}

/// A session cookie for `domain` (".e-hentai.org", or a host for a host-only one).
@MainActor func fakeCookie(_ name: String, _ value: String, domain: String = ".e-hentai.org") -> HTTPCookie {
    HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"])!
}

/// Lets WebKit's own teardown run: yields, then polls until `handler` holds no WebView, for at most five seconds (a busy
/// simulator is slow to let go).
@MainActor func waitForRelease(of handler: ForumPageHandler) async {
    for _ in 0..<5 { await Task.yield() }
    for _ in 0..<250 where handler.webView != nil { try? await Task.sleep(for: .milliseconds(20)) }
}

/// Polls `condition` every 20 ms for at most `limit`; true once it holds.
@MainActor func eventually(within limit: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// A reference a test fills in after the object it refers to is made (a page answer that acts on the harness's store).
@MainActor final class Box<Value: AnyObject> {
    weak var value: Value?
}

/// Holds every `wait()` until `open()`; once open, `wait()` returns at once.
@MainActor final class Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var hasWaiters: Bool { !waiting.isEmpty }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let held = waiting
        waiting = []
        for continuation in held { continuation.resume() }
    }
}

/// Starts WebKit's processes: two WKWebViews, one after the other, each on a store of its own, load about:blank and
/// run a script, then go.
///
/// Measured on the iOS 27.2 simulator: the first WebView of a test process takes about 2 s to make its first request,
/// and the one right after a single warm-up WebView still 0.5–1.5 s; from the next one on about 0.5 s. So the first
/// timing-sensitive test of a run would otherwise spend most of a 1 s limit (`BackgroundPageTests`) before its page is
/// even asked for. Loads nothing from any site.
@MainActor enum WebContentWarmUp {
    static func run() async {
        for _ in 0..<2 {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            _ = await eventually { !webView.isLoading }
            _ = try? await webView.evaluateJavaScript("1", contentWorld: .defaultClient)
        }
    }
}

/// A suite trait for the suites with tight limits on WebView loads (the 1 s ones of `BackgroundPageTests`):
/// `WebContentWarmUp.run()` once, before the suite's first test. ErosTests run one test after another anyway (the
/// scheme does not run them in parallel): this is about the WebKit processes' start-up time, not about order.
struct WarmsUpWebContent: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        await WebContentWarmUp.run()
        try await function()
    }
}

extension WebContentWarmUp {
    /// The time limit of a load whose page must be asked for, or answered, before the time runs out, when the code
    /// under test makes the load's WebView itself (`ForumProfileLoader`, `WebPasswordLogin`): the warm-up does not
    /// start that WebView's web content process, which then starts within the limit. That took about 0.5 s on a quiet
    /// simulator, but 2–4.5 s for every such load on a host short of memory, in whole
    /// `ErosTests` runs and in one suite alone; limits of 1 and 3 s then failed. 10 s leaves about twice the
    /// slowest.
    nonisolated static let firstAnswerLimit = Duration.seconds(10)
}

extension Trait where Self == WarmsUpWebContent {
    /// See `WarmsUpWebContent`.
    static var warmsUpWebContent: Self { Self() }
}

/// The WebKit store calls of a `WebSessionBridge` (`WebStoreAccess`), on a non-persistent store of its own, that a test
/// can hold: a call of a kind in `holding` waits until `release()`, as a call into a WebKit process that hangs does,
/// then goes on to the store. Every call is recorded when it begins and when it ends ("begin allCookies", …).
///
/// A held call ignores cancellation, as WebKit's do. So that code that waits for one cannot hang a whole test run, a
/// held call goes on by itself after `longestHold` (far beyond every time limit the tests give).
@MainActor final class ControlledWebStore: WebStoreAccess {
    enum Call: String, Sendable {
        case allCookies, setCookies, deleteCookie, removeAllData
    }

    /// How long a held call waits for `release()` at most.
    nonisolated static let longestHold = Duration.seconds(20)

    let dataStore = WKWebsiteDataStore.nonPersistent()
    /// The kinds of call that wait for `release()`.
    var holding: Set<Call>
    /// "begin <call>" and "end <call>", oldest first.
    private(set) var events: [String] = []
    private var held: [Call: Int] = [:]
    private let gate = Gate()

    init(holding: Set<Call> = []) {
        self.holding = holding
    }

    /// The calls begun so far, oldest first.
    var calls: [Call] {
        events.compactMap { $0.hasPrefix("begin ") ? Call(rawValue: String($0.dropFirst("begin ".count))) : nil }
    }

    /// Whether a call of `kind` waits for `release()` now.
    func isHolding(_ kind: Call) -> Bool {
        (held[kind] ?? 0) > 0
    }

    /// Lets every held call, and every later one, go on.
    func release() {
        holding = []
        gate.open()
    }

    func allCookies() async -> [HTTPCookie] {
        await begin(.allCookies)
        defer { end(.allCookies) }
        return await dataStore.httpCookieStore.allCookies()
    }

    func setCookies(_ cookies: [HTTPCookie]) async {
        await begin(.setCookies)
        await dataStore.httpCookieStore.setCookies(cookies)
        end(.setCookies)
    }

    func deleteCookie(_ cookie: HTTPCookie) async {
        await begin(.deleteCookie)
        await dataStore.httpCookieStore.deleteCookie(cookie)
        end(.deleteCookie)
    }

    func removeAllData() async {
        await begin(.removeAllData)
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        end(.removeAllData)
    }

    private func begin(_ call: Call) async {
        events.append("begin \(call.rawValue)")
        guard holding.contains(call) else { return }
        held[call, default: 0] += 1
        let gate = gate
        let failSafe = Task {
            guard (try? await Task.sleep(for: Self.longestHold)) != nil else { return }
            gate.open()
        }
        await gate.wait()
        failSafe.cancel()
        held[call, default: 1] -= 1
    }

    private func end(_ call: Call) {
        events.append("end \(call.rawValue)")
    }
}

extension WebSessionBridge {
    /// The WebView store's time in the tests that are not about the time: the UI testing environments' own
    /// (`AppEnvironment.uiTestingStoreTimeout`), so that a busy host, where a real `WKHTTPCookieStore` call took over
    /// 10 s, does not fail them (M2 re-review I-2). The tests about the time give their own.
    nonisolated static let roomyTestTimeout = AppEnvironment.uiTestingStoreTimeout
}

/// The test helpers' own calls on a real `WKHTTPCookieStore` (reading what the WebView holds, putting a cookie in),
/// with a deadline (M2 re-review F2 fix 1, M-b). They go past the bridge and its time: a WebKit that stopped answering
/// would hold the test until its time limit ends the test process, and where it failed would be lost. After `limit`
/// an issue is recorded and the answer is one nothing passes by: `allCookies` gives one made-up cookie of the site
/// (`timedOutCookie`: the store is neither empty nor free of the site's cookies), `setCookie` throws.
@MainActor enum WebKitTestCalls {
    static let limit: Duration = .seconds(15)

    /// What `allCookies(of:)` gives once the store has not answered in time.
    static let timedOutCookie = HTTPCookie(properties: [
        .name: "eros-test-helper-timed-out", .value: "timed-out", .domain: ".e-hentai.org", .path: "/",
    ])!

    /// The store's cookies, or `[timedOutCookie]` (an issue recorded) when it does not answer within `limit`.
    static func allCookies(
        of store: WKHTTPCookieStore, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [HTTPCookie] {
        do {
            return try await WebKitDeadline.run(limit) { await store.allCookies() }
        } catch {
            record(error, sourceLocation: sourceLocation)
            return [timedOutCookie]
        }
    }

    /// Puts `cookie` into the store; records an issue and throws when it does not answer within `limit`.
    static func setCookie(
        _ cookie: HTTPCookie, in store: WKHTTPCookieStore, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        do {
            try await WebKitDeadline.run(limit) { await store.setCookie(cookie) }
        } catch {
            record(error, sourceLocation: sourceLocation)
            throw error
        }
    }

    private static func record(_ error: any Error, sourceLocation: SourceLocation) {
        if error is WebKitDeadline.TimedOut {
            Issue.record("The WebKit store did not answer within 15 s (test helper)", sourceLocation: sourceLocation)
        } else {
            Issue.record(error, "The WebKit store call ended (test helper)", sourceLocation: sourceLocation)
        }
    }
}
