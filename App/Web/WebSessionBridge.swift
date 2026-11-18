import EHModels
import EHNetwork
import EHParsing
import Foundation
import WebKit

/// The WebKit store calls `WebSessionBridge` makes, so a test can stand in for them (one that hangs, as a WebKit
/// process can). `dataStore` is the store every session WebView's configuration uses; the calls act on it.
@MainActor protocol WebStoreAccess: AnyObject, Sendable {
    var dataStore: WKWebsiteDataStore { get }
    func allCookies() async -> [HTTPCookie]
    func setCookies(_ cookies: [HTTPCookie]) async
    func deleteCookie(_ cookie: HTTPCookie) async
    /// Every kind of data, of every site (`WKWebsiteDataStore.allWebsiteDataTypes()`).
    func removeAllData() async
}

/// The app's `WebStoreAccess`: the calls of `dataStore` and its cookie store, as they are.
@MainActor final class WebKitStoreAccess: WebStoreAccess {
    let dataStore: WKWebsiteDataStore

    init(_ dataStore: WKWebsiteDataStore = .nonPersistent()) {
        self.dataStore = dataStore
    }

    func allCookies() async -> [HTTPCookie] {
        await dataStore.httpCookieStore.allCookies()
    }

    func setCookies(_ cookies: [HTTPCookie]) async {
        await dataStore.httpCookieStore.setCookies(cookies)
    }

    func deleteCookie(_ cookie: HTTPCookie) async {
        await dataStore.httpCookieStore.deleteCookie(cookie)
    }

    func removeAllData() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

/// A WebKit store call of `WebSessionBridge` did not finish within its time (`storeTimeout`).
nonisolated struct WebStoreTimeout: Error, Equatable {}

/// Copies the session between the `CookieStore` and the WebKit store every session WebView shares (the web login,
/// the background forum profile page).
///
/// The cookie store stays the only place cookies persist (in the Keychain); `dataStore` is non-persistent, so what
/// the WebViews hold lives as long as this bridge. No WebView set up with it may set `customUserAgent` or inject
/// scripts that change what the browser reports (user decision 2026-11-05).
///
/// Every operation on the WebKit store (`push`, `siteCookies`, `pull`'s read, `clear`, `removeAllData`) has a time
/// limit, `storeTimeout`: WebKit does not answer Swift cancellation, and a store call that hangs held a login, a
/// logout and the login sheet for minutes (M2 review). One that runs out throws `WebStoreTimeout`; one whose caller is
/// cancelled throws `CancellationError` at once. The operations run one after another, each once the one before has
/// ended, whether or not its caller still waits (a new one waits for it within its own time): a clear that timed out
/// and finishes late cannot delete what a later push put in. An operation whose caller gave up (it ran out of time, or
/// was cancelled) before its turn came does not run at all, except a clean-up that is asked to run anyway
/// (`removeAllData()`, `clear(evenWhenGivenUp: true)`): it runs in its turn, after whatever was queued before it, so a
/// push that hung and ends late is cleaned up after all, and nothing queued after it is touched.
@MainActor final class WebSessionBridge {
    /// What one `push()` copied into the WebView: each site's names and values, `nw` left out.
    ///
    /// No description shows a value: `description` and the mirror give the number of cookies per site only.
    /// `nonisolated` as the app's other value types (the target's default isolation is the main actor): the
    /// conformances then hold off the main actor too, where `String(describing:)` or `dump` of a main-actor one would
    /// fall back to plain reflection and show every value.
    nonisolated struct Pushed: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
        let jars: [EHSite: [String: String]]

        /// Whether `cookie`, a WebView cookie of `site`, still holds the value that was pushed for its name.
        func isUnchanged(_ cookie: ParsedCookie, of site: EHSite) -> Bool {
            !cookie.isDeletion && jars[site]?[cookie.name] == cookie.value
        }

        var description: String {
            let counts = EHSite.allCases.map { "\($0): \(jars[$0]?.count ?? 0)" }
            return "Pushed(\(counts.joined(separator: ", ")))"
        }

        var customMirror: Mirror { Mirror(self, children: ["description": description]) }
    }

    /// The time each WebKit store operation has (see the type). C9 measured `allCookies()` at over ten seconds on a
    /// heavily loaded host, so ten seconds is the most a login waits for a store that will not answer.
    nonisolated static let defaultStoreTimeout: Duration = .seconds(10)

