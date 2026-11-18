import EHNetwork
import Foundation
import WebKit

/// How one `BackgroundPage.load` ended.
nonisolated enum BackgroundPageOutcome: Equatable, Sendable {
    /// The main frame finished on a 200 (or on the tests' statusless scheme).
    case loaded
    /// The main frame answered a non-200 that is not a Cloudflare challenge.
    case httpStatus(Int)
    /// A challenge answered a load that does not allow one.
    case challenged
    /// A challenge page was still showing when the time ran out.
    case challengeTimedOut
    /// The time ran out without a challenge.
    case timedOut
    /// The throttle threw for a navigation.
    case throttled
    /// More than `BackgroundPage.maxNavigations` main-frame navigations.
    case tooManyNavigations
    /// A load error, or the web content process ended; also a caller that gave up, and a closed page.
    case failed
}

/// Cloudflare's answer when it wants the browser to prove itself first (a "challenge page").
nonisolated enum CloudflareChallenge {
    /// An HTTP answer whose `cf-mitigated` header is `challenge` (case-insensitive name and value), whatever its status.
    static func isChallenge(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              let value = http.value(forHTTPHeaderField: "cf-mitigated") else { return false }
        return value.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("challenge") == .orderedSame
    }
}

/// Tests only (in the app `schemeHandler` is nil, so this is never used): a test's scheme handler that tells the HTTP
/// answer it gave for a URL.
///
/// WebKit hands a custom scheme's answer to the navigation delegate as a plain `URLResponse`, without the status and
/// the headers the handler gave (measured on the iOS 27.2 simulator, account A3b), so without this a test could not
/// make a page answer 403 or carry `cf-mitigated`.
@MainActor protocol HTTPAnswerReporting: AnyObject {
    /// The HTTP answer this handler last gave for `url`; nil when it gave none.
    func httpAnswer(for url: URL) -> HTTPURLResponse?
}

/// One WKWebView that is never attached to a window, for the forum pages the app reads or posts in the background
/// with the session store: the profile page (account A2) and the password login (A3b).
///
/// User decisions 2026-11-05 and 2026-11-07: no evasion of bot detection. No `customUserAgent`, no user scripts,
/// nothing injected, read or clicked on a challenge page. A Cloudflare challenge (`cf-mitigated: challenge`) is left
/// to its own scripts, as in any browser, when the load allows one; when the time runs out first, the caller falls
/// back.
///
/// Every main-frame navigation of a load, the page's own included (a challenge's reload, a redirect, the page after a
/// form), waits for the throttle first and counts against `maxNavigations`; sub-frames (the challenge's iframe) and
/// sub-resources do neither, and the blocklist keeps images, style sheets, fonts and media from loading at all.
/// Outside a load, main-frame navigations are refused: a page left showing cannot request on its own.
@MainActor final class BackgroundPage {
    static let maxNavigations = 4

    private static let ruleListIdentifier = "proj.eros.swifte.background-page-blocklist"

    private var webView: WKWebView?
    private var navigator: Navigator?
    /// How the last load ended; `html()` reads only after `.loaded`.
    private var lastOutcome: BackgroundPageOutcome?

    /// One WKWebView never attached to a window: the app's configuration (`WKWebViewConfiguration.app()`, mobile
    /// content: the UA it sends is the probe's), `dataStore`, the rules, the scheme handler (tests only); no
    /// customUserAgent, no user scripts, nothing injected.
    init(
        dataStore: WKWebsiteDataStore, rules: WKContentRuleList, throttle: any RequestThrottle,
        schemeHandler: (handler: any WKURLSchemeHandler, scheme: String)? = nil
    ) {
        let configuration = WKWebViewConfiguration.app()
        configuration.websiteDataStore = dataStore
        if let schemeHandler {
            configuration.setURLSchemeHandler(schemeHandler.handler, forURLScheme: schemeHandler.scheme)
        }
        configuration.userContentController.add(rules)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        let navigator = Navigator(
            throttle: throttle, statuslessScheme: schemeHandler?.scheme,
            reporter: schemeHandler?.handler as? any HTTPAnswerReporting
        )
        webView.navigationDelegate = navigator
        self.webView = webView
        self.navigator = navigator
    }

    /// The URL of the page now showing; nil once closed.
    var url: URL? { webView?.url }

