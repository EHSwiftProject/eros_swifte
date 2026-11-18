import EHModels
import EHNetwork
import Foundation

/// Where a gallery list's pages come from (`GalleryListModel`): the page at `position`; `refresh` asks the site, never
/// the response cache. `QueryFeed` reads a `ListQuery`; the favorites (browse B8) and search results (search) bring
/// feeds of their own.
@MainActor protocol ListFeed {
    func page(at position: ListPosition, refresh: Bool) async throws -> ListPageResult
}

/// The pages of `query` on `site`, through `EHService.galleryListResult(_:site:refresh:)`: `position` replaces the
/// query's own. The lists of the gallery and toplist tabs use it, and so do the entry links (E1) and search (Q2).
struct QueryFeed: ListFeed {
    let query: ListQuery
    let site: EHSite
    let service: EHService

    init(query: ListQuery, site: EHSite, service: EHService) {
        self.query = query
        self.site = site
        self.service = service
    }

    func page(at position: ListPosition, refresh: Bool) async throws -> ListPageResult {
        var query = query
        query.position = position
        return try await service.galleryListResult(query, site: site, refresh: refresh)
    }
}