    /// The store every session WebView's configuration uses.
    var dataStore: WKWebsiteDataStore { webStore.dataStore }
    /// The time each WebKit store operation has, read when it is called (a test shortens it once its own setup, which
    /// goes through the real store, is done).
    var storeTimeout: Duration
    private let store: CookieStore
    private let userAgents: UserAgentStore
    private let webStore: any WebStoreAccess
    /// The last operation on the WebKit store; the next one starts once it has ended.
    private var lastOperation: Task<Void, Never>?

    /// `webStore`: the WebKit store calls, `WebKitStoreAccess` on a store of its own (non-persistent) unless a test
    /// gives one.
    init(
        store: CookieStore, userAgents: UserAgentStore, webStore: (any WebStoreAccess)? = nil,
        storeTimeout: Duration = WebSessionBridge.defaultStoreTimeout
    ) {
        self.store = store
        self.userAgents = userAgents
        self.webStore = webStore ?? WebKitStoreAccess()
        self.storeTimeout = storeTimeout
    }

    /// Copies both jars into the WebView: each cookie for the domain of its site (".e-hentai.org", ".exhentai.org"),
    /// path "/", secure, a session cookie; plus `nw=1` for both (the jar never stores it, every site request sends it).
    /// Skips the `CookieNames.isUserAgentBound` names (cf_clearance, cf_duid, __cf_bm, _cfuvid, cf_chl*): no Cloudflare cookie from elsewhere goes into a WebView.
    ///
    /// Cookies of the same name, domain and path in the WebView are replaced; the WebView's other cookies stay.
    /// Returns what it copied, for `pull(expectedMemberID:epoch:unchangedSince:)`.
    /// - Throws: `WebStoreTimeout`, `CancellationError` (see the type).
    @discardableResult
    func push() async throws -> Pushed {
        let snapshot = await store.snapshot()
        var cookies: [HTTPCookie] = []
        var pushed: [EHSite: [String: String]] = [:]
        for site in EHSite.allCases {
            let jar = (snapshot.cookies[site] ?? [:]).filter { name, _ in
                name != CookieNames.noWarning && !WebLoginRules.isNotPushedToWebView(name)
            }
            let pairs = jar.sorted { $0.key < $1.key } + [(key: CookieNames.noWarning, value: "1")]
            cookies += pairs.compactMap { Self.cookie(name: $0.key, value: $0.value, site: site) }
            pushed[site] = jar
        }
        let webStore = webStore
        try await perform { await webStore.setCookies(cookies) }
        return Pushed(jars: pushed)
    }

    /// `WebLoginRules.siteCookies(from:)` of everything the WebView store holds.
    /// - Throws: `WebStoreTimeout`, `CancellationError` (see the type).
    func siteCookies() async throws -> [ParsedCookie] {
        let webStore = webStore
        return WebLoginRules.siteCookies(from: try await perform { await webStore.allCookies() })
    }

    /// Writes the WebView's site cookies into the cookie store, each by its own domain
    /// (`CookieStore.ingestWebViewCookies(_:fallback:expectedMemberID:)`, as the web login does); never `nw`.
    ///
    /// While the app runs on the Chrome fallback (`UserAgentStore.isWebKit` false), the UA-bound Cloudflare cookies stay in
    /// the WebView, deletions too: they are not synced between the two (user decision 2026-11-05). The UA is not
    /// touched: it already is the WebView's.
    ///
    /// `expectedMemberID`: when not nil, nothing is written unless that member is still the one signed in and every
    /// `ipb_member_id` the WebView holds is that member's (see `ingestWebViewCookies`): a page read for an account that
    /// has logged out or been replaced meanwhile, a leftover host-only identity of an earlier account and the forum's
    /// `ipb_member_id=0` write nothing. An earlier account's other cookies are not told apart: `clear()` the WebView
    /// store whenever the account changes.
    ///
    /// `epoch`: when not nil, nothing is written unless the cookie store's session (`CookieStore.epoch`) is still that
    /// one: a page read for a session that has ended (logged out, another login began) writes nothing.
    ///
    /// `unchangedSince`: what the `push()` before the page copied in. A WebView cookie that still holds the value
    /// pushed for its site and name is left out, so a newer value the jar got meanwhile (a response's `sk`, `hath_perks`,
    /// …) is not put back to the pushed one; the cookies the page set or changed are written.
    ///
    /// - Throws: `WebStoreTimeout`, `CancellationError` (reading the WebView store, see the type), and what
    ///   `ingestWebViewCookies` throws; nothing is written then.
    func pull(expectedMemberID: Int? = nil, epoch: UInt64? = nil, unchangedSince pushed: Pushed? = nil) async throws {
        var cookies = try await siteCookies().filter { $0.name != CookieNames.noWarning }
        if await !userAgents.isWebKit {
            cookies.removeAll { WebLoginRules.isNotPushedToWebView($0.name) }
        }
        if let pushed {
            cookies.removeAll { cookie in
                EHSite(cookieHost: cookie.domain ?? "").map { pushed.isUnchanged(cookie, of: $0) } ?? false
            }
        }
        try await store.ingestWebViewCookies(
            cookies, fallback: EHEndpoints.forumsBaseURL, expectedMemberID: expectedMemberID, epoch: epoch
        )
    }

