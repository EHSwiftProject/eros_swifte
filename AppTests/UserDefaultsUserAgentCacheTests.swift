import EHModels
import EHNetwork
import Foundation
import Testing

@testable import Eros

/// Runs inside the Eros app on the simulator, so the suite's plist lives in the app's container (and goes with it),
/// never in the Mac's ~/Library/Preferences, where the package test that used to cover this left one. One fixed suite,
/// cleared before and after.
@Suite struct UserDefaultsUserAgentCacheTests {
    private static let suite = "proj.eros.swifte.tests.user-agent-cache"
    private static let key = "eros.webKitUserAgent"
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func roundTrips() async throws {
        let defaults = try #require(UserDefaults(suiteName: Self.suite))
        defaults.removePersistentDomain(forName: Self.suite)
        defer { defaults.removePersistentDomain(forName: Self.suite) }

        // A cache of its own instance: UserDefaults is not Sendable here, and instances of one suite share the data.
        let cache = UserDefaultsUserAgentCache(defaults: try #require(UserDefaults(suiteName: Self.suite)))
        #expect(await cache.load() == nil)
        let value = WebKitUserAgent(value: "FakeWebKit/1", systemVersion: "27.2", capturedAt: Self.now)
        await cache.save(value)
        #expect(await cache.load() == value)
        #expect(defaults.data(forKey: Self.key) != nil)
        // Another cache on the same suite, made by name, reads what was saved.
        #expect(await UserDefaultsUserAgentCache(suiteName: Self.suite).load() == value)
        // Data that does not decode is no UA.
        defaults.set(Data("not json".utf8), forKey: Self.key)
        #expect(await UserDefaultsUserAgentCache(defaults: try #require(UserDefaults(suiteName: Self.suite))).load() == nil)
    }
}

/// The app's UA cache keeps the version of how the UA was read: a UA cached by an older reading (the iPad's Mac UA,
/// before every WebView asked for mobile content) is not loaded, so the next launch reads it again, once.
@Suite struct UserAgentCacheVersionTests {
    private static let suite = "proj.eros.swifte.tests.user-agent-cache-version"
    private static let cached = WebKitUserAgent(
        value: "FakeWebKit/desktop", systemVersion: "27.2", capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    @Test func anOlderReadingIsReadAgain() async throws {
        let defaults = try #require(UserDefaults(suiteName: Self.suite))
        defaults.removePersistentDomain(forName: Self.suite)
        defer { defaults.removePersistentDomain(forName: Self.suite) }
        let base = InMemoryUserAgentCache(Self.cached)

        // Cached before the version was kept: not loaded.
        let cache = UserAgentCacheVersion(base: base, suiteName: Self.suite)
        #expect(await cache.load() == nil)
        // An older version: not loaded either.
        defaults.set(1, forKey: UserAgentCacheVersion.versionKey)
        #expect(await cache.load() == nil)

        // The next read is saved with the version, and loaded from then on.
        let read = WebKitUserAgent(
            value: "FakeWebKit/mobile", systemVersion: "27.2", capturedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        await cache.save(read)
        #expect(defaults.integer(forKey: UserAgentCacheVersion.versionKey) == WebKitUserAgentProbe.readingVersion)
        #expect(await cache.load() == read)
        #expect(await base.load() == read)
        #expect(WebKitUserAgentProbe.readingVersion == 2)
    }
}
