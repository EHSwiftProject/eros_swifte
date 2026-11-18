import EHModels
import EHNetwork
import Foundation
import Testing

@testable import Eros

/// `SearchFeeds` (search Q2): the list query of each scope, and the feed it makes. Requests go to a `StubURLProtocol`
/// that answers with a page of the Debug bundle's fixtures; nothing reaches the network. Every search text here is made
/// up.
@MainActor @Suite struct SearchFeedsTests {
    /// Records every question and answers each with `answer`.
    private actor CountingPresenter: SiteSettingPresenter {
        private let answer: Bool
        private(set) var changes: [SiteSettingChange] = []

        init(answer: Bool) {
            self.answer = answer
        }

        func confirm(_ change: SiteSettingChange, site: EHSite) async -> Bool {
            changes.append(change)
            return answer
        }
    }

    /// A page of the Debug bundle's fixtures (`scripts/copy-replay-fixtures.sh`).
    static func fixture(_ path: String) -> Data {
        let root = Bundle.main.resourceURL!.appending(path: FixtureReplay.bundleDirectory, directoryHint: .isDirectory)
        return try! Data(contentsOf: root.appending(path: path))
    }

    /// An empty search result (Compact, no galleries).
    static let emptyResult = fixture("eh/list/search-empty.html")
    /// The constructed favorites page: Compact, ordered by Favorited, five galleries, a next cursor.
    static let favoritesPage = fixture("constructed/eh/list-favorites.html")

    /// An environment (in-memory stores) whose requests go to a stub answering every one with `answer`; started.
    static func makeEnvironment(answer: Data = emptyResult) async -> (environment: AppEnvironment, stub: StubSession) {
        let stub = StubURLProtocol.install { _ in StubResponse(body: answer) }
        let environment = AppEnvironment(
            uiTesting: true, sessionConfigurator: stub.configurator, userAgentProbe: { "FakeWebKit/1" }
        )
        await environment.start()
        return (environment, stub)
    }

    /// The decoded query items of `url`, by name (the first of each).
    static func query(of url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func galleryScopeUsesTheFrontPage() throws {
        let request = SearchRequest(scope: .gallery, site: .eh)
        let misc = try #require(SearchFeeds.listQuery(
            text: "fake", request: request, categories: CategoryMask(excluding: [.misc]), advanced: nil
        ))
        #expect(misc == ListQuery(source: .front, search: "fake", excludedCategories: 1, advanced: nil))

        let none = try #require(SearchFeeds.listQuery(text: "fake", request: request, categories: [], advanced: nil))
        #expect(none.excludedCategories == nil)
        #expect(none.source == .front)

