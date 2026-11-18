import EHModels
import EHNetwork
import EHStore
import Foundation
import Observation
import os

/// What submitting the search field did.
nonisolated enum SubmitOutcome: Equatable, Sendable {
    /// Nothing: the text was blank.
    case ignored
    /// The text was searched (a pasted tag, uploader or search link as its term or text).
    case searched
    /// The text is a link to a gallery or an image page, which the page opens instead.
    case navigate(EHLink)
}

/// The search page (Flutter `search_page_controller.dart`): the text, its tag suggestions, the history and the quick
/// searches, and the results of the last search, in the scope and with the filters chosen.
///
/// - `start()` loads the history (the newest `historyLimit`) and the quick searches; the first time, it searches the
///   request's text, or brings up the field when there is none.
/// - `submit()` searches the normalized text (`SearchText.normalized(_:)`). A pasted site link is read
///   (`SearchText.link(in:)`): a gallery or an image page is opened (`.navigate`, nothing recorded); a tag or an
///   uploader is searched as its term (`SearchText.tagTerm(for:)`, Flutter); a search link as its text.
/// - A search records the text in the history, drops the suggestions and puts new results in place
///   (`resultsID` goes up by one). While the field holds the text searched, the suggestions area shows nothing
///   (`isShowingSubmittedText`), so it does not cover the results.
/// - A history entry or a tag of the results is appended to the text (`SearchText.appending(_:to:)`), with no search.
/// - Another scope, or other filters (`filtersDidChange()`: the categories of the settings, the advanced search of
///   the preferences), searches the text searched again; the same ones change nothing. Closing the filters puts the
///   page range right first (`filtersDidClose()`, search Q3); logging out leaves the Favorites scope
///   (`loginDidChange(isLoggedIn:)`).
/// - Suggestions come from `tagQuery` (search Q1), for any text but the one searched and a site link (a link is not
///   sent to the site's API).
@MainActor @Observable final class SearchModel {
    /// One history entry: its text, and its translation when the history is shown translated and it has one.
    nonisolated struct HistoryEntry: Hashable, Sendable {
        let text: String
        let translation: String?
    }

    /// The history shows this many entries, the newest.
    static let historyLimit = 30

    /// Failures of the store: logged by the error's domain and code only (`Logger.storeFailure(_:_:)`; an error of the
    /// store may describe the records it touched, texts included), and otherwise taken as nothing recorded or nothing
    /// stored.
    private static let log = Logger(subsystem: "proj.eros.swifte", category: "Search")

    /// The page the model was made for: its site and first text, scope and favorites folder.
    let request: SearchRequest
    /// The search field's text.
    var text: String
    /// The scope searched; another one searches the text searched again (`filtersDidChange()`).
    var scope: SearchScope {
        didSet {
            if scope != oldValue { filtersDidChange() }
        }
    }
    /// Whether the search field is active.
    var isSearchPresented = false
    /// The newest `historyLimit` history entries; empty without a store.
    private(set) var history: [HistoryEntry] = []
    /// The quick searches, in order; empty without a store.
    private(set) var quickSearches: [String] = []
    /// The results of the last search; nil before one.
    private(set) var results: GalleryListModel?
    /// One more with every new `results`: the view gives the list this identity, so a new search starts at its top.
    private(set) var resultsID = 0
    /// The text last searched; nil before a search.
    private(set) var submittedText: String?

    /// The tag suggestions of the field (search Q1). For the page and tests: the view reads them through
    /// `suggestions`.
    @ObservationIgnored let tagQuery: TagSuggestionQuery
    @ObservationIgnored private let service: EHService
    @ObservationIgnored private let userData: UserDataStore?
    @ObservationIgnored private let settings: AppSettingsStore
    @ObservationIgnored private let preferences: SearchPreferencesStore
    @ObservationIgnored private let terms: SearchTermTranslator
    /// Reads the history in place of the store (tests hold reads to order them); nil: the store's.
    @ObservationIgnored private let readHistory: (@MainActor () async throws -> [String])?
    /// What the last search was: its text, scope and filters.
    @ObservationIgnored private var searched: Snapshot?
    /// The feed of `results`; a favorites feed is retired when the results are replaced.
    @ObservationIgnored private var resultsFeed: (any ListFeed)?
    @ObservationIgnored private var hasStarted = false
    /// One more with every history load: an older load that ends later changes nothing.
    @ObservationIgnored private var historyLoad = 0

