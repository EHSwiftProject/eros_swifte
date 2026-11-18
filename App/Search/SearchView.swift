import EHModels
import SwiftUI

/// The search page (search Q2; Flutter `search_page.dart`), identified `search.root`, titled `Search` (inline): the
/// search field (`.searchable`, its prompt `Search or paste a gallery link`), its scopes while logged in (Gallery,
/// Watched, Favorites) and its suggestions (`SearchSuggestionsContent`). Before a search the page says what to type;
/// after one it shows the results (`GalleryListView` in the list style of the settings, with the list's jumps), on the
/// request's site, their tags buttons that append the tag to the text (`listTagAction`).
///
/// - Return in the field searches; a link to a gallery or an image page opens it instead, pushed onto the tab's stack
///   (the search page is on it).
/// - The toolbar's Quick Search (`search.quickSearch`, secondary; search Q4) pushes the quick search page
///   (`QuickSearchListView`) onto the stack, in every scope. Tapping a quick search there comes back and searches it
///   like a submit, a gallery link opened instead (`SearchModel.search(_:opening:)`). Back on
///   the page, `SearchModel.start()` reads the quick searches again, so Add to Quick Search follows what changed there.
/// - A request whose text is a link to a gallery or an image page opens that page above the search page
///   (`SearchModel.start(opening:)`), as a submit of the link does.
/// - The toolbar's Image Search (`search.imageSearch`, secondary, after Quick Search; search Q5) pushes the image
///   search page (`ImageSearchView`) by value onto the tab's stack (`ImageSearchRoute`), on the request's site, in
///   every scope.
/// - The toolbar's Add to Quick Search (`search.addQuickSearch`, secondary, low priority, so it may go to the overflow
///   menu) reads In Quick Search once the text is one; it is disabled for a blank text, a site link, a text already
///   there, and without a store.
/// - The toolbar's Filter (`search.filter`, primary; search Q3) opens the search filters (`SearchFilterView`) in a
///   sheet, and is disabled in the Favorites scope, which they do not apply to. Closing the sheet, by Done or a swipe,
///   puts the page range right and runs the search again with the new filters (`SearchModel.filtersDidClose()`).
/// - Logging out leaves the Favorites scope (`SearchModel.loginDidChange(isLoggedIn:)`).
struct SearchView: View {
    @Environment(AppEnvironment.self) private var environment
    private let request: SearchRequest

    init(request: SearchRequest) {
        self.request = request
    }

    var body: some View {
        SearchPage(environment: environment, request: request)
    }
}

