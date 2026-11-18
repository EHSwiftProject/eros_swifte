import EHModels
import EHNetwork
import Foundation
import Testing

@testable import Eros

/// `SearchPreferences` (search Q3): its defaults, the advanced search a search sends, and the page range put right when
/// the filters close. Every search text here is made up but `language:chinese`, which the
/// captured advanced search page was asked for.
@MainActor @Suite struct SearchPreferencesTests {
    /// Flutter's defaults (`search_page_controller.dart`, `advance_search.dart`): no advanced search, the history
    /// shown translated.
    @Test func defaultsMatchFlutter() {
        let preferences = SearchPreferences()
        #expect(!preferences.usesAdvancedSearch)
        #expect(preferences.advancedSearch == AdvancedSearch())
        #expect(preferences.translatesHistory)
    }

    @Test func pageRangeIsNormalized() {
        #expect(Self.normalizedRange(PageRange(from: 0, to: 5)) == PageRange(from: nil, to: 5))
        #expect(Self.normalizedRange(PageRange(from: 200, to: 20)) == PageRange(from: 20, to: 200))
        #expect(Self.normalizedRange(PageRange(from: 20, to: 200)) == PageRange(from: 20, to: 200))
        #expect(Self.normalizedRange(PageRange(from: -3, to: 0)) == PageRange(from: nil, to: nil))
        // Only one bound: nothing to swap.
        #expect(Self.normalizedRange(PageRange(from: 200, to: nil)) == PageRange(from: 200, to: nil))
        // The range is the Pages switch: it stays on though no bound is left.
        #expect(Self.normalizedRange(PageRange(from: 0, to: nil)) == PageRange(from: nil, to: nil))
        #expect(Self.normalizedRange(nil) == nil)
        // A bound below 1 does not count towards a swap.
        #expect(Self.normalizedRange(PageRange(from: 5, to: 0)) == PageRange(from: 5, to: nil))

        // The rest is kept as it is, the switch included.
        var preferences = SearchPreferences()
        preferences.translatesHistory = false
        preferences.advancedSearch.requireTorrent = true
        preferences.advancedSearch.minimumRating = 3
        preferences.advancedSearch.pageRange = PageRange(from: 200, to: 20)
        var expected = preferences
        expected.advancedSearch.pageRange = PageRange(from: 20, to: 200)
        #expect(preferences.normalized() == expected)
        #expect(expected.normalized() == expected)
    }

    @Test func pageBoundsToSwapAreTold() {
        var preferences = SearchPreferences()
        #expect(!preferences.swapsPageBounds)
        preferences.advancedSearch.pageRange = PageRange(from: 200, to: 20)
        #expect(preferences.swapsPageBounds)
        preferences.advancedSearch.pageRange = PageRange(from: 20, to: 20)
        #expect(!preferences.swapsPageBounds)
        preferences.advancedSearch.pageRange = PageRange(from: 200, to: nil)
        #expect(!preferences.swapsPageBounds)
        preferences.advancedSearch.pageRange = PageRange(from: 5, to: 0)
        #expect(!preferences.swapsPageBounds)
    }

    @Test func advancedOffOrEmptySendsNothing() {
        var preferences = SearchPreferences()
        preferences.advancedSearch.requireTorrent = true
        #expect(preferences.effectiveAdvancedSearch == nil)

        preferences.usesAdvancedSearch = true
        preferences.advancedSearch = AdvancedSearch()
        #expect(preferences.effectiveAdvancedSearch == nil)
        #expect(Self.searchURL(preferences).map(Self.query(of:)) == ["f_search": "fake"])

        // Pages on with no bound still sends f_sp=on (`AdvancedSearchParser`), so it is something.
        preferences.advancedSearch.pageRange = PageRange(from: nil, to: nil)
        #expect(preferences.effectiveAdvancedSearch == preferences.advancedSearch)
    }

