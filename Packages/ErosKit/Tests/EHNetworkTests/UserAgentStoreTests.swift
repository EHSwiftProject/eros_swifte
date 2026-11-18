import EHModels
import EHNetwork
import Foundation
import Testing

@Suite struct UserAgentStoreTests {
    private static let system = "27.2"
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let later = Date(timeIntervalSince1970: 1_800_086_400)
    private static let bound = [CookieNames.clearance: "clearance-fake-0007", "cf_duid": "duid-fake-0008"]
    private static let memberID = [CookieNames.memberID: "1234567"]

    private static func loadedStore(_ cached: WebKitUserAgent? = nil) async -> (UserAgentStore, InMemoryUserAgentCache) {
        let cache = InMemoryUserAgentCache(cached)
        let store = UserAgentStore(cache: cache, systemVersion: system)
        await store.load()
        return (store, cache)
    }

    /// A loaded cookie store whose two jars hold the UA-bound cookies and a member id.
    private static func cookiesWithClearance() async throws -> CookieStore {
        let cookies = CookieStore(vault: InMemoryVault())
        try await cookies.load()
        try await cookies.set(bound.merging(memberID) { $1 }, for: [.eh, .ex])
        return cookies
    }

    @Test func fallsBackToChromeUntilCaptured() async {
        let (store, _) = await Self.loadedStore()
        #expect(await store.current == RequestDefaults.chromeUserAgent)
        #expect(await store.isWebKit == false)
        #expect(await store.needsCapture)
    }

    @Test func freshCacheIsUsed() async {
        let (store, _) = await Self.loadedStore(WebKitUserAgent(value: "FakeWebKit/1", systemVersion: "27.2", capturedAt: Self.now))
        #expect(await store.current == "FakeWebKit/1")
        #expect(await store.isWebKit)
        #expect(await store.needsCapture == false)
    }

    @Test func systemUpdateMakesTheCacheStale() async {
        let (store, _) = await Self.loadedStore(WebKitUserAgent(value: "FakeWebKit/1", systemVersion: "27.1", capturedAt: Self.now))
        #expect(await store.current == RequestDefaults.chromeUserAgent)
        #expect(await store.isWebKit == false)
        #expect(await store.needsCapture)
    }

    @Test func adoptSavesWithTheSystemVersion() async {
        let (store, cache) = await Self.loadedStore()
        #expect(await store.adopt("FakeWebKit/2", now: Self.now))
        let saved = WebKitUserAgent(value: "FakeWebKit/2", systemVersion: "27.2", capturedAt: Self.now)
        #expect(await cache.load() == saved)
        #expect(await store.current == "FakeWebKit/2")
        #expect(await store.isWebKit)
        #expect(await store.needsCapture == false)
        #expect(await store.adopt("FakeWebKit/2", now: Self.later) == false)
        #expect(await cache.load() == saved)
    }

    @Test func changedUserAgentDropsEveryUserAgentBoundCookie() async throws {
        let extra = ["__cf_bm": "bm-fake-0001", "_cfuvid": "uvid-fake-0002", "cf_chl_prog": "chl-fake-0003"]
        let cookies = try await Self.cookiesWithClearance()
        try await cookies.set(extra.merging(["ipb_session_id": "session-fake-0004"]) { $1 }, for: [.eh, .ex])
        let (userAgents, _) = await Self.loadedStore(WebKitUserAgent(value: "FakeWebKit/1", systemVersion: "27.2", capturedAt: Self.now))
        #expect(try await adoptWebKitUserAgent("FakeWebKit/2", userAgents: userAgents, cookies: cookies))
        for site in EHSite.allCases {
            #expect(await cookies.snapshot().cookies[site] == Self.memberID.merging(["ipb_session_id": "session-fake-0004"]) { $1 }, "\(site)")
        }
    }

    @Test func changedUserAgentDropsClearanceCookies() async throws {
        let cookies = try await Self.cookiesWithClearance()
        let (userAgents, _) = await Self.loadedStore(WebKitUserAgent(value: "FakeWebKit/1", systemVersion: "27.2", capturedAt: Self.now))
        #expect(try await adoptWebKitUserAgent("FakeWebKit/2", userAgents: userAgents, cookies: cookies))
        for site in EHSite.allCases {
            #expect(await cookies.snapshot().cookies[site] == Self.memberID, "\(site)")
        }
        #expect(await userAgents.current == "FakeWebKit/2")

        try await cookies.set(Self.bound, for: [.eh, .ex])
        let before = await cookies.snapshot()
        #expect(try await adoptWebKitUserAgent("FakeWebKit/2", userAgents: userAgents, cookies: cookies) == false)
        #expect(await cookies.snapshot() == before)
    }