/// The page over its model. The model is made once, with the page (`State(initialValue:)` needs the environment's
/// stores and services, so this view takes the environment from its parent).
private struct SearchPage: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: SearchModel
    /// Whether the search filters are up.
    @State private var isShowingFilters = false
    /// Whether the quick search page is pushed.
    @State private var isShowingQuickSearches = false

    init(environment: AppEnvironment, request: SearchRequest) {
        _model = State(initialValue: SearchModel(
            request: request, service: environment.service, userData: environment.userData,
            settings: environment.settings, preferences: environment.searchPreferences,
            terms: environment.searchTerms, tagQuery: TagSuggestionQuery(service: environment.tagSuggestions)
        ))
    }

    var body: some View {
        @Bindable var model = model
        content
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("search.root")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            // Below the title at every width: in the bar's trailing end, where a regular
            // width puts it by default, the field shrinks to a button when not focused and hides the overflow menu
            // when it is, and the suggestions become a menu that drops their identifiers and custom rows.
            .searchable(
                text: $model.text, isPresented: $model.isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("Search or paste a gallery link")
            )
            // As in the keyword sheet (browse B6): the site's syntax needs straight quotes and tags as typed.
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            // The search stays presented after a search; without this the system hides the
            // primary toolbar items meanwhile, the results' jumps (browse B5) among them, the field in the drawer too.
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .searchSuggestions {
                SearchSuggestionsContent(model: model)
            }
            .scopes($model.scope, isShown: environment.isLoggedIn)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    filterButton
                }
                // The page's way to the quick searches: before Add to Quick Search, and not low priority.
                ToolbarItem(placement: .secondaryAction) {
                    quickSearchesButton
                }
                // After Quick Search, not low priority, in every scope.
                ToolbarItem(placement: .secondaryAction) {
                    imageSearchButton
                }
                ToolbarItem(placement: .secondaryAction) {
                    quickSearchButton
                }
                .visibilityPriority(.low)
            }
            .sheet(isPresented: $isShowingFilters, onDismiss: { [model = self.model] in model.filtersDidClose() }) {
                SearchFilterView(preferences: environment.searchPreferences, settings: environment.settings)
            }
            .navigationDestination(isPresented: $isShowingQuickSearches) {
                QuickSearchPage(environment: environment) { text in
                    runQuickSearch(text)
                }
            }
            .onChange(of: environment.isLoggedIn) { _, isLoggedIn in
                model.loginDidChange(isLoggedIn: isLoggedIn)
            }
            .onSubmit(of: .search) {
                submit()
            }
            .onChange(of: model.text) {
                model.textDidChange()
            }
            .task {
                await model.start(opening: environment.router)
            }
    }

    @ViewBuilder private var content: some View {
        if let results = model.results {
            GalleryListView(model: results, style: environment.settings.settings.listStyle)
                .id(model.resultsID)
                .listJumpControls(results)
                .environment(\.listTagAction, ListTagAction(model) { $0.appendTag($1) })
                .environment(\.browsingSite, model.request.site)
        } else {
            ContentUnavailableView(
                "Search Galleries", systemImage: "magnifyingglass",
                description: Text("Type keywords or tags, or paste a gallery link.")
            )
            .keepsClearOfFold()
        }
    }

    /// Filter: the search filters, for any scope but Favorites.
    private var filterButton: some View {
        Button("Filter", systemImage: "line.3.horizontal.decrease.circle") {
            isShowingFilters = true
        }
        .disabled(model.scope == .favorites)
        .accessibilityIdentifier("search.filter")
    }

    /// Quick Search: the quick search page, in every scope.
    private var quickSearchesButton: some View {
        Button("Quick Search", systemImage: "list.bullet") {
            isShowingQuickSearches = true
        }
        .accessibilityIdentifier("search.quickSearch")
    }

    /// Image Search: the image search page on the request's site, pushed by value onto the
    /// tab selected at the tap.
    private var imageSearchButton: some View {
        Button("Image Search", systemImage: "photo") {
            let router = environment.router
            router.push(ImageSearchRoute.search(model.request.site), onto: router.selectedTab)
        }
        .accessibilityIdentifier("search.imageSearch")
    }

    private var quickSearchButton: some View {
        let isIn = model.isInQuickSearch
        return Button(
            isIn ? "In Quick Search" : "Add to Quick Search", systemImage: isIn ? "checkmark" : "text.badge.plus"
        ) {
            let model = model
            Task { _ = await model.addToQuickSearch() }
        }
        .disabled(!model.canAddToQuickSearch)
        .accessibilityIdentifier("search.addQuickSearch")
    }

    /// The field's text, submitted from the keyboard.
    private func submit() {
        let model = model
        let router = environment.router
        Task {
            await model.submit(opening: router)
        }
    }

    /// A quick search tapped on the quick search page: back to this page, then `text` searched.
    private func runQuickSearch(_ text: String) {
        isShowingQuickSearches = false
        let model = model
        let router = environment.router
        Task {
            await model.search(text, opening: router)
        }
    }
}

/// The quick search page over its model, made once with the page: the destination's closure
/// runs again with every update of the search page, so a model made there would be made again, the page's state lost.
/// As `SearchPage`, it takes the environment from its parent for `State(initialValue:)`.
private struct QuickSearchPage: View {
    @State private var model: QuickSearchListModel
    private let onSelect: (String) -> Void

    init(environment: AppEnvironment, onSelect: @escaping (String) -> Void) {
        _model = State(initialValue: QuickSearchListModel(
            userData: environment.userData, terms: environment.searchTerms, settings: environment.settings
        ))
        self.onSelect = onSelect
    }

    var body: some View {
        QuickSearchListView(model: model, onSelect: onSelect)
    }
}

private extension View {
    /// The search field's scopes (`searchScopes`) when `isShown`, shown as soon as the field is (on iOS the automatic
    /// activation waits for text); otherwise none.
    @ViewBuilder func scopes(_ scope: Binding<SearchScope>, isShown: Bool) -> some View {
        if isShown {
            searchScopes(scope, activation: .onSearchPresentation) {
                ForEach(SearchScope.allCases, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
        } else {
            self
        }
    }
}