    /// Every option on, a minimum rating of 4 and pages 20 to 200: the URL of the search has the same name-value set as
    /// the captured `eh/list/search-advanced.html`, and the fixture replay answers it with that page, which
    /// search Q3's UI test relies on; switched off, the same search is the captured `eh/list/search.html`.
    @Test func everyOptionReachesTheURL() throws {
        var preferences = SearchPreferences()
        preferences.usesAdvancedSearch = true
        preferences.advancedSearch.requireTorrent = true
        preferences.advancedSearch.showExpunged = true
        preferences.advancedSearch.minimumRating = 4
        preferences.advancedSearch.pageRange = PageRange(from: 20, to: 200)
        preferences.advancedSearch.disableLanguageFilter = true
        preferences.advancedSearch.disableUploaderFilter = true
        preferences.advancedSearch.disableTagFilter = true

        let url = try #require(Self.searchURL(preferences, text: "language:chinese"))
        #expect(url.host() == "e-hentai.org")
        #expect(url.path() == "/")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(Set(items) == Set([
            URLQueryItem(name: "f_search", value: "language:chinese"), URLQueryItem(name: "advsearch", value: "1"),
            URLQueryItem(name: "f_sto", value: "on"), URLQueryItem(name: "f_sh", value: "on"),
            URLQueryItem(name: "f_sr", value: "on"), URLQueryItem(name: "f_srdd", value: "4"),
            URLQueryItem(name: "f_sp", value: "on"), URLQueryItem(name: "f_spf", value: "20"),
            URLQueryItem(name: "f_spt", value: "200"), URLQueryItem(name: "f_sfl", value: "on"),
            URLQueryItem(name: "f_sfu", value: "on"), URLQueryItem(name: "f_sft", value: "on"),
        ]))
        #expect(items.count == 12)

        let replay = try FixtureReplay(root: Self.fixturesRoot)
        Self.expect(replay.answer(method: "GET", url: url, body: nil), serves: "eh/list/search-advanced.html")
        preferences.usesAdvancedSearch = false
        let plain = try #require(Self.searchURL(preferences, text: "language:chinese"))
        Self.expect(replay.answer(method: "GET", url: plain, body: nil), serves: "eh/list/search.html")

        // `SearchFilterTests.testAdvancedOptionsReachTheResults` routes the plain search to the empty page: the
        // advanced one is another request and still gets the captured page.
        let empty = FixtureRoute(path: "eh/list/search-empty.html")
        let routed = try FixtureReplay(
            root: Self.fixturesRoot, routes: ["GET https://e-hentai.org/?f_search=language:chinese": empty]
        )
        Self.expect(routed.answer(method: "GET", url: plain, body: nil), serves: "eh/list/search-empty.html")
        Self.expect(routed.answer(method: "GET", url: url, body: nil), serves: "eh/list/search-advanced.html")
    }

    // MARK: - Helpers

    /// The page range of preferences with `range`, normalized.
    private static func normalizedRange(_ range: PageRange?) -> PageRange? {
        var preferences = SearchPreferences()
        preferences.usesAdvancedSearch = true
        preferences.advancedSearch.pageRange = range
        return preferences.normalized().advancedSearch.pageRange
    }

    /// The URL of a gallery-scope search for `text` on e-hentai.org with `preferences`, no categories hidden.
    private static func searchURL(_ preferences: SearchPreferences, text: String = "fake") -> URL? {
        SearchFeeds.listQuery(
            text: text, request: SearchRequest(scope: .gallery, site: .eh), categories: [],
            advanced: preferences.effectiveAdvancedSearch
        )?.url(for: .eh)
    }

    private static func query(of url: URL) -> [String: String] {
        SearchFeedsTests.query(of: url)
    }

    /// The fixtures the copy script put into the app (the test host), which the UI tests replay.
    private static let fixturesRoot = Bundle.main.resourceURL!.appending(
        path: FixtureReplay.bundleDirectory, directoryHint: .isDirectory
    )

    /// The answer is a 200 with the bytes of the fixture at `path`.
    private static func expect(
        _ answer: FixtureReplayAnswer, serves path: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(answer.status == 200, "\(path)", sourceLocation: sourceLocation)
        #expect(answer.body == SearchFeedsTests.fixture(path), "\(path)", sourceLocation: sourceLocation)
    }
}
