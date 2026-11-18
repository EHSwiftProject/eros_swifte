import EHModels
import EHNetwork
import EHParsing
import Foundation
import Testing
import WebKit

@testable import Eros

/// The forum's login page and form are served from the custom scheme `eros-test://` (`ForumPageHandler`); the
/// handler writes the identity cookies into the WebView store before it answers the form, as the forum's Set-Cookie
/// would. Every value is made up; nothing here reaches the network. WebKit is up before the first test
/// (`.warmsUpWebContent`), yet every login still starts a web content process of its own within its time limit
/// (`WebPasswordLogin` makes its page): a test whose page must be answered before the time runs out gives it
/// `WebContentWarmUp.firstAnswerLimit`.
///
/// Each test has five minutes (`.timeLimit`): some hold a page or a WebKit store call until they let it go, and one
/// that never lets go must fail at the limit, not hang the run (the test process is then ended and started again
/// for the tests after it); five, as WebKit's processes are slow on a busy host (an account flow test once took
/// 143 s under a heavy load), and as `scripts/test.sh` gives a test by default.
@MainActor @Suite(.warmsUpWebContent, .timeLimit(.minutes(5))) struct WebPasswordLoginTests {
    private static let memberID = "1234567"
    private static let passHash = "0123456789abcdef0123456789abcdef"
    private static let password = "fake-password-0001"
    private static let loginPage = "<html><body><form>Fake login form</form></body></html>"
    private static let welcome = "<html><body>Fake welcome</body></html>"

    @MainActor private final class Counter {
        var value = 0

        func next() -> Int {
            value += 1
            return value
        }
    }

    private struct Harness {
        let login: WebPasswordLogin
        let handler: ForumPageHandler
        let throttle: ThrottleRecorder
        let bridge: WebSessionBridge
        let store: CookieStore

        @MainActor func methodsAndURLs() -> [String] {
            handler.received.map { "\($0.httpMethod ?? "?") \($0.url?.absoluteString ?? "?")" }
        }
    }

    /// `throttle` is what the page's loads wait for; `breaker` what the run reports a ban notice to.
    private static func makeHarness(
        timeout: Duration = .seconds(10), offline: Bool = false, jar: [String: String] = [:],
        throttle: ThrottleRecorder = ThrottleRecorder(), breaker: SiteBreaker? = nil,
        respond: @escaping @MainActor (URLRequest) -> PageAnswer? = forum()
    ) async throws -> Harness {
        let store = CookieStore(vault: InMemoryVault())
        try await store.load()
        if !jar.isEmpty { try await store.set(jar, for: [.eh]) }
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        let bridge = WebSessionBridge(
            store: store, userAgents: userAgents, storeTimeout: WebSessionBridge.roomyTestTimeout
        )
        let handler = ForumPageHandler(respond: respond)
        let login = WebPasswordLogin(
            bridge: bridge, throttle: throttle, timeout: timeout, loginPageURL: ForumPageHandler.loginPage,
            formURL: ForumPageHandler.form, schemeHandler: (handler, ForumPageHandler.scheme), offline: offline,
            breaker: breaker
        )
        return Harness(login: login, handler: handler, throttle: throttle, bridge: bridge, store: store)
    }

    /// The breakers' fixed time (T).
    nonisolated private static let breakerTime = Date(timeIntervalSince1970: 1_800_000_000)

    /// The login page answers `loginPage(n)` and the form `form(n)` (n counts each from 1); anything else is a 404.
    private static func forum(
        loginPage: @escaping @MainActor (Int) -> PageAnswer? = { _ in PageAnswer(body: Self.loginPage) },
        form: @escaping @MainActor (Int) -> PageAnswer? = { _ in signsIn() }
    ) -> @MainActor (URLRequest) -> PageAnswer? {
        let pageCalls = Counter()
        let formCalls = Counter()
        return { request in
            switch request.url {
            case ForumPageHandler.loginPage?: loginPage(pageCalls.next())
            case ForumPageHandler.form?: form(formCalls.next())
            default: PageAnswer(status: 404, body: "<html><body>Fake 404</body></html>")
            }
        }
    }

    /// The welcome page, after writing the identity pair (and `extra`) into the WebView's store.
    private static func signsIn(extra: [HTTPCookie] = []) -> PageAnswer {
        PageAnswer(body: welcome) { webView in
            let cookies = [fakeCookie(CookieNames.memberID, memberID), fakeCookie(CookieNames.passHash, passHash)] + extra
            await webView.configuration.websiteDataStore.httpCookieStore.setCookies(cookies)
        }
    }

    private static func value(_ name: String, in cookies: [ParsedCookie]) -> String? {
        cookies.last { $0.name == name }?.value
    }

    // MARK: - Tests

    @Test func postsTheFormAfterTheLoginPage() async throws {
        let h = try await Self.makeHarness()
        let result = try await h.login.run(username: "fake-user", password: Self.password)
        #expect(h.methodsAndURLs() == [
            "GET \(ForumPageHandler.loginPage.absoluteString)", "POST \(ForumPageHandler.form.absoluteString)",
        ])
        let (get, post) = (h.handler.received[0], h.handler.received[1])
        #expect(get.httpBody == nil)
        #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(post.value(forHTTPHeaderField: "Referer") == EHEndpoints.forumLoginReferer.absoluteString)
        // WebKit hands the POST body to the scheme handler.
        let body = String(decoding: try #require(post.httpBody), as: UTF8.self)
        #expect(body.contains("UserName=fake-user&"))
        #expect(body.contains("PassWord=\(Self.password)&"))
        // The password is in the POST body only.
        #expect(!h.handler.received.contains { ($0.url?.absoluteString ?? "").contains(Self.password) })
        #expect(await h.throttle.urls == [ForumPageHandler.loginPage, ForumPageHandler.form])
        // What the forum set, read back from the WebView store, and the page the run ended on.
        #expect(Self.value(CookieNames.memberID, in: result.cookies) == Self.memberID)
        #expect(Self.value(CookieNames.passHash, in: result.cookies) == Self.passHash)
        #expect(result.page == ForumPageHandler.form)
        // The run itself writes nothing into the cookie store.
        #expect(await h.store.snapshot() == .empty)
    }

    @Test func challengeOnTheLoginPageThatFinishesIsWaitedFor() async throws {
        let h = try await Self.makeHarness(respond: Self.forum(loginPage: { call in
            call == 1 ? .challenge(reloads: true) : PageAnswer(body: Self.loginPage)
        }))
        let result = try await h.login.run(username: "fake-user", password: Self.password)
        #expect(h.methodsAndURLs() == [
            "GET \(ForumPageHandler.loginPage.absoluteString)", "GET \(ForumPageHandler.loginPage.absoluteString)",
            "POST \(ForumPageHandler.form.absoluteString)",
        ])
        #expect(await h.throttle.urls.count == 3)
        #expect(Self.value(CookieNames.memberID, in: result.cookies) == Self.memberID)
    }

    /// `WebContentWarmUp.firstAnswerLimit`: the challenge must have arrived before the time runs out.
    @Test func challengeThatDoesNotFinishNeedsTheWebLogin() async throws {
        let limit = WebContentWarmUp.firstAnswerLimit
        let h = try await Self.makeHarness(timeout: limit, respond: Self.forum(loginPage: { _ in
            .challenge(reloads: false)
        }))
        await #expect(throws: WebPasswordLoginError.needsWebLogin) {
            try await h.login.run(username: "fake-user", password: Self.password)
        }
        #expect(h.methodsAndURLs() == ["GET \(ForumPageHandler.loginPage.absoluteString)"])
    }

    @Test func challengeOnThePostNeedsTheWebLogin() async throws {
        let h = try await Self.makeHarness(respond: Self.forum(form: { _ in .challenge(reloads: true) }))
        await #expect(throws: WebPasswordLoginError.needsWebLogin) {
            try await h.login.run(username: "fake-user", password: Self.password)
        }
        // The challenge was not let run: it would post the form again (or lose it).
        try await Task.sleep(for: .milliseconds(500))
        #expect(h.methodsAndURLs() == [
            "GET \(ForumPageHandler.loginPage.absoluteString)", "POST \(ForumPageHandler.form.absoluteString)",
        ])
    }

    @Test func unreachablePagesThrowUnreachable() async throws {
        let unavailable = try await Self.makeHarness(respond: Self.forum(loginPage: { _ in
            PageAnswer(status: 503, body: "<html><body>Fake 503</body></html>")
        }))
        await #expect(throws: WebPasswordLoginError.unreachable) {
            try await unavailable.login.run(username: "fake-user", password: Self.password)
        }
        #expect(unavailable.methodsAndURLs() == ["GET \(ForumPageHandler.loginPage.absoluteString)"])

        let silent = try await Self.makeHarness(timeout: .seconds(1), respond: Self.forum(loginPage: { _ in nil }))
        let started = ContinuousClock.now
        await #expect(throws: WebPasswordLoginError.unreachable) {
            try await silent.login.run(username: "fake-user", password: Self.password)
        }
        // The limit given ends it, not a fixed one of the login's own (the default is 10 s).
        #expect(ContinuousClock.now - started < .seconds(2))

        let failingForm = try await Self.makeHarness(respond: Self.forum(form: { _ in
            PageAnswer(status: 500, body: "<html><body>Fake 500</body></html>")
        }))
        await #expect(throws: WebPasswordLoginError.unreachable) {
            try await failingForm.login.run(username: "fake-user", password: Self.password)
        }
        #expect(failingForm.handler.received.count == 2)
    }

    /// The forum answers the form with a bare-text IP ban notice and sets no identity: the notice is thrown, whether
    /// WebKit shows the text as an HTML body or as a `text/plain` document.
    @Test func banNoticeAnswerIsThrown() async throws {
        let notice = "Your IP address has been temporarily banned for excessive pageloads which indicates that you "
            + "are using automated mirroring/harvesting software. The ban expires in 2 hours and 1 minute"
        for contentType in ["text/html; charset=utf-8", "text/plain; charset=utf-8"] {
            let h = try await Self.makeHarness(respond: Self.forum(form: { _ in
                PageAnswer(headers: ["Content-Type": contentType], body: notice)
            }))
            await #expect(throws: EHNetworkError.issue(.banned(remaining: .seconds(7_260))), Comment(rawValue: contentType)) {
                try await h.login.run(username: "fake-user", password: Self.password)
            }
            #expect(h.handler.received.count == 2, Comment(rawValue: contentType))
            await waitForRelease(of: h.handler)
            #expect(h.handler.webView == nil, Comment(rawValue: contentType))
        }
    }

    /// The forum's ban is the IP's: the notice pauses both sites until its end (user decision 2026-11-08).
    @Test func banNoticePausesTheSites() async throws {
        let notice = "Your IP address has been temporarily banned for excessive pageloads which indicates that you "
            + "are using automated mirroring/harvesting software. The ban expires in 2 hours and 1 minute"
        let breaker = SiteBreaker(now: { Self.breakerTime })
        let h = try await Self.makeHarness(breaker: breaker, respond: Self.forum(form: { _ in
            PageAnswer(headers: ["Content-Type": "text/plain; charset=utf-8"], body: notice)
        }))
        await #expect(throws: EHNetworkError.issue(.banned(remaining: .seconds(7_260)))) {
            try await h.login.run(username: "fake-user", password: Self.password)
        }
        let expected = SitePause(reason: .banned, until: Self.breakerTime.addingTimeInterval(7_260))
        #expect(await breaker.current() == expected)
    }

    /// A 429 from the forum, on the login page or on the form, pauses both sites for a minute (user decision
    /// 2026-11-08) and is thrown as such, so the login screen says the requests were too many.
    @Test func tooManyRequestsPausesTheSites() async throws {
        let tooMany = PageAnswer(status: 429, body: "<html><body>Fake 429</body></html>")
        let cases: [(String, @MainActor (URLRequest) -> PageAnswer?, Int)] = [
            ("login page", Self.forum(loginPage: { _ in tooMany }), 1),
            ("form", Self.forum(form: { _ in tooMany }), 2),
        ]
        for (name, respond, requests) in cases {
            let breaker = SiteBreaker(now: { Self.breakerTime })
            let h = try await Self.makeHarness(breaker: breaker, respond: respond)
            do {
                _ = try await h.login.run(username: "fake-user", password: Self.password)
                Issue.record("the run went on after a 429 (\(name))")
            } catch {
                #expect(error as? EHNetworkError == .issue(.tooManyRequests), Comment(rawValue: name))
                #expect(
                    LoginFailureMessage.text(for: error) == "Too many requests. Try again in a minute.",
                    Comment(rawValue: name)
                )
            }
            let pause = SitePause(reason: .tooManyRequests, until: Self.breakerTime.addingTimeInterval(60))
            #expect(await breaker.current() == pause, Comment(rawValue: name))
            #expect(h.handler.received.count == requests, Comment(rawValue: name))
        }
    }

    /// A load the throttle refused while both sites are paused (`BreakerThrottle`): the pause is thrown, so the login
    /// screen says until when, instead of `.unreachable`. Without a pause a
    /// refused load is still `.unreachable`.
    @Test func refusedLoadDuringAPauseThrowsThePause() async throws {
        let breaker = SiteBreaker(now: { Self.breakerTime })
        let pause = try #require(await breaker.record(.tooManyRequests, at: URL(string: "https://e-hentai.org/")!))

        // The pause as it happens: `BreakerThrottle` refuses the forum's (guarded) host before the page is asked for.
        let guardedPage = URL(string: "\(ForumPageHandler.scheme)://forums.e-hentai.org/index.php?act=Login&CODE=00")!
        let refused = try await Self.makeHarness()
        let login = WebPasswordLogin(
            bridge: refused.bridge, throttle: BreakerThrottle(base: refused.throttle, breaker: breaker),
            loginPageURL: guardedPage, formURL: ForumPageHandler.form,
            schemeHandler: (refused.handler, ForumPageHandler.scheme), breaker: breaker
        )
        await #expect(throws: EHNetworkError.paused(pause)) {
            try await login.run(username: "fake-user", password: Self.password)
        }
        #expect(refused.handler.received.isEmpty)
        #expect(await refused.throttle.urls.isEmpty)

        // Refused at the form: the same.
        let atTheForm = try await Self.makeHarness(throttle: ThrottleRecorder(refusingFrom: 2), breaker: breaker)
        await #expect(throws: EHNetworkError.paused(pause)) {
            try await atTheForm.login.run(username: "fake-user", password: Self.password)
        }
        #expect(atTheForm.methodsAndURLs() == ["GET \(ForumPageHandler.loginPage.absoluteString)"])

        // No pause in force: a refused load is unreachable, as before.
        let unpaused = try await Self.makeHarness(
            throttle: ThrottleRecorder(refusingFrom: 1), breaker: SiteBreaker(now: { Self.breakerTime })
        )
        await #expect(throws: WebPasswordLoginError.unreachable) {
            try await unpaused.login.run(username: "fake-user", password: Self.password)
        }
        #expect(unpaused.handler.received.isEmpty)
    }

    /// Only a bare-text page can be a notice: a page with markup that mentions a ban is the forum's own page (its
    /// cookies then decide), and an answer that signed in is never checked.
    @Test func pagesWithMarkupOrAnIdentityAreNoNotice() async throws {
        let forumPage = "<html><body><p>Members who are banned cannot post.</p>"
            + "<p>The ban expires in 2 hours and 1 minute</p></body></html>"
        let markup = try await Self.makeHarness(respond: Self.forum(form: { _ in PageAnswer(body: forumPage) }))
        let page = try await markup.login.run(username: "fake-user", password: Self.password)
        #expect(Self.value(CookieNames.memberID, in: page.cookies) == nil)

        let notice = "Your IP address has been temporarily banned. The ban expires in 1 hour"
        let signedIn = try await Self.makeHarness(respond: Self.forum(form: { _ in
            var answer = Self.signsIn()
            answer.body = notice
            return answer
        }))
        let result = try await signedIn.login.run(username: "fake-user", password: Self.password)
        #expect(Self.value(CookieNames.memberID, in: result.cookies) == Self.memberID)

        // A guest's ipb_member_id=0 is no identity: the notice is still found.
        let guest = try await Self.makeHarness(respond: Self.forum(form: { _ in
            PageAnswer(body: notice) { webView in
                await webView.configuration.websiteDataStore.httpCookieStore.setCookies([
                    fakeCookie(CookieNames.memberID, "0"), fakeCookie(CookieNames.passHash, "0"),
                ])
            }
        }))
        await #expect(throws: EHNetworkError.issue(.banned(remaining: .seconds(3_600)))) {
            try await guest.login.run(username: "fake-user", password: Self.password)
        }
    }

    @Test func offlineSendsNothing() async throws {
        let h = try await Self.makeHarness(offline: true)
        await #expect(throws: WebPasswordLoginError.unreachable) {
            try await h.login.run(username: "fake-user", password: Self.password)
        }
        #expect(h.handler.received.isEmpty)
        #expect(await h.throttle.urls.isEmpty)
    }

    @Test func theWebViewIsReleasedAfterRun() async throws {
        let signedIn = try await Self.makeHarness()
        _ = try await signedIn.login.run(username: "fake-user", password: Self.password)
        await waitForRelease(of: signedIn.handler)
        #expect(signedIn.handler.webView == nil)

        let refused = try await Self.makeHarness(respond: Self.forum(form: { _ in .challenge(reloads: true) }))
        await #expect(throws: WebPasswordLoginError.needsWebLogin) {
            try await refused.login.run(username: "fake-user", password: Self.password)
        }
        await waitForRelease(of: refused.handler)
        #expect(refused.handler.webView == nil)
    }

    /// The run does not push the cookie store's jar into the WebView: an earlier account's identity never goes along.
    @Test func doesNotPushTheJar() async throws {
        let oldIdentity = [
            CookieNames.memberID: "7654321", CookieNames.passHash: "fedcba9876543210fedcba9876543210",
            "sk": "sk-old-fake-0001",
        ]
        let seen = Counter()
        let h = try await Self.makeHarness(jar: oldIdentity, respond: Self.forum(form: { _ in
            PageAnswer(body: Self.welcome) { webView in
                // What the WebView store holds when the form arrives.
                let held = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                if held.contains(where: { oldIdentity.values.contains($0.value) }) { seen.value += 1 }
                await webView.configuration.websiteDataStore.httpCookieStore.setCookies([
                    fakeCookie(CookieNames.memberID, Self.memberID), fakeCookie(CookieNames.passHash, Self.passHash),
                ])
            }
        }))
        let result = try await h.login.run(username: "fake-user", password: Self.password)
        #expect(seen.value == 0)
        for request in h.handler.received {
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            #expect(!oldIdentity.values.contains { cookie.contains($0) })
        }
        #expect(!result.cookies.contains { oldIdentity.values.contains($0.value) })
        // The jar itself is untouched by the run.
        #expect(await h.store.snapshot().cookies[.eh] == oldIdentity)
    }

    /// A caller that gives up gets a cancellation at once, long before the timeout.
    @Test func cancellingTheRunThrowsCancellation() async throws {
        let h = try await Self.makeHarness(timeout: .seconds(30), respond: Self.forum(loginPage: { _ in nil }))
        let login = h.login
        let run = Task { try await login.run(username: "fake-user", password: Self.password) }
        #expect(await eventually { h.handler.received.count == 1 })
        let cancelled = ContinuousClock.now
        run.cancel()
        let result = await run.result
        #expect(ContinuousClock.now - cancelled < .seconds(2))
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(h.methodsAndURLs() == ["GET \(ForumPageHandler.loginPage.absoluteString)"])
    }

    /// Cancelled after the form's answer loaded, while the run reads the WebView store's cookies or the page's text
    ///: the run throws `CancellationError`, not the cookies. `bareText()` gives nil at once to
    /// a cancelled caller, so nothing on that way checked for the cancellation.
    ///
    /// The answer has no identity, so the run reads the page's text; the page keeps its main thread busy for two
    /// seconds once it has loaded, so that read waits for WebKit while the test cancels.
    @Test func cancellingWhileTheAnswerIsReadThrowsCancellation() async throws {
        let busy = """
            <html><body><p>Fake answer</p><script>
            window.addEventListener("load", () => setTimeout(() => {
              const end = Date.now() + 2000;
              while (Date.now() < end) {}
            }, 0));
            </script></body></html>
            """
        let h = try await Self.makeHarness(respond: Self.forum(form: { _ in PageAnswer(body: busy) }))
        let login = h.login
        let run = Task { try await login.run(username: "fake-user", password: Self.password) }
        #expect(await eventually { h.handler.httpAnswer(for: ForumPageHandler.form) != nil })
        // The answer has loaded by now, and the run waits for its text.
        try await Task.sleep(for: .milliseconds(500))
        let cancelled = ContinuousClock.now
        run.cancel()
        let result = await run.result
        #expect(ContinuousClock.now - cancelled < .seconds(2))
        #expect(throws: CancellationError.self) { try result.get() }
        // The page's script ends before the next test's WebViews start.
        try await Task.sleep(for: .milliseconds(1600))
    }
}
