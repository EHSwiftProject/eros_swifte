import EHModels
import EHNetwork
import Foundation
import Nuke
import Security
import Synchronization
import SwiftUI
import Testing
import UIKit
import WebKit

@testable import Eros

/// The account flows of `AppEnvironment` in UI testing mode (in-memory vault, ledger and UA cache): URLSession requests
/// are answered by `StubURLProtocol`; the forum pages the background WebView loads (the profile page, the login page
/// and the login form) by a custom scheme (`eros-test://`, `ForumPageHandler`); the web login page is about:blank and
/// the UA probe is a stub. Nothing reaches the network. Every cookie value and name is made up ("…-fake-…", member id
/// 1234567).
///
/// Each test has five minutes (`.timeLimit`): some hold a page or a WebKit store call until they let it go, and one
/// that never lets go must fail at the limit, not hang the run (the test process is then ended and started again
/// for the tests after it); five, as WebKit's processes are slow on a busy host (an account flow test once took
/// 143 s under a heavy load), and as `scripts/test.sh` gives a test by default.
@MainActor @Suite(.timeLimit(.minutes(5))) struct AccountFlowTests {
    private static let memberID = 1_234_567
    private static let passHash = "0123456789abcdef0123456789abcdef"
    private static let identity = [CookieNames.memberID: String(memberID), CookieNames.passHash: passHash]
    private static let probedUserAgent =
        "Mozilla/5.0 (FakePhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    private static let identityHeader = "ipb_member_id=\(memberID); path=/; domain=.e-hentai.org, "
        + "ipb_pass_hash=\(passHash); path=/; domain=.e-hentai.org"
    private static let avatarURL = URL(string: "https://forums.e-hentai.org/uploads/av-fake.jpg")!
    private static let hathURL = URL(string: "https://abc.hath.network/h/fake-0001/av-fake.jpg")!

    private static let profilePage = """
        <html><body><div id="profile"><div id="profilename"><font>Fake Nickname</font></div>\
        <div>x</div><div><img src="uploads/av-fake.jpg"></div></div></body></html>
        """

    private struct ProbeFailure: Error {}

    /// What the UA probe saw while it ran.
    @MainActor private final class ProbeLog {
        var calls = 0
        var requestsDuringProbe: Int?
        var readyDuringProbe: Bool?
        var stub: StubSession?
        weak var environment: AppEnvironment?
    }

    @MainActor private final class Counter {
        var value = 0
    }

    /// What happened, in order.
    @MainActor private final class EventLog {
        var entries: [String] = []
    }

    /// A probe that waits until the test releases it.
    @MainActor private final class ProbeGate {
        private var continuation: CheckedContinuation<String, any Error>?
        var isWaiting: Bool { continuation != nil }

        func value() async throws -> String {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func release(_ value: String) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// A vault whose writes fail (as a Keychain that cannot be written) while `writesFail`.
    private final class WriteFailingVault: CredentialVault {
        let writesFail = Mutex(false)
        private let inner = InMemoryVault()

        func read() throws -> Data? { try inner.read() }

        func write(_ data: Data) throws {
            if writesFail.withLock({ $0 }) { throw KeychainError(status: errSecInteractionNotAllowed) }
            try inner.write(data)
        }

        func delete() throws { try inner.delete() }
    }

    /// A vault whose reads fail (as a Keychain before the first unlock) while `isFailing`.
    private final class FlakyVault: CredentialVault {
        let isFailing = Mutex(true)
        private let inner = InMemoryVault()

        func read() throws -> Data? {
            if isFailing.withLock({ $0 }) { throw KeychainError(status: errSecInteractionNotAllowed) }
            return try inner.read()
        }

        func write(_ data: Data) throws { try inner.write(data) }
        func delete() throws { try inner.delete() }
    }

    /// A vault whose delete fails (as a Keychain before the first unlock) while `deleteFails`; holds bytes from the start.
    private final class DeleteFailingVault: CredentialVault {
        let deleteFails = Mutex(true)
        private let inner = InMemoryVault()

        func read() throws -> Data? { try inner.read() }
        func write(_ data: Data) throws { try inner.write(data) }

        func delete() throws {
            if deleteFails.withLock({ $0 }) { throw KeychainError(status: errSecInteractionNotAllowed) }
            try inner.delete()
        }
    }

    private struct Harness {
        let environment: AppEnvironment
        let stub: StubSession
        let pages: ForumPageHandler

        /// "METHOD url" of every forum page the WebViews asked for.
        @MainActor func pageRequests() -> [String] {
            pages.received.map { "\($0.httpMethod ?? "?") \($0.url?.absoluteString ?? "?")" }
        }

        /// The WebView store's cookies, read past the bridge within `WebKitTestCalls.limit`.
        func webCookies(sourceLocation: SourceLocation = #_sourceLocation) async -> [HTTPCookie] {
            await WebKitTestCalls.allCookies(
                of: environment.bridge.dataStore.httpCookieStore, sourceLocation: sourceLocation
            )
        }

        /// Puts a cookie into the WebView store, past the bridge, within `WebKitTestCalls.limit`.
        func put(
            _ name: String, _ value: String, domain: String, sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            let cookie = try #require(HTTPCookie(properties: [
                .name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE",
            ]))
            try await WebKitTestCalls.setCookie(
                cookie, in: environment.bridge.dataStore.httpCookieStore, sourceLocation: sourceLocation
            )
        }

        func jar(_ site: EHSite) async -> [String: String] {
            await environment.cookies.snapshot().cookies[site] ?? [:]
        }

        /// Waits for the forum profile read the last login started, if any (the logins return without it).
        func profileRead() async {
            await environment.forumProfileRead?.value
        }

        /// Every kind of data the WebView store holds, as "<display name> <type>" (sorted).
        @MainActor func webDataRecords() async -> [String] {
            let records = await environment.bridge.dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            return records.flatMap { record in record.dataTypes.map { "\(record.displayName) \($0)" } }.sorted()
        }
    }

    /// `webStore` and `webStoreTimeout`: the WebView session store's calls and their time (WebKit's own, and the UI
    /// testing environment's roomy time, by default).
    private static func makeHarness(
        vault: any CredentialVault = InMemoryVault(), cache: any UserAgentCache = InMemoryUserAgentCache(),
        systemVersion: String = "27.0", throttle: (any RequestThrottle)? = nil, responseCache: ResponseCache? = nil,
        launchMarker: (any LaunchMarker)? = nil,
        probe: @escaping @MainActor () async throws -> String = { probedUserAgent },
        page: @escaping @MainActor (URLRequest) -> PageAnswer? = forum(),
        responder: @escaping @Sendable (URLRequest) throws -> StubResponse = site(),
        webStore: (any WebStoreAccess)? = nil, webStoreTimeout: Duration? = nil
    ) -> Harness {
        let stub = StubURLProtocol.install(responder)
        let pages = ForumPageHandler(respond: page)
        let environment = AppEnvironment(
            uiTesting: true, sessionConfigurator: stub.configurator,
            forumSchemeHandler: (pages, ForumPageHandler.scheme), userAgentCache: cache,
            systemVersion: systemVersion, userAgentProbe: probe, vault: vault, throttle: throttle,
            responseCache: responseCache, launchMarker: launchMarker, webStore: webStore,
            webStoreTimeout: webStoreTimeout
        )
        return Harness(environment: environment, stub: stub, pages: pages)
    }

    /// The forum pages the background WebView loads: the profile page answers `profile`, the login page a form, and the
    /// login form `form` (by default the welcome page after the identity pair, and `extra`, went into the WebView store,
    /// as the forum's Set-Cookie would).
    private static func forum(
        profile: PageAnswer? = PageAnswer(body: profilePage), form: PageAnswer? = nil, extra: [HTTPCookie] = []
    ) -> @MainActor (URLRequest) -> PageAnswer? {
        { request in
            switch request.url {
            case ForumPageHandler.profile(memberID)?: profile
            case ForumPageHandler.loginPage?: PageAnswer(body: "<html><body><form>Fake login form</form></body></html>")
            case ForumPageHandler.form?: form ?? signsIn(extra: extra)
            default: PageAnswer(status: 404, body: "<html><body>Fake 404</body></html>")
            }
        }
    }

    private static func signsIn(extra: [HTTPCookie]) -> PageAnswer {
        PageAnswer(body: "<html><body>Fake welcome</body></html>") { webView in
            let cookies = [
                fakeCookie(CookieNames.memberID, String(memberID)), fakeCookie(CookieNames.passHash, passHash),
            ] + extra
            await webView.configuration.websiteDataStore.httpCookieStore.setCookies(cookies)
        }
    }

    /// The forum login over URLSession (which nothing should send any more: the password login posts the form in the
    /// background WebView) and both settings pages (`uconfig`, a 404 unless given: the profile run ends `.failed` at
    /// once).
    private static func site(
        uconfig: StubResponse = StubResponse(status: 404)
    ) -> @Sendable (URLRequest) throws -> StubResponse {
        let header = identityHeader
        return { request in
            switch request.url {
            case EHEndpoints.forumLogin?:
                return StubResponse(headers: ["Set-Cookie": header], body: Data("<html>Fake welcome</html>".utf8))
            case EHEndpoints.uconfig(site: .eh)?, EHEndpoints.uconfig(site: .ex)?:
                return uconfig
            default:
                throw URLError(.badURL)
            }
        }
    }

    /// The avatar, a PNG; with `redirect`, the forum URL answers 302 to the H@H node, which serves it.
    /// The avatar URL answers the statuses in turn (the last one from then on); a 200 is a PNG.
    private static func avatarAnswers(_ statuses: [Int]) -> @Sendable (URLRequest) throws -> StubResponse {
        let png = pngData()
        let avatar = avatarURL
        let calls = CallCounter()
        return { request in
            guard request.url == avatar else { throw URLError(.badURL) }
            let status = statuses[min(calls.next(), statuses.count) - 1]
            return status == 200
                ? StubResponse(headers: ["Content-Type": "image/png"], body: png) : StubResponse(status: status)
        }
    }

    private static func avatarSite(redirect: Bool) -> @Sendable (URLRequest) throws -> StubResponse {
        let png = pngData()
        let (avatar, hath) = (avatarURL, hathURL)
        return { request in
            let image = StubResponse(headers: ["Content-Type": "image/png"], body: png)
            if request.url == avatar { return redirect ? StubResponse(status: 302, redirectTo: hath) : image }
            if redirect, request.url == hath { return image }
            throw URLError(.badURL)
        }
    }

    // MARK: - First launch after an install

    /// Puts a made-up old session (member 7654321) into `vault` and returns its bytes.
    private static func seedOldSession(_ vault: any CredentialVault) async throws -> Data {
        let store = CookieStore(vault: vault)
        try await store.load()
        try await store.set(
            [CookieNames.memberID: "7654321", CookieNames.passHash: passHash], for: [.eh, .ex]
        )
        return try #require(try vault.read())
    }

    @Test func firstLaunchClearsAnOldSession() async throws {
        let vault = InMemoryVault()
        _ = try await Self.seedOldSession(vault)
        let marker = InMemoryLaunchMarker(hasLaunched: false)
        let h = Self.makeHarness(vault: vault, launchMarker: marker)
        await h.environment.start()
        #expect(!h.environment.isLoggedIn)
        #expect(h.environment.session == .empty)
        #expect(try vault.read() == nil)
        #expect(await marker.hasLaunched())
    }

    @Test func laterLaunchesKeepTheSession() async throws {
        let vault = InMemoryVault()
        let bytes = try await Self.seedOldSession(vault)
        let h = Self.makeHarness(vault: vault, launchMarker: InMemoryLaunchMarker(hasLaunched: true))
        await h.environment.start()
        #expect(h.environment.isLoggedIn)
        #expect(try vault.read() == bytes)
    }

    @Test func failedClearLeavesTheStoreUnloaded() async throws {
        let vault = DeleteFailingVault()
        let bytes = try await Self.seedOldSession(vault)
        let marker = InMemoryLaunchMarker(hasLaunched: false)
        let h = Self.makeHarness(vault: vault, launchMarker: marker)
        await h.environment.start()
        #expect(h.environment.isReady)
        #expect(!h.environment.isLoggedIn)
        #expect(await !h.environment.cookies.isLoaded)
        #expect(await !marker.hasLaunched())
        #expect(try vault.read() == bytes)
    }

    @Test func loginRetriesTheFirstLaunchClear() async throws {
        let vault = DeleteFailingVault()
        _ = try await Self.seedOldSession(vault)
        let marker = InMemoryLaunchMarker(hasLaunched: false)
        let h = Self.makeHarness(vault: vault, launchMarker: marker)
        await h.environment.start()
        vault.deleteFails.withLock { $0 = false }
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        await h.profileRead()
        #expect(await marker.hasLaunched())
        let stored = try #require(try vault.read())
        #expect(String(decoding: stored, as: UTF8.self).contains(String(Self.memberID)))
        #expect(!String(decoding: stored, as: UTF8.self).contains("7654321"))
    }

    /// The login tries the first launch's clear again, which still fails: the login throws its error, the marker
    /// stays unset, nothing is sent and the login has ended.
    @Test func loginFailsWhileTheFirstLaunchClearStillFails() async throws {
        let vault = DeleteFailingVault()
        let bytes = try await Self.seedOldSession(vault)
        let marker = InMemoryLaunchMarker(hasLaunched: false)
        let h = Self.makeHarness(vault: vault, launchMarker: marker)
        await h.environment.start()
        await #expect(throws: KeychainError.self) {
            try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        }
        #expect(await !marker.hasLaunched())
        #expect(!h.environment.isLoggingIn)
        #expect(!h.environment.isLoggedIn)
        #expect(try vault.read() == bytes)
        #expect(h.stub.requests().isEmpty)
    }

    @Test func testEnvironmentsSkipTheClear() async throws {
        let vault = InMemoryVault()
        _ = try await Self.seedOldSession(vault)
        let environment = AppEnvironment(uiTesting: true, vault: vault)
        await environment.start()
        #expect(environment.isLoggedIn)
    }

    // MARK: - Logins

    @Test func logOutClearsTheStoreAndTheWebView() async throws {
        let vault = InMemoryVault()
        let h = Self.makeHarness(vault: vault)
        await h.environment.start()
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        await h.profileRead()
        #expect(h.environment.isLoggedIn)
        #expect(h.environment.session.account?.displayName == "Fake Nickname")
        // Both sites' cookies in the WebView (the profile page pushed the jars), and another domain's.
        try await h.put("ipb_session_id", "session-fake-0001", domain: "forums.e-hentai.org")
        try await h.put(CookieNames.igneous, "igneous-fake-0002", domain: ".exhentai.org")
        try await h.put("other", "other-fake-0003", domain: ".example.com")
        try await h.put(CookieNames.clearance, "clearance-fake-0004", domain: "challenges.cloudflare.com")
        let before = await h.webCookies()
        #expect(before.contains { $0.domain == ".e-hentai.org" && $0.name == CookieNames.memberID })
        #expect(before.contains { $0.domain == ".exhentai.org" && $0.name == CookieNames.memberID })

        try await h.environment.logOut()
        #expect(h.environment.session == .empty)
        #expect(!h.environment.isLoggedIn)
        #expect(h.environment.forumProfileStep == nil)
        #expect(await h.environment.cookies.snapshot() == .empty)
        #expect(try vault.read() == nil)
        // Every site's cookies go, not just both sites' (the WebView store keeps nothing of the account).
        #expect(await h.webCookies().isEmpty)
    }

    /// Logging out removes every kind of data the WebView store holds, of every site: local storage too, not only
    /// cookies. The page is loaded from a string (its base URL a reserved .invalid host), so nothing is requested.
    @Test func logOutRemovesEveryKindOfWebsiteData() async throws {
        let h = Self.makeHarness()
        await h.environment.start()
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        await h.profileRead()
        try await h.put("other", "other-fake-0001", domain: ".example.com")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = h.environment.bridge.dataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(
            "<html><body><script>localStorage.setItem('fake', 'storage-fake-0002')</script></body></html>",
            baseURL: URL(string: "https://eros-test.invalid/")
        )
        let localStorage = WKWebsiteDataTypeLocalStorage
        #expect(await eventually { await h.webDataRecords().contains { $0.hasSuffix(localStorage) } })
        #expect(await h.webDataRecords().contains { $0.hasSuffix(WKWebsiteDataTypeCookies) })

        try await h.environment.logOut()
        #expect(await h.webDataRecords().isEmpty)
        #expect(await h.webCookies().isEmpty)
        withExtendedLifetime(webView) {}
    }

    /// The 403 page even has a #profilename: the status decides (the handler reports it, see `ForumPageHandler`).
    @Test func failedProfileLoadKeepsTheUsername() async throws {
        let h = Self.makeHarness(page: Self.forum(profile: PageAnswer(status: 403, body: Self.profilePage)))
        await h.environment.start()
        try await h.environment.logIn(username: "fake-user", password: "fake-password")
        await h.profileRead()
        #expect(h.environment.isLoggedIn)
        let account = try #require(h.environment.session.account)
        #expect(account.method == .password)
        #expect(account.username == "fake-user")
        #expect(account.displayName == nil)
        #expect(account.avatarURL == nil)
        #expect(AccountDisplay.resolve(account).name == "fake-user")
        #expect(h.environment.forumProfileStep == .unavailable(.page(.httpStatus(403))))
        // Loaded once, never retried.
        #expect(h.pages.requests.filter { $0 == ForumPageHandler.profile(Self.memberID) }.count == 1)
        #expect(h.stub.requests().compactMap(\.url) == [EHEndpoints.uconfig(site: .eh)])
    }

    @Test func failedProfileLoadRecordsTheReason() async throws {
        let h = Self.makeHarness(page: Self.forum(profile: PageAnswer(status: 403, body: "<html><body>Fake</body></html>")))
        await h.environment.start()
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        await h.profileRead()
        #expect(h.environment.isLoggedIn)
        #expect(h.environment.forumProfileStep == .unavailable(.page(.httpStatus(403))))
        #if DEBUG
        let report = await SessionDiagnostics.collect(h.environment)
        #expect(report.forumProfile == "unavailable (httpStatus 403)")
        #endif
    }

    // MARK: - Password login (background WebView, account A3b)

    @Test func passwordLoginGoesThroughTheWebView() async throws {
        let password = "fake-password-a3b9"
        let vault = InMemoryVault()
        let h = Self.makeHarness(vault: vault)
        await h.environment.start()
        try await h.environment.logIn(username: "fake-user", password: password)
        #expect(h.environment.isLoggedIn)
        await h.profileRead()
        let account = try #require(h.environment.session.account)
        #expect(account.method == .password)
        #expect(account.username == "fake-user")
        #expect(await h.jar(.eh) == Self.identity)
        #expect(await h.jar(.ex) == Self.identity)
        // The login page, the form, then the profile page once; URLSession sent no forum login.
        #expect(h.pageRequests() == [
            "GET \(ForumPageHandler.loginPage.absoluteString)", "POST \(ForumPageHandler.form.absoluteString)",
            "GET \(ForumPageHandler.profile(Self.memberID).absoluteString)",
        ])
        let post = h.pages.received[1]
        let body = String(decoding: post.httpBody ?? Data(), as: UTF8.self)
        // Bound to a Bool first, as below: a failure must not print the form, password and all.
        let carriesUsername = body.contains("UserName=fake-user&")
        #expect(carriesUsername)
        #expect(!h.stub.requests().contains { $0.url == EHEndpoints.forumLogin })
        #expect(h.stub.requests().compactMap(\.url) == [EHEndpoints.uconfig(site: .eh)])
        #expect(h.environment.forumProfileStep == .loaded)
        #expect(account.displayName == "Fake Nickname")

        // The password went out in the form's body, and nowhere else. Bound to a Bool first, so a
        // failure prints no value.
        let inBody = body.contains("PassWord=\(password)&")
        #expect(inBody)
        let inURLs = h.pages.received.contains { ($0.url?.absoluteString ?? "").contains(password) }
            || h.stub.requests().contains { ($0.url?.absoluteString ?? "").contains(password) }
        #expect(!inURLs)
        let inHeaders = (h.pages.received + h.stub.requests()).contains { request in
            (request.allHTTPHeaderFields ?? [:]).contains { $0.key.contains(password) || $0.value.contains(password) }
        }
        #expect(!inHeaders)
        let inVault = try vault.read().map { $0.range(of: Data(password.utf8)) != nil } ?? false
        #expect(!inVault)
        let snapshot = await h.environment.cookies.snapshot()
        let texts = [
            String(describing: snapshot), String(reflecting: snapshot), String(describing: h.environment.session),
            String(describing: account), String(reflecting: account),
            String(describing: h.environment.forumProfileStep),
        ]
        let inState = texts.contains { $0.contains(password) }
        #expect(!inState)
        let inWebView = await h.webCookies().contains { $0.value.contains(password) || $0.name.contains(password) }
        #expect(!inWebView)
        #if DEBUG
        let report = String(describing: await SessionDiagnostics.collect(h.environment))
        let inDiagnostics = report.contains(password)
        #expect(!inDiagnostics)
        #endif
    }

    /// The forum answers the form with a bare-text IP ban notice and no identity: the user is told about the ban
    ///, not to check the password; nothing is written, no profile read starts.
    @Test func bannedPasswordLoginSaysSo() async throws {
        let notice = "Your IP address has been temporarily banned for excessive pageloads which indicates that you "
            + "are using automated mirroring/harvesting software. The ban expires in 2 hours and 1 minute"
        let h = Self.makeHarness(page: Self.forum(form: PageAnswer(body: notice)))
        await h.environment.start()
        do {
            try await h.environment.logIn(username: "fake-user", password: "fake-password")
            Issue.record("a ban notice signed in")
        } catch {
            let isBan = if case EHNetworkError.issue(.banned(remaining: .seconds(7_260)))? = error as? EHNetworkError {
                true
            } else {
                false
            }
            #expect(isBan, Comment(rawValue: "\(type(of: error))"))
            #expect(LoginFailureMessage.text(for: error) == "Your IP address is temporarily banned. Try again later.")
        }
        // The forum's ban is the IP's: both sites pause (the environment's password login reports to its breaker).
        #expect(await h.environment.breaker.current()?.reason == .banned)
        #expect(!h.environment.isLoggedIn)
        #expect(h.environment.session == .empty)
        #expect(h.environment.forumProfileRead == nil)
        #expect(h.environment.forumProfileStep == nil)
        #expect(h.pageRequests() == [
            "GET \(ForumPageHandler.loginPage.absoluteString)", "POST \(ForumPageHandler.form.absoluteString)",
        ])
        #expect(h.stub.requests().isEmpty)
    }

    @Test func passwordLoginNeedingAPersonThrowsNeedsWebLogin() async throws {
        let h = Self.makeHarness(page: Self.forum(form: .challenge(reloads: true)))
        await h.environment.start()
        await #expect(throws: WebPasswordLoginError.needsWebLogin) {
            try await h.environment.logIn(username: "fake-user", password: "fake-password")
        }
        #expect(!h.environment.isLoggedIn)
        #expect(h.environment.session == .empty)
        #expect(h.environment.forumProfileStep == nil)
        #expect(h.stub.requests().isEmpty)
        #expect(h.pageRequests() == [
            "GET \(ForumPageHandler.loginPage.absoluteString)", "POST \(ForumPageHandler.form.absoluteString)",
        ])
        // The login has ended: the web login it hands over to may begin.
        #expect(!h.environment.isLoggingIn)
        try await h.environment.prepareLogin()
    }

    /// Logging out while a password login's WebView run is going cancels the run: the login ends without an alert,
    /// and the next one is not refused as one in progress.
    @Test func logOutEndsThePasswordLogin() async throws {
        let gate = Gate()
        let h = Self.makeHarness(page: { request in
            guard request.url == ForumPageHandler.loginPage else { return Self.forum()(request) }
            return PageAnswer(body: "<html><body><form>Fake login form</form></body></html>", gate: gate)
        })
        await h.environment.start()
        let environment = h.environment
        let login = Task { try await environment.logIn(username: "fake-user", password: "fake-password") }
        // The page's WebView starts a web content process of its own first (`WebContentWarmUp.firstAnswerLimit`).
        #expect(await eventually(within: WebContentWarmUp.firstAnswerLimit) { gate.hasWaiters })
        #expect(environment.isLoggingIn)

        try await environment.logOut()
        let result = await login.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(LoginFailureMessage.text(for: CancellationError()) == nil)
        #expect(!environment.isLoggingIn)
        #expect(!environment.isLoggedIn)
        gate.open()
        try await environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        #expect(environment.isLoggedIn)
        await h.profileRead()
    }

    /// On the Chrome fallback the WebView's UA-bound Cloudflare cookies stay out of the jar, as `pull()` keeps them.
    @Test func fallbackModeDropsUserAgentBoundCookies() async throws {
        let h = Self.makeHarness(
            probe: { throw ProbeFailure() },
            page: Self.forum(extra: [
                fakeCookie(CookieNames.clearance, "clearance-fake-0001"), fakeCookie("__cf_bm", "bm-fake-0002"),
                fakeCookie("sk", "sk-fake-0003"),
            ])
        )
        await h.environment.start()
        #expect(!h.environment.canUseWebLogin)
        try await h.environment.logIn(username: "fake-user", password: "fake-password")
        #expect(h.environment.isLoggedIn)
        #expect(await h.jar(.eh) == Self.identity.merging(["sk": "sk-fake-0003"]) { $1 })
        await h.profileRead()
        #expect(await h.jar(.eh) == Self.identity.merging(["sk": "sk-fake-0003"]) { $1 })
        // The WebView keeps them: they are its own.
        #expect(await h.webCookies().contains { $0.name == CookieNames.clearance })
    }

    /// A profile run stopped by a site notice: the login stands, the forum profile page is not loaded.
    @Test func stoppedProfileRunSkipsTheForumProfile() async throws {
        let h = Self.makeHarness(responder: Self.site(uconfig: StubResponse(status: 429)))
        await h.environment.start()
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        #expect(h.environment.isLoggedIn)
        #expect(h.environment.forumProfileStep == .skipped(.tooManyRequests))
        #expect(h.pages.requests.isEmpty)
        #expect(h.stub.requests().compactMap(\.url) == [EHEndpoints.uconfig(site: .eh)])
        #expect(await h.environment.account.profileDiagnostics(for: .eh)?.outcome == .stopped(.tooManyRequests))
        #expect(h.environment.session.account?.displayName == nil)
    }

    /// Cookies an earlier session left in the WebView store do not ride along into the next login's jar.
    @Test func everyLoginStartsWithACleanWebView() async throws {
        let h = Self.makeHarness()
        await h.environment.start()
        try await h.put("ipb_session_id", "leftover-fake-0001", domain: "forums.e-hentai.org")
        try await h.put("sk", "leftover-fake-0002", domain: "forums.e-hentai.org")
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        await h.profileRead()
        #expect(h.environment.forumProfileStep == .loaded)
        let eh = await h.jar(.eh)
        #expect(eh["ipb_session_id"] == nil)
        #expect(eh["sk"] == nil)
        #expect(await !h.webCookies().contains { $0.value.hasPrefix("leftover") })
    }

    /// A cookie store that could not load at launch is loaded again before a login; until it loads, no login starts.
    @Test func aLoginRetriesACookieStoreThatDidNotLoad() async throws {
        let vault = FlakyVault()
        let h = Self.makeHarness(vault: vault)
        await h.environment.start()
        #expect(h.environment.isReady)
        #expect(await !h.environment.cookies.isLoaded)
        #expect(h.environment.session == .empty)
        // The UA waits for the store (adopting it removes cf_* from the jars first).
        #expect(!h.environment.canUseWebLogin)

        await #expect(throws: KeychainError.self) { try await h.environment.prepareLogin() }
        do {
            try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
            Issue.record("the login went on without a loaded cookie store")
        } catch {
            #expect(LoginFailureMessage.text(for: error) == "Could not reach the server.")
        }
        #expect(h.stub.requests().isEmpty)
        #expect(!h.environment.isLoggedIn)

        vault.isFailing.withLock { $0 = false }
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        await h.profileRead()
        #expect(await h.environment.cookies.isLoaded)
        #expect(h.environment.isLoggedIn)
        #expect(h.environment.canUseWebLogin)
        #expect(await h.environment.userAgents.current == Self.probedUserAgent)
        #expect(h.stub.requests().first?.value(forHTTPHeaderField: "User-Agent") == Self.probedUserAgent)
    }

    @Test func loginFailuresReadAsTheBriefSays() {
        let cases: [(any Error, String?)] = [
            (LoginError.rejected, "Login failed. Check your username and password, or try the web login."),
            (LoginError.invalidMemberID, "ipb_member_id must be a number."),
            (LoginError.invalidPassHash, "ipb_pass_hash must be 32 hexadecimal characters."),
            (EHNetworkError.issue(.banned(remaining: nil)), "Your IP address is temporarily banned. Try again later."),
            (EHNetworkError.issue(.banned(remaining: .seconds(600))), "Your IP address is temporarily banned. Try again later."),
            (EHNetworkError.issue(.tooManyRequests), "Too many requests. Try again in a minute."),
            (EHNetworkError.transport(.timedOut), "Could not reach the server."),
            (EHNetworkError.httpStatus(503), "Could not reach the server."),
            (CookieStoreError.notLoaded, "Could not reach the server."),
            (KeychainError(status: errSecInteractionNotAllowed), "Could not reach the server."),
            (WebPasswordLoginError.unreachable, "Could not reach the server."),
            (WebStoreTimeout(), "Could not prepare the login. Try again."),
            (
                WebPasswordLoginError.needsWebLogin,
                "The forum wants a check that only the web login can do, and the web login is unavailable right now."
            ),
            // Refused while another login runs, or ended by logging out: it ends without an alert.
            (CancellationError(), nil),
        ]
        for (error, message) in cases {
            #expect(LoginFailureMessage.text(for: error) == message, Comment(rawValue: "\(error)"))
            // The alert the login screen puts up through the app's alerts says the same, under Login Failed.
            let alert = LoginFailureMessage.alert(for: error)
            #expect(alert?.message == message, Comment(rawValue: "\(error)"))
            #expect(alert.map { $0.title == "Login Failed" && $0.actions.map(\.title) == ["OK"] } ?? true)
        }
    }

    // MARK: - The WebKit store's time (M2 review, topic 3)

    /// A WebKit store that does not answer ends the login's preparation within the store's time (`WebStoreTimeout`),
    /// and the login state with it: the next login is no `CancellationError` (it runs out of time the same way).
    @Test(.timeLimit(.minutes(1))) func prepareLoginEndsWhenTheWebStoreHangs() async throws {
        let webStore = ControlledWebStore(holding: [.allCookies])
        defer { webStore.release() }
        let h = Self.makeHarness(webStore: webStore, webStoreTimeout: .milliseconds(200))
        await h.environment.start()
        let started = ContinuousClock.now
        await #expect(throws: WebStoreTimeout.self) { try await h.environment.prepareLogin() }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(!h.environment.isLoggingIn)
        do {
            try await h.environment.prepareLogin()
            Issue.record("the store answered")
        } catch {
            #expect(error is WebStoreTimeout)
        }
        #expect(!h.environment.isLoggingIn)
    }

    /// The cookie login's values are checked first: a member id that is no number, or a pass hash that is none, is
    /// refused at once, before the login begins and without a call to the WebKit store (slow on a busy device).
    @Test(.timeLimit(.minutes(1))) func cookieLoginValidatesBeforeTouchingTheWebStore() async throws {
        let webStore = ControlledWebStore(holding: [.allCookies, .setCookies, .deleteCookie, .removeAllData])
        defer { webStore.release() }
        let h = Self.makeHarness(webStore: webStore)
        await h.environment.start()
        let started = ContinuousClock.now
        await #expect(throws: LoginError.invalidMemberID) {
            try await h.environment.logIn(memberID: "abc", passHash: Self.passHash)
        }
        await #expect(throws: LoginError.invalidPassHash) {
            try await h.environment.logIn(memberID: String(Self.memberID), passHash: "not-a-pass-hash")
        }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(webStore.calls.isEmpty)
        #expect(!h.environment.isLoggingIn)
        #expect(h.stub.requests().isEmpty)
    }

    /// Logging out shows at once: the session is refreshed before the WebKit store is cleared, and a store that does
    /// not answer holds the logout no longer than its time.
    @Test(.timeLimit(.minutes(1))) func logOutShowsLoggedOutBeforeTheWebStoreAnswers() async throws {
        let webStore = ControlledWebStore(holding: [.removeAllData])
        defer { webStore.release() }
        let limit = Duration.seconds(1)
        let h = Self.makeHarness(webStore: webStore)
        await h.environment.start()
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        await h.profileRead()
        #expect(h.environment.isLoggedIn)
        // Short from here on: the login's store calls (real ones) had the roomy default time, which a busy host
        // needs.
        h.environment.bridge.storeTimeout = limit
        // A thumbnail the account loaded.
        let thumbnail = ImageRequest(url: URL(string: "https://ehgt.org/fake/thumbnail.png"))
        let image = try #require(UIImage(data: Self.pngData()))
        h.environment.images.cache.storeCachedImage(ImageContainer(image: image), for: thumbnail, caches: .memory)

        let environment = h.environment
        let started = ContinuousClock.now
        let logout = Task { try await environment.logOut() }
        #expect(await eventually { webStore.isHolding(.removeAllData) })
        #expect(!environment.isLoggedIn)
        #expect(environment.session == .empty)
        // The images went before the screens showed the logout (and reloaded), not after the WebKit store.
        #expect(!environment.images.cache.containsCachedImage(for: thumbnail, caches: .memory))
        try await logout.value
        #expect(ContinuousClock.now - started < limit + .seconds(2))
        #expect(!environment.isLoggedIn)
    }

    /// A forum profile read held by the WebKit store (its push hangs) ends at once when logging out cancels it: the
    /// logout waits for nothing longer than the store's time (the store's removal, queued behind the push).
    @Test(.timeLimit(.minutes(1))) func logOutIsNotHeldByAHungProfileRead() async throws {
        let webStore = ControlledWebStore()
        defer { webStore.release() }
        let limit = Duration.seconds(3)
        let h = Self.makeHarness(webStore: webStore)
        await h.environment.start()
        webStore.holding = [.setCookies]
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        #expect(await eventually { webStore.isHolding(.setCookies) })
        #expect(h.environment.forumProfileRead != nil)
        // Short from here on (see `logOutShowsLoggedOutBeforeTheWebStoreAnswers`); the push keeps its roomy default
        // time.
        h.environment.bridge.storeTimeout = limit

        let started = ContinuousClock.now
        try await h.environment.logOut()
        #expect(ContinuousClock.now - started < limit + .seconds(2))
        #expect(!h.environment.isLoggedIn)
        #expect(h.environment.forumProfileRead == nil)
        #expect(h.environment.forumProfileStep == nil)
        #expect(h.pages.requests.isEmpty)

        // WebKit answers at last: the push the logout cancelled ends, and the logout's removal, queued behind it and
        // out of time, runs after it all the same. Nothing of the account stays in the WebView store.
        webStore.release()
        #expect(await eventually(within: .seconds(10)) { webStore.events.contains("end removeAllData") })
        let pushEnd = try #require(webStore.events.lastIndex(of: "end setCookies"))
        let removalEnd = try #require(webStore.events.lastIndex(of: "end removeAllData"))
        #expect(pushEnd < removalEnd)
        #expect(await h.webCookies().isEmpty)
    }

    /// The web login's sheet closed while a store call hangs ahead of its clear, which runs out of time: once WebKit
    /// answers, the clear still runs, in its turn, and what the pages left of both sites goes.
    @Test(.timeLimit(.minutes(1))) func closingTheWebLoginBehindAHungCallStillClears() async throws {
        let webStore = ControlledWebStore()
        defer { webStore.release() }
        let h = Self.makeHarness(webStore: webStore)
        await h.environment.start()
        try await h.environment.prepareLogin()
        let session = WebLoginSession(environment: h.environment) { _ in }
        session.start()
        #expect(await eventually { session.webView.url?.absoluteString == "about:blank" && !session.webView.isLoading })
        // What the forum would have set before the user gave up.
        try await h.put(CookieNames.memberID, String(Self.memberID), domain: ".e-hentai.org")

        // A store call that hangs (here a push), then the close, whose clear runs out of time behind it.
        webStore.holding = [.setCookies]
        h.environment.bridge.storeTimeout = .milliseconds(300)
        let bridge = h.environment.bridge
        let push = Task { _ = try? await bridge.push() }
        #expect(await eventually { webStore.isHolding(.setCookies) })
        await session.close()

        webStore.release()
        await push.value
        #expect(await eventually(within: .seconds(10)) {
            await !h.webCookies().contains { EHSite(cookieHost: $0.domain) != nil }
        })
        #expect(webStore.events.last == "end deleteCookie")
    }

    /// The test environments (UI testing, which the hosted tests and the UI tests run) give the WebView store a
    /// roomy time: a busy host must not fail tests that are not about the time; the app keeps ten seconds.
    @Test func testEnvironmentsGiveTheWebStoreRoom() {
        #expect(AppEnvironment(uiTesting: true).bridge.storeTimeout == .seconds(60))
        #expect(AppEnvironment.uiTestingStoreTimeout == .seconds(60))
        #expect(AppEnvironment.webStoreTimeout(uiTesting: true) == WebSessionBridge.roomyTestTimeout)
        #expect(AppEnvironment.webStoreTimeout(uiTesting: false) == .seconds(10))
        #expect(WebSessionBridge.defaultStoreTimeout == .seconds(10))
    }

    // MARK: - Site pause (user decision 2026-11-08)

    /// `sitePause` follows the environment's breaker (browse B3 shows it), and every request of the environment waits
    /// for the breaker: the client's are refused during the pause, without reaching the site.
    @Test func sitePauseFollowsTheBreaker() async throws {
        let h = Self.makeHarness()
        await h.environment.start()
        #expect(h.environment.throttle is BreakerThrottle)
        #expect(h.environment.sitePause == nil)
        let pause = try #require(
            await h.environment.breaker.record(.tooManyRequests, at: URL(string: "https://e-hentai.org/")!)
        )
        #expect(await eventually { h.environment.sitePause?.reason == .tooManyRequests })
        #expect(h.environment.sitePause == pause)
        await #expect(throws: EHNetworkError.paused(pause)) {
            try await h.environment.client.send(EHRequest(url: EHEndpoints.uconfig(site: .ex), site: .ex))
        }
        #expect(h.stub.requests().isEmpty)
    }

    /// A hosted test can give the environment a breaker of its own (a clock it moves): the environment's breaker, the
    /// throttle every request waits for and `sitePause` are that one.
    @Test func injectedBreakerIsTheEnvironments() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let breaker = SiteBreaker(now: { now })
        let stub = StubURLProtocol.install { _ in StubResponse(status: 404) }
        defer { stub.remove() }
        let environment = AppEnvironment(
            uiTesting: true, sessionConfigurator: stub.configurator, userAgentProbe: { Self.probedUserAgent },
            breaker: breaker
        )
        await environment.start()
        #expect(environment.breaker === breaker)
        let pause = try #require(await breaker.record(.tooManyRequests, at: URL(string: "https://e-hentai.org/")!))
        #expect(pause.until == now.addingTimeInterval(60))
        #expect(await eventually { environment.sitePause == pause })
        await #expect(throws: EHNetworkError.paused(pause)) {
            try await environment.client.send(EHRequest(url: EHEndpoints.uconfig(site: .ex), site: .ex))
        }
        #expect(stub.requests().isEmpty)
    }

    /// When the pause ends: the time alone today, the date too on a later day (L063: a ban may last days), as the
    /// lists say it (`ListFailure.expiryText(until:now:calendar:locale:)`).
    @Test func pausedLoginSaysUntilWhen() {
        let today = Date.now
        let later = today.addingTimeInterval(2 * 86_400)
        let cases: [(PauseReason, String)] = [
            (.tooManyRequests, "Too many requests. Requests to E-Hentai and ExHentai are paused until "),
            (.banned, "Your IP address is temporarily banned. Requests to E-Hentai and ExHentai are paused until "),
        ]
        for (reason, start) in cases {
            for until in [today, later] {
                let text = LoginFailureMessage.text(for: EHNetworkError.paused(SitePause(reason: reason, until: until)))
                let expiry = ListFailure.expiryText(until: until, now: .now, calendar: .current, locale: .current)
                #expect(text?.hasPrefix(start) == true, Comment(rawValue: "\(reason)"))
                #expect(text == start + expiry + ".", Comment(rawValue: "\(reason) \(until)"))
            }
        }
        // Two days on, the end is not the time alone.
        let time = later.formatted(date: .omitted, time: .shortened)
        let text = LoginFailureMessage.text(for: EHNetworkError.paused(SitePause(reason: .banned, until: later)))
        #expect(text?.hasSuffix(" until \(time).") == false)
    }

    /// Image loading (browse B1) builds its sessions from `clientConfiguration`: in UI testing they are offline too.
    @Test func uiTestingSessionsStayOffline() async throws {
        let configuration = AppEnvironment(uiTesting: true).clientConfiguration
        let session = URLSession(
            configuration: EHClient.makeSessionConfiguration(for: .eh, configuration: configuration)
        )
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: "https://ehgt.org/fake.jpg")!)
            Issue.record("an offline session answered")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        }
    }

    // MARK: - User agent at launch

    @Test func launchCapturesTheUserAgentBeforeAnyRequest() async throws {
        let log = ProbeLog()
        let h = Self.makeHarness(probe: {
            log.calls += 1
            log.requestsDuringProbe = log.stub?.requests().count
            log.readyDuringProbe = log.environment?.isReady
            return Self.probedUserAgent
        })
        log.stub = h.stub
        log.environment = h.environment
        #expect(!h.environment.isReady)

        await h.environment.start()
        #expect(h.environment.isReady)
        #expect(log.calls == 1)
        #expect(log.readyDuringProbe == false)
        #expect(log.requestsDuringProbe == 0)
        #expect(h.stub.requests().isEmpty)
        #expect(await h.environment.userAgents.isWebKit)
        #expect(await h.environment.userAgents.current == Self.probedUserAgent)
        #expect(h.environment.canUseWebLogin)

        // The password login posts the form in the WebView; the first URLSession request is the profile run's.
        try await h.environment.logIn(username: "fake-user", password: "fake-password")
        await h.profileRead()
        let first = try #require(h.stub.requests().first)
        #expect(first.url == EHEndpoints.uconfig(site: .eh))
        #expect(first.value(forHTTPHeaderField: "User-Agent") == Self.probedUserAgent)
    }

    @Test func launchReusesAFreshUserAgent() async throws {
        let cached = WebKitUserAgent(
            value: "FakeWebKit/cached", systemVersion: "27.0", capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let gate = ProbeGate()
        let vault = InMemoryVault(data: try Self.encoded(SessionSnapshot(cookies: [
            .eh: Self.identity.merging([CookieNames.clearance: "clearance-fake-0001", "sk": "sk-fake-0002"]) { $1 },
        ])))
        let h = Self.makeHarness(
            vault: vault, cache: InMemoryUserAgentCache(cached), probe: { try await gate.value() }
        )
        await h.environment.start()
        // Ready at once with the cached UA, while the probe still runs.
        #expect(h.environment.isReady)
        #expect(await h.environment.userAgents.current == "FakeWebKit/cached")
        #expect(h.environment.canUseWebLogin)
        #expect(await h.jar(.eh)[CookieNames.clearance] == "clearance-fake-0001")

        // The background read finds another value: adopted as at launch (the UA-bound cookies go).
        #expect(await eventually { gate.isWaiting })
        gate.release("FakeWebKit/new")
        await h.environment.userAgentRefresh?.value
        #expect(await h.environment.userAgents.current == "FakeWebKit/new")
        #expect(await h.jar(.eh) == Self.identity.merging(["sk": "sk-fake-0002"]) { $1 })
        #expect(h.environment.session.cookies[.eh]?[CookieNames.clearance] == nil)
        #expect(h.stub.requests().isEmpty)
    }

    @Test func launchRecapturesTheUserAgentAfterASystemUpdate() async throws {
        let cached = WebKitUserAgent(
            value: "FakeWebKit/old", systemVersion: "26.4", capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let vault = InMemoryVault(data: try Self.encoded(SessionSnapshot(cookies: [
            .eh: Self.identity.merging([
                CookieNames.clearance: "clearance-fake-0001", "cf_duid": "duid-fake-0002", "sk": "sk-fake-0003",
            ]) { $1 },
            .ex: Self.identity.merging([
                CookieNames.clearance: "clearance-fake-0004", CookieNames.igneous: "igneous-fake-0005",
            ]) { $1 },
        ])))
        let log = ProbeLog()
        let h = Self.makeHarness(vault: vault, cache: InMemoryUserAgentCache(cached), systemVersion: "27.0", probe: {
            log.readyDuringProbe = log.environment?.isReady
            return Self.probedUserAgent
        })
        log.environment = h.environment
        await h.environment.start()
        #expect(log.readyDuringProbe == false)
        #expect(await h.environment.userAgents.current == Self.probedUserAgent)
        #expect(await h.jar(.eh) == Self.identity.merging(["sk": "sk-fake-0003"]) { $1 })
        #expect(await h.jar(.ex) == Self.identity.merging([CookieNames.igneous: "igneous-fake-0005"]) { $1 })
        #expect(h.environment.session == (await h.environment.cookies.snapshot()))
        #expect(h.environment.canUseWebLogin)
    }

    /// A UA cached by an older reading (the app's cache keeps the reading's version, `UserAgentCacheVersion`) is read
    /// again before the first request, as after a system update; the new one is cached with the version.
    @Test func launchRereadsAUserAgentOfAnOlderReading() async throws {
        let suite = "proj.eros.swifte.tests.account-flow-ua-version"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let cached = WebKitUserAgent(
            value: "FakeWebKit/desktop", systemVersion: "27.0", capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let cache = UserAgentCacheVersion(base: InMemoryUserAgentCache(cached), suiteName: suite)
        let log = ProbeLog()
        let h = Self.makeHarness(cache: cache, probe: {
            log.calls += 1
            log.readyDuringProbe = log.environment?.isReady
            return Self.probedUserAgent
        })
        log.environment = h.environment
        await h.environment.start()
        #expect(log.calls == 1)
        #expect(log.readyDuringProbe == false)
        #expect(await h.environment.userAgents.current == Self.probedUserAgent)
        #expect(await cache.load()?.value == Self.probedUserAgent)
    }

    @Test func failedProbeDisablesWebLogin() async throws {
        let cache = InMemoryUserAgentCache()
        let failing = Self.makeHarness(cache: cache, probe: { throw ProbeFailure() })
        await failing.environment.start()
        #expect(failing.environment.isReady)
        #expect(await failing.environment.userAgents.current == RequestDefaults.chromeUserAgent)
        #expect(await !failing.environment.userAgents.isWebKit)
        #expect(!failing.environment.canUseWebLogin)
        // Nothing is cached: the next launch reads again.
        #expect(await cache.load() == nil)

        let next = Self.makeHarness(cache: cache)
        await next.environment.start()
        #expect(next.environment.canUseWebLogin)
        #expect(await next.environment.userAgents.current == Self.probedUserAgent)
    }

    // MARK: - Web login

    @Test func closingTheWebLoginWritesNothing() async throws {
        let vault = InMemoryVault()
        let h = Self.makeHarness(vault: vault)
        await h.environment.start()
        try await h.environment.prepareLogin()
        let reports = Counter()
        let session = WebLoginSession(environment: h.environment) { _ in reports.value += 1 }
        session.start()
        #expect(await eventually { session.webView.url?.absoluteString == "about:blank" && !session.webView.isLoading })
        #expect(session.webView.configuration.websiteDataStore === h.environment.bridge.dataStore)
        #expect((session.webView.customUserAgent ?? "").isEmpty)
        // What the forum would have set before the user gave up.
        try await h.put("ipb_session_id", "session-fake-0001", domain: "forums.e-hentai.org")
        try await h.put(CookieNames.memberID, String(Self.memberID), domain: ".e-hentai.org")
        try await h.put("other", "other-fake-0002", domain: ".example.com")

        await session.close()
        #expect(reports.value == 0)
        #expect(await h.environment.cookies.snapshot() == .empty)
        #expect(try vault.read() == nil)
        #expect(h.environment.session == .empty)
        #expect(!h.environment.isLoggedIn)
        #expect(await h.webCookies().map { "\($0.domain) \($0.name)" } == [".example.com other"])
        #expect(h.stub.requests().isEmpty)
        #expect(h.pages.requests.isEmpty)
    }

    @Test func webLoginTakesTheWebViewCookies() async throws {
        let h = Self.makeHarness()
        await h.environment.start()
        try await h.environment.prepareLogin()
        let session = WebLoginSession(environment: h.environment) { _ in }
        session.start()
        #expect(await eventually { session.webView.url != nil && !session.webView.isLoading })
        try await h.put(CookieNames.memberID, String(Self.memberID), domain: ".e-hentai.org")
        try await h.put(CookieNames.passHash, Self.passHash, domain: ".e-hentai.org")
        try await h.put(CookieNames.igneous, "igneous-fake-0001", domain: ".exhentai.org")

        try await h.environment.completeWebLogin(from: session.webView)
        await h.profileRead()
        #expect(h.environment.isLoggedIn)
        #expect(h.environment.session.account?.method == .web)
        #expect(h.environment.session.account?.displayName == "Fake Nickname")
        #expect(await h.jar(.ex)[CookieNames.igneous] == "igneous-fake-0001")
        #expect(h.pages.requests.count == 1)
        await session.close()
        // The login completed: closing afterwards keeps the session.
        #expect(h.environment.isLoggedIn)
    }

    // MARK: - The forum profile read is the environment's

    /// The profile page of `memberID`, answered once `gate` opens, with two cookies it sets only when it is answered.
    private static func lateProfile(gate: Gate) -> PageAnswer {
        PageAnswer(body: profilePage, setCookies: [
            fakeCookie("ipb_session_id", "late-fake-0001", domain: "forums.e-hentai.org"),
            fakeCookie("sk", "late-fake-0002"),
        ], gate: gate)
    }

    /// The login returns (so the sheet can close) while the profile page is still being read; logging out ends the
    /// read at once: the page is stopped, its WebView released, the step stays none, and its late answer changes
    /// nothing.
    @Test func logOutStopsTheProfileRead() async throws {
        let gate = Gate()
        let h = Self.makeHarness(page: Self.forum(profile: Self.lateProfile(gate: gate)))
        await h.environment.start()
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        // Signed in and returned; the read goes on by itself.
        #expect(h.environment.isLoggedIn)
        #expect(h.environment.forumProfileRead != nil)
        #expect(await eventually { gate.hasWaiters })
        #expect(h.environment.forumProfileStep == nil)

        let started = ContinuousClock.now
        try await h.environment.logOut()
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(h.environment.forumProfileRead == nil)
        #expect(h.environment.forumProfileStep == nil)
        #expect(!h.environment.isLoggedIn)
        #expect(h.environment.session == .empty)
        // The page's WebView is gone with the read (the handler holds it weakly; its answer is still held).
        await waitForRelease(of: h.pages)
        #expect(h.pages.webView == nil)

        // The page's answer comes after all: it reaches nothing.
        gate.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await h.webCookies().isEmpty)
        #expect(await h.environment.cookies.snapshot() == .empty)
        #expect(h.environment.forumProfileStep == nil)
        #expect(h.environment.session == .empty)
    }

    /// Logged out while A's profile page was being read, then signed in as B at once: A's late page writes nothing
    /// into B's session (jar, WebView store, account) and leaves B's step as it is.
    @Test func anEarlierReadWritesNothingIntoTheNextSession() async throws {
        let gate = Gate()
        let other = 7_654_321
        let otherPage = Self.profilePage.replacingOccurrences(of: "Fake Nickname", with: "Other Nickname")
        let h = Self.makeHarness(page: { request in
            switch request.url {
            case ForumPageHandler.profile(Self.memberID)?: Self.lateProfile(gate: gate)
            case ForumPageHandler.profile(other)?: PageAnswer(body: otherPage)
            default: PageAnswer(status: 404, body: "<html><body>Fake 404</body></html>")
            }
        })
        await h.environment.start()
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        #expect(await eventually { gate.hasWaiters })
        try await h.environment.logOut()
        try await h.environment.logIn(memberID: String(other), passHash: "fedcba9876543210fedcba9876543210")
        await h.profileRead()
        #expect(h.environment.forumProfileStep == .loaded)
        #expect(h.environment.session.account?.displayName == "Other Nickname")
        let jars = await h.environment.cookies.snapshot().cookies

        gate.open()
        try await Task.sleep(for: .milliseconds(500))
        #expect(await h.environment.cookies.snapshot().cookies == jars)
        #expect(await !h.webCookies().contains { $0.value.hasPrefix("late-fake") })
        #expect(await h.environment.cookies.memberID == other)
        #expect(h.environment.forumProfileStep == .loaded)
        #expect(h.environment.session.account?.displayName == "Other Nickname")
    }

    /// The start of a login (here the web login's, which the user may close again) ends the read in progress the same
    /// way, and the read it ended records nothing: the step stays none, the account signed in stays as it was.
    @Test func aLoginStartingEndsTheReadWithoutAStep() async throws {
        let gate = Gate()
        let h = Self.makeHarness(page: Self.forum(profile: Self.lateProfile(gate: gate)))
        await h.environment.start()
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        #expect(await eventually { gate.hasWaiters })
        let signedIn = await h.environment.cookies.snapshot()

        try await h.environment.prepareLogin()
        #expect(h.environment.forumProfileRead == nil)
        #expect(h.environment.forumProfileStep == nil)
        await waitForRelease(of: h.pages)
        #expect(h.pages.webView == nil)
        gate.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.environment.forumProfileStep == nil)
        #expect(h.environment.isLoggedIn)
        #expect(await h.environment.cookies.snapshot() == signedIn)
        #expect(await !h.webCookies().contains { $0.value.hasPrefix("late-fake") })
    }

    #if DEBUG
    /// Two logouts at once (Log Out tapped again before the first has refreshed `isLoggedIn`) while the work the first
    /// one cancelled takes its time to end: the second returns only after that work has ended,
    /// as the first does, so it does not clear the WebView store (`removeAllData()`) while that work could still write
    /// into it.
    ///
    /// The real read ends at once when cancelled, so a stand-in takes its place: a read that ignores its cancellation
    /// until the gate opens.
    @Test func overlappingLogoutsBothWaitForTheCancelledWork() async throws {
        let h = Self.makeHarness()
        await h.environment.start()
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        await h.profileRead()
        let gate = Gate()
        let log = EventLog()
        h.environment.adoptForumProfileRead(Task {
            await gate.wait()
            log.entries.append("read ended")
        })
        let environment = h.environment
        let first = Task {
            try await environment.logOut()
            log.entries.append("first logout returned")
        }
        // The first logout has taken the read.
        #expect(await eventually { environment.forumProfileRead == nil })
        let second = Task {
            try await environment.logOut()
            log.entries.append("second logout returned")
        }
        // Time for the second logout to run to its end if it did not wait (a logout here takes milliseconds).
        try await Task.sleep(for: .milliseconds(500))
        #expect(log.entries.isEmpty)
        gate.open()
        try await first.value
        try await second.value
        #expect(log.entries.first == "read ended")
        #expect(log.entries.count == 3)
        #expect(!environment.isLoggedIn)
        #expect(environment.session == .empty)
    }
    #endif

    // MARK: - One login at a time

    /// A second login while one runs (here two cookie logins; the first held at the throttle before its settings page)
    /// is refused at once with `CancellationError` and sends nothing; the first goes on and signs in.
    @Test func secondLoginWhileOneRunsIsRefused() async throws {
        let throttle = GatedThrottle()
        let h = Self.makeHarness(throttle: throttle)
        await h.environment.start()
        let environment = h.environment
        let first = Task { try await environment.logIn(memberID: "1234567", passHash: Self.passHash) }
        #expect(await eventually { await throttle.urls.contains(EHEndpoints.uconfig(site: .eh)) })
        #expect(environment.isLoggingIn)

        await #expect(throws: CancellationError.self) {
            try await environment.logIn(memberID: "7654321", passHash: "fedcba9876543210fedcba9876543210")
        }
        #expect(environment.isLoggingIn)
        await throttle.open()
        try await first.value
        #expect(environment.isLoggedIn)
        #expect(await environment.cookies.memberID == Self.memberID)
        #expect(!environment.isLoggingIn)
        await h.profileRead()
        #expect(await throttle.urls.filter { $0 == EHEndpoints.uconfig(site: .eh) }.count == 1)
    }

    /// A login that fails ends the login state too: the next one is not refused.
    @Test func failedLoginEndsTheLoginState() async throws {
        let h = Self.makeHarness()
        await h.environment.start()
        await #expect(throws: LoginError.invalidMemberID) {
            try await h.environment.logIn(memberID: "12a", passHash: Self.passHash)
        }
        #expect(!h.environment.isLoggingIn)
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        #expect(h.environment.isLoggedIn)
        #expect(!h.environment.isLoggingIn)
        await h.profileRead()
    }

    /// Every way into a login is refused while a password login's WebView run is still going: the run is neither
    /// cancelled nor shared, and the refused one ends with `CancellationError` (no alert) and sends nothing. The first
    /// login goes on and signs in under its own name.
    @Test func aLoginDuringThePasswordRunIsRefused() async throws {
        let gate = Gate()
        let h = Self.makeHarness(page: { request in
            switch request.url {
            case ForumPageHandler.loginPage?:
                PageAnswer(body: "<html><body><form>Fake login form</form></body></html>", gate: gate)
            case ForumPageHandler.form?: Self.signsIn(extra: [])
            case ForumPageHandler.profile(Self.memberID)?: PageAnswer(body: Self.profilePage)
            default: PageAnswer(status: 404, body: "<html><body>Fake 404</body></html>")
            }
        })
        await h.environment.start()
        let environment = h.environment
        let first = Task { try await environment.logIn(username: "fake-user-a", password: "fake-password-a") }
        #expect(await eventually { gate.hasWaiters })
        #expect(environment.isLoggingIn)

        do {
            try await environment.logIn(username: "fake-user-b", password: "fake-password-b")
            Issue.record("a second password login started while the first one ran")
        } catch {
            #expect(error is CancellationError)
            #expect(LoginFailureMessage.text(for: error) == nil)
        }
        await #expect(throws: CancellationError.self) {
            try await environment.logIn(memberID: "7654321", passHash: "fedcba9876543210fedcba9876543210")
        }
        await #expect(throws: CancellationError.self) { try await environment.prepareLogin() }
        await #expect(throws: CancellationError.self) { try await environment.completeWebLogin(from: WKWebView()) }
        #expect(environment.isLoggingIn)
        #expect(environment.forumProfileStep == nil)

        gate.open()
        try await first.value
        #expect(!environment.isLoggingIn)
        await h.profileRead()
        #expect(environment.session.account?.username == "fake-user-a")
        #expect(environment.forumProfileStep == .loaded)
        #expect(h.pageRequests() == [
            "GET \(ForumPageHandler.loginPage.absoluteString)", "POST \(ForumPageHandler.form.absoluteString)",
            "GET \(ForumPageHandler.profile(Self.memberID).absoluteString)",
        ])
        #expect(h.stub.requests().compactMap(\.url) == [EHEndpoints.uconfig(site: .eh)])
        #expect(await h.jar(.eh) == Self.identity)
        #expect(await h.jar(.ex) == Self.identity)
    }

    /// A page read whose nickname cannot be stored is not recorded as loaded: the Keychain write
    /// fails, or the member is not the one signed in any more.
    @Test func aProfileThatIsNotStoredIsNotLoaded() async throws {
        let vault = WriteFailingVault()
        let gate = Gate()
        let h = Self.makeHarness(vault: vault, page: Self.forum(profile: PageAnswer(body: Self.profilePage, gate: gate)))
        await h.environment.start()
        try await h.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        #expect(await eventually { gate.hasWaiters })
        vault.writesFail.withLock { $0 = true }
        gate.open()
        await h.profileRead()
        #expect(h.environment.forumProfileStep == .notStored)
        #expect(h.environment.session.account?.displayName == nil)
        #if DEBUG
        #expect(await SessionDiagnostics.collect(h.environment).forumProfile == "notStored")
        #endif

        // Another member signed in behind the environment's back while the page was read: nothing is stored.
        let otherGate = Gate()
        let other = Self.makeHarness(page: Self.forum(profile: PageAnswer(body: Self.profilePage, gate: otherGate)))
        await other.environment.start()
        try await other.environment.logIn(memberID: String(Self.memberID), passHash: Self.passHash)
        #expect(await eventually { otherGate.hasWaiters })
        try await other.environment.cookies.set(
            [CookieNames.memberID: "7654321", CookieNames.passHash: "fedcba9876543210fedcba9876543210"], for: [.eh]
        )
        otherGate.open()
        await other.profileRead()
        #expect(other.environment.forumProfileStep == .notStored)
        #expect(await other.environment.cookies.snapshot().account?.displayName == nil)
    }

    /// The user decision of 2026-11-07: the forum profile read has 60 seconds in all, and the loader gets them.
    @Test func theForumProfileReadHasSixtySeconds() {
        #expect(AppEnvironment.forumProfileTimeout == .seconds(60))
        #expect(AppEnvironment(uiTesting: true).profileLoader.timeout == .seconds(60))
        #expect(Self.makeHarness().environment.profileLoader.timeout == .seconds(60))
    }

    #if DEBUG
    /// ErosTests run inside the app: the app's own environment is the offline, in-memory one of UI testing, so a test
    /// run never reads or writes the Keychain and never reaches the site.
    ///
    /// `launchedUITesting` is what `forLaunch()` recorded when `ErosApp` made the app's environment at launch, before
    /// any test ran (no other test calls it): an app that built its environment some other way leaves it nil. Read
    /// before this test calls `forLaunch()` itself. DEBUG only: a Release build has no test switches
    /// (`AppEnvironment.forLaunch()`).
    @Test func theTestHostLaunchesOffline() {
        #expect(AppEnvironment.isHostedByTests)
        #expect(AppEnvironment.launchedUITesting == true)
        #expect(AppEnvironment.forLaunch().uiTesting)
    }
    #endif

    // MARK: - Avatar

    @Test func avatarIsFetchedThroughTheLimiter() async throws {
        let throttle = ThrottleRecorder()
        let h = Self.makeHarness(throttle: throttle, responder: Self.avatarSite(redirect: false))
        await h.environment.start()
        try await h.environment.cookies.set(Self.identity, for: [.eh])

        let window = try Self.show(AvatarView(url: Self.avatarURL).environment(h.environment))
        defer { Self.hide(window) }
        #expect(await eventually { h.environment.avatars.hasImage(for: Self.avatarURL) })
        #expect(await throttle.urls == [Self.avatarURL])
        let requests = h.stub.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "User-Agent") == Self.probedUserAgent)
        #expect(requests.first?.value(forHTTPHeaderField: "Cookie")?.contains("ipb_member_id=1234567") == true)

        // Shown again: from memory, nothing more is asked for.
        let again = try Self.show(AvatarView(url: Self.avatarURL).environment(h.environment))
        defer { Self.hide(again) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await throttle.urls == [Self.avatarURL])
        #expect(h.stub.requests().count == 1)
    }

    /// Forum images can redirect to third-party H@H nodes: the hop waits for the throttle and carries no cookie.
    @Test func avatarRedirectToHathCarriesNoCookieAndIsThrottled() async throws {
        let throttle = ThrottleRecorder()
        let h = Self.makeHarness(throttle: throttle, responder: Self.avatarSite(redirect: true))
        await h.environment.start()
        try await h.environment.cookies.set(Self.identity, for: [.eh])

        #expect(await h.environment.avatars.image(for: Self.avatarURL) != nil)
        #expect(await throttle.urls == [Self.avatarURL, Self.hathURL])
        let requests = h.stub.requests()
        #expect(requests.compactMap(\.url) == [Self.avatarURL, Self.hathURL])
        #expect(requests.first?.value(forHTTPHeaderField: "Cookie")?.contains("ipb_member_id=1234567") == true)
        #expect(requests.last?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "User-Agent") == Self.probedUserAgent)

        // A throttle that refuses the hop: the redirect is not followed.
        let refusing = ThrottleRecorder(refusing: [Self.hathURL.host() ?? ""])
        let r = Self.makeHarness(throttle: refusing, responder: Self.avatarSite(redirect: true))
        await r.environment.start()
        #expect(await r.environment.avatars.image(for: Self.avatarURL) == nil)
        #expect(await refusing.urls == [Self.avatarURL, Self.hathURL])
        #expect(r.stub.requests().compactMap(\.url) == [Self.avatarURL])
    }

    /// What cannot be read is not asked for again: not when the view shows again, not by another view.
    @Test func failedAvatarIsNotAskedForAgain() async throws {
        let throttle = ThrottleRecorder()
        let h = Self.makeHarness(throttle: throttle, responder: Self.avatarAnswers([429]))
        await h.environment.start()

        let window = try Self.show(AvatarView(url: Self.avatarURL).environment(h.environment))
        #expect(await eventually { h.environment.avatars.hasFailed(Self.avatarURL) })
        Self.hide(window)
        // The view comes back, and another one shows the same avatar.
        let again = try Self.show(AvatarView(url: Self.avatarURL).environment(h.environment))
        defer { Self.hide(again) }
        let other = try Self.show(AvatarView(url: Self.avatarURL).environment(h.environment))
        defer { Self.hide(other) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await h.environment.avatars.image(for: Self.avatarURL) == nil)
        #expect(h.stub.requests().count == 1)
        #expect(await throttle.urls == [Self.avatarURL])
    }

    @Test func avatarsOfOneURLShareOneLoad() async throws {
        let throttle = GatedThrottle()
        let h = Self.makeHarness(throttle: throttle, responder: Self.avatarAnswers([200]))
        await h.environment.start()

        let window = try Self.show(VStack {
            AvatarView(url: Self.avatarURL)
            AvatarView(url: Self.avatarURL)
        }.environment(h.environment))
        defer { Self.hide(window) }
        #expect(await eventually { await throttle.urls.count == 1 })
        // Both views are up and waiting; only one load was started.
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.environment.avatars.isLoading(Self.avatarURL))
        #expect(await throttle.urls.count == 1)
        await throttle.open()
        #expect(await eventually { h.environment.avatars.hasImage(for: Self.avatarURL) })
        #expect(h.stub.requests().count == 1)
        #expect(await throttle.urls == [Self.avatarURL])
    }

    /// A view that leaves mid-load does not cancel it: the result is kept, and the view coming back asks nothing.
    @Test func avatarLeftMidLoadIsNotAskedForAgain() async throws {
        let throttle = GatedThrottle()
        let h = Self.makeHarness(throttle: throttle, responder: Self.avatarAnswers([200]))
        await h.environment.start()

        let window = try Self.show(AvatarView(url: Self.avatarURL).environment(h.environment))
        #expect(await eventually { await throttle.urls.count == 1 })
        Self.hide(window)
        try await Task.sleep(for: .milliseconds(200))
        let back = try Self.show(AvatarView(url: Self.avatarURL).environment(h.environment))
        defer { Self.hide(back) }
        try await Task.sleep(for: .milliseconds(200))
        await throttle.open()
        #expect(await eventually { h.environment.avatars.hasImage(for: Self.avatarURL) })
        #expect(h.stub.requests().count == 1)
        #expect(await throttle.urls == [Self.avatarURL])
    }

    @Test func loggingOutForgetsFailedAvatars() async throws {
        let h = Self.makeHarness(responder: Self.avatarAnswers([403, 200]))
        await h.environment.start()
        #expect(await h.environment.avatars.image(for: Self.avatarURL) == nil)
        #expect(await h.environment.avatars.image(for: Self.avatarURL) == nil)
        #expect(h.stub.requests().count == 1)

        try await h.environment.logOut()
        #expect(!h.environment.avatars.hasFailed(Self.avatarURL))
        #expect(await h.environment.avatars.image(for: Self.avatarURL) != nil)
        #expect(h.stub.requests().count == 2)
    }

    // MARK: - Diagnostics

    #if DEBUG
    @Test func diagnosticsShowNamesNotValues() async throws {
        let h = Self.makeHarness()
        await h.environment.start()
        try await h.environment.cookies.set(
            [CookieNames.memberID: "7654321", CookieNames.passHash: "fedcba9876543210fedcba9876543210",
             "sk": "sk-secret-fake-0001", CookieNames.profile: "7"],
            for: [.eh]
        )
        let report = await SessionDiagnostics.collect(h.environment)
        let text = String(describing: report)
        for value in ["7654321", "fedcba9876543210", "sk-secret-fake"] {
            #expect(!text.contains(value), Comment(rawValue: value))
        }
        let eh = try #require(report.sites.first { $0.site == .eh })
        #expect(eh.cookieNames == [CookieNames.memberID, CookieNames.passHash, "sk", CookieNames.profile])
        #expect(eh.profileNumber == 7)
        #expect(report.isLoggedIn)
        #expect(report.isWebKit)
        #expect(report.userAgent == Self.probedUserAgent)

        #expect(SessionDiagnostics.describe(activation: .success(.granted)) == "granted")
        #expect(SessionDiagnostics.describe(activation: .success(.denied)) == "denied")
        #expect(SessionDiagnostics.describe(activation: .failure(EHNetworkError.issue(.exAccessDenied))) == "denied")
        #expect(SessionDiagnostics.describe(activation: .failure(EHNetworkError.issue(.tooManyRequests))) == "tooManyRequests")
        let pauseEnd = Date(timeIntervalSince1970: 1_800_000_000)
        for (reason, text) in [(PauseReason.banned, "paused (banned)"), (.tooManyRequests, "paused (tooManyRequests)")] {
            let error = EHNetworkError.paused(SitePause(reason: reason, until: pauseEnd))
            #expect(SessionDiagnostics.describe(error) == text)
        }
        #expect(SessionDiagnostics.describe(.stopped(.bandwidthExceeded)) == "stopped(bandwidthExceeded)")
        #expect(SessionDiagnostics.describe(ForumProfileStep.skipped(.banned(remaining: nil))) == "skipped (banned)")
        let reasons: [(ForumProfileFailure, String)] = [
            (.page(.challengeTimedOut), "unavailable (challengeTimedOut)"),
            (.page(.httpStatus(403)), "unavailable (httpStatus 403)"),
            (.notAProfilePage, "unavailable (notAProfilePage)"),
            (.rules, "unavailable (rules)"),
            (.page(.timedOut), "unavailable (timedOut)"),
            (.page(.challenged), "unavailable (challenged)"),
            (.page(.throttled), "unavailable (throttled)"),
            (.page(.tooManyNavigations), "unavailable (tooManyNavigations)"),
            (.page(.failed), "unavailable (failed)"),
        ]
        for (reason, text) in reasons {
            #expect(SessionDiagnostics.describe(ForumProfileStep.unavailable(reason)) == text)
        }
        #expect(SessionDiagnostics.describe(ForumProfileStep?.none) == "none")
        #expect(SessionDiagnostics.describe(ForumProfileStep.loaded) == "loaded")
        #expect(SessionDiagnostics.describe(ForumProfileStep.notStored) == "notStored")
    }

    /// A4 checks each login's session with the front page: every check asks the site, and nothing cached answers it,
    /// not even for a 403 (which a reload alone would answer from the cache).
    @Test func frontPageCheckAsksTheSiteEveryTime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "eros-tests-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let front = EHRequests.list(ListQuery(source: .front), site: .eh).url
        let calls = CallCounter()
        let h = Self.makeHarness(responseCache: ResponseCache(directory: directory), responder: { request in
            guard request.url == front else { throw URLError(.badURL) }
            let page = Data("<html><body><div class=\"ido\"><p>No hits found</p></div></body></html>".utf8)
            return calls.next() <= 2 ? StubResponse(body: page) : StubResponse(status: 403)
        })
        await h.environment.start()

        let first = await SessionDiagnostics.loadFrontPage(site: .eh, environment: h.environment)
        let second = await SessionDiagnostics.loadFrontPage(site: .eh, environment: h.environment)
        #expect(first == "0 items, Compact: no selector, source: network")
        #expect(second == first)
        #expect(h.stub.requests().compactMap(\.url) == [front, front])

        // The page is cached now, and the site answers 403: the check says so instead of showing the old page.
        let refused = await SessionDiagnostics.loadFrontPage(site: .eh, environment: h.environment)
        #expect(refused == "HTTP 403")
        #expect(h.stub.requests().count == 3)
    }
    #endif

    // MARK: - Helpers

    private static func encoded(_ snapshot: SessionSnapshot) throws -> Data {
        try JSONEncoder().encode(snapshot)
    }

    private static func pngData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    /// `view` in a window of its own on the host app's scene, so its tasks run as on screen.
    private static func show(_ view: some View) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        return window
    }

    private static func hide(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }
}
