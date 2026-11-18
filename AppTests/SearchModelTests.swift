import EHModels
import EHNetwork
import EHStore
import Foundation
import SwiftUI
import Testing

@testable import Eros

/// `SearchModel` (search Q2): submitting, links, history, quick searches, filters, suggestions, and the search
/// preferences it reads. Requests go to a `StubURLProtocol` answering with an empty search result; tag suggestions come
/// from an injected `suggest`, so none reaches the stub. Every text, tag and link here is made up. Each test has a
/// minute: some hold a stub's answer or a read until they let it go, and a regression must fail them, not hang the run.
@MainActor @Suite(.timeLimit(.minutes(1))) struct SearchModelTests {
    /// The texts an injected `suggest` was asked for, oldest first.
    @MainActor final class AskedTexts {
        var all: [String] = []
    }

    /// History reads held until the test answers them, in the order it chooses.
    @MainActor final class HeldReads {
        private var waiting: [CheckedContinuation<[String], Never>] = []

        func read() async -> [String] {
            await withCheckedContinuation { waiting.append($0) }
        }

        /// Returns once `count` reads are waiting (or after many turns, for the expectations to fail).
        func waitForReads(_ count: Int) async {
            for _ in 0..<10_000 where waiting.count < count {
                await Task.yield()
            }
        }

        /// The read at `index` (the first one is 0) returns `texts`; a read that is not waiting fails the test rather
        /// than the test process.
        func answer(_ index: Int, with texts: [String]) throws {
            try #require(index < waiting.count, "read \(index) is not waiting (\(waiting.count) are)")
            waiting[index].resume(returning: texts)
        }
    }

    struct Harness {
        let environment: AppEnvironment
        let stub: StubSession
        let asked: AskedTexts

        /// The URLs the stub received, oldest first.
        func urls() -> [URL] {
            stub.requests().compactMap(\.url)
        }

        func cleanUp() {
            stub.remove()
        }
    }

    static func makeHarness(answer: Data = SearchFeedsTests.emptyResult) async -> Harness {
        let (environment, stub) = await SearchFeedsTests.makeEnvironment(answer: answer)
        return Harness(environment: environment, stub: stub, asked: AskedTexts())
    }

    /// A model over `h`'s environment (its store unless `missingStore`), whose suggestions answer every text with one
    /// made-up tag and record what they were asked; `readHistory` in place of the store's history reads.
    static func makeModel(
        _ h: Harness, request: SearchRequest = SearchRequest(site: .eh), missingStore: Bool = false,
        terms: SearchTermTranslator? = nil, readHistory: (@MainActor () async throws -> [String])? = nil
    ) -> SearchModel {
        let asked = h.asked
        let tagQuery = TagSuggestionQuery(service: h.environment.tagSuggestions) { text, _ in
            asked.all.append(text)
            return [TagSuggestion(tag: TagRef(namespace: "female", name: "fake suggestion"), translation: nil)]
        }
        return SearchModel(
            request: request, service: h.environment.service,
            userData: missingStore ? nil : h.environment.userData, settings: h.environment.settings,
            preferences: h.environment.searchPreferences, terms: terms ?? h.environment.searchTerms,
            tagQuery: tagQuery, readHistory: readHistory
        )
    }

    private static func query(of url: URL?) -> [String: String] {
        SearchFeedsTests.query(of: url)
    }

    // MARK: - Submitting

    @Test func submitRecordsHistoryAndSearches() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()
        #expect(model.history.isEmpty)
        #expect(model.isSearchPresented)

        model.text = "  fake\n"
        #expect(await model.submit() == .searched)
        #expect(model.text == "fake")
        #expect(model.history.map(\.text) == ["fake"])
        let results = try #require(model.results)
        #expect(model.resultsID == 1)
        await results.loadFirst()
        #expect(h.urls().count == 1)
        #expect(Self.query(of: h.urls().first) == ["f_search": "fake"])
        #expect(h.urls().first?.path() == "/")
    }

    @Test func blankSubmitDoesNothing() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()

        model.text = " \n\t\r "
        #expect(await model.submit() == .ignored)
        #expect(model.history.isEmpty)
        #expect(model.results == nil)
        #expect(model.resultsID == 0)
        #expect(try await h.environment.userData?.searchHistory() == [])
        #expect(h.stub.requests().isEmpty)
    }

    /// A site gallery link is opened, not searched: nothing is recorded or asked.
    @Test func siteGalleryURLNavigates() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()

        model.text = "https://e-hentai.org/g/1234/0123456789/\n"
        let gallery = EHLink.gallery(GalleryID(gid: 1234, token: "0123456789"), site: .eh)
        #expect(model.linkTarget == gallery)
        #expect(await model.submit() == .navigate(gallery))
        #expect(model.history.isEmpty)
        #expect(model.results == nil)
        #expect(try await h.environment.userData?.searchHistory() == [])
        #expect(h.stub.requests().isEmpty)
    }

    /// Submitted from the page (the keyboard, the Search row), a gallery link is pushed onto the selected tab's stack,
    /// where the search page is; a search pushes nothing.
    @Test func submittingAGalleryLinkPushesIt() async {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        let router = AppRouter(selectedTab: .favorites)
        await model.start()

        model.text = "https://e-hentai.org/g/1234/0123456789/"
        await model.submit(opening: router)
        #expect(router.path(for: .favorites).wrappedValue.count == 1)
        #expect(router.path(for: .gallery).wrappedValue.isEmpty)

        model.text = "fake"
        await model.submit(opening: router)
        #expect(router.path(for: .favorites).wrappedValue.count == 1)
        #expect(model.results != nil)
    }

    /// A search page opened with a gallery link as its text (an external search link whose `f_search` is a gallery's
    /// URL) opens the gallery on the tab's stack above it, as a submit of the link does: nothing is searched or
    /// recorded. Coming back to the page opens nothing again.
    @Test func startWithAGalleryLinkOpensIt() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let request = SearchRequest(text: "https://e-hentai.org/g/1234/0123456789/", site: .eh)
        let model = Self.makeModel(h, request: request)
        let router = AppRouter(selectedTab: .gallery)
        await model.start(opening: router)
        #expect(router.path(for: .gallery).wrappedValue.count == 1)
        #expect(model.results == nil)
        #expect(model.history.isEmpty)
        #expect(try await h.environment.userData?.searchHistory() == [])
        #expect(h.stub.requests().isEmpty)

        await model.start(opening: router)
        #expect(router.path(for: .gallery).wrappedValue.count == 1)

        // A text that is no such link is searched, and nothing is pushed.
        let search = Self.makeModel(h, request: SearchRequest(text: "fake", site: .eh))
        await search.start(opening: router)
        #expect(search.results != nil)
        #expect(router.path(for: .gallery).wrappedValue.count == 1)
    }

    /// A pasted tag link searches the tag in place (Flutter), unlike an external open (entry E1's tag list).
    @Test func tagLinkSearchesInPlace() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()

        model.text = "https://e-hentai.org/tag/female:fake+tag"
        #expect(await model.submit() == .searched)
        #expect(model.text == "female:\"fake tag$\"")
        #expect(model.history.map(\.text) == ["female:\"fake tag$\""])
        await model.results?.loadFirst()
        #expect(Self.query(of: h.urls().first) == ["f_search": "female:\"fake tag$\""])

        model.text = "https://e-hentai.org/uploader/fake+uploader"
        #expect(await model.submit() == .searched)
        #expect(model.text == "uploader:\"fake uploader\"")

        model.text = "https://e-hentai.org/?f_search=fake%0Atext"
        #expect(await model.submit() == .searched)
        #expect(model.text == "fake text")
    }

    /// A link to another site is searched as text: the search goes to e-hentai.org, nothing to the link's host.
    @Test func foreignURLIsSearchedAsText() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()

        model.text = "https://example.com/g/1/abc/"
        #expect(model.linkTarget == nil)
        #expect(await model.submit() == .searched)
        #expect(model.linkTarget == nil)
        await model.results?.loadFirst()
        #expect(h.urls().map { $0.host() } == ["e-hentai.org"])
        #expect(Self.query(of: h.urls().first) == ["f_search": "https://example.com/g/1/abc/"])
    }

    @Test func initialTextSearchesOnStart() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h, request: SearchRequest(text: "fake", site: .eh))
        #expect(model.text == "fake")
        await model.start()
        #expect(!model.isSearchPresented)
        #expect(model.history.map(\.text) == ["fake"])
        let results = try #require(model.results)
        await results.loadFirst()
        #expect(Self.query(of: h.urls().first) == ["f_search": "fake"])

        // The page appearing again (back from a gallery) does not search again.
        await model.start()
        #expect(model.resultsID == 1)
        #expect(model.results === results)
    }

    /// Submitting drops the suggestions, and while the field holds the text searched, the
    /// suggestions area shows nothing (nor asks for any), so it does not cover the results.
    @Test func submittedTextShowsNoSuggestions() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()

        model.text = "fak"
        model.textDidChange()
        await model.tagQuery.task?.value
        #expect(!model.suggestions.isEmpty)
        #expect(!model.isShowingSubmittedText)

        #expect(await model.submit() == .searched)
        #expect(model.suggestions.isEmpty)
        #expect(model.isShowingSubmittedText)
        // The view reports the change submit made to the text: nothing is asked.
        model.textDidChange()
        #expect(model.tagQuery.task == nil)
        #expect(h.asked.all == ["fak"])

        model.text = "fak x"
        model.textDidChange()
        #expect(!model.isShowingSubmittedText)
        await model.tagQuery.task?.value
        #expect(h.asked.all == ["fak", "fak x"])
    }

    /// A pasted site link asks for no suggestions (it would send the link to the site's
    /// API), and drops those shown.
    @Test func pastedLinksAskForNoSuggestions() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()

        model.text = "fak"
        model.textDidChange()
        await model.tagQuery.task?.value
        #expect(!model.suggestions.isEmpty)

        for link in ["https://e-hentai.org/g/1234/0123456789/", "https://e-hentai.org/tag/female:fake+tag\n"] {
            model.text = link
            model.textDidChange()
            #expect(model.tagQuery.task == nil)
            #expect(model.suggestions.isEmpty)
        }
        // A link to another site is text: it is asked for.
        model.text = "https://example.com/g/1/abc/"
        model.textDidChange()
        await model.tagQuery.task?.value
        #expect(h.asked.all == ["fak", "https://example.com/g/1/abc/"])
        #expect(h.stub.requests().isEmpty)
    }

    // MARK: - History and quick searches

    @Test func historyShowsThirtyNewestOfAHundred() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let store = try #require(h.environment.userData)
        for index in 0..<100 {
            try await store.recordSearch("fake \(index)")
        }
        let model = Self.makeModel(h)
        await model.start()
        #expect(model.history.map(\.text) == (70..<100).reversed().map { "fake \($0)" })
    }

    /// A history entry or a tag is appended to the text, with no search (Flutter appends only).
    @Test func historyAndTagsAppendWithoutSearching() async {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()
        model.isSearchPresented = false

        model.useHistory("fake")
        #expect(model.text == "fake ")
        #expect(model.isSearchPresented)

        model.text = "a"
        model.isSearchPresented = false
        model.appendTag(TagRef(namespace: "female", name: "example tag"))
        #expect(model.text == "a female:\"example tag$\" ")
        #expect(model.isSearchPresented)
        #expect(model.results == nil)
        #expect(model.history.isEmpty)
        #expect(h.stub.requests().isEmpty)
    }

    @Test func historyEntriesAreRemovedAndCleared() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let store = try #require(h.environment.userData)
        for text in ["fake 1", "fake 2", "fake 3"] {
            try await store.recordSearch(text)
        }
        let model = Self.makeModel(h)
        await model.start()
        #expect(model.history.map(\.text) == ["fake 3", "fake 2", "fake 1"])

        await model.removeHistory("fake 2")
        #expect(model.history.map(\.text) == ["fake 3", "fake 1"])
        await model.clearHistory()
        #expect(model.history.isEmpty)
        #expect(try await store.searchHistory().isEmpty)
    }

    /// A history load that began before another but ends after it changes nothing: the history shows what the newer
    /// load read.
    @Test func aLateOlderHistoryLoadChangesNothing() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let reads = HeldReads()
        let model = Self.makeModel(h, readHistory: { await reads.read() })

        let older = Task { await model.start() }
        await reads.waitForReads(1)
        let newer = Task { await model.start() }
        await reads.waitForReads(2)

        try reads.answer(1, with: ["fake newer"])
        _ = await newer.value
        #expect(model.history.map(\.text) == ["fake newer"])
        try reads.answer(0, with: ["fake older"])
        _ = await older.value
        #expect(model.history.map(\.text) == ["fake newer"])
    }

    @Test func addToQuickSearchStoresOneLine() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()
        #expect(model.canSaveData)

        model.text = "a\nb"
        #expect(!model.isInQuickSearch)
        #expect(await model.addToQuickSearch())
        #expect(model.quickSearches == ["a b"])
        #expect(model.isInQuickSearch)
        #expect(await model.addToQuickSearch() == false)
        #expect(try await h.environment.userData?.quickSearches() == ["a b"])
    }

    /// Add to Quick Search is offered for a text that is not one yet: not for a blank text, a site link, a text
    /// already there, or without a store.
    @Test func addToQuickSearchNeedsANewText() async {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()
        #expect(!model.canAddToQuickSearch)
        model.text = " \n "
        #expect(!model.canAddToQuickSearch)
        model.text = "https://e-hentai.org/g/1234/0123456789/"
        #expect(!model.canAddToQuickSearch)
        model.text = "https://e-hentai.org/tag/female:fake+tag"
        #expect(!model.canAddToQuickSearch)

        model.text = "fake"
        #expect(model.canAddToQuickSearch)
        #expect(await model.addToQuickSearch())
        #expect(!model.canAddToQuickSearch)

        let withoutStore = Self.makeModel(h, missingStore: true)
        withoutStore.text = "fake"
        #expect(!withoutStore.canAddToQuickSearch)
    }

    /// The page appearing again (back from the quick search page, search Q4) reads the quick
    /// searches again, so In Quick Search follows what was added or removed meanwhile; nothing is searched again.
    @Test func startingAgainReloadsTheQuickSearches() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let store = try #require(h.environment.userData)
        let model = Self.makeModel(h, request: SearchRequest(text: "fake searched", site: .eh))
        await model.start()
        let results = try #require(model.results)
        #expect(model.quickSearches.isEmpty)
        #expect(model.canAddToQuickSearch)

        #expect(try await store.addQuickSearch("fake searched"))
        #expect(!model.isInQuickSearch)
        await model.start()
        #expect(model.quickSearches == ["fake searched"])
        #expect(model.isInQuickSearch)
        #expect(!model.canAddToQuickSearch)

        try await store.removeQuickSearch("fake searched")
        await model.start()
        #expect(model.quickSearches.isEmpty)
        #expect(!model.isInQuickSearch)
        #expect(model.canAddToQuickSearch)

        #expect(model.resultsID == 1)
        #expect(model.results === results)
        #expect(model.history.map(\.text) == ["fake searched"])
    }

    /// A quick search runs like a submit from the page. A gallery link (an imported file may
    /// hold one) is pushed onto the selected tab's stack and recorded nowhere; a text is searched and recorded in the
    /// history, as any search.
    @Test func quickSearchingAGalleryLinkPushesIt() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        let router = AppRouter(selectedTab: .favorites)
        await model.start()

        await model.search("https://e-hentai.org/g/1234/0123456789/", opening: router)
        let gallery = EHLink.gallery(GalleryID(gid: 1234, token: "0123456789"), site: .eh)
        #expect(router.path(for: .favorites).wrappedValue == NavigationPath([AppRoute(gallery)]))
        #expect(router.path(for: .gallery).wrappedValue.isEmpty)
        #expect(model.results == nil)
        #expect(model.history.isEmpty)

        await model.search("fake quick", opening: router)
        #expect(router.path(for: .favorites).wrappedValue.count == 1)
        #expect(model.text == "fake quick")
        #expect(model.results != nil)
        #expect(model.history.map(\.text) == ["fake quick"])
        #expect(try await h.environment.userData?.searchHistory() == ["fake quick"])
    }

    @Test func missingStoreStillSearches() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h, missingStore: true)
        await model.start()
        #expect(model.history.isEmpty)
        #expect(model.quickSearches.isEmpty)
        #expect(!model.canSaveData)

        model.text = "fake"
        #expect(await model.submit() == .searched)
        #expect(model.history.isEmpty)
        #expect(await model.addToQuickSearch() == false)
        await model.results?.loadFirst()
        #expect(Self.query(of: h.urls().first) == ["f_search": "fake"])
    }

    /// Translations show only while tags are shown translated and the history's own switch is on.
    @Test func historyTranslationsFollowTheToggle() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let store = try #require(h.environment.userData)
        try await store.recordSearch("plain")
        try await store.recordSearch("female:\"fake tag$\"")
        let terms = SearchTermTranslator(translations: try await FakeTagTable.store())
        let settings = h.environment.settings
        let preferences = h.environment.searchPreferences
        settings.settings.showsTagTranslations = true
        #expect(preferences.preferences.translatesHistory)

        let model = Self.makeModel(h, terms: terms)
        await model.start()
        #expect(model.history == [
            SearchModel.HistoryEntry(text: "female:\"fake tag$\"", translation: "女性:示例标签"),
            SearchModel.HistoryEntry(text: "plain", translation: nil),
        ])

        await model.toggleHistoryTranslation()
        #expect(!preferences.preferences.translatesHistory)
        #expect(model.history.map(\.translation) == [nil, nil])

        await model.toggleHistoryTranslation()
        #expect(model.history.first?.translation == "女性:示例标签")

        settings.settings.showsTagTranslations = false
        await model.start()
        #expect(preferences.preferences.translatesHistory)
        #expect(model.history.map(\.translation) == [nil, nil])
    }

    // MARK: - Scope and filters

    @Test func changingScopeRerunsTheSearch() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()

        // Before a search, a scope only waits for one.
        model.scope = .watched
        #expect(model.results == nil)
        model.scope = .gallery

        model.text = "fake"
        _ = await model.submit()
        let first = try #require(model.results)
        model.text = "fake more"
        model.scope = .watched
        #expect(model.resultsID == 2)
        let second = try #require(model.results)
        #expect(second !== first)
        // The text searched runs again, not the one being typed.
        #expect(model.text == "fake more")
        await second.loadFirst()
        let url = try #require(h.urls().last)
        #expect(url.path() == "/watched")
        #expect(Self.query(of: url) == ["f_search": "fake"])
    }

    @Test func changingFiltersRerunsTheSearch() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()
        model.text = "fake"
        _ = await model.submit()
        await model.results?.loadFirst()
        #expect(Self.query(of: h.urls().last) == ["f_search": "fake"])

        h.environment.settings.settings.categoryFilter = CategoryMask(excluding: [.misc])
        model.filtersDidChange()
        #expect(model.resultsID == 2)
        await model.results?.loadFirst()
        #expect(Self.query(of: h.urls().last) == ["f_cats": "1", "f_search": "fake"])

        var advanced = AdvancedSearch()
        advanced.requireTorrent = true
        h.environment.searchPreferences.preferences.advancedSearch = advanced
        h.environment.searchPreferences.preferences.usesAdvancedSearch = true
        model.filtersDidChange()
        #expect(model.resultsID == 3)
        await model.results?.loadFirst()
        let query = Self.query(of: h.urls().last)
        #expect(query["advsearch"] == "1")
        #expect(query["f_sto"] == "on")
        #expect(query["f_search"] == "fake")
    }

    @Test func unchangedFiltersDoNotRerun() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()

        // Nothing searched yet: nothing to run again.
        h.environment.settings.settings.categoryFilter = CategoryMask(excluding: [.misc])
        model.filtersDidChange()
        #expect(model.results == nil)

        model.text = "fake"
        _ = await model.submit()
        let results = try #require(model.results)
        model.filtersDidChange()
        model.scope = .gallery
        // Advanced options switched on but empty send nothing, so they change nothing.
        h.environment.searchPreferences.preferences.usesAdvancedSearch = true
        model.filtersDidChange()
        #expect(model.resultsID == 1)
        #expect(model.results === results)
        #expect(h.stub.requests().isEmpty)
    }

    /// Closing the filters puts the page range right (`SearchPreferences.normalized()`), then runs the search again
    /// with it (search Q3: the sheet's `onDismiss`).
    @Test func closingTheFiltersNormalizesThemAndReruns() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()

        // Nothing searched yet: only put right.
        h.environment.searchPreferences.preferences.usesAdvancedSearch = true
        h.environment.searchPreferences.preferences.advancedSearch.pageRange = PageRange(from: 0, to: 5)
        model.filtersDidClose()
        #expect(h.environment.searchPreferences.preferences.advancedSearch.pageRange == PageRange(from: nil, to: 5))
        #expect(model.results == nil)

        model.text = "fake"
        _ = await model.submit()
        h.environment.searchPreferences.preferences.advancedSearch.pageRange = PageRange(from: 200, to: 20)
        model.filtersDidClose()
        #expect(h.environment.searchPreferences.preferences.advancedSearch.pageRange == PageRange(from: 20, to: 200))
        // Saved as put right.
        let saved = SearchPreferencesStore(defaults: h.environment.settings.defaults).preferences
        #expect(saved.advancedSearch.pageRange == PageRange(from: 20, to: 200))
        #expect(model.resultsID == 2)
        await model.results?.loadFirst()
        let query = Self.query(of: h.urls().last)
        #expect(query["f_spf"] == "20")
        #expect(query["f_spt"] == "200")

        // Closed again with nothing changed: nothing runs.
        model.filtersDidClose()
        #expect(model.resultsID == 2)
    }

    /// A search sends the advanced search put right, whatever is saved. The
    /// saved value is only put right when the filters close, so another window searching meanwhile, or a launch after
    /// the app was ended with the sheet open, finds it as typed.
    @Test func searchesSendThePageRangePutRight() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()
        h.environment.searchPreferences.preferences.usesAdvancedSearch = true
        h.environment.searchPreferences.preferences.advancedSearch.pageRange = PageRange(from: 200, to: 20)

        model.text = "fake"
        _ = await model.submit()
        await model.results?.loadFirst()
        let query = Self.query(of: h.urls().last)
        #expect(query["f_spf"] == "20")
        #expect(query["f_spt"] == "200")
        // The saved value is left as typed until the filters close.
        #expect(h.environment.searchPreferences.preferences.advancedSearch.pageRange == PageRange(from: 200, to: 20))
    }

    /// Bounds that put right are the ones searched change nothing, so nothing runs again: neither while the
    /// filters are open (another reason to look at them, here `filtersDidChange()`) nor when they close.
    @Test func boundsThatPutRightAreTheSameDoNotRerun() async throws {
        let h = await Self.makeHarness()
        defer { h.cleanUp() }
        let model = Self.makeModel(h)
        await model.start()
        h.environment.searchPreferences.preferences.usesAdvancedSearch = true
        h.environment.searchPreferences.preferences.advancedSearch.pageRange = PageRange(from: 20, to: 200)
        model.text = "fake"
        _ = await model.submit()
        let results = try #require(model.results)

        h.environment.searchPreferences.preferences.advancedSearch.pageRange = PageRange(from: 200, to: 20)
        model.filtersDidChange()
        #expect(model.resultsID == 1)
        model.filtersDidClose()
        #expect(h.environment.searchPreferences.preferences.advancedSearch.pageRange == PageRange(from: 20, to: 200))
        #expect(model.resultsID == 1)
        #expect(model.results === results)
        #expect(h.stub.requests().isEmpty)
    }

    /// The Favorites scope is only offered while logged in, so logging out
    /// while it is the scope goes back to Gallery, and a search that ran in it runs again in the gallery; in another
    /// scope logging out changes nothing.
    @Test func signingOutLeavesTheFavoritesScope() async throws {
        let h = await Self.makeHarness(answer: SearchFeedsTests.favoritesPage)
        defer { h.cleanUp() }
        let model = Self.makeModel(h, request: SearchRequest(scope: .favorites, site: .eh))
        await model.start()
        model.text = "fake"
        _ = await model.submit()
        await model.results?.loadFirst()
        #expect(h.urls().last?.path() == "/favorites.php")

        model.loginDidChange(isLoggedIn: true)
        #expect(model.scope == .favorites)
        #expect(model.resultsID == 1)

        model.loginDidChange(isLoggedIn: false)
        #expect(model.scope == .gallery)
        #expect(model.resultsID == 2)
        await model.results?.loadFirst()
        let url = try #require(h.urls().last)
        #expect(url.path() == "/")
        #expect(Self.query(of: url)["f_search"] == "fake")

        // In the gallery scope: nothing runs again.
        let requests = h.stub.requests().count
        model.loginDidChange(isLoggedIn: false)
        #expect(model.scope == .gallery)
        #expect(model.resultsID == 2)
        #expect(h.stub.requests().count == requests)
    }

    /// Logged out in the Favorites scope before any search, the scope goes back to Gallery and nothing is
    /// searched.
    @Test func signingOutBeforeASearchOnlyLeavesTheScope() async throws {
        let h = await Self.makeHarness(answer: SearchFeedsTests.favoritesPage)
        defer { h.cleanUp() }
        let model = Self.makeModel(h, request: SearchRequest(scope: .favorites, site: .eh))
        await model.start()

        model.loginDidChange(isLoggedIn: false)
        #expect(model.scope == .gallery)
        #expect(model.results == nil)
        #expect(model.resultsID == 0)
        #expect(h.stub.requests().isEmpty)
    }

    // MARK: - Replacing the results

    /// New results take the place of the ones shown: the old list is cancelled, so the page it was waiting for is not
    /// shown (the list is idle again, not loaded).
    @Test func replacedResultsAreCancelled() async throws {
        let gate = DispatchSemaphore(value: 0)
        let answer = SearchFeedsTests.emptyResult
        let stub = StubURLProtocol.install { _ in
            gate.wait()
            return StubResponse(body: answer)
        }
        defer { stub.remove() }
        // A failure on the way must not leave the stubs' shared loading thread waiting for good: the answer held
        // here would hold every later stub's.
        defer { gate.signal() }
        let environment = AppEnvironment(
            uiTesting: true, sessionConfigurator: stub.configurator, userAgentProbe: { "FakeWebKit/1" }
        )
        await environment.start()
        let model = Self.makeModel(Harness(environment: environment, stub: stub, asked: AskedTexts()))
        await model.start()
        model.text = "fake"
        _ = await model.submit()
        let old = try #require(model.results)

        let loading = Task { await old.loadFirst() }
        #expect(await eventually { !stub.requests().isEmpty })
        #expect(stub.requests().count == 1)
        model.text = "fake more"
        _ = await model.submit()
        gate.signal()
        await loading.value
        #expect(model.results !== old)
        #expect(old.status == .idle)
    }

    /// New results take the place of a favorites search: its feed is retired, so the old list asks the site nothing
    /// more.
    @Test func replacedFavoritesFeedIsRetired() async throws {
        let h = await Self.makeHarness(answer: SearchFeedsTests.favoritesPage)
        defer { h.cleanUp() }
        let model = Self.makeModel(h, request: SearchRequest(scope: .favorites, site: .eh))
        await model.start()
        model.text = "fake"
        _ = await model.submit()
        let old = try #require(model.results)
        model.text = "fake more"
        _ = await model.submit()

        await old.loadFirst()
        #expect(h.stub.requests().isEmpty)
        #expect(old.items.isEmpty)
        await model.results?.loadFirst()
        #expect(h.urls().count == 1)
        #expect(Self.query(of: h.urls().first)["f_search"] == "fake more")
    }

    // MARK: - Preferences

    @Test func preferencesSurviveAndRecoverFromCorruptData() throws {
        let name = "proj.eros.swifte.tests.search.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let store = SearchPreferencesStore(defaults: defaults)
        var changed = store.preferences
        changed.translatesHistory = false
        changed.usesAdvancedSearch = true
        changed.advancedSearch.minimumRating = 4
        changed.advancedSearch.pageRange = PageRange(from: 20, to: nil)
        store.preferences = changed
        #expect(SearchPreferencesStore(defaults: defaults).preferences == changed)

        defaults.set(Data("not json".utf8), forKey: SearchPreferencesStore.key)
        #expect(SearchPreferencesStore(defaults: defaults).preferences == SearchPreferences())
        defaults.set(Data("{\"translatesHistory\": false, \"usesAdvancedSearch\": \"yes\"}".utf8),
                     forKey: SearchPreferencesStore.key)
        // A field that does not decode keeps its default; the others are read.
        var partly = SearchPreferences()
        partly.translatesHistory = false
        #expect(SearchPreferencesStore(defaults: defaults).preferences == partly)
    }

    /// The search preferences live in the defaults of the environment's settings, so two
    /// environments made without `settingsDefaults` never see each other's, and none changes the host app's (whatever
    /// the app itself stored there before).
    @Test func searchPreferencesStayInTheirEnvironment() throws {
        let hostApp = UserDefaults.standard.data(forKey: SearchPreferencesStore.key)
        let first = AppEnvironment(uiTesting: true)
        let second = AppEnvironment(uiTesting: true)
        first.searchPreferences.preferences.usesAdvancedSearch = true
        first.searchPreferences.preferences.translatesHistory = false

        #expect(second.searchPreferences.preferences == SearchPreferences())
        #expect(SearchPreferencesStore(defaults: second.settings.defaults).preferences == SearchPreferences())
        #expect(SearchPreferencesStore(defaults: first.settings.defaults).preferences.usesAdvancedSearch)
        #expect(first.settings.defaults !== second.settings.defaults)
        #expect(UserDefaults.standard.data(forKey: SearchPreferencesStore.key) == hostApp)
    }
}
