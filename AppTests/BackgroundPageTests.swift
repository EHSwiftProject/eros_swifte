import EHNetwork
import Foundation
import Testing
import WebKit

@testable import Eros

/// Every page is made up and served from the custom scheme `eros-test://` (`ForumPageHandler`), including the
/// "Cloudflare challenges" (a 403 with `cf-mitigated: challenge`); nothing here reaches the network. The 1–2 s limits
/// below assume WebKit is up (`.warmsUpWebContent`).
///
/// Each test has five minutes (`.timeLimit`): some hold a page or a WebKit store call until they let it go, and one
/// that never lets go must fail at the limit, not hang the run (the test process is then ended and started again
/// for the tests after it); five, as WebKit's processes are slow on a busy host (an account flow test once took
/// 143 s under a heavy load), and as `scripts/test.sh` gives a test by default.
@MainActor @Suite(.warmsUpWebContent, .timeLimit(.minutes(5))) struct BackgroundPageTests {
    private static let page = ForumPageHandler.profile(1_234_567)
    private static let plainPage = "<html><body>Fake page</body></html>"

    @MainActor private final class Counter {
        var value = 0

        func next() -> Int {
            value += 1
            return value
        }
    }

    /// Reports one fixed answer for every URL.
    @MainActor private final class FixedReporter: HTTPAnswerReporting {
        let answer: HTTPURLResponse?
        init(_ answer: HTTPURLResponse?) { self.answer = answer }
        func httpAnswer(for url: URL) -> HTTPURLResponse? { answer }
    }

    private struct Harness {
        let page: BackgroundPage
        let handler: ForumPageHandler
        let throttle: ThrottleRecorder
    }

    private static func makeHarness(
        throttle: ThrottleRecorder = ThrottleRecorder(),
        respond: @escaping @MainActor (URLRequest) -> PageAnswer?
    ) async throws -> Harness {
        let rules = try #require(await BackgroundPage.compileRules())
        let handler = ForumPageHandler(respond: respond)
        let page = BackgroundPage(
            dataStore: .nonPersistent(), rules: rules, throttle: throttle,
            schemeHandler: (handler, ForumPageHandler.scheme)
        )
        return Harness(page: page, handler: handler, throttle: throttle)
    }

    private static func load(
        _ h: Harness, allowsChallenge: Bool = true, timeout: Duration = .seconds(10)
    ) async -> BackgroundPageOutcome {
        await h.page.load(URLRequest(url: page), allowsChallenge: allowsChallenge, timeout: timeout)
    }

    // MARK: - Loads

    @Test func plainPageLoads() async throws {
        let h = try await Self.makeHarness { _ in PageAnswer(body: Self.plainPage) }
        defer { h.page.close() }
        #expect(await Self.load(h) == .loaded)
        #expect(await h.throttle.urls == [Self.page])
        #expect(h.handler.requests == [Self.page])
        #expect(await h.page.html()?.contains("Fake page") == true)
        #expect(h.page.url == Self.page)
    }

    @Test func challengeThatReloadsByItselfLoads() async throws {
        let calls = Counter()
        let h = try await Self.makeHarness { _ in
            calls.next() == 1 ? .challenge(reloads: true) : PageAnswer(body: Self.plainPage)
        }
        defer { h.page.close() }
        #expect(await Self.load(h) == .loaded)
        // The reload is a navigation of its own: it waited for the throttle too.
        #expect(await h.throttle.urls == [Self.page, Self.page])
        #expect(h.handler.requests.count == 2)
        #expect(await h.page.html()?.contains("Fake page") == true)
    }

    /// A challenge whose script moves on twice: its first navigation has gone out and is still waiting for its answer
    /// when the second one replaces it. WebKit cancels the first (-999, before it asks about the second); that is not a
    /// failure, the second decides.
    ///
    /// Measured on the iOS 27.2 simulator: a page that navigates at once while it is parsed
    /// produces no -999, as WebKit holds that navigation until the page has finished; nor does a page whose sub-frame
    /// is still loading (the page then finishes). Only a navigation still provisional is cancelled with -999.
    @Test func challengeThatMovesOnTwiceLoads() async throws {
        let pending = URL(string: "eros-test://forums/index.php?act=pending")!
        let calls = Counter()
        let h = try await Self.makeHarness { request in
            if request.url == pending { return nil }
            guard calls.next() == 1 else { return PageAnswer(body: Self.plainPage) }
            return PageAnswer(
                status: 403, headers: ["cf-mitigated": "challenge"],
                body: "<html><head><title>Just a moment...</title></head><body>Fake challenge<script>"
                    + "setTimeout(function () { location.replace('\(pending.absoluteString)') }, 0);"
                    + "setTimeout(function () { location.replace('\(Self.page.absoluteString)') }, 500)"
                    + "</script></body></html>"
            )
        }
        defer { h.page.close() }
        #expect(await Self.load(h) == .loaded)
        // The first navigation had gone out (so it was cancelled while provisional), then the second one loaded.
        #expect(h.handler.requests == [Self.page, pending, Self.page])
        #expect(await h.throttle.urls == [Self.page, pending, Self.page])
        #expect(await h.page.html()?.contains("Fake page") == true)
    }

    @Test func challengeThatNeverMovesTimesOut() async throws {
        let warmUp = ForumPageHandler.loginPage
        let h = try await Self.makeHarness { request in
            request.url == warmUp ? PageAnswer(body: Self.plainPage) : .challenge(reloads: false)
        }
        defer { h.page.close() }
        // A WebView's first load starts its web content process, which can take longer than the second here when
        // many tests start WebViews at once: a page loaded first leaves the whole second for the challenge.
        #expect(await h.page.load(URLRequest(url: warmUp), allowsChallenge: false, timeout: .seconds(10)) == .loaded)
        let started = ContinuousClock.now
        #expect(await Self.load(h, timeout: .seconds(1)) == .challengeTimedOut)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(h.handler.requests.filter { $0 == Self.page }.count == 1)
        // The challenge page is never read.
        #expect(await h.page.html() == nil)
    }

    @Test func challengeIsRefusedWhenNotAllowed() async throws {
        let h = try await Self.makeHarness { _ in .challenge(reloads: true) }
        defer { h.page.close() }
        #expect(await Self.load(h, allowsChallenge: false) == .challenged)
        // The page was never shown, so its script never ran: no second request.
        try await Task.sleep(for: .milliseconds(500))
        #expect(h.handler.requests.count == 1)
        #expect(await h.throttle.urls.count == 1)
        #expect(await h.page.html() == nil)
    }

    @Test func non200WithoutChallengeHeaderIsAStatus() async throws {
        let h = try await Self.makeHarness { _ in PageAnswer(status: 403, body: Self.plainPage) }
        defer { h.page.close() }
        #expect(await Self.load(h) == .httpStatus(403))
        #expect(await h.page.html() == nil)

        // The header decides, not the page: a 200 that looks like a challenge is a page.
        let lookalike = try await Self.makeHarness { _ in
            PageAnswer(body: "<html><head><title>Just a moment...</title></head><body>Fake</body></html>")
        }
        defer { lookalike.page.close() }
        #expect(await Self.load(lookalike) == .loaded)
    }

    @Test func throttleErrorOnALaterNavigationStops() async throws {
        let h = try await Self.makeHarness(throttle: ThrottleRecorder(refusingFrom: 2)) { _ in .challenge(reloads: true) }
        defer { h.page.close() }
        #expect(await Self.load(h) == .throttled)
        #expect(await h.throttle.urls.count == 2)
        #expect(h.handler.requests.count == 1)
    }

    @Test func navigationLoopStopsAtTheCap() async throws {
        let h = try await Self.makeHarness { _ in .challenge(reloads: true) }
        defer { h.page.close() }
        #expect(await Self.load(h, timeout: .seconds(20)) == .tooManyNavigations)
        // The fifth main-frame navigation was refused before the throttle.
        #expect(h.handler.requests.count == BackgroundPage.maxNavigations)
        #expect(await h.throttle.urls.count == BackgroundPage.maxNavigations)
    }

    /// The page's own navigations after a load has ended are refused (they would not wait for the throttle).
    @Test func navigationsAfterTheLoadAreRefused() async throws {
        let page = "<html><body>Fake page<script>setTimeout(function () { "
            + "location.href = 'eros-test://forums/index.php?act=other' }, 200)</script></body></html>"
        let h = try await Self.makeHarness { _ in PageAnswer(body: page) }
        defer { h.page.close() }
        #expect(await Self.load(h) == .loaded)
        try await Task.sleep(for: .milliseconds(700))
        #expect(h.handler.requests == [Self.page])
        #expect(await h.throttle.urls == [Self.page])
        #expect(h.page.url == Self.page)
    }

    @Test func timeoutWithoutAChallengeIsTimedOut() async throws {
        let h = try await Self.makeHarness { _ in nil }
        defer { h.page.close() }
        let started = ContinuousClock.now
        #expect(await Self.load(h, timeout: .seconds(1)) == .timedOut)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    /// A caller that gives up ends the load at once: `.failed`, long before the timeout.
    @Test func cancellingTheCallerEndsTheLoad() async throws {
        let h = try await Self.makeHarness { _ in nil }
        defer { h.page.close() }
        let page = h.page
        let load = Task { await page.load(URLRequest(url: Self.page), allowsChallenge: true, timeout: .seconds(30)) }
        #expect(await eventually { h.handler.requests.count == 1 })
        let cancelled = ContinuousClock.now
        load.cancel()
        #expect(await load.value == .failed)
        #expect(ContinuousClock.now - cancelled < .seconds(2))

        // Already cancelled before it starts: nothing is sent.
        let other = try await Self.makeHarness { _ in PageAnswer(body: Self.plainPage) }
        defer { other.page.close() }
        let otherPage = other.page
        // The task runs on the main actor, so it cannot start before it is cancelled here.
        let early = Task { await otherPage.load(URLRequest(url: Self.page), allowsChallenge: true, timeout: .seconds(10)) }
        early.cancel()
        #expect(await early.value == .failed)
        #expect(other.handler.requests.isEmpty)
        #expect(await other.throttle.urls.isEmpty)
    }

    /// A read the caller gives up on ends at once, even while the page's main thread is busy and WebKit cannot
    /// answer: nothing that ends a read (logging out, the next login) waits on the page.
    @Test func cancellingAReadEndsItAtOnce() async throws {
        // The page keeps its main thread busy for 2 s, from 300 ms after it loaded.
        let busy = "<html><body>Fake page<script>setTimeout(function () { "
            + "var end = Date.now() + 2000; while (Date.now() < end) {} }, 300)</script></body></html>"
        let h = try await Self.makeHarness { _ in PageAnswer(body: busy) }
        defer { h.page.close() }
        #expect(await Self.load(h) == .loaded)
        try await Task.sleep(for: .milliseconds(500))
        let page = h.page
        let read = Task { await page.html() }
        try await Task.sleep(for: .milliseconds(200))
        let cancelled = ContinuousClock.now
        read.cancel()
        #expect(await read.value == nil)
        #expect(ContinuousClock.now - cancelled < .milliseconds(500))
        // Once the page is free again, a read that is not cancelled gets the page.
        #expect(await h.page.html()?.contains("Fake page") == true)
    }

    /// A load that ends while its navigation waits for the throttle (its caller cancelled, or the page closed) stops
    /// that wait at once: WebKit's decision returns without the throttle ever letting the request
    /// through, so whoever ends a password login or a profile read does not keep the WebView until the throttle's turn.
    @Test func cancelledLoadStopsWaitingForTheThrottle() async throws {
        let throttle = SuspendingThrottle()
        let h = try await Self.makePage(throttle: throttle) { _ in PageAnswer(body: Self.plainPage) }
        defer { h.page.close() }
        let page = h.page
        let load = Task { await page.load(URLRequest(url: Self.page), allowsChallenge: true, timeout: .seconds(30)) }
        #expect(await eventually { await throttle.waiting == 1 })
        load.cancel()
        #expect(await load.value == .failed)
        #expect(await eventually(within: .seconds(1)) { await throttle.cancellations == 1 })
        #expect(h.handler.requests.isEmpty)

        // Closing the page while its load waits for the throttle ends the wait the same way.
        let closing = SuspendingThrottle()
        let other = try await Self.makePage(throttle: closing) { _ in PageAnswer(body: Self.plainPage) }
        let otherPage = other.page
        let pending = Task {
            await otherPage.load(URLRequest(url: Self.page), allowsChallenge: true, timeout: .seconds(30))
        }
        #expect(await eventually { await closing.waiting == 1 })
        otherPage.close()
        #expect(await pending.value == .failed)
        #expect(await eventually(within: .seconds(1)) { await closing.cancellations == 1 })
        #expect(other.handler.requests.isEmpty)
    }

    /// A page on `throttle` (any kind, unlike `makeHarness`) and its scheme handler.
    private static func makePage(
        throttle: any RequestThrottle, respond: @escaping @MainActor (URLRequest) -> PageAnswer?
    ) async throws -> (page: BackgroundPage, handler: ForumPageHandler) {
        let rules = try #require(await BackgroundPage.compileRules())
        let handler = ForumPageHandler(respond: respond)
        let page = BackgroundPage(
            dataStore: .nonPersistent(), rules: rules, throttle: throttle,
            schemeHandler: (handler, ForumPageHandler.scheme)
        )
        return (page, handler)
    }

    @Test func oneLoadAfterAnother() async throws {
        let second = ForumPageHandler.loginPage
        let h = try await Self.makeHarness { request in
            PageAnswer(body: request.url == second ? "<html><body>Second</body></html>" : Self.plainPage)
        }
        defer { h.page.close() }
        #expect(await Self.load(h) == .loaded)
        #expect(await h.page.load(URLRequest(url: second), allowsChallenge: false, timeout: .seconds(10)) == .loaded)
        #expect(await h.page.html()?.contains("Second") == true)
        #expect(await h.throttle.urls == [Self.page, second])
        #expect(h.page.url == second)
    }

    @Test func closedPageDoesNothing() async throws {
        let h = try await Self.makeHarness { _ in PageAnswer(body: Self.plainPage) }
        h.page.close()
        #expect(await Self.load(h) == .failed)
        #expect(await h.page.html() == nil)
        #expect(h.page.url == nil)
        h.page.close()
        #expect(h.handler.requests.isEmpty)
        #expect(await h.throttle.urls.isEmpty)
    }

    // MARK: - Rules and checks

    @Test func rulesExemptTheChallengeHost() async throws {
        #expect(await BackgroundPage.compileRules() != nil)
        let json = BackgroundPage.blockRulesJSON
        #expect(json.contains("ignore-previous-rules"))
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(rules.count == 2)
        let block = try #require(rules.first)
        #expect((block["action"] as? [String: String]) == ["type": "block"])
        let blockTrigger = try #require(block["trigger"] as? [String: Any])
        #expect(blockTrigger["url-filter"] as? String == ".*")
        #expect(blockTrigger["resource-type"] as? [String] == ForumProfileLoader.blockedResourceTypes)
        // The exemption comes after the blocklist, so it lifts it for the challenge's own resources.
        let exemption = try #require(rules.last)
        #expect((exemption["action"] as? [String: String]) == ["type": "ignore-previous-rules"])
        let exemptionTrigger = try #require(exemption["trigger"] as? [String: Any])
        #expect(exemptionTrigger["url-filter"] as? String == #"^https://challenges\.cloudflare\.com/"#)
        #expect(exemptionTrigger["resource-type"] == nil)
    }

    @Test func challengeHeaderIsReadCaseInsensitively() throws {
        let url = try #require(URL(string: "https://forums.e-hentai.org/index.php"))
        func answer(_ status: Int, _ headers: [String: String]) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
        }
        #expect(CloudflareChallenge.isChallenge(try answer(403, ["CF-Mitigated": "Challenge"])))
        #expect(CloudflareChallenge.isChallenge(try answer(403, ["cf-mitigated": "challenge"])))
        #expect(CloudflareChallenge.isChallenge(try answer(200, ["Cf-Mitigated": "CHALLENGE"])))
        #expect(!CloudflareChallenge.isChallenge(try answer(403, [:])))
        #expect(!CloudflareChallenge.isChallenge(try answer(403, ["cf-mitigated": "block"])))
        #expect(!CloudflareChallenge.isChallenge(try answer(403, ["cf-mitigated-other": "challenge"])))
        let plain = URLResponse(url: url, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil)
        #expect(!CloudflareChallenge.isChallenge(plain))
    }

    /// WebKit drops the status of a custom scheme's answer, so the 200 rule itself is checked on the responses.
    @Test func onlyA200HttpAnswerIsAccepted() throws {
        let https = try #require(URL(string: "https://forums.e-hentai.org/index.php?showuser=1"))
        func answer(_ status: Int) throws -> URLResponse {
            try #require(HTTPURLResponse(url: https, statusCode: status, httpVersion: nil, headerFields: nil))
        }
        func plain(_ url: URL) -> URLResponse {
            URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        }
        let scheme = ForumPageHandler.scheme
        #expect(try BackgroundPage.accepts(answer(200)))
        for status in [204, 301, 403, 429, 503] { #expect(try !BackgroundPage.accepts(answer(status))) }
        #expect(!BackgroundPage.accepts(plain(https)))
        #expect(!BackgroundPage.accepts(plain(https), statuslessScheme: scheme))

        // Only the scheme the test registered may come without a status.
        let custom = try #require(URL(string: "eros-test://forums/index.php"))
        #expect(BackgroundPage.accepts(plain(custom), statuslessScheme: scheme))
        #expect(!BackgroundPage.accepts(plain(custom)))
        for other in ["data:text/html,x", "about:blank", "blob:eros-test://x", "file:///x", "other-scheme://x"] {
            let url = try #require(URL(string: other))
            #expect(!BackgroundPage.accepts(plain(url), statuslessScheme: scheme), Comment(rawValue: other))
        }
    }

    /// How a main-frame answer is decided, on HTTP answers as the site gives them.
    @Test func answersAreDecidedAsTheBriefSays() throws {
        let url = try #require(URL(string: "https://forums.e-hentai.org/index.php"))
        func answer(_ status: Int, challenge: Bool = false) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: challenge ? ["cf-mitigated": "challenge"] : [:]
            ))
        }
        func decision(_ response: URLResponse, allowsChallenge: Bool = true) -> BackgroundPage.ResponseDecision {
            BackgroundPage.decision(for: response, allowsChallenge: allowsChallenge, statuslessScheme: nil)
        }
        #expect(try decision(answer(200)) == .page)
        #expect(try decision(answer(403, challenge: true)) == .challenge)
        #expect(try decision(answer(503, challenge: true)) == .challenge)
        #expect(try decision(answer(403, challenge: true), allowsChallenge: false) == .refuse(.challenged))
        #expect(try decision(answer(403)) == .refuse(.httpStatus(403)))
        #expect(try decision(answer(302)) == .refuse(.httpStatus(302)))
        let plain = URLResponse(url: url, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil)
        #expect(decision(plain) == .refuse(.failed))
    }

    /// The tests-only answer report is used only for a status-less answer of the registered scheme.
    @Test func reportedAnswersStandInOnlyForTheTestScheme() throws {
        let custom = try #require(URL(string: "eros-test://forums/index.php"))
        let https = try #require(URL(string: "https://forums.e-hentai.org/index.php"))
        let reported = try #require(HTTPURLResponse(
            url: custom, statusCode: 403, httpVersion: nil, headerFields: ["cf-mitigated": "challenge"]
        ))
        let reporter = FixedReporter(reported)
        let plainCustom = URLResponse(url: custom, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil)
        let plainHTTPS = URLResponse(url: https, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil)
        let webKitHTTP = try #require(HTTPURLResponse(url: custom, statusCode: 200, httpVersion: nil, headerFields: nil))

        #expect(BackgroundPage.answer(for: plainCustom, statuslessScheme: "eros-test", reporter: reporter) === reported)
        // WebKit's own HTTP answer always wins.
        #expect(BackgroundPage.answer(for: webKitHTTP, statuslessScheme: "eros-test", reporter: reporter) === webKitHTTP)
        // Another scheme, no registered scheme, no reporter, or nothing reported: WebKit's answer.
        #expect(BackgroundPage.answer(for: plainHTTPS, statuslessScheme: "eros-test", reporter: reporter) === plainHTTPS)
        #expect(BackgroundPage.answer(for: plainCustom, statuslessScheme: nil, reporter: reporter) === plainCustom)
        #expect(BackgroundPage.answer(for: plainCustom, statuslessScheme: "eros-test", reporter: nil) === plainCustom)
        let silent = FixedReporter(nil)
        #expect(BackgroundPage.answer(for: plainCustom, statuslessScheme: "eros-test", reporter: silent) === plainCustom)
    }

    /// A page loaded in the background sends the UA the probe reads, the one URLSession sends: on the iPad too, where
    /// WebKit would otherwise load it as a desktop browser with the Mac UA (M2 review A-I1). Its content mode is the
    /// app's (`WKWebViewConfiguration.app()`).
    @Test func pagesSendTheProbesUserAgent() async throws {
        let probed = try await WebKitUserAgentProbe.read()
        let h = try await Self.makeHarness { _ in PageAnswer(body: Self.plainPage) }
        defer { h.page.close() }
        #expect(await Self.load(h) == .loaded)
        let request = try #require(h.handler.received.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == probed)
        let webView = try #require(h.handler.webView)
        #expect(webView.configuration.defaultWebpagePreferences.preferredContentMode == .mobile)
        let reported = try await webView.evaluateJavaScript("navigator.userAgent", contentWorld: .defaultClient)
        #expect(reported as? String == probed)
    }

    @Test func neverInjectsAnything() async throws {
        let h = try await Self.makeHarness { _ in PageAnswer(body: Self.plainPage) }
        defer { h.page.close() }
        #expect(await Self.load(h) == .loaded)
        _ = await h.page.html()
        let facts = try #require(h.handler.facts.first)
        // WebKit reports an unset customUserAgent as "".
        #expect((facts.customUserAgent ?? "").isEmpty)
        #expect(facts.applicationName == WKWebViewConfiguration().applicationNameForUserAgent)
        #expect(facts.userScriptCount == 0)
        let webView = try #require(h.handler.webView)
        #expect((webView.customUserAgent ?? "").isEmpty)
        #expect(webView.configuration.userContentController.userScripts.isEmpty)
    }
}
