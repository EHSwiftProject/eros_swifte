import EHModels
import EHNetwork
import SwiftUI

/// The page of `AppRoute.list` (`RouteDestinationView`): the galleries of `query` on `site` (a `QueryFeed`) in the
/// list style of the settings, titled `title`, identified `route.list`. Its items open galleries on `site`.
struct RouteListView: View {
    @Environment(AppEnvironment.self) private var environment
    private let query: ListQuery
    private let title: String
    private let site: EHSite

    init(query: ListQuery, title: String, site: EHSite) {
        self.query = query
        self.title = title
        self.site = site
    }

    var body: some View {
        RouteListContent(query: query, site: site, service: environment.service)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.browsingSite, site)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("route.list")
    }
}

/// The list of a `RouteListView`. The model is made once, with the page (`State(initialValue:)` needs the service,
/// which only the environment has, so this view takes it from its parent).
private struct RouteListContent: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: GalleryListModel

    init(query: ListQuery, site: EHSite, service: EHService) {
        _model = State(initialValue: GalleryListModel(feed: QueryFeed(query: query, site: site, service: service)))
    }

    var body: some View {
        GalleryListView(model: model, style: environment.settings.settings.listStyle)
    }
}