    @Test func failedReadKeepsTheFallbackAndRetriesNextLaunch() async {
        let (first, cache) = await Self.loadedStore()
        #expect(await first.isWebKit == false)
        #expect(await first.needsCapture)
        let nextLaunch = UserAgentStore(cache: cache, systemVersion: Self.system)
        await nextLaunch.load()
        #expect(await nextLaunch.needsCapture)
        #expect(await nextLaunch.current == RequestDefaults.chromeUserAgent)
    }

    /// The comparison is with the UA itself: an OS update that leaves it unchanged keeps the Cloudflare cookies.
    @Test func sameUserAgentAfterASystemUpdateKeepsClearanceCookies() async throws {
        let cookies = try await Self.cookiesWithClearance()
        let before = await cookies.snapshot()
        let (userAgents, cache) = await Self.loadedStore(WebKitUserAgent(value: "FakeWebKit/1", systemVersion: "27.1", capturedAt: Self.now))
        #expect(await userAgents.needsCapture)
        #expect(try await adoptWebKitUserAgent("FakeWebKit/1", userAgents: userAgents, cookies: cookies) == false)
        #expect(await cookies.snapshot() == before)
        #expect(await cache.load()?.systemVersion == "27.2")
        #expect(await userAgents.needsCapture == false)
        #expect(await userAgents.current == "FakeWebKit/1")
    }

    @Test(arguments: ["", "FakeWebKit/3\r\nX-Injected: 1", "FakeWebKit/3\u{7F}"])
    func unusableValuesAreNotAdopted(value: String) async throws {
        let cookies = try await Self.cookiesWithClearance()
        let before = await cookies.snapshot()
        let (userAgents, cache) = await Self.loadedStore()
        #expect(try await adoptWebKitUserAgent(value, userAgents: userAgents, cookies: cookies) == false)
        #expect(await userAgents.isWebKit == false)
        #expect(await userAgents.needsCapture)
        #expect(await cache.load() == nil)
        #expect(await cookies.snapshot() == before)
    }

    /// When the Cloudflare cookies cannot be removed, the old UA stays, so the next adopt removes them again.
    @Test func failedClearanceRemovalKeepsTheOldUserAgent() async throws {
        let source = try await Self.cookiesWithClearance()
        let snapshotData = try JSONEncoder().encode(await source.snapshot())
        let cookies = CookieStore(vault: FailingVault(stored: snapshotData))
        try await cookies.load()
        let cached = WebKitUserAgent(value: "FakeWebKit/1", systemVersion: "27.2", capturedAt: Self.now)
        let (userAgents, cache) = await Self.loadedStore(cached)
        await #expect(throws: FailingVault.Failure.self) {
            try await adoptWebKitUserAgent("FakeWebKit/2", userAgents: userAgents, cookies: cookies)
        }
        #expect(await userAgents.current == "FakeWebKit/1")
        #expect(await cache.load() == cached)
    }

    /// The vault of a cookie store that could not load may hold cf_* for the old UA, so a new UA waits for it.
    @Test func unloadedCookieStoreKeepsTheOldUserAgent() async throws {
        let source = try await Self.cookiesWithClearance()
        let bytes = try JSONEncoder().encode(await source.snapshot())
        let vault = UnreadableVault(data: bytes)
        let cookies = CookieStore(vault: vault)
        await #expect(throws: UnreadableVault.ReadFailure.self) { try await cookies.load() }
        let cached = WebKitUserAgent(value: "FakeWebKit/1", systemVersion: "27.2", capturedAt: Self.now)
        let (userAgents, cache) = await Self.loadedStore(cached)
        await #expect(throws: CookieStoreError.notLoaded) {
            try await adoptWebKitUserAgent("FakeWebKit/2", userAgents: userAgents, cookies: cookies)
        }
        #expect(await userAgents.current == "FakeWebKit/1")
        #expect(await cache.load() == cached)
        #expect(try await adoptWebKitUserAgent("FakeWebKit/1", userAgents: userAgents, cookies: cookies) == false)
        #expect(vault.bytes == bytes)
        #expect(vault.writes == 0)
    }

    // UserDefaultsUserAgentCache is tested in the app-hosted ErosTests (AppTests/UserDefaultsUserAgentCacheTests.swift):
    // a suite written from a package test on the Mac leaves a plist in ~/Library/Preferences.
}