    /// A search, and the scope and filters it ran with.
    private nonisolated struct Snapshot {
        let text: String
        let filters: Filters
    }

    private nonisolated struct Filters: Equatable {
        let scope: SearchScope
        let categories: CategoryMask
        let advanced: AdvancedSearch?
    }

    /// `tagQuery`: the field's suggestions (`TagSuggestionQuery(service: environment.tagSuggestions)` on the page;
    /// tests inject a `suggest`). `readHistory`: for tests, the history's reads in place of `userData`'s (which must
    /// be there for any history).
    init(
        request: SearchRequest, service: EHService, userData: UserDataStore?, settings: AppSettingsStore,
        preferences: SearchPreferencesStore, terms: SearchTermTranslator, tagQuery: TagSuggestionQuery,
        readHistory: (@MainActor () async throws -> [String])? = nil
    ) {
        self.request = request
        self.service = service
        self.userData = userData
        self.settings = settings
        self.preferences = preferences
        self.terms = terms
        self.tagQuery = tagQuery
        self.readHistory = readHistory
        text = request.text
        scope = request.scope
    }

    // MARK: - State

    /// The tag suggestions for the text being typed (`tagQuery`).
    var suggestions: [TagSuggestion] {
        tagQuery.suggestions
    }

    /// The site page the text links to (`SearchText.link(in:)` of the normalized text), if any.
    var linkTarget: EHLink? {
        SearchText.link(in: SearchText.normalized(text))
    }

    /// Whether the normalized text is one of the quick searches.
    var isInQuickSearch: Bool {
        let text = SearchText.normalized(text)
        return !text.isEmpty && quickSearches.contains(text)
    }

    /// Whether there is a store for the history and the quick searches.
    var canSaveData: Bool {
        userData != nil
    }

    /// Whether Add to Quick Search can add the text: not a blank text, a site link, a text already there, or without
    /// a store.
    var canAddToQuickSearch: Bool {
        !SearchText.normalized(text).isEmpty && linkTarget == nil && !isInQuickSearch && canSaveData
    }

    /// Whether the field holds the text last searched: then the suggestions area shows nothing.
    var isShowingSubmittedText: Bool {
        submittedText == text
    }

    // MARK: - Starting and submitting

    /// Loads the history and the quick searches (again each time the page appears). The first time, then searches
    /// the request's text, or, without one, brings up the search field. Returns what the first time's submit of the
    /// request's text came to (`start(opening:)` opens a gallery or an image page it links to); nil otherwise.
    @discardableResult
    func start() async -> SubmitOutcome? {
        let isFirst = !hasStarted
        hasStarted = true
        let initial = SearchText.normalized(request.text)
        if isFirst, initial.isEmpty { isSearchPresented = true }
        await reloadSaved()
        guard isFirst, !initial.isEmpty else { return nil }
        return await submit()
    }

    /// Asks for the suggestions of the text (`tagQuery`), or drops them while the field holds the text searched or a
    /// site link.
    func textDidChange() {
        if isShowingSubmittedText || linkTarget != nil {
            tagQuery.clear()
            return
        }
        tagQuery.textDidChange(text, site: request.site)
    }

