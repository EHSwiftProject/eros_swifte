import EHModels
import EHNetwork
import EHParsing
import Foundation
import WebKit

/// Why the forum profile page gave no profile (the session diagnostics show it; the UI only falls back).
nonisolated enum ForumProfileFailure: Error, Equatable, Sendable {
    /// The content rules did not compile: nothing loaded.
    case rules
    /// The page did not load: anything but `.loaded`.
    case page(BackgroundPageOutcome)
    /// Loaded, but no `#profilename`, or the parser threw.
    case notAProfilePage
    /// The forum answered with a site notice instead of the page: a 429, or a bare-text ban notice. It went to the
    /// breaker (both sites pause, user decision 2026-11-08).
    case notice(ResponseIssue)
}

/// Reads the nickname and avatar from the forum profile page in a `BackgroundPage` (a WebView never attached to a
/// window) with the user's own session (`WebSessionBridge`).
///
/// User decisions 2026-11-05 and 2026-11-07: no evasion of bot detection. No `customUserAgent`, no injected script,
/// no `cf_clearance` from elsewhere (`WebSessionBridge.push()` skips it); a Cloudflare challenge in front of the page
/// is left to finish by itself within the timeout. Nothing is retried: any failure is a `.failure`, and the UI falls
/// back to the login name and the default avatar (`AccountDisplay.resolve`).
@MainActor final class ForumProfileLoader {
    /// The sub-resources the page is not allowed to load (they bypass the app's throttle, so as few as possible).
    nonisolated static let blockedResourceTypes = ["image", "style-sheet", "font", "media"]

    /// How long past `timeout` the whole load may run before it is given up regardless. The page's own time ends at
    /// `timeout` (counted from the start of the load) and tells a challenge that did not finish from a plain timeout;
    /// this margin lets it, and is what ends a load held by WebKit outside the page (the rules, the store).
    nonisolated static let overrun: Duration = .seconds(2)

    private let bridge: WebSessionBridge
    private let throttle: any RequestThrottle
    /// The whole load's time, a challenge and its reloads included (the app passes
    /// `AppEnvironment.forumProfileTimeout`).
    let timeout: Duration
    private let profileURL: @Sendable (Int) -> URL
    private let schemeHandler: (handler: any WKURLSchemeHandler, scheme: String)?
    private let breaker: SiteBreaker?

    private let encodedRules: String

    /// `breaker`: a site notice the forum answers with goes to it (the forum's ban is the IP's, so both sites pause);
    /// nil: to none.
    init(
        bridge: WebSessionBridge, throttle: any RequestThrottle, timeout: Duration = .seconds(20),
        profileURL: @escaping @Sendable (Int) -> URL = EHEndpoints.forumProfile(memberID:),
        schemeHandler: (handler: any WKURLSchemeHandler, scheme: String)? = nil,
        encodedRules: String = BackgroundPage.blockRulesJSON, breaker: SiteBreaker? = nil
    ) {
        self.bridge = bridge
        self.throttle = throttle
        self.timeout = timeout
        self.profileURL = profileURL
        self.schemeHandler = schemeHandler
        self.encodedRules = encodedRules
        self.breaker = breaker
    }

    /// Loads the profile page of `memberID` once and parses it.
    ///
    /// Compiles the content rules first (without them the sub-resource blocking, part of the user decision, would
    /// silently not apply: no rules, no load), pushes the session into the WebView store, then loads the page in a
    /// `BackgroundPage`, which waits for the throttle before every main-frame navigation (a challenge's reload
    /// included). Only a page read as the profile has its cookies pulled back into the cookie store
    /// (`pull(expectedMemberID:epoch:unchangedSince:)`: only what the page set or changed since the push, and nothing
    /// once `memberID` is no longer signed in or, when `epoch` is given, once the cookie store's session is no longer
    /// that one); every failure writes nothing. Never retries.
    ///
    /// `timeout` covers the whole load, the WebKit calls around the page included: the page has what is left of it
    /// once the rules and the push are done, and the load as a whole is given up `overrun` after it
    /// (`WebKitDeadline`; `.page(.timedOut)`), a store or rules call that hangs included (a push that runs out of its
    /// own time is `.page(.timedOut)` too). A caller that is cancelled gets `.page(.failed)` at once, whatever WebKit
    /// is doing, and nothing is written. The page is closed and its WebView released once the load has stopped.
    ///
    /// A 429, and a bare-text page that `ResponseClassifier` takes for a site notice (an IP ban), are recorded with
    /// the breaker (at the forum's address: both sites pause) and give `.notice`.
    func load(memberID: Int, epoch: UInt64? = nil) async -> Result<ForumProfile, ForumProfileFailure> {
        let started = ContinuousClock.now
        do {
            return try await WebKitDeadline.run(timeout + Self.overrun) { [self] in
                await read(memberID: memberID, epoch: epoch, started: started)
            }
        } catch is WebKitDeadline.TimedOut {
            return .failure(.page(.timedOut))
        } catch {
            // The caller gave up.
            return .failure(.page(.failed))
        }
    }

    /// The load itself (see `load(memberID:epoch:)`), with `timeout` counted from `started`.
    private func read(
        memberID: Int, epoch: UInt64?, started: ContinuousClock.Instant
    ) async -> Result<ForumProfile, ForumProfileFailure> {
        guard let rules = await BackgroundPage.compileRules(encodedRules) else { return .failure(.rules) }
        let pushed: WebSessionBridge.Pushed
        do {
            pushed = try await bridge.push()
        } catch is WebStoreTimeout {
            return .failure(.page(.timedOut))
        } catch {
            return .failure(.page(.failed))
        }
        let remaining = timeout - (ContinuousClock.now - started)
        guard remaining > .zero else { return .failure(.page(.timedOut)) }
        guard !Task.isCancelled else { return .failure(.page(.failed)) }
        let page = BackgroundPage(
            dataStore: bridge.dataStore, rules: rules, throttle: throttle, schemeHandler: schemeHandler
        )
        defer { page.close() }
        let outcome = await page.load(URLRequest(url: profileURL(memberID)), allowsChallenge: true, timeout: remaining)
        if outcome == .httpStatus(429) { return await notice(.tooManyRequests) }
        guard outcome == .loaded else { return .failure(.page(outcome)) }
        let html = await page.html()
        // A caller that gave up meanwhile gets nothing written.
        guard !Task.isCancelled else { return .failure(.page(.failed)) }
        guard let html, let profile = try? ForumProfileParser.parse(html) else {
            let host = (page.url ?? profileURL(memberID)).host()
            if let text = await page.bareText(), !Task.isCancelled,
               let issue = ResponseClassifier.issue(
                   status: 200, body: Data(text.utf8), expectsJSON: false, host: host
               ) {
                return await notice(issue)
            }
            return .failure(.notAProfilePage)
        }
        try? await bridge.pull(expectedMemberID: memberID, epoch: epoch, unchangedSince: pushed)
        return .success(profile)
    }

    /// `issue` recorded with the breaker, at the forum's address (the ban is the IP's, so both sites pause).
    private func notice(_ issue: ResponseIssue) async -> Result<ForumProfile, ForumProfileFailure> {
        _ = await breaker?.record(issue, at: EHEndpoints.forumsBaseURL)
        return .failure(.notice(issue))
    }
}
