import EHModels
import EHNetwork
import Foundation

/// The image search's pages (search Q5), pushed by value onto the stack of the tab selected when the user tapped
/// (`AppRouter.push(_:onto:)`) and shown by `RoutedStack`, which registers the type once for
/// the stack: the image search page on a site, from the search page's Image Search,
/// and a search's results, from a successful search.
///
/// Both go by value, as the galleries the results open do. Search Q4 observed on iOS 27.2 that a value pushed onto the
/// tab's path takes down a page pushed with `navigationDestination(isPresented:)`. A probe in search Q5 (not checked
/// in) pushed the results that way instead, and on iOS 27.2 a gallery tapped on them then did not open at all:
/// `ImageSearchTests.testOpeningAResultKeepsTheResults` failed at that tap, twice.
nonisolated enum ImageSearchRoute: Hashable, Sendable {
    /// The image search page, searching `EHSite`.
    case search(EHSite)
    /// The results of one search.
    case results(ImageSearchResults)
}

/// The results of one image search, as a route value: equal, and hashed, by `id` alone, so every search is a push of
/// its own (the result itself need not be `Hashable`).
nonisolated struct ImageSearchResults: Hashable, Sendable {
    let id: UUID
    let result: ImageLookupResult
    /// The site searched: the results' galleries open there.
    let site: EHSite

    init(id: UUID = UUID(), result: ImageLookupResult, site: EHSite) {
        self.id = id
        self.result = result
        self.site = site
    }

    static func == (lhs: ImageSearchResults, rhs: ImageSearchResults) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
