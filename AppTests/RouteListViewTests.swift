import EHModels
import EHNetwork
import Foundation
import SwiftUI
import Testing

@testable import Eros

/// `RouteDestinationView`'s list: a `RouteListView` that loads its query (`StubURLProtocol` answers, nothing reaches
/// the network).
@MainActor @Suite struct RouteListViewTests {
    /// The site's empty result, as little of it as the parser needs.
    private static let noHits = Data(#"<html><body><div class="ido"><p>No hits found</p></div></body></html>"#.utf8)

    @Test func routeListLoadsItsQuery() async throws {
        let noHits = Self.noHits
        let stub = StubURLProtocol.install { _ in StubResponse(body: noHits) }
        defer { stub.remove() }
        let environment = AppEnvironment(
            uiTesting: true, sessionConfigurator: stub.configurator, userAgentProbe: { "FakeWebKit/1" }
        )
        await environment.start()
        let route = AppRoute.list(ListQuery(source: .tag(TagRef(raw: "other:fake"))), title: "Fake List", site: .eh)

        let host = try HostedViews.show(NavigationStack { RouteDestinationView(route: route) }, environment: environment)
        defer { HostedViews.hide(host) }
        #expect(await eventually {
            stub.requests().contains { $0.url?.absoluteString == "https://e-hentai.org/tag/other:fake" }
        })
        #expect(await eventually {
            let identifiers = HostedViews.identifiers(in: host.view)
            return identifiers.contains("route.list") && identifiers.contains("gallery.empty")
        })
        #expect(!HostedViews.identifiers(in: host.view).contains("route.placeholder.list"))
    }
}
