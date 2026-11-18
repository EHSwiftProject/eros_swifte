import EHModels
import EHNetwork
import SwiftUI

/// The results of an image search (search Q5), identified `imageSearch.results`, titled `Image Search Results`
/// (inline), pushed by value after a search (`ImageSearchRoute.results`): the galleries in
/// the list style of the settings (`GalleryListView` over an `ImageLookupFeed`, which pages by cursor and offers no
/// jumps), opening on the site searched. When the site says its Similarity Scan was off for the search, a note above
/// the list (`imageSearch.similarityNote`) says that only the exact file was looked for.
struct ImageSearchResultsView: View {
    @Environment(AppEnvironment.self) private var environment
    private let results: ImageSearchResults

    init(results: ImageSearchResults) {
        self.results = results
    }

    var body: some View {
        ImageSearchResultsList(environment: environment, results: results)
            .navigationTitle("Image Search Results")
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.browsingSite, results.site)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("imageSearch.results")
    }
}

/// The list of an `ImageSearchResultsView`. Its model is made once, with the page:
/// the stack's destination runs again with every update, so a model made there would load the results again. It takes
/// the environment from its parent for `State(initialValue:)`.
private struct ImageSearchResultsList: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: GalleryListModel
    private let showsSimilarityNote: Bool

    init(environment: AppEnvironment, results: ImageSearchResults) {
        _model = State(initialValue: GalleryListModel(
            feed: ImageLookupFeed(result: results.result, service: environment.service, site: results.site)
        ))
        showsSimilarityNote = results.result.page.similarityScanDisabled
    }

    var body: some View {
        GalleryListView(model: model, style: environment.settings.settings.listStyle)
            .safeAreaBar(edge: .top) {
                if showsSimilarityNote {
                    Label(
                        "Similarity scan was disabled for this search. Only galleries with this exact file are shown.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("imageSearch.similarityNote")
                }
            }
    }
}
