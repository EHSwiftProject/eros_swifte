import EHModels
import Foundation

// UA (user decision 2026-11-05): the device's WebKit UA for every request; a setting, not a credential (never in the Keychain).

/// Where the WebKit user agent is kept between launches.
public protocol UserAgentCache: Sendable {
    func load() async -> WebKitUserAgent?
    func save(_ userAgent: WebKitUserAgent) async
}

/// Keeps the UA as JSON in UserDefaults under "eros.webKitUserAgent".
public actor UserDefaultsUserAgentCache: UserAgentCache {
    private static let key = "eros.webKitUserAgent"
    private let defaults: UserDefaults

    /// nil, or a suite UserDefaults refuses (such as the app's own bundle identifier): the standard defaults.
    public init(suiteName: String? = nil) {
        self.init(defaults: suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard)
    }

    /// Keeps the UA in `defaults` (the app-hosted tests pass a suite inside the simulator app's container).
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// nil when nothing is stored or the data does not decode.
    public func load() -> WebKitUserAgent? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(WebKitUserAgent.self, from: data)
    }

    public func save(_ userAgent: WebKitUserAgent) {
        guard let data = try? JSONEncoder().encode(userAgent) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Keeps the UA in memory; for tests and UI tests.
public actor InMemoryUserAgentCache: UserAgentCache {
    private var value: WebKitUserAgent?

    public init(_ value: WebKitUserAgent? = nil) {
        self.value = value
    }

    public func load() -> WebKitUserAgent? {
        value
    }

    public func save(_ userAgent: WebKitUserAgent) {
        value = userAgent
    }
}

/// The `User-Agent` of every request: the device's WebKit UA once known, `RequestDefaults.chromeUserAgent` before.
///
/// The app reads `navigator.userAgent` from a WKWebView that loads nothing, then `adoptWebKitUserAgent(_:…)`.
/// While `isWebKit` is false the app runs on the Chrome fallback: web login is disabled and the UA-bound Cloudflare cookies (`CookieNames.isUserAgentBound`)
/// are neither sent nor synced with the WebView.
public actor UserAgentStore {
    private let cache: any UserAgentCache
    private let systemVersion: String
    /// The last UA cached or adopted, whatever system version it was read on.
    private var known: WebKitUserAgent?
    private var hasLoaded = false

    public init(cache: any UserAgentCache, systemVersion: String) {
        self.cache = cache
        self.systemVersion = systemVersion
    }

    /// Reads the cache; a cached UA counts only when its systemVersion equals ours (an OS update changes WebKit's UA).
    ///
    /// Reads once: later calls, and calls after an `adopt`, keep the current state.
    public func load() async {
        guard !hasLoaded else { return }
        let stored = await cache.load()
        // An adopt (or another load) may have finished while this one waited.
        guard !hasLoaded else { return }
        known = stored
        hasLoaded = true
    }

    /// The WebKit UA once known; RequestDefaults.chromeUserAgent before that.
    public var current: String {
        fresh?.value ?? RequestDefaults.chromeUserAgent
    }

    /// false: Chrome fallback — web login disabled, UA-bound Cloudflare cookies neither sent nor synced.
    public var isWebKit: Bool {
        fresh != nil
    }

    /// No fresh cached UA for this system version (stays true after a failed read, so the next launch reads again).
    public var needsCapture: Bool {
        fresh == nil
    }

    /// Saves `value` with the system version; true when it differs from the cached value (or there was none).
    ///
    /// "The cached value" is the last UA cached or adopted, whatever system version it was read on: an OS update
    /// that leaves the UA as it was returns false, and only the system version is saved. An empty value, or one
    /// with a C0 control or DEL (it would break the header), is a failed read: nothing is saved and it returns false.
    /// Saves nothing when neither the UA nor the system version changed (`capturedAt` keeps the first capture).
    public func adopt(_ value: String, now: Date = Date()) async -> Bool {
        await load()
        guard Self.isUsable(value) else { return false }
        let changed = known?.value != value
        guard changed || known?.systemVersion != systemVersion else { return false }
        let adopted = WebKitUserAgent(value: value, systemVersion: systemVersion, capturedAt: now)
        known = adopted
        await cache.save(adopted)
        return changed
    }

    /// Whether `adopt(value)` would return true.
    func wouldChange(to value: String) async -> Bool {
        await load()
        return Self.isUsable(value) && known?.value != value
    }

    /// The cached or adopted UA when it was read on this system version.
    private var fresh: WebKitUserAgent? {
        guard let known, known.systemVersion == systemVersion else { return nil }
        return known
    }

    private static func isUsable(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value > 0x1F && $0.value != 0x7F }
    }
}

/// Adopts a freshly read WebKit UA; when it changed, removes the UA-bound Cloudflare cookies
/// (`CookieNames.isUserAgentBound`) from both jars, because Cloudflare binds them to the UA they were issued for.
///
/// The cookies go first: when removing them throws, the UA is not adopted, so the next call removes them again
/// instead of leaving the new UA with cookies issued for the old one. That includes a cookie store that has not
/// loaded (`CookieStoreError.notLoaded`): the vault may still hold cf_* issued for the old UA.
///
/// Leaving the Chrome fallback with an unchanged UA string (WebKit freezes its version, so an OS update often keeps
/// it) removes nothing, and need not: a response to a request sent with the fallback writes no UA-bound cookie
/// (`EHClient`), so the jars hold only cookies issued for the WebKit UA.
public func adoptWebKitUserAgent(_ value: String, userAgents: UserAgentStore, cookies: CookieStore) async throws -> Bool {
    if await userAgents.wouldChange(to: value) {
        try await cookies.removeUserAgentBound(for: Set(EHSite.allCases))
    }
    return await userAgents.adopt(value)
}
