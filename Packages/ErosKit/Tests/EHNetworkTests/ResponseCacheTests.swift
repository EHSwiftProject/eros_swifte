import CryptoKit
import EHFixtures
import EHModels
import EHNetwork
import EHNetworkTesting
import EHParsing
import Foundation
import Synchronization
import Testing

/// Every request in this suite goes to `MockURLProtocol`; none reaches the network. The cache lives in a
/// temporary directory, with a clock the tests move.
@Suite struct ResponseCacheTests {
    private static let ehPage = URL(string: "https://e-hentai.org/g/1234/0123456789/")!
    private static let post = URL(string: "https://forums.e-hentai.org/index.php?act=Login&CODE=01")!
    private static let firstBody = Data("<html><body>first</body></html>".utf8)
    private static let secondBody = Data("<html><body>second</body></html>".utf8)

    /// A clock the tests move.
    private final class Clock: Sendable {
        private let current: Mutex<Date>
        init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = Mutex(start) }
        var date: Date { current.withLock { $0 } }
        func advance(seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private struct Harness {
        let client: EHClient
        let cookies: CookieStore
        let cache: ResponseCache
        let directory: URL
        let clock: Clock
        let throttle: RecordingThrottle
        let mock: MockSession

        /// The names of the files in the cache directory.
        func files() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
        }

        func cleanUp() {
            mock.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A client with a cache in a new temporary directory. The responder gets the 1-based number of the request.
    private static func makeHarness(
        vault: any CredentialVault = InMemoryVault(),
        eh: [String: String] = [:],
        responder: @escaping @Sendable (URLRequest, Int) throws -> MockResponse = { _, _ in
            MockResponse(body: firstBody)
        }
    ) async throws -> Harness {
        let count = Mutex(0)
        let mock = MockURLProtocol.install { request in
            let number = count.withLock { value -> Int in
                value += 1
                return value
            }
            return try responder(request, number)
        }
        let directory = try temporaryDirectory()
        let clock = Clock()
        let cache = ResponseCache(directory: directory, now: { clock.date })
        let cookies = CookieStore(vault: vault)
        try await cookies.load()
        if !eh.isEmpty { try await cookies.set(eh, for: [.eh]) }
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        await userAgents.load()
        let throttle = RecordingThrottle()
        let configuration = try EHClientConfiguration(sessionConfigurator: mock.configurator)
        let client = EHClient(
            configuration: configuration, cookies: cookies, userAgents: userAgents, throttle: throttle, cache: cache
        )
        return Harness(
            client: client, cookies: cookies, cache: cache, directory: directory, clock: clock, throttle: throttle,
            mock: mock
        )
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "eros-cache-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func page(_ url: URL = ehPage, policy: CachePolicy = .preferCache) -> EHRequest {
        EHRequest(url: url, site: .eh, cachePolicy: policy)
    }

    // MARK: - Client

    @Test func getUsesTheCacheWhenPresent() async throws {
        let h = try await Self.makeHarness()
        defer { h.cleanUp() }
        let first = try await h.client.send(Self.page())
        let second = try await h.client.send(Self.page())
        #expect(first.source == .network)
        #expect(second.source == .cache)
        #expect(second.status == 200)
        #expect(second.body == Self.firstBody)
        #expect(second.url == Self.ehPage)
        #expect(h.mock.requests().count == 1)
        #expect(await h.throttle.acquiredURLs == [Self.ehPage])
    }

    @Test func reloadBypassesTheCache() async throws {
        let h = try await Self.makeHarness { _, number in
            MockResponse(body: number == 1 ? Self.firstBody : Self.secondBody)
        }
        defer { h.cleanUp() }
        _ = try await h.client.send(Self.page())
        let reloaded = try await h.client.send(Self.page(policy: .reload))
        #expect(reloaded.source == .network)
        #expect(reloaded.body == Self.secondBody)
        #expect(h.mock.requests().count == 2)
        // The new response replaced the cached one.
        let third = try await h.client.send(Self.page())
        #expect(third.source == .cache)
        #expect(third.body == Self.secondBody)
        #expect(h.mock.requests().count == 2)
    }

    @Test func entriesOlderThanThreeDaysAreIgnored() async throws {
        let h = try await Self.makeHarness()
        defer { h.cleanUp() }
        _ = try await h.client.send(Self.page())
        h.clock.advance(seconds: 259_200)
        #expect(try await h.client.send(Self.page()).source == .cache)
        #expect(h.mock.requests().count == 1)
        // 259_201 seconds after it was stored.
        h.clock.advance(seconds: 1)
        #expect(try await h.client.send(Self.page()).source == .network)
        #expect(h.mock.requests().count == 2)
        // The new response was stored in place of the expired one.
        #expect(try await h.client.send(Self.page()).source == .cache)
        #expect(try h.files().count == 1)
    }

    @Test(arguments: [401, 403, 503]) func fallsBackToTheCache(status: Int) async throws {
        let h = try await Self.makeHarness { _, number in
            number == 1 ? MockResponse(body: Self.firstBody) : MockResponse(status: status, body: Self.secondBody)
        }
        defer { h.cleanUp() }
        _ = try await h.client.send(Self.page())
        let fallback = try await h.client.send(Self.page(policy: .reload))
        #expect(fallback.source == .cache)
        #expect(fallback.status == 200)
        #expect(fallback.body == Self.firstBody)
        #expect(h.mock.requests().count == 2)
        // The error response did not overwrite the cached page.
        #expect(try await h.client.send(Self.page()).body == Self.firstBody)
    }

    @Test func withoutAFreshCachedPageTheStatusIsThrown() async throws {
        let none = try await Self.makeHarness { _, _ in MockResponse(status: 503, body: Self.secondBody) }
        defer { none.cleanUp() }
        await #expect(throws: EHNetworkError.httpStatus(503)) { try await none.client.send(Self.page()) }
        // Past its age the cached page does not stand in either.
        let old = try await Self.makeHarness { _, number in
            number == 1 ? MockResponse(body: Self.firstBody) : MockResponse(status: 503)
        }
        defer { old.cleanUp() }
        _ = try await old.client.send(Self.page())
        old.clock.advance(seconds: 259_201)
        await #expect(throws: EHNetworkError.httpStatus(503)) { try await old.client.send(Self.page()) }
    }

    @Test func otherErrorsDoNotFallBack() async throws {
        let h = try await Self.makeHarness { _, number in
            switch number {
            case 1: MockResponse(body: Self.firstBody)
            case 2: MockResponse(status: 404)
            default: MockResponse(status: 500)
            }
        }
        defer { h.cleanUp() }
        _ = try await h.client.send(Self.page())
        await #expect(throws: EHNetworkError.httpStatus(404)) { try await h.client.send(Self.page(policy: .reload)) }
        await #expect(throws: EHNetworkError.httpStatus(500)) { try await h.client.send(Self.page(policy: .reload)) }
    }

    @Test func postIsNeverCached() async throws {
        let h = try await Self.makeHarness()
        defer { h.cleanUp() }
        let request = EHRequest(
            method: .post, url: Self.post, site: .eh,
            body: .form([URLQueryItem(name: "UserName", value: "fake-user")])
        )
        _ = try await h.client.send(request)
        let second = try await h.client.send(request)
        #expect(second.source == .network)
        #expect(h.mock.requests().count == 2)
        #expect(try h.files().isEmpty)
    }

    @Test func policyNoneNeitherReadsNorWrites() async throws {
        let h = try await Self.makeHarness()
        defer { h.cleanUp() }
        _ = try await h.client.send(Self.page(policy: .none))
        #expect(try h.files().isEmpty)
        _ = try await h.client.send(Self.page())
        let third = try await h.client.send(Self.page(policy: .none))
        #expect(third.source == .network)
        #expect(h.mock.requests().count == 3)
    }

    @Test func redirectResponsesAreNotStored() async throws {
        let h = try await Self.makeHarness { _, _ in
            MockResponse(status: 302, headers: ["Location": "https://e-hentai.org/"], body: Self.firstBody)
        }
        defer { h.cleanUp() }
        let response = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh, followsRedirects: false))
        #expect(response.status == 302)
        #expect(try h.files().isEmpty)
    }

