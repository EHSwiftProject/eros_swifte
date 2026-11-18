import EHModels
import EHNetwork
import EHParsing
import Foundation
import WebKit

/// Why the background WebView did not post the forum login form.
nonisolated enum WebPasswordLoginError: Error, Equatable {
    /// The forum wants something the background WebView cannot finish by itself: the web login takes over.
    case needsWebLogin
    /// The pages could not be loaded (rules, the throttle while no pause is in force, a status other than 200 and
    /// 429, timeout without a challenge, load error).
    case unreachable
}

/// The password login (account A3b): a `BackgroundPage` on the session store opens the forum's login page, then posts
/// the login form (`EHRequests.passwordLogin`), and the store's site cookies are what the login gets.
///
/// The forum answers a URLSession POST of its form with a Cloudflare 403 (A4); user decision 2026-11-07: the form goes
/// through a WebView no one sees, and when the forum wants a check that needs a person, the visible web login takes
/// over. Nothing is injected into a page (the form is posted by `load`, not filled in by script), and no jar is
/// pushed: `AppEnvironment.prepareLogin()` cleared both sites' cookies from the store, so no earlier identity goes
/// along. The password is in the POST body only: never in a URL, a log, a property or a description; neither this
/// class nor `BackgroundPage` keeps the request.
@MainActor final class WebPasswordLogin {
    private let bridge: WebSessionBridge
    private let throttle: any RequestThrottle
    private let timeout: Duration
    private let loginPageURL: URL
    private let formURL: URL
    private let schemeHandler: (handler: any WKURLSchemeHandler, scheme: String)?
    private let offline: Bool
    private let breaker: SiteBreaker?

    /// `timeout` is each page's (the login page, then the form). `offline` (UI testing without a test scheme): `run`
    /// fails at once without a WebView or a request. `breaker`: the site notice the form's answer is goes to it (the
    /// forum's ban is the IP's, so both sites pause), and a load the throttle refused during a pause is thrown as the
    /// pause; nil: neither.
    init(
        bridge: WebSessionBridge, throttle: any RequestThrottle, timeout: Duration = .seconds(20),
        loginPageURL: URL = EHEndpoints.forumLoginReferer, formURL: URL = EHEndpoints.forumLogin,
        schemeHandler: (handler: any WKURLSchemeHandler, scheme: String)? = nil, offline: Bool = false,
        breaker: SiteBreaker? = nil
    ) {
        self.bridge = bridge
        self.throttle = throttle
        self.timeout = timeout
        self.loginPageURL = loginPageURL
        self.formURL = formURL
        self.schemeHandler = schemeHandler
        self.offline = offline
        self.breaker = breaker
    }

