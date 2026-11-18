import EHModels
import EHNetwork
import Foundation
import Testing
import WebKit

@testable import Eros

/// Every page is served from the custom scheme `eros-test://` (`ForumPageHandler`) and made up (nickname "Fake
/// Nickname"); nothing here reaches the network. WebKit is up before the first test (`.warmsUpWebContent`), yet every
/// load still starts a web content process of its own within its time limit (`ForumProfileLoader` makes its page):
/// a test whose page must be asked for, or answered, before the time runs out gives it `firstAnswerLimit`.
///
/// Each test has five minutes (`.timeLimit`): some hold a page or a WebKit store call until they let it go, and one
/// that never lets go must fail at the limit, not hang the run (the test process is then ended and started again
/// for the tests after it); five, as WebKit's processes are slow on a busy host (an account flow test once took
/// 143 s under a heavy load), and as `scripts/test.sh` gives a test by default.
@MainActor @Suite(.warmsUpWebContent, .timeLimit(.minutes(5))) struct ForumProfileLoaderTests {
    /// See `WebContentWarmUp.firstAnswerLimit`.
    private static let firstAnswerLimit = WebContentWarmUp.firstAnswerLimit
    /// The longest such a load may take: the limit, and a second for the page to close.
    private static let loadBound = firstAnswerLimit + .seconds(1)
    private static let memberID = 1_234_567
    private static let passHash = "0123456789abcdef0123456789abcdef"
    private static let profileURL = ForumPageHandler.profile(memberID)

    private static let profilePage = """
        <html><body><div id="profile"><div id="profilename"><font>Fake Nickname</font></div>\
        <div>x</div><div><img src="uploads/av-fake.jpg"></div></div></body></html>
        """
    private static let profile = ForumProfile(
        displayName: "Fake Nickname", avatarURL: URL(string: "https://forums.e-hentai.org/uploads/av-fake.jpg")
    )

    private struct ThrottleFailure: Error {}

    /// Counts what it is asked for; throws when `fails`.
    private actor RecordingThrottle: RequestThrottle {
        private(set) var urls: [URL] = []
        let fails: Bool
        init(fails: Bool = false) { self.fails = fails }
        func acquire(for url: URL) async throws {
            urls.append(url)
            if fails { throw ThrottleFailure() }
        }
    }

    @MainActor private final class Counter {
        var value = 0

        func next() -> Int {
            value += 1
            return value
        }
    }

    private struct Harness {
        let loader: ForumProfileLoader
        let handler: ForumPageHandler
        let throttle: RecordingThrottle
        let bridge: WebSessionBridge
        let store: CookieStore
    }

    /// `webStore` and `storeTimeout` go to the bridge (WebKit's own calls and `roomyTestTimeout` by default),
    /// `breaker` to the loader.
    private static func makeHarness(
        timeout: Duration = .seconds(10), throttle: RecordingThrottle = RecordingThrottle(),
        encodedRules: String = BackgroundPage.blockRulesJSON, breaker: SiteBreaker? = nil,
        webStore: (any WebStoreAccess)? = nil, storeTimeout: Duration = WebSessionBridge.roomyTestTimeout,
        respond: @escaping @MainActor (URLRequest) -> PageAnswer? = { _ in PageAnswer(body: profilePage) }
    ) async throws -> Harness {
        let store = CookieStore(vault: InMemoryVault())
        try await store.load()
        try await store.set(
            [CookieNames.memberID: String(memberID), CookieNames.passHash: passHash], for: [.eh]
        )
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        let bridge = WebSessionBridge(
            store: store, userAgents: userAgents, webStore: webStore, storeTimeout: storeTimeout
        )
        let handler = ForumPageHandler(respond: respond)
        let loader = ForumProfileLoader(
            bridge: bridge, throttle: throttle, timeout: timeout, profileURL: { ForumPageHandler.profile($0) },
            schemeHandler: (handler, ForumPageHandler.scheme), encodedRules: encodedRules, breaker: breaker
        )
        return Harness(loader: loader, handler: handler, throttle: throttle, bridge: bridge, store: store)
    }

    @Test func loadsTheProfileFromThePage() async throws {
        let h = try await Self.makeHarness()
        #expect(await h.loader.load(memberID: Self.memberID) == .success(Self.profile))
        #expect(h.handler.requests == [Self.profileURL])
    }

    /// The status decides: a 403 is not read even when its page has a #profilename.
    @Test func non200FallsBack() async throws {
        let h = try await Self.makeHarness { _ in PageAnswer(status: 403, body: Self.profilePage) }
        #expect(await h.loader.load(memberID: Self.memberID) == .failure(.page(.httpStatus(403))))
    }

    @Test func pageWithoutAProfileFallsBack() async throws {
        let h = try await Self.makeHarness { _ in PageAnswer(body: "<html><body>Fake forum error</body></html>") }
        #expect(await h.loader.load(memberID: Self.memberID) == .failure(.notAProfilePage))
    }

    @Test func profileBehindAChallengeLoads() async throws {
        let calls = Counter()
        let h = try await Self.makeHarness { _ in
            calls.next() == 1 ? .challenge(reloads: true) : PageAnswer(body: Self.profilePage)
        }
        try await Self.putHostOnly("ipb_session_id", "fake-session", in: h.bridge)
        #expect(await h.loader.load(memberID: Self.memberID) == .success(Self.profile))
        #expect(h.handler.requests == [Self.profileURL, Self.profileURL])
        #expect(await h.throttle.urls == [Self.profileURL, Self.profileURL])
        // The page was read, so its cookies were pulled back.
        #expect(await h.store.snapshot().cookies[.eh]?["ipb_session_id"] == "fake-session")
    }

    /// `firstAnswerLimit`: the challenge must have arrived before the time runs out.
    @Test func challengeTimeoutFallsBack() async throws {
        let h = try await Self.makeHarness(timeout: Self.firstAnswerLimit) { _ in .challenge(reloads: false) }
        try await Self.putHostOnly("ipb_session_id", "fake-session", in: h.bridge)
        let before = await h.store.snapshot()
        let started = ContinuousClock.now
        #expect(await h.loader.load(memberID: Self.memberID) == .failure(.page(.challengeTimedOut)))
        #expect(ContinuousClock.now - started < Self.loadBound)
        #expect(await h.store.snapshot() == before)
        #expect(h.handler.requests.count == 1)
    }

    /// The load ends when the limit given to the loader runs out, not at some fixed time of its own (the other
    /// timeout tests give 10 s, the same as the default), whether or not the page was asked for, so this needs no
    /// request to arrive (`firstAnswerLimit` is for the tests that do). Each load ends within its limit and a margin
    /// (the loader's `overrun`, the page's close, a busy host), and a limit 3 s longer ends the load about 3 s later.
    @Test func timeoutFollowsTheGivenLimit() async throws {
        var took: [Duration] = []
        for limit in [Duration.seconds(1), .seconds(4)] {
            let h = try await Self.makeHarness(timeout: limit) { _ in nil }
            let started = ContinuousClock.now
            #expect(await h.loader.load(memberID: Self.memberID) == .failure(.page(.timedOut)))
            let elapsed = ContinuousClock.now - started
            #expect(elapsed < limit + .seconds(5), "limit \(limit): \(elapsed)")
            took.append(elapsed)
        }
        let difference = took[1] - took[0]
        #expect(difference > .seconds(1) && difference < .seconds(6), "\(took)")
    }

    /// The limit covers the WebKit store too (M2 review A-M3): a push that hangs ends the load with the limit, a
    /// timeout, without a page and without waiting for the store's own time.
    @Test(.timeLimit(.minutes(1))) func aHungPushEndsWithTheLimit() async throws {
        let webStore = ControlledWebStore(holding: [.setCookies])
        defer { webStore.release() }
        let limit = Duration.seconds(1)
        let h = try await Self.makeHarness(timeout: limit, webStore: webStore, storeTimeout: .seconds(30))
        let before = await h.store.snapshot()
        let started = ContinuousClock.now
        #expect(await h.loader.load(memberID: Self.memberID) == .failure(.page(.timedOut)))
        #expect(ContinuousClock.now - started < limit + ForumProfileLoader.overrun + .seconds(2))
        #expect(webStore.isHolding(.setCookies))
        #expect(h.handler.requests.isEmpty)
        #expect(await h.store.snapshot() == before)
    }

    /// A caller that gives up while the push hangs gets a failure at once, as during the page.
    @Test(.timeLimit(.minutes(1))) func cancellingDuringAHungPushReturnsAtOnce() async throws {
        let webStore = ControlledWebStore(holding: [.setCookies])
        defer { webStore.release() }
        let h = try await Self.makeHarness(timeout: .seconds(30), webStore: webStore, storeTimeout: .seconds(30))
        let loader = h.loader
        let read = Task { await loader.load(memberID: Self.memberID) }
        #expect(await eventually { webStore.isHolding(.setCookies) })
        let cancelled = ContinuousClock.now
        read.cancel()
        #expect(await read.value == .failure(.page(.failed)))
        #expect(ContinuousClock.now - cancelled < .seconds(2))
        #expect(h.handler.requests.isEmpty)
    }

    // MARK: - Site notices (user decision 2026-11-08)

    /// The breakers' fixed time (T).
    nonisolated private static let breakerTime = Date(timeIntervalSince1970: 1_800_000_000)

    /// A bare-text ban notice in place of the profile: recorded with the breaker (both sites pause until its end),
    /// and given as the notice, whether WebKit shows the text as an HTML body or as a `text/plain` document.
    @Test func aBanNoticeInPlaceOfTheProfilePausesTheSites() async throws {
        let notice = "Your IP address has been temporarily banned for excessive pageloads which indicates that you "
            + "are using automated mirroring/harvesting software. The ban expires in 2 hours and 1 minute"
        for contentType in ["text/html; charset=utf-8", "text/plain; charset=utf-8"] {
            let breaker = SiteBreaker(now: { Self.breakerTime })
            let h = try await Self.makeHarness(breaker: breaker) { _ in
                PageAnswer(headers: ["Content-Type": contentType], body: notice)
            }
            let before = await h.store.snapshot()
            let result = await h.loader.load(memberID: Self.memberID)
            #expect(result == .failure(.notice(.banned(remaining: .seconds(7_260)))), Comment(rawValue: contentType))
            let pause = SitePause(reason: .banned, until: Self.breakerTime.addingTimeInterval(7_260))
            #expect(await breaker.current() == pause, Comment(rawValue: contentType))
            #expect(await h.store.snapshot() == before, Comment(rawValue: contentType))
        }

        // A forum page with markup that mentions a ban is no notice.
        let breaker = SiteBreaker(now: { Self.breakerTime })
        let markup = try await Self.makeHarness(breaker: breaker) { _ in
            PageAnswer(body: "<html><body><p>Members who are banned cannot post.</p></body></html>")
        }
        #expect(await markup.loader.load(memberID: Self.memberID) == .failure(.notAProfilePage))
        #expect(await breaker.current() == nil)
    }

    /// A 429 in place of the profile pauses both sites for a minute.
    @Test func tooManyRequestsInPlaceOfTheProfilePausesTheSites() async throws {
        let breaker = SiteBreaker(now: { Self.breakerTime })
        let h = try await Self.makeHarness(breaker: breaker) { _ in
            PageAnswer(status: 429, body: "<html><body>Fake 429</body></html>")
        }
        #expect(await h.loader.load(memberID: Self.memberID) == .failure(.notice(.tooManyRequests)))
        let pause = SitePause(reason: .tooManyRequests, until: Self.breakerTime.addingTimeInterval(60))
        #expect(await breaker.current() == pause)
        #if DEBUG
        #expect(
            SessionDiagnostics.describe(ForumProfileStep.unavailable(.notice(.tooManyRequests)))
                == "unavailable (notice tooManyRequests)"
        )
        #endif
    }

    /// `firstAnswerLimit`: the one request must have reached the handler before the time runs out.
    @Test func timeoutFallsBack() async throws {
        let h = try await Self.makeHarness(timeout: Self.firstAnswerLimit) { _ in nil }
        let started = ContinuousClock.now
        #expect(await h.loader.load(memberID: Self.memberID) == .failure(.page(.timedOut)))
        #expect(ContinuousClock.now - started < Self.loadBound)
        #expect(h.handler.requests.count == 1)
    }

    @Test func oneNavigationIsThrottled() async throws {
        let h = try await Self.makeHarness()
        _ = await h.loader.load(memberID: Self.memberID)
        #expect(await h.throttle.urls == [Self.profileURL])
        #expect(h.handler.requests.count == 1)

        let failing = try await Self.makeHarness(throttle: RecordingThrottle(fails: true))
        #expect(await failing.loader.load(memberID: Self.memberID) == .failure(.page(.throttled)))
        #expect(await failing.throttle.urls.count == 1)
        #expect(failing.handler.requests.isEmpty)
    }

    @Test func contentRulesCompile() async throws {
        #expect(ForumProfileLoader.blockedResourceTypes == ["image", "style-sheet", "font", "media"])
        #expect(await BackgroundPage.compileRules() != nil)
        // Whether they are installed in the WebView shows in blockedResourcesAreNotRequested.
    }

    @Test func rulesThatDoNotCompileMeanNoLoadAtAll() async throws {
        let h = try await Self.makeHarness(encodedRules: "this is not a rule list")
        #expect(await BackgroundPage.compileRules("this is not a rule list") == nil)
        #expect(await h.loader.load(memberID: Self.memberID) == .failure(.rules))
        #expect(await h.throttle.urls.isEmpty)
        #expect(h.handler.requests.isEmpty)
    }

    @Test func blockedResourcesAreNotRequested() async throws {
        let page = Self.profilePage.replacingOccurrences(
            of: "</body>", with: "<img src=\"eros-test://forums/pic.png\"></body>"
        )
        let h = try await Self.makeHarness { request in
            request.url?.path == "/pic.png" ? PageAnswer(body: "x") : PageAnswer(body: page)
        }
        _ = await h.loader.load(memberID: Self.memberID)
        #expect(h.handler.requests.count == 1)
    }

    @Test func neverSetsACustomUserAgent() async throws {
        let h = try await Self.makeHarness()
        _ = await h.loader.load(memberID: Self.memberID)
        let facts = try #require(h.handler.facts.first)
        // WebKit reports an unset customUserAgent as "".
        #expect((facts.customUserAgent ?? "").isEmpty)
        #expect(facts.applicationName == WKWebViewConfiguration().applicationNameForUserAgent)
        #expect(facts.userScriptCount == 0)
        #expect(facts.dataStore === h.bridge.dataStore)
    }

    @Test func theWebViewIsReleasedWhenLoadReturns() async throws {
        let h = try await Self.makeHarness()
        _ = await h.loader.load(memberID: Self.memberID)
        #expect(h.handler.requests.count == 1)
        await waitForRelease(of: h.handler)
        #expect(h.handler.webView == nil)

        // Also after a timeout. The request must have reached the handler (which then held the WebView), or a nil
        // WebView would prove nothing.
        let slow = try await Self.makeHarness(timeout: Self.firstAnswerLimit) { _ in nil }
        #expect(await slow.loader.load(memberID: Self.memberID) == .failure(.page(.timedOut)))
        #expect(slow.handler.requests.count == 1)
        await waitForRelease(of: slow.handler)
        #expect(slow.handler.webView == nil)
    }

    @Test func anotherAccountsIdentityInThePageIsNotWrittenBack() async throws {
        let h = try await Self.makeHarness()
        let before = await h.store.snapshot()
        // A leftover host-only identity of an earlier account: push() does not overwrite it.
        try await Self.putHostOnly(CookieNames.memberID, "7654321", in: h.bridge)
        let profile = try await h.loader.load(memberID: Self.memberID).get()
        #expect(profile.displayName == "Fake Nickname")
        #expect(await h.store.snapshot() == before)
        #expect(await h.store.memberID == Self.memberID)
    }

    @Test func pageCookiesAreWrittenBack() async throws {
        let h = try await Self.makeHarness()
        try await Self.putHostOnly("ipb_session_id", "fake-session", in: h.bridge)
        #expect(try await h.loader.load(memberID: Self.memberID).get().displayName == "Fake Nickname")
        #expect(await h.store.snapshot().cookies[.eh]?["ipb_session_id"] == "fake-session")
    }

    /// Each case must fail the way it is named (a challenge that had not arrived within the time
    /// would have been a plain timeout, and proved nothing about challenges). The plain timeout is one whether or not
    /// its page was asked for, so a second does.
    @Test func failedLoadsWriteNothing() async throws {
        let cases: [(String, ForumProfileFailure, Harness)] = [
            ("page without a profile", .notAProfilePage, try await Self.makeHarness { _ in
                PageAnswer(body: "<html><body>Just a moment...</body></html>")
            }),
            ("403", .page(.httpStatus(403)), try await Self.makeHarness { _ in
                PageAnswer(status: 403, body: Self.profilePage)
            }),
            ("challenge timeout", .page(.challengeTimedOut), try await Self.makeHarness(
                timeout: Self.firstAnswerLimit
            ) { _ in
                .challenge(reloads: false)
            }),
            ("timeout", .page(.timedOut), try await Self.makeHarness(timeout: .seconds(1)) { _ in nil }),
            ("throttle error", .page(.throttled), try await Self.makeHarness(throttle: RecordingThrottle(fails: true))),
        ]
        for (name, failure, h) in cases {
            try await Self.putHostOnly("ipb_session_id", "fake-session", in: h.bridge)
            let before = await h.store.snapshot()
            let result = await h.loader.load(memberID: Self.memberID)
            #expect(result == .failure(failure), Comment(rawValue: name))
            #expect(await h.store.snapshot() == before, Comment(rawValue: name))
        }
    }

    /// A value the jar got while the page was read (a URLSession response's `sk`) is not put back to the one pushed
    /// before the page; what the page itself set is written.
    @Test func aNewerJarValueOutlivesTheRead() async throws {
        let store = Box<CookieStore>()
        let h = try await Self.makeHarness { _ in
            PageAnswer(body: Self.profilePage) { webView in
                // While the page loads: a response elsewhere changes sk, and the page sets a session cookie.
                try? await store.value?.set(["sk": "sk-new-fake-0002"], for: [.eh])
                await webView.configuration.websiteDataStore.httpCookieStore.setCookie(
                    fakeCookie("ipb_session_id", "fake-session", domain: "forums.e-hentai.org")
                )
            }
        }
        store.value = h.store
        try await h.store.set(["sk": "sk-old-fake-0001"], for: [.eh])
        #expect(try await h.loader.load(memberID: Self.memberID).get() == Self.profile)
        let jar = await h.store.snapshot().cookies[.eh] ?? [:]
        #expect(jar["sk"] == "sk-new-fake-0002")
        #expect(jar["ipb_session_id"] == "fake-session")
        #expect(jar[CookieNames.memberID] == String(Self.memberID))
    }

    /// A read for a session that ended while the page loaded (`epoch` no longer the cookie store's) writes nothing,
    /// even when the same member is signed in again.
    @Test func aReadForAnEndedSessionWritesNothing() async throws {
        let store = Box<CookieStore>()
        let identity = [CookieNames.memberID: String(Self.memberID), CookieNames.passHash: Self.passHash]
        let h = try await Self.makeHarness { _ in
            PageAnswer(body: Self.profilePage) { webView in
                // Logged out and signed in again as the same member while the page loads.
                try? await store.value?.reset()
                try? await store.value?.set(identity, for: [.eh])
                await webView.configuration.websiteDataStore.httpCookieStore.setCookie(
                    fakeCookie("ipb_session_id", "fake-session", domain: "forums.e-hentai.org")
                )
            }
        }
        store.value = h.store
        let epoch = await h.store.epoch
        #expect(try await h.loader.load(memberID: Self.memberID, epoch: epoch).get() == Self.profile)
        #expect(await h.store.snapshot().cookies[.eh] == identity)
        #expect(await h.store.epoch != epoch)

        // The same read with the store's own epoch takes the page's cookie.
        let current = try await Self.makeHarness()
        try await Self.putHostOnly("ipb_session_id", "fake-session", in: current.bridge)
        _ = await current.loader.load(memberID: Self.memberID, epoch: await current.store.epoch)
        #expect(await current.store.snapshot().cookies[.eh]?["ipb_session_id"] == "fake-session")
    }

    /// A caller that gives up while the page loads gets a failure at once and nothing is written.
    @Test func cancellingTheCallerWritesNothing() async throws {
        let h = try await Self.makeHarness(timeout: .seconds(30)) { _ in nil }
        try await Self.putHostOnly("ipb_session_id", "fake-session", in: h.bridge)
        let before = await h.store.snapshot()
        let loader = h.loader
        let read = Task { await loader.load(memberID: Self.memberID) }
        #expect(await eventually { h.handler.requests.count == 1 })
        let cancelled = ContinuousClock.now
        read.cancel()
        #expect(await read.value == .failure(.page(.failed)))
        #expect(ContinuousClock.now - cancelled < .seconds(2))
        #expect(await h.store.snapshot() == before)
        await waitForRelease(of: h.handler)
        #expect(h.handler.webView == nil)
    }

    private static func putHostOnly(_ name: String, _ value: String, in bridge: WebSessionBridge) async throws {
        await bridge.dataStore.httpCookieStore.setCookie(fakeCookie(name, value, domain: "forums.e-hentai.org"))
    }
}
