import EHModels

/// A gallery list page and whether the answer it was read from came from the response cache (N4), so that a list
/// shown from the cache can be refreshed silently (`EHService.galleryListResult(_:site:refresh:)`). A page resent for
/// the Compact view always comes from the site.
public struct ListPageResult: Sendable, Equatable {
    public let page: GalleryListPage
    /// The answer the page was parsed from was the cache's (`EHResponse.Source.cache`).
    public let isFromCache: Bool

    public init(page: GalleryListPage, isFromCache: Bool) {
        self.page = page
        self.isFromCache = isFromCache
    }
}
