import SwiftUI

/// A tab's only `NavigationStack`, bound to its path in `AppEnvironment.router` (M2 index §3.4); every `AppRoute`
/// pushed onto it is shown by `RouteDestinationView`, every `SearchRequest` (the search pages the list tabs' Search
/// items open, search Q2) by `SearchView`, every `ImageSearchRoute` (the image search page and its results, search Q5)
/// by `ImageSearchDestinationView`. Each is registered here once for the stack. Used
/// only by `TabRootView`: pages never make stacks of their own.
struct RoutedStack<Root: View>: View {
    @Environment(AppEnvironment.self) private var environment
    private let tab: AppTab
    private let root: Root

    init(tab: AppTab, @ViewBuilder root: () -> Root) {
        self.tab = tab
        self.root = root()
    }

    var body: some View {
        NavigationStack(path: environment.router.path(for: tab)) {
            root
                .navigationDestination(for: AppRoute.self) { route in
                    RouteDestinationView(route: route)
                }
                .navigationDestination(for: SearchRequest.self) { request in
                    SearchView(request: request)
                }
                .navigationDestination(for: ImageSearchRoute.self) { route in
                    ImageSearchDestinationView(route: route)
                }
        }
    }
}

/// The page of an image search route (search Q5): the image search page (`ImageSearchView`) or a search's results
/// (`ImageSearchResultsView`). Each page makes its model once, in a view of its own.
struct ImageSearchDestinationView: View {
    let route: ImageSearchRoute

    init(route: ImageSearchRoute) {
        self.route = route
    }

    var body: some View {
        switch route {
        case .search(let site):
            ImageSearchView(site: site)
        case .results(let results):
            ImageSearchResultsView(results: results)
        }
    }
}

/// The page of a route: the list is a `RouteListView` (browse B4), the search the search page with the text searched
/// (`SearchView`, search Q2). Until their pages exist, the others show a `RoutePlaceholderView`: the gallery (M3 detail
/// page) and the image page (M4 reader).
struct RouteDestinationView: View {
    let route: AppRoute

    init(route: AppRoute) {
        self.route = route
    }

    var body: some View {
        switch route {
        case .gallery(let id, _):
            RoutePlaceholderView(
                title: "Gallery", systemImage: "doc.richtext", description: "Gallery \(id.gid)",
                identifier: "route.placeholder.gallery"
            )
        case .imagePage(_, let gid, let page, _):
            RoutePlaceholderView(
                title: "Image", systemImage: "photo", description: "Gallery \(gid), page \(page)",
                identifier: "route.placeholder.imagePage"
            )
        case .list(let query, let title, let site):
            RouteListView(query: query, title: title, site: site)
        case .search(let text, let site):
            SearchView(request: SearchRequest(text: text, site: site))
        }
    }
}