        var advanced = AdvancedSearch()
        advanced.requireTorrent = true
        advanced.minimumRating = 4
        let withAdvanced = try #require(
            SearchFeeds.listQuery(text: "fake", request: request, categories: [], advanced: advanced)
        )
        #expect(withAdvanced.advanced == advanced)
    }

    @Test func watchedScopeUsesWatched() throws {
        let request = SearchRequest(scope: .watched, site: .eh)
        let query = try #require(SearchFeeds.listQuery(
            text: "fake", request: request, categories: CategoryMask(excluding: [.misc]), advanced: nil
        ))
        #expect(query == ListQuery(source: .watched, search: "fake", excludedCategories: 1, advanced: nil))
    }

    /// The favorites scope has no list query: its feed asks favorites.php for the folder with `f_search`, without the
    /// categories or the advanced options (Flutter hides both there).
    @Test func favoritesScopeCallsFavorites() async throws {
        let (environment, stub) = await Self.makeEnvironment(answer: Self.favoritesPage)
        defer { stub.remove() }
        let request = SearchRequest(scope: .favorites, favoritesFolder: 3, site: .eh)
        var advanced = AdvancedSearch()
        advanced.requireTorrent = true
        let categories = CategoryMask(excluding: [.misc])
        #expect(
            SearchFeeds.listQuery(text: "fake", request: request, categories: categories, advanced: advanced) == nil
        )

        let feed = SearchFeeds.make(
            text: "fake", request: request, categories: categories, advanced: advanced,
            favoritesOrder: .favoritedTime, service: environment.service
        )
        #expect(feed is FavoritesFeed)
        let result = try await feed.page(at: .first, refresh: false)
        #expect(result.page.items.count == 5)

        let urls = stub.requests().compactMap(\.url)
        #expect(urls.count == 1)
        let url = try #require(urls.first)
        #expect(url.host() == "e-hentai.org")
        #expect(url.path() == "/favorites.php")
        #expect(Self.query(of: url) == ["favcat": "3", "f_search": "fake"])
    }

    /// The user declines the order the search asked for: the first page comes in the site's order, and the next page
    /// is asked in it, still with the search, and without the parameter that would change the order on the site.
    @Test func declinedOrderKeepsTheSearchOnLaterPages() async throws {
        let (environment, stub) = await Self.makeEnvironment(answer: Self.favoritesPage)
        defer { stub.remove() }
        let presenter = CountingPresenter(answer: false)
        let service = EHService(client: environment.client, presenter: presenter, ledger: InMemoryNoticeLedger())
        let feed = SearchFeeds.make(
            text: "fake text", request: SearchRequest(scope: .favorites, site: .eh), categories: [], advanced: nil,
            favoritesOrder: .postedTime, service: service
        )
        let favorites = try #require(feed as? FavoritesFeed)

        let first = try await feed.page(at: .first, refresh: false)
        #expect(first.page.favoritesOrder == .favoritedTime)
        #expect(await presenter.changes == [.favoritesOrder(.postedTime)])
        #expect(favorites.order == .favoritedTime)
        let cursor = try #require(first.page.nextCursor)

        _ = try await feed.page(at: .next(cursor), refresh: false)
        #expect(await presenter.changes.count == 1)
        let urls = stub.requests().compactMap(\.url)
        #expect(urls.count == 2)
        #expect(Self.query(of: urls.first) == ["f_search": "fake text"])
        #expect(Self.query(of: urls.last) == ["f_search": "fake text", "next": cursor])
        #expect(urls.allSatisfy { Self.query(of: $0)["inline_set"] == nil })
    }

    /// Quotes, a "$" and a "-" reach the site as typed: the `f_search` the session sends decodes to the text.
    @Test func searchTextRoundTripsThroughTheURL() async throws {
        let text = "female:\"example tag$\" -x"
        let request = SearchRequest(scope: .gallery, site: .eh)
        let query = try #require(SearchFeeds.listQuery(text: text, request: request, categories: [], advanced: nil))
        #expect(Self.query(of: query.url(for: .eh))["f_search"] == text)

        let (environment, stub) = await Self.makeEnvironment()
        defer { stub.remove() }
        let feed = SearchFeeds.make(
            text: text, request: request, categories: [], advanced: nil, favoritesOrder: .favoritedTime,
            service: environment.service
        )
        _ = try await feed.page(at: .first, refresh: false)
        let sent = try #require(stub.requests().first?.url)
        #expect(Self.query(of: sent) == ["f_search": text])
        #expect(sent.path() == "/")
    }

    /// A request on ExHentai searches there, in every scope.
    @Test(arguments: [SearchScope.gallery, .watched, .favorites])
    func exRequestsSearchTheExSite(scope: SearchScope) async throws {
        let (environment, stub) = await Self.makeEnvironment(
            answer: scope == .favorites ? Self.favoritesPage : Self.emptyResult
        )
        defer { stub.remove() }
        let feed = SearchFeeds.make(
            text: "fake", request: SearchRequest(scope: scope, site: .ex), categories: [], advanced: nil,
            favoritesOrder: .favoritedTime, service: environment.service
        )
        _ = try await feed.page(at: .first, refresh: false)
        let hosts = stub.requests().compactMap { $0.url?.host() }
        #expect(hosts == ["exhentai.org"])
    }
}
