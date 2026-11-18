import EHModels

/// What a search looks through (Flutter's search types): the site's galleries (the front page), the watched list, or
/// the favorites.
nonisolated enum SearchScope: String, Hashable, CaseIterable, Sendable {
    case gallery, watched, favorites

    /// The scope's name in the search field's scope bar.
    var title: String {
        switch self {
        case .gallery: "Gallery"
        case .watched: "Watched"
        case .favorites: "Favorites"
        }
    }
}

/// The search page to open: its first text (searched at once when not empty), its scope, the favorites folder of the
/// favorites scope (nil: all of them) and the site. A route value of the search plan: `RoutedStack` shows it with
/// `SearchView`; `AppRoute` does not change.
nonisolated struct SearchRequest: Hashable, Sendable {
    var text = ""
    var scope: SearchScope = .gallery
    var favoritesFolder: Int?
    var site: EHSite
}