    /// Searches the normalized text, or tells the page to open the gallery or image page it links to (see the type).
    func submit() async -> SubmitOutcome {
        var searchText = SearchText.normalized(text)
        guard !searchText.isEmpty else { return .ignored }
        if let link = SearchText.link(in: searchText) {
            switch link {
            case .gallery, .imagePage:
                return .navigate(link)
            case .tag(let tag, _):
                searchText = SearchText.tagTerm(for: tag)
            case .uploader(let name, _):
                searchText = SearchText.tagTerm(for: TagRef(namespace: "uploader", name: name))
            case .search(let linked, _):
                searchText = SearchText.normalized(linked)
                guard !searchText.isEmpty else { return .ignored }
            }
        }
        text = searchText
        submittedText = searchText
        tagQuery.clear()
        showResults(for: searchText)
        if let userData {
            do {
                try await userData.recordSearch(searchText)
            } catch {
                Self.log.storeFailure("Recording the search", error)
            }
            await reloadHistory()
        }
        return .searched
    }

    /// `text` in the field, submitted (a quick search, search Q4).
    func search(_ text: String) async -> SubmitOutcome {
        self.text = text
        return await submit()
    }

    /// The scope or the filters may have changed: when a search ran with others, it runs again with these (its text,
    /// not the one being typed).
    func filtersDidChange() {
        guard let searched, currentFilters != searched.filters else { return }
        showResults(for: searched.text)
    }

    /// The filters sheet closed (search Q3, its `onDismiss`): the saved page range is put right
    /// (`SearchPreferences.normalized()`), then the search runs again when the filters changed (`filtersDidChange()`).
    /// Requests already send the range put right (`currentFilters`), so bounds that only swap run nothing again.
    func filtersDidClose() {
        let normalized = preferences.preferences.normalized()
        if normalized != preferences.preferences {
            preferences.preferences = normalized
        }
        filtersDidChange()
    }

    /// The login changed: logged out, the Favorites scope, offered only while logged in,
    /// goes back to Gallery, which runs a search made in it again (`scope`, through `filtersDidChange()`). Any other
    /// scope stays.
    func loginDidChange(isLoggedIn: Bool) {
        guard !isLoggedIn, scope == .favorites else { return }
        scope = .gallery
    }

    // MARK: - Editing the text

    /// `suggestion` in place of the word being typed (`TagSuggestionQuery.apply(_:to:)`).
    func apply(_ suggestion: TagSuggestion) {
        text = tagQuery.apply(suggestion, to: text)
    }

    /// The history entry `entry` appended to the text; the field comes up. Nothing is searched.
    func useHistory(_ entry: String) {
        text = SearchText.appending(entry, to: text)
        isSearchPresented = true
    }

    /// The term of `tag` (`SearchText.tagTerm(for:)`) appended to the text; the field comes up. Nothing is searched.
    func appendTag(_ tag: TagRef) {
        text = SearchText.appending(SearchText.tagTerm(for: tag), to: text)
        isSearchPresented = true
    }

    // MARK: - History and quick searches

    func removeHistory(_ entry: String) async {
        guard let userData else { return }
        do {
            try await userData.removeSearch(entry)
        } catch {
            Self.log.storeFailure("Removing a history entry", error)
        }
        await reloadHistory()
    }

    func clearHistory() async {
        guard let userData else { return }
        do {
            try await userData.clearSearchHistory()
        } catch {
            Self.log.storeFailure("Clearing the history", error)
        }
        await reloadHistory()
    }

    /// Shows the history translated or not (`SearchPreferences.translatesHistory`), the other way from now.
    func toggleHistoryTranslation() async {
        preferences.preferences.translatesHistory.toggle()
        await reloadHistory()
    }

    /// Adds the normalized text to the quick searches; false when it is blank, already there, or there is no store.
    func addToQuickSearch() async -> Bool {
        let text = SearchText.normalized(text)
        guard let userData, !text.isEmpty else { return false }
        var added = false
        do {
            added = try await userData.addQuickSearch(text)
        } catch {
            Self.log.storeFailure("Adding a quick search", error)
        }
        await reloadQuickSearches()
        return added
    }

    // MARK: - Private