    /// The WebView store's site cookies after the form was posted, and the page it ended on.
    ///
    /// First the login page (a challenge may finish by itself; one still showing at the timeout → `.needsWebLogin`),
    /// then the form, where a challenge is refused (`.needsWebLogin`: letting it run would post the form again or lose
    /// it). A load the throttle refused while both sites are paused (`SiteBreaker.current()`; `BreakerThrottle` refuses
    /// the forum then) is `EHNetworkError.paused`, so the user is told until when. A 429 from either page is recorded
    /// with the breaker (at the forum's address: both sites pause for a minute, user decision 2026-11-08) and thrown as
    /// `EHNetworkError.issue(.tooManyRequests)`. Any other failure is `.unreachable`, the rules not compiling within
    /// `timeout` included; reading the store's cookies has the bridge's time (`WebStoreTimeout`). The WebView is closed
    /// whatever happens; a cancelled caller gets `CancellationError` at once, whatever WebKit is doing. Whether the
    /// forum took the password is up to the cookies (`AccountService`).
    ///
    /// When the form's answer leaves no signed-in identity in the store, the page is checked for a site notice before
    /// the cookies go on: a bare-text page (`BackgroundPage.bareText()`) that `ResponseClassifier` takes for one, an IP
    /// ban, is recorded with the breaker (at the forum's address: the ban is the IP's, so both sites pause) and thrown
    /// as `EHNetworkError.issue`, so a banned user is told so instead of being sent to check the password (and to try
    /// again). A page with markup is never taken for a notice.
    func run(username: String, password: String) async throws -> (cookies: [ParsedCookie], page: URL) {
        guard !offline else { throw WebPasswordLoginError.unreachable }
        try Task.checkCancellation()
        guard let rules = try await compileRules() else { throw WebPasswordLoginError.unreachable }
        try Task.checkCancellation()
        let page = BackgroundPage(
            dataStore: bridge.dataStore, rules: rules, throttle: throttle, schemeHandler: schemeHandler
        )
        defer { page.close() }

        let loginPage = await page.load(URLRequest(url: loginPageURL), allowsChallenge: true, timeout: timeout)
        try Task.checkCancellation()
        switch loginPage {
        case .loaded: break
        case .challengeTimedOut: throw WebPasswordLoginError.needsWebLogin
        case .throttled: throw await refusal()
        case .httpStatus(429): throw await tooManyRequests()
        default: throw WebPasswordLoginError.unreachable
        }

        var form = EHRequests.passwordLogin(username: username, password: password).webViewRequest()
        form.url = formURL
        let posted = await page.load(form, allowsChallenge: false, timeout: timeout)
        try Task.checkCancellation()
        switch posted {
        case .loaded: break
        case .challenged, .challengeTimedOut: throw WebPasswordLoginError.needsWebLogin
        case .throttled: throw await refusal()
        case .httpStatus(429): throw await tooManyRequests()
        default: throw WebPasswordLoginError.unreachable
        }
        let cookies = try await bridge.siteCookies()
        if !Self.holdsIdentity(cookies), let text = await page.bareText() {
            try Task.checkCancellation()
            let host = (page.url ?? formURL).host()
            if let issue = ResponseClassifier.issue(status: 200, body: Data(text.utf8), expectsJSON: false, host: host) {
                _ = await breaker?.record(issue, at: EHEndpoints.forumsBaseURL)
                throw EHNetworkError.issue(issue)
            }
        }
        // Cancelled while the cookies or the page's text were read (`bareText()` gives nil at once then, so the check
        // above may not have run): the caller gets `CancellationError`, as documented, not the cookies.
        try Task.checkCancellation()
        return (cookies, page.url ?? formURL)
    }

    /// The content rules, compiled within `timeout`; nil when WebKit refuses them or does not answer in time. A
    /// cancelled caller gets `CancellationError` at once.
    private func compileRules() async throws -> WKContentRuleList? {
        do {
            return try await WebKitDeadline.run(timeout) { await BackgroundPage.compileRules() }
        } catch is WebKitDeadline.TimedOut {
            return nil
        }
    }

    /// A 429 from the forum: recorded with the breaker at the forum's address (both sites pause), and thrown.
    private func tooManyRequests() async -> any Error {
        _ = await breaker?.record(.tooManyRequests, at: EHEndpoints.forumsBaseURL)
        return EHNetworkError.issue(.tooManyRequests)
    }

    /// What a load the throttle refused is thrown as: the pause in force (`BackgroundPage` reports any throttle error
    /// as `.throttled`, so the breaker is asked), or `.unreachable` when there is none.
    private func refusal() async -> any Error {
        if let pause = await breaker?.current() { return EHNetworkError.paused(pause) }
        return WebPasswordLoginError.unreachable
    }

    /// Whether `cookies` hold a signed-in identity: an `ipb_member_id` that is a number other than 0, and an
    /// `ipb_pass_hash`, neither a deletion (the forum sets `ipb_member_id=0` for a guest).
    private static func holdsIdentity(_ cookies: [ParsedCookie]) -> Bool {
        let live = cookies.filter { !$0.isDeletion }
        let member = live.last { $0.name == CookieNames.memberID }?.value ?? ""
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        let isMember = !member.isEmpty && member.utf8.allSatisfy(digits.contains) && member.contains { $0 != "0" }
        return isMember && live.contains { $0.name == CookieNames.passHash }
    }
}