    /// Loads `request` in the main frame and waits for the outcome; `timeout` is the whole load's time, a challenge
    /// and its reloads included.
    ///
    /// A challenge answer is let through when `allowsChallenge` (its own scripts may then navigate on; its finishing
    /// does not count), and refused otherwise (`.challenged`). Any other main-frame answer must be a 200 (or the
    /// tests' statusless scheme): otherwise `.httpStatus` (`.failed` without a status). The first main-frame
    /// navigation that is no challenge and finishes gives `.loaded`. When the time runs out: `.challengeTimedOut`
    /// once a challenge was seen, `.timedOut` otherwise. A caller that is cancelled gets `.failed` at once and the
    /// load is stopped; a navigation still waiting for the throttle then stops waiting (it never goes out). Loads run
    /// one after another, each with its own count and time; after `close()`, `.failed`.
    func load(_ request: URLRequest, allowsChallenge: Bool, timeout: Duration) async -> BackgroundPageOutcome {
        lastOutcome = nil
        guard let webView, let navigator, !Task.isCancelled else { return .failed }
        let attempt = navigator.begin(allowsChallenge: allowsChallenge)
        let timer = Task { [weak navigator] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            navigator?.timeUp(attempt)
        }
        defer { timer.cancel() }
        navigator.started(webView.load(request), attempt: attempt)
        let outcome = await withTaskCancellationHandler {
            await navigator.outcome(of: attempt)
        } onCancel: {
            Task { @MainActor in navigator.finish(.failed, attempt: attempt) }
        }
        // Whatever is still loading stops; a loaded page stays for `html()`.
        if outcome != .loaded { webView.stopLoading() }
        lastOutcome = outcome
        return outcome
    }

    /// document.documentElement.outerHTML of the page now shown; nil on failure.
    ///
    /// Only after a load ended `.loaded`, so a challenge page is never read; run in the client content world, where
    /// the page's scripts can neither see nor change the read. A caller that is cancelled gets nil at once.
    func html() async -> String? {
        await read("document.documentElement.outerHTML")
    }

    /// The text of the page now shown when it is bare text, as the site's notices are (an IP ban: no markup at all);
    /// nil for any other page, and on failure.
    ///
    /// Bare text: a `text/plain` document, or an HTML one whose body holds text but no element (WebKit wraps a body
    /// without markup in `<html><head></head><body>…`, so `html()` of such a page always has "<html"). Read as
    /// `html()` is: only after `.loaded`, in the client content world, nil at once for a cancelled caller.
    func bareText() async -> String? {
        await read("""
            (() => {
              const body = document.body;
              if (body === null) { return null; }
              if (document.contentType !== "text/plain" && body.firstElementChild !== null) { return null; }
              return body.innerText;
            })()
            """)
    }