    /// The scope, the categories of the settings and the advanced search of the preferences, as now. The advanced
    /// search is always the one put right (`SearchPreferences.normalized()`): the saved value
    /// is only put right when the filters close (`filtersDidClose()`), and until then a search from another window, or
    /// after a launch that found it as typed, still sends sound page bounds. The results' snapshot holds the same.
    private var currentFilters: Filters {
        Filters(
            scope: scope, categories: settings.settings.categoryFilter,
            advanced: preferences.preferences.normalized().effectiveAdvancedSearch
        )
    }

    /// New results for `text` with the current filters, in place of the ones shown (cancelled, a favorites feed
    /// retired).
    private func showResults(for text: String) {
        results?.cancel()
        (resultsFeed as? FavoritesFeed)?.retire()
        let filters = currentFilters
        var request = request
        request.scope = filters.scope
        let feed = SearchFeeds.make(
            text: text, request: request, categories: filters.categories, advanced: filters.advanced,
            favoritesOrder: settings.settings.favoritesOrder, service: service
        )
        resultsFeed = feed
        results = GalleryListModel(feed: feed)
        resultsID += 1
        searched = Snapshot(text: text, filters: filters)
    }

    private func reloadSaved() async {
        await reloadHistory()
        await reloadQuickSearches()
    }

    private func reloadHistory() async {
        historyLoad += 1
        let load = historyLoad
        guard let userData else {
            history = []
            return
        }
        let texts: ArraySlice<String>
        do {
            let all: [String]
            if let readHistory {
                all = try await readHistory()
            } else {
                all = try await userData.searchHistory()
            }
            texts = all.prefix(Self.historyLimit)
        } catch {
            Self.log.storeFailure("Reading the history", error)
            texts = []
        }
        let translates = settings.settings.showsTagTranslations && preferences.preferences.translatesHistory
        var entries: [HistoryEntry] = []
        for text in texts {
            let translation = translates ? await terms.translation(of: text) : nil
            entries.append(HistoryEntry(text: text, translation: translation))
        }
        guard load == historyLoad else { return }
        history = entries
    }

    private func reloadQuickSearches() async {
        guard let userData else {
            quickSearches = []
            return
        }
        do {
            quickSearches = try await userData.quickSearches()
        } catch {
            Self.log.storeFailure("Reading the quick searches", error)
            quickSearches = []
        }
    }
}

extension SearchModel {
    /// `start()`; when the request's text is a link to a gallery or an image page (an external search link whose
    /// `f_search` is a gallery's URL opened the page), that page is pushed onto the selected tab's stack, above the
    /// search page, as `submit(opening:)` does. Only the first time: coming back to the page opens nothing again.
    func start(opening router: AppRouter) async {
        if case .navigate(let link)? = await start() {
            router.push(AppRoute(link))
        }
    }

    /// `submit()`; a link to a gallery or an image page is pushed onto the selected tab's stack, where the search page
    /// is (browse B2's `AppRouter.push(_:)`).
    func submit(opening router: AppRouter) async {
        if case .navigate(let link) = await submit() {
            router.push(AppRoute(link))
        }
    }

    /// A quick search (search Q4): `search(_:)`, which records the text in the history like any search; a link to a
    /// gallery or an image page (an imported file may hold one) is pushed as `submit(opening:)` does.
    func search(_ text: String, opening router: AppRouter) async {
        if case .navigate(let link) = await search(text) {
            router.push(AppRoute(link))
        }
    }
}

extension Logger {
    /// `action` failed in the store: logged with the error's domain and code only, both public. The description is
    /// not logged at all: an error of the store may describe the records it touched, and their texts with them. The
    /// search page and the quick search page (search Q4) log with it.
    func storeFailure(_ action: String, _ error: any Error) {
        let error = error as NSError
        let domain = error.domain
        let code = error.code
        self.error("\(action, privacy: .public) failed: \(domain, privacy: .public) \(code, privacy: .public)")
    }
}
