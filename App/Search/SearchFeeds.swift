import EHModels
import EHNetwork

/// The feed of a search's results, by scope (Flutter `search_page_controller.dart`, `getGallery` of each search type).
@MainActor enum SearchFeeds {
    /// The list query of a search for `text` in the gallery or watched scope: the front page or the watched list on
    /// `request.site`, with `f_search`, the categories hidden (no `f_cats` when none is: Flutter sends `f_cats=0`,
    /// which hides nothing either) and `advanced` as given. nil for the favorites scope, which is no list query.
    static func listQuery(
        text: String, request: SearchRequest, categories: CategoryMask, advanced: AdvancedSearch?
    ) -> ListQuery? {
        let source: ListSource
        switch request.scope {
        case .gallery: source = .front
        case .watched: source = .watched
        case .favorites: return nil
        }
        return ListQuery(
            source: source, search: text, excludedCategories: categories.isEmpty ? nil : categories.rawValue,
            advanced: advanced
        )
    }

    /// The feed of a search for `text`: a `QueryFeed` over `listQuery` on `request.site`; for the favorites scope a
    /// `FavoritesFeed` (browse B8) of `request.favoritesFolder` with `f_search`, in `favoritesOrder` (then in the order
    /// the site kept, when the user declines to change it), without categories or advanced options, which Flutter's
    /// favorites search does not offer either.
    static func make(
        text: String, request: SearchRequest, categories: CategoryMask, advanced: AdvancedSearch?,
        favoritesOrder: FavoritesOrder, service: EHService
    ) -> any ListFeed {
        if let query = listQuery(text: text, request: request, categories: categories, advanced: advanced) {
            return QueryFeed(query: query, site: request.site, service: service)
        }
        return FavoritesFeed(
            folder: request.favoritesFolder, order: favoritesOrder, site: request.site, service: service, search: text,
            onPage: { _ in }
        )
    }
}
