import EHModels
import EHNetwork

/// A page a tab's stack can show above its root (M2 index §3.4). Pages push one with `NavigationLink(value:)`, or
/// `AppRouter.push(_:)`; `RoutedStack` shows it with `RouteDestinationView`. Compared by value, so a path holds plain
/// data. Entry E1 adds `init(_ link: EHLink)`.
nonisolated enum AppRoute: Hashable, Sendable {
    /// A gallery's detail page (M3).
    case gallery(GalleryID, EHSite)
    /// One page of a gallery in the reader (M4).
    case imagePage(imageKey: String, gid: Int, page: Int, site: EHSite)
    /// A gallery list (browse B4), titled `title`.
    case list(ListQuery, title: String, site: EHSite)
    /// The results of searching `text` (search Q2).
    case search(String, EHSite)
}
