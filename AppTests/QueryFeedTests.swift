import EHModels
import EHNetwork
import Foundation
import Testing

@testable import Eros

/// `QueryFeed` over the environment's `EHService`; `StubURLProtocol` answers, nothing reaches the network.
@MainActor @Suite struct QueryFeedTests {
    /// The site's empty result, as little of it as the parser needs.
    private static let noHits = Data(#"<html><body><div class="ido"><p>No hits found</p></div></body></html>"#.utf8)

    @Test func positionReplacesTheQueryPosition() async throws {
        let noHits = Self.noHits
        let stub = StubURLProtocol.install { _ in StubResponse(body: noHits) }
        defer { stub.remove() }
        let environment = AppEnvironment(
            uiTesting: true, sessionConfigurator: stub.configurator, userAgentProbe: { "FakeWebKit/1" }
        )
        await environment.start()
        let feed = QueryFeed(
            query: ListQuery(source: .front, position: .seek("2024-01-01")), site: .eh, service: environment.service
        )

        let result = try await feed.page(at: .next("5"), refresh: true)
        #expect(stub.requests().compactMap(\.url) == [URL(string: "https://e-hentai.org/?next=5")!])
        #expect(result.page.items.isEmpty)
        #expect(!result.isFromCache)
    }
}
