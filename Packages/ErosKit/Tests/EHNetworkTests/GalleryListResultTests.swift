import EHFixtures
import EHModels
import EHNetwork
import EHNetworkTesting
import EHParsing
import Foundation
import Testing

/// `EHService.galleryListResult`: the page and whether the answer it was parsed from came from the response cache.
/// Every request goes to `MockURLProtocol` and is answered with checked-in fixtures; nothing reaches the network.
@Suite struct GalleryListResultTests {
    private static let compact = Data(try! Fixtures.data("eh/list/front.html"))
    private static let nonCompact = Data(try! Fixtures.data("constructed/eh/list-non-compact.html"))
    private static let query = ListQuery(source: .front)

    private struct Harness {
        let service: EHService
        let client: EHClient
        let mock: MockSession
        let directory: URL

        func cleanUp() {
            mock.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A signed-out client with a response cache in a new temporary directory; the presenter agrees to the Compact
    /// view at once.
    private static func makeHarness(
        responder: @escaping @Sendable (URLRequest) throws -> MockResponse
    ) async throws -> Harness {
        let mock = MockURLProtocol.install(responder)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "eros-list-result-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cookies = CookieStore(vault: InMemoryVault())
        try await cookies.load()
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        await userAgents.load()
        let client = EHClient(
            configuration: try EHClientConfiguration(sessionConfigurator: mock.configurator), cookies: cookies,
            userAgents: userAgents, throttle: RecordingThrottle(), cache: ResponseCache(directory: directory)
        )
        let service = EHService(client: client, presenter: AlwaysAgree(), ledger: InMemoryNoticeLedger())
        return Harness(service: service, client: client, mock: mock, directory: directory)
    }

    /// Non-Compact until a request carries `inline_set`.
    private static func compactOnResend(_ request: URLRequest) -> MockResponse {
        MockResponse(body: request.url?.absoluteString.contains("inline_set") == true ? compact : nonCompact)
    }

    @Test func networkPagesAreNotFromCache() async throws {
        let h = try await Self.makeHarness { _ in MockResponse(body: Self.compact) }
        defer { h.cleanUp() }
        let result = try await h.service.galleryListResult(Self.query, site: .eh, refresh: false)
        #expect(!result.isFromCache)
        #expect(result.page.items.count == 25)
        #expect(h.mock.requests().count == 1)
    }

    @Test func cachedPagesAreFromCache() async throws {
        let h = try await Self.makeHarness { _ in MockResponse(body: Self.compact) }
        defer { h.cleanUp() }
        let first = try await h.service.galleryListResult(Self.query, site: .eh, refresh: false)
        let second = try await h.service.galleryListResult(Self.query, site: .eh, refresh: false)
        #expect(!first.isFromCache)
        #expect(second.isFromCache)
        #expect(second.page == first.page)
        #expect(h.mock.requests().count == 1)
    }

    @Test func refreshIsNeverFromCache() async throws {
        let h = try await Self.makeHarness { _ in MockResponse(body: Self.compact) }
        defer { h.cleanUp() }
        _ = try await h.service.galleryListResult(Self.query, site: .eh, refresh: false)
        let refreshed = try await h.service.galleryListResult(Self.query, site: .eh, refresh: true)
        #expect(!refreshed.isFromCache)
        #expect(refreshed.page.items.count == 25)
        #expect(h.mock.requests().count == 2)
    }

    /// The page parsed is the resend's, from the site, also when the first answer (not Compact) came from the cache.
    /// The resend is cached under the first request's URL, so the next call is answered from the cache.
    @Test(arguments: [false, true])
    func compactResendIsNotFromCache(firstFromCache: Bool) async throws {
        let h = try await Self.makeHarness(responder: Self.compactOnResend)
        defer { h.cleanUp() }
        if firstFromCache {
            _ = try await h.client.send(EHRequests.list(Self.query, site: .eh))
        }
        let result = try await h.service.galleryListResult(Self.query, site: .eh, refresh: false)
        #expect(!result.isFromCache)
        #expect(result.page.items.count == 25)
        let urls = h.mock.requests().compactMap(\.url)
        #expect(urls.count == 2)
        #expect(urls.last?.absoluteString.contains("inline_set=dm_l") == true)
        let again = try await h.service.galleryListResult(Self.query, site: .eh, refresh: false)
        #expect(again.isFromCache)
        #expect(again.page == result.page)
        #expect(h.mock.requests().count == 2)
    }

    /// `galleryList` is `galleryListResult(…).page`; EHServiceTests and SessionBoundaryTests keep covering it.
    @Test func galleryListReturnsTheSamePage() async throws {
        let h = try await Self.makeHarness { _ in MockResponse(body: Self.compact) }
        defer { h.cleanUp() }
        let page = try await h.service.galleryList(Self.query, site: .eh, refresh: true)
        let result = try await h.service.galleryListResult(Self.query, site: .eh, refresh: true)
        #expect(result.page == page)
        #expect(!result.isFromCache)
        #expect(h.mock.requests().count == 2)
    }
}