    /// The string `script` gives on the page now shown, run in the client content world after a load that ended
    /// `.loaded`; nil otherwise and on failure.
    ///
    /// A caller that is cancelled gets nil at once, without waiting for WebKit: a page whose main thread is busy
    /// holds every script call up, and must not hold up whoever ends the read (logging out, the next login).
    private func read(_ script: String) async -> String? {
        guard let webView, lastOutcome == .loaded, !Task.isCancelled else { return nil }
        let pending = PendingRead()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.continuation = continuation
                webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                    pending.finish((try? result.get()) as? String)
                }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(nil) }
        }
    }

    /// One `read(_:)`: whichever comes first, WebKit's answer or the caller's cancellation, resumes it.
    @MainActor private final class PendingRead {
        var continuation: CheckedContinuation<String?, Never>?

        func finish(_ value: String?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// Stops loading (a navigation waiting for the throttle stops waiting), drops the delegate and releases the
    /// WebView; later calls do nothing.
    func close() {
        guard let webView else { return }
        navigator?.finishCurrent(.failed)
        webView.stopLoading()
        webView.navigationDelegate = nil
        self.webView = nil
        navigator = nil
        lastOutcome = nil
    }

    // MARK: - Content rules

    /// The blocklist of ForumProfileLoader.blockedResourceTypes, then an `ignore-previous-rules` rule for
    /// `^https://challenges\.cloudflare\.com/`, so the challenge's own resources load as in any browser.
    nonisolated static let blockRulesJSON: String = {
        let rules: [[String: Any]] = [
            [
                "trigger": ["url-filter": ".*", "resource-type": ForumProfileLoader.blockedResourceTypes],
                "action": ["type": "block"],
            ],
            [
                "trigger": ["url-filter": #"^https://challenges\.cloudflare\.com/"#],
                "action": ["type": "ignore-previous-rules"],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }()

    /// Compiles `encoded`; nil when WebKit refuses it. Without the rules nothing may load (fail closed): the blocklist
    /// is part of the user decision.
    static func compileRules(_ encoded: String = blockRulesJSON) async -> WKContentRuleList? {
        try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: ruleListIdentifier, encodedContentRuleList: encoded
        )
    }

    // MARK: - Deciding answers

    /// What a main-frame answer means for a load.
    nonisolated enum ResponseDecision: Equatable, Sendable {
        /// A page to show; its finishing ends the load.
        case page
        /// A challenge to let run; its finishing does not end the load.
        case challenge
        /// Refused: the load ends with this outcome.
        case refuse(BackgroundPageOutcome)
    }

    /// A challenge (`CloudflareChallenge`) is let run when `allowsChallenge`, else `.challenged`; an answer `accepts`
    /// takes is a page; another HTTP answer is its status; anything else `.failed`.
    nonisolated static func decision(
        for response: URLResponse, allowsChallenge: Bool, statuslessScheme: String?
    ) -> ResponseDecision {
        if CloudflareChallenge.isChallenge(response) { return allowsChallenge ? .challenge : .refuse(.challenged) }
        if accepts(response, statuslessScheme: statuslessScheme) { return .page }
        if let http = response as? HTTPURLResponse { return .refuse(.httpStatus(http.statusCode)) }
        return .refuse(.failed)
    }

    /// Whether the main frame's answer may be shown: an HTTP answer must be a 200. WebKit hands a custom scheme's
    /// answer over as a plain `URLResponse` without a status; that is accepted only for `statuslessScheme`, the one
    /// scheme the tests register (nil in the app). Any other answer without a status is refused.
    nonisolated static func accepts(_ response: URLResponse, statuslessScheme: String? = nil) -> Bool {
        if let http = response as? HTTPURLResponse { return http.statusCode == 200 }
        guard let statuslessScheme, let scheme = response.url?.scheme else { return false }
        return scheme.lowercased() == statuslessScheme.lowercased()
    }

    /// Tests only (the app's `schemeHandler` is nil, so `statuslessScheme` and `reporter` are nil): the answer to
    /// decide on. WebKit hands a custom scheme's answer over without status and headers (measured on the iOS 27.2
    /// simulator), so the HTTP answer the test's handler reports stands in for it, when all three hold: the answer's
    /// URL has the registered test scheme, WebKit's answer is not an `HTTPURLResponse`, and the handler reports one.
    /// An `HTTPURLResponse` from WebKit is always used as it is.
    static func answer(
        for response: URLResponse, statuslessScheme: String?, reporter: (any HTTPAnswerReporting)?
    ) -> URLResponse {
        guard !(response is HTTPURLResponse), let statuslessScheme, let reporter, let url = response.url,
              url.scheme?.lowercased() == statuslessScheme.lowercased(),
              let reported = reporter.httpAnswer(for: url)
        else { return response }
        return reported
    }

    // MARK: - Navigator

    /// The navigation delegate: the throttle and the count for every main-frame navigation, the decision on every
    /// main-frame answer, and the outcome of the load in progress (the first one set wins).
    @MainActor private final class Navigator: NSObject, WKNavigationDelegate {
        private let throttle: any RequestThrottle
        private let statuslessScheme: String?
        private weak var reporter: (any HTTPAnswerReporting)?

        /// The number of the load in progress (or of the last one).
        private var attempt = 0
        /// A load is waiting for its outcome.
        private var isActive = false
        private var allowsChallenge = false
        private var navigations = 0
        private var sawChallenge = false
        /// The main-frame navigation the load is following, and whether its answer was a challenge.
        private var current: WKNavigation?
        private var currentIsChallenge = false
        private var outcome: BackgroundPageOutcome?
        private var continuation: CheckedContinuation<BackgroundPageOutcome, Never>?
        /// The throttle waits of the main-frame navigations being decided, each its own task: ending
        /// the load (`finish(_:attempt:)`; its caller cancelled, `close()`, the time up) cancels them, so a decision
        /// returns `.cancel` at once instead of holding the WebView until the throttle's turn comes. Normally one;
        /// a set, so a navigation that replaced another while that one still waited cannot leave it behind.
        private var throttleWaits: Set<Task<Void, any Error>> = []

        init(throttle: any RequestThrottle, statuslessScheme: String?, reporter: (any HTTPAnswerReporting)?) {
            self.throttle = throttle
            self.statuslessScheme = statuslessScheme
            self.reporter = reporter
        }

        /// Starts a new load (ending one still waiting with `.failed`) and returns its number.
        func begin(allowsChallenge: Bool) -> Int {
            finishCurrent(.failed)
            attempt += 1
            isActive = true
            self.allowsChallenge = allowsChallenge
            navigations = 0
            sawChallenge = false
            current = nil
            currentIsChallenge = false
            outcome = nil
            return attempt
        }

        /// The navigation `WKWebView.load` returned for load `id`; nil means it did not start.
        func started(_ navigation: WKNavigation?, attempt id: Int) {
            guard id == attempt, isActive else { return }
            guard let navigation else {
                finish(.failed, attempt: id)
                return
            }
            current = navigation
        }

        func outcome(of id: Int) async -> BackgroundPageOutcome {
            guard id == attempt else { return .failed }
            if let outcome { return outcome }
            return await withCheckedContinuation { continuation = $0 }
        }

        /// Ends load `id` with `value` unless it has ended already; its navigations stop waiting for the throttle.
        func finish(_ value: BackgroundPageOutcome, attempt id: Int) {
            guard id == attempt, isActive else { return }
            isActive = false
            for wait in throttleWaits { wait.cancel() }
            throttleWaits = []
            outcome = value
            continuation?.resume(returning: value)
            continuation = nil
        }

        func finishCurrent(_ value: BackgroundPageOutcome) {
            finish(value, attempt: attempt)
        }

        func timeUp(_ id: Int) {
            finish(sawChallenge ? .challengeTimedOut : .timedOut, attempt: id)
        }

        private func isCurrent(_ navigation: WKNavigation?) -> Bool {
            navigation == nil || navigation === current
        }

        // MARK: WKNavigationDelegate

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // No new windows; sub-frames are not throttled or counted.
            guard let frame = navigationAction.targetFrame else { return .cancel }
            guard frame.isMainFrame else { return .allow }
            let id = attempt
            guard isActive else { return .cancel }
            navigations += 1
            guard navigations <= BackgroundPage.maxNavigations else {
                finish(.tooManyNavigations, attempt: id)
                return .cancel
            }
            guard let url = navigationAction.request.url else {
                finish(.failed, attempt: id)
                return .cancel
            }
            // Its own task, so ending the load ends the wait (`finish`): WebKit's call here cannot be cancelled.
            let throttle = throttle
            let wait = Task { try await throttle.acquire(for: url) }
            throttleWaits.insert(wait)
            defer { throttleWaits.remove(wait) }
            do {
                try await wait.value
            } catch {
                // The throttle refused; or the load's end cancelled the wait, whose outcome is set already (no change).
                finish(.throttled, attempt: id)
                return .cancel
            }
            // The load may have ended (time, cancellation, close) while the throttle waited.
            guard id == attempt, isActive else { return .cancel }
            return .allow
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
        ) async -> WKNavigationResponsePolicy {
            guard navigationResponse.isForMainFrame else { return .allow }
            let id = attempt
            guard isActive else { return .cancel }
            let response = BackgroundPage.answer(
                for: navigationResponse.response, statuslessScheme: statuslessScheme, reporter: reporter
            )
            switch BackgroundPage.decision(
                for: response, allowsChallenge: allowsChallenge, statuslessScheme: statuslessScheme
            ) {
            case .page:
                currentIsChallenge = false
                return .allow
            case .challenge:
                sawChallenge = true
                currentIsChallenge = true
                return .allow
            case .refuse(let value):
                // Set before the cancel: the failure WebKit reports for it does not change the outcome.
                finish(value, attempt: id)
                return .cancel
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard isActive else { return }
            current = navigation
            currentIsChallenge = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard isActive, isCurrent(navigation), !currentIsChallenge else { return }
            finishCurrent(.loaded)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            failed(navigation, error)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
        ) {
            failed(navigation, error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finishCurrent(.failed)
        }

        /// A load error of the navigation the load follows. A cancelled one is not: WebKit cancels a navigation
        /// another one replaces (that one decides), and what this class cancels has its outcome already.
        private func failed(_ navigation: WKNavigation?, _ error: any Error) {
            guard isActive, isCurrent(navigation) else { return }
            if (error as? URLError)?.code == .cancelled { return }
            finishCurrent(.failed)
        }
    }
}