    /// Deletes both sites' cookies from the WebView store (at the start of every login, and when the web login's
    /// sheet goes before it completed); other domains' cookies, the store's other data and the cookie store are not
    /// touched.
    ///
    /// `evenWhenGivenUp`: when the caller gives up before the store's turn comes, the deletions still run in it,
    /// late (the web login's close: what its pages left would otherwise stay until the next login or logout);
    /// otherwise they do not run (a login's start: the login has failed, and the next one clears again first).
    /// - Throws: `WebStoreTimeout`, `CancellationError` (see the type).
    func clear(evenWhenGivenUp: Bool = false) async throws {
        let webStore = webStore
        try await perform(evenWhenGivenUp: evenWhenGivenUp) {
            for cookie in await webStore.allCookies() where EHSite(cookieHost: cookie.domain) != nil {
                await webStore.deleteCookie(cookie)
            }
        }
    }

    /// Removes everything the WebView store holds, of every site and every kind (`WKWebsiteDataStore
    /// .allWebsiteDataTypes()`: cookies, local and session storage, caches, …), when logging out: nothing of the
    /// account, of a challenge it passed or of any page it opened stays. The cookie store is not touched.
    ///
    /// When the caller gives up before the store's turn comes (a call queued before it hangs), the removal still runs
    /// in its turn, late: after the call that hung (a push of the account's jar ending late), so that nothing of the
    /// account stays. It is idempotent, and anything queued after it (the next login's) runs after it.
    /// - Throws: `WebStoreTimeout`, `CancellationError` (see the type).
    func removeAllData() async throws {
        let webStore = webStore
        try await perform(evenWhenGivenUp: true) { await webStore.removeAllData() }
    }

    /// `SessionConsistency.compare` of the cookie store and the WebView's site cookies, with the URLSession UA
    /// (`UserAgentStore.current`) against `webUserAgent`, a session WebView's `navigator.userAgent`.
    /// - Throws: `WebStoreTimeout`, `CancellationError` (reading the WebView store, see the type).
    func consistency(webUserAgent: String) async throws -> SessionConsistency {
        let snapshot = await store.snapshot()
        let webCookies = try await siteCookies()
        let sessionUserAgent = await userAgents.current
        return SessionConsistency.compare(
            snapshot: snapshot, webCookies: webCookies, sessionUserAgent: sessionUserAgent, webUserAgent: webUserAgent
        )
    }

    /// Runs `operation` on the WebKit store once the operation before it has ended, within `storeTimeout` counted
    /// from now (the wait for the one before included); see the type. `evenWhenGivenUp`: it runs in its turn even
    /// when the caller gave up before (a clean-up).
    private func perform<Value: Sendable>(
        evenWhenGivenUp: Bool = false, _ operation: @escaping @MainActor @Sendable () async -> Value
    ) async throws -> Value {
        let previous = lastOperation
        let turn = StoreTurn()
        let task = Task { @MainActor () -> Value? in
            await previous?.value
            guard evenWhenGivenUp || !turn.isAbandoned else { return nil }
            return await operation()
        }
        lastOperation = Task { _ = await task.value }
        do {
            let value = try await WebKitDeadline.run(storeTimeout) { await task.value }
            // The caller still waited, so the operation ran.
            guard let value else { throw CancellationError() }
            return value
        } catch is WebKitDeadline.TimedOut {
            turn.isAbandoned = true
            throw WebStoreTimeout()
        } catch {
            turn.isAbandoned = true
            throw error
        }
    }

    /// Whether the caller of one `perform` call gave up (timed out, cancelled) before its operation's turn came.
    private final class StoreTurn {
        var isAbandoned = false
    }

    /// A session cookie for every host of `site`; nil when HTTPCookie refuses it (the jar's values are validated).
    private static func cookie(name: String, value: String, site: EHSite) -> HTTPCookie? {
        HTTPCookie(properties: [
            .name: name, .value: value, .domain: ".\(site.host)", .path: "/", .secure: "TRUE",
        ])
    }
}