    @Test func issuesAreNeverCached() async throws {
        let banned = try Fixtures.data("constructed/eh/banned.txt")
        let h = try await Self.makeHarness { _, _ in MockResponse(body: banned) }
        defer { h.cleanUp() }
        await #expect(throws: EHNetworkError.issue(.banned(remaining: .seconds(3587)))) {
            try await h.client.send(Self.page())
        }
        #expect(try h.files().isEmpty)
        await #expect(throws: EHNetworkError.issue(.banned(remaining: .seconds(3587)))) {
            try await h.client.send(Self.page())
        }
        #expect(h.mock.requests().count == 2)
    }

    @Test func issuesAreNotAnsweredFromTheCache() async throws {
        let h = try await Self.makeHarness { _, number in
            number == 1 ? MockResponse(body: Self.firstBody) : MockResponse(status: 429)
        }
        defer { h.cleanUp() }
        _ = try await h.client.send(Self.page())
        await #expect(throws: EHNetworkError.issue(.tooManyRequests)) {
            try await h.client.send(Self.page(policy: .reload))
        }
        // The old page is still there for a later read, but the notice was not turned into a success.
        #expect(try await h.client.send(Self.page()).source == .cache)
    }

    @Test func cachedHeadersHaveNoSetCookie() async throws {
        let cookieValue = "cookie-value-fake-0001"
        let h = try await Self.makeHarness { _, _ in
            MockResponse(
                headers: ["Set-Cookie": "sk=\(cookieValue); path=/; domain=.e-hentai.org", "X-Page": "kept"],
                body: Self.firstBody
            )
        }
        defer { h.cleanUp() }
        let fresh = try await h.client.send(Self.page())
        #expect(await h.cookies.snapshot().cookies[.eh]?["sk"] == cookieValue)
        #expect(fresh.headers["set-cookie"] != nil)
        let files = try h.files()
        try #require(files.count == 1)
        let bytes = try Data(contentsOf: h.directory.appending(path: files[0]))
        #expect(bytes.range(of: Data(cookieValue.utf8)) == nil)
        #expect(bytes.range(of: Data("set-cookie".utf8)) == nil)
        let cached = try await h.client.send(Self.page())
        #expect(cached.source == .cache)
        #expect(cached.headers["set-cookie"] == nil)
        #expect(cached.headers["x-page"] == "kept")
        let stored = await h.cache.lookup(CacheKey(url: Self.ehPage, scope: "anonymous|-"))
        #expect(stored != nil)
        #expect(stored?.headers.keys.contains { $0.lowercased() == "set-cookie" } == false)
    }

    @Test func cacheIsScopedToAccountAndProfile() async throws {
        let h = try await Self.makeHarness(
            eh: ["ipb_member_id": "1234567", "ipb_pass_hash": "0123456789abcdef0123456789abcdef"]
        )
        defer { h.cleanUp() }
        _ = try await h.client.send(Self.page())
        #expect(try await h.client.send(Self.page()).source == .cache)
        // Another profile.
        try await h.cookies.set(["sp": "2"], for: [.eh])
        #expect(try await h.client.send(Self.page()).source == .network)
        #expect(try await h.client.send(Self.page()).source == .cache)
        // Another account.
        try await h.cookies.set(["ipb_member_id": "7654321"], for: [.eh])
        #expect(try await h.client.send(Self.page()).source == .network)
        // Back to the first account and profile: its page is still there.
        try await h.cookies.set(["ipb_member_id": "1234567"], for: [.eh])
        try await h.cookies.remove(["sp"], for: [.eh])
        #expect(try await h.client.send(Self.page()).source == .cache)
        #expect(h.mock.requests().count == 3)
        #expect(try h.files().count == 3)
    }

    @Test func cacheScopeFormat() async throws {
        let cookies = CookieStore(vault: InMemoryVault())
        try await cookies.load()
        let eh = URL(string: "https://e-hentai.org/")!
        let ex = URL(string: "https://exhentai.org/")!
        #expect(await cookies.cacheScope(for: eh) == "anonymous|-")
        try await cookies.set(["ipb_member_id": "1234567", "sp": "3"], for: [.eh])
        try await cookies.set(["ipb_member_id": "0", "sp": "5"], for: [.ex])
        #expect(await cookies.cacheScope(for: eh) == "1234567|3")
        #expect(await cookies.cacheScope(for: URL(string: "https://forums.e-hentai.org/")!) == "1234567|3")
        #expect(await cookies.cacheScope(for: ex) == "anonymous|5")
        // Hosts outside both sites carry no cookie: not account-specific.
        #expect(await cookies.cacheScope(for: URL(string: "https://ehgt.org/t.jpg")!) == "anonymous|-")
        #expect(await cookies.cacheScope(for: URL(string: "https://abc.hath.network/h/1.jpg")!) == "anonymous|-")
    }

    @Test func vaultFailureStillFallsBackToTheCache() async throws {
        let h = try await Self.makeHarness(vault: WriteFailingVault()) { _, number in
            number == 1
                ? MockResponse(body: Self.firstBody)
                : MockResponse(
                    status: 503, headers: ["Set-Cookie": "sk=sk-fake-new; path=/; domain=.e-hentai.org"],
                    body: Self.secondBody
                )
        }
        defer { h.cleanUp() }
        _ = try await h.client.send(Self.page())
        let fallback = try await h.client.send(Self.page(policy: .reload))
        #expect(fallback.source == .cache)
        #expect(fallback.body == Self.firstBody)
        // Without a cached page the vault's error is thrown, as before.
        await #expect(throws: VaultWriteError()) {
            try await h.client.send(Self.page(URL(string: "https://e-hentai.org/other")!, policy: .reload))
        }
    }

    @Test func storeInCacheAndEvictCache() async throws {
        let h = try await Self.makeHarness()
        defer { h.cleanUp() }
        let request = Self.page()
        let resent = EHResponse(
            status: 200, url: URL(string: "https://e-hentai.org/?inline_set=dm_l")!,
            headers: ["Set-Cookie": "sk=never-stored", "X-Page": "kept"], body: Self.secondBody, source: .network
        )
        await h.client.storeInCache(resent, for: request)
        let cached = try await h.client.send(request)
        #expect(cached.source == .cache)
        #expect(cached.body == Self.secondBody)
        #expect(cached.url == resent.url)
        #expect(cached.headers["set-cookie"] == nil)
        #expect(h.mock.requests().isEmpty)
        await h.client.evictCache(for: request)
        #expect(try h.files().isEmpty)
        // Stored only as send(_:) would: not a cache answer, not an error status, not policy .none, not a POST.
        await h.client.storeInCache(
            EHResponse(status: 200, url: Self.ehPage, headers: [:], body: Self.firstBody, source: .cache), for: request
        )
        await h.client.storeInCache(
            EHResponse(status: 404, url: Self.ehPage, headers: [:], body: Self.firstBody, source: .network), for: request
        )
        await h.client.storeInCache(resent, for: Self.page(policy: .none))
        await h.client.storeInCache(resent, for: EHRequest(method: .post, url: Self.ehPage, site: .eh))
        #expect(try h.files().isEmpty)
    }

    @Test func aClientWithoutACacheNeverCaches() async throws {
        let mock = MockURLProtocol.install { _ in MockResponse(body: Self.firstBody) }
        defer { mock.remove() }
        let cookies = CookieStore(vault: InMemoryVault())
        try await cookies.load()
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        await userAgents.load()
        let client = EHClient(
            configuration: try EHClientConfiguration(sessionConfigurator: mock.configurator),
            cookies: cookies, userAgents: userAgents, throttle: RecordingThrottle()
        )
        _ = try await client.send(Self.page())
        #expect(try await client.send(Self.page()).source == .network)
        #expect(mock.requests().count == 2)
    }

    // MARK: - ResponseCache

    @Test func fileNameIsTheSHA256OfScopeAndURL() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let cache = ResponseCache(directory: directory, now: { clock.date })
        let key = CacheKey(url: Self.ehPage, scope: "1234567|2")
        await cache.store(
            CachedResponse(status: 200, url: Self.ehPage, headers: [:], body: Self.firstBody, storedAt: clock.date),
            for: key
        )
        let expected = SHA256.hash(data: Data(("1234567|2" + "\n" + Self.ehPage.absoluteString).utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [expected])
        #expect(await cache.lookup(CacheKey(url: Self.ehPage, scope: "1234567|3")) == nil)
    }

    @Test func lookupRoundTripsAndDropsExpiredAndCorruptFiles() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let cache = ResponseCache(directory: directory, now: { clock.date })
        let key = CacheKey(url: Self.ehPage, scope: "anonymous|-")
        let response = CachedResponse(
            status: 200, url: Self.ehPage, headers: ["x-page": "kept"], body: Self.firstBody, storedAt: clock.date
        )
        await cache.store(response, for: key)
        #expect(await cache.lookup(key) == response)
        await cache.remove(key)
        #expect(await cache.lookup(key) == nil)
        // A file that does not decode is a miss and is deleted.
        await cache.store(response, for: key)
        let file = try #require(FileManager.default.contentsOfDirectory(atPath: directory.path).first)
        try Data("not json".utf8).write(to: directory.appending(path: file))
        #expect(await cache.lookup(key) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        // Expired: deleted on lookup.
        await cache.store(response, for: key)
        clock.advance(seconds: 259_201)
        #expect(await cache.lookup(key) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func storeDropsSetCookieOfAnyCase() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory)
        let key = CacheKey(url: Self.ehPage, scope: "anonymous|-")
        await cache.store(
            CachedResponse(
                status: 200, url: Self.ehPage,
                headers: ["Set-Cookie": "a=secret-0001", "set-cookie": "b=secret-0002", "etag": "x"],
                body: Self.firstBody, storedAt: Date()
            ),
            for: key
        )
        #expect(await cache.lookup(key)?.headers == ["etag": "x"])
    }

    @Test func removeAllClearsEverything() async throws {
        let h = try await Self.makeHarness()
        defer { h.cleanUp() }
        _ = try await h.client.send(Self.page())
        _ = try await h.client.send(Self.page(URL(string: "https://e-hentai.org/?page=1")!))
        #expect(try h.files().count == 2)
        await h.cache.removeAll()
        #expect(try h.files().isEmpty)
        #expect(try await h.client.send(Self.page()).source == .network)
    }

    /// `standard(cachesDirectory:)` with a temporary directory standing in for the Caches directory, so the test
    /// leaves nothing in the Mac's `~/Library/Caches` (an empty `HTTPCache` was left there).
    @Test func standardCacheLivesInTheCachesDirectory() async throws {
        let caches = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: caches) }
        let cache = try ResponseCache.standard(cachesDirectory: caches)
        let directory = caches.appending(path: "HTTPCache", directoryHint: .isDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: caches.path) == ["HTTPCache"])
        let key = CacheKey(url: URL(string: "https://e-hentai.org/standard-test")!, scope: "anonymous|-")
        await cache.store(
            CachedResponse(status: 200, url: key.url, headers: [:], body: Self.firstBody, storedAt: Date()), for: key
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        #expect(await cache.lookup(key)?.body == Self.firstBody)
        await cache.remove(key)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(ResponseCache.maximumAge == .seconds(259_200))
    }
}

private struct VaultWriteError: Error, Equatable {}

private struct WriteFailingVault: CredentialVault {
    func read() throws -> Data? { nil }
    func write(_ data: Data) throws { throw VaultWriteError() }
    func delete() throws {}
}
