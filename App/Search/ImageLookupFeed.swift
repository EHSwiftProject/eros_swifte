import EHModels
import EHNetwork
import Foundation

/// The pages of an image search's results (search Q5) for a `GalleryListModel`, by cursor only
/// (`ImageLookupResult.url(for:)`, `EHService.galleryList(at:site:refresh:)`):
///
/// - `.first` without `refresh` is the page the search already read: nothing is asked, and it is not from the cache,
///   so the list does not refresh it in the background.
/// - `.first` with `refresh` (pull to refresh, a reload) asks for the result address again; Flutter uploads the image
///   again, which this does not.
/// - `.next` and `.previous` ask the site, never the cache.
/// - Any other position throws `ImageLookupFeed.UnsupportedPosition` without a request: the results page offers no
///   jumps (it has no `listJumpControls`).
@MainActor final class ImageLookupFeed: ListFeed {
    /// A position the results cannot be asked at (a page number, a jump or a seek).
    struct UnsupportedPosition: Error {}

    private let result: ImageLookupResult
    private let service: EHService
    private let site: EHSite

    init(result: ImageLookupResult, service: EHService, site: EHSite) {
        self.result = result
        self.service = service
        self.site = site
    }

    func page(at position: ListPosition, refresh: Bool) async throws -> ListPageResult {
        if case .first = position, !refresh {
            return ListPageResult(page: result.page, isFromCache: false)
        }
        guard let url = result.url(for: position) else { throw UnsupportedPosition() }
        return try await service.galleryList(at: url, site: site, refresh: true)
    }
}
