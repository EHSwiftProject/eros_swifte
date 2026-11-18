import EHFixtures
import EHModels
import EHNetwork
import EHNetworkTesting
import EHParsing
import Foundation
import Testing

/// `EHService.tagSuggestions`. Every request goes to `MockURLProtocol`; nothing reaches the network. The captured
/// tagsuggest answers are compared with what the parser reads from them, never with literal tags.
@Suite struct TagSuggestionRequestTests {
    private struct Harness {
        let service: EHService
        let throttle: RecordingThrottle
        let mock: MockSession

        func cleanUp() { mock.remove() }
    }

    /// A signed-out service on a new mock registration, with a `RecordingThrottle` and no response cache.
    private static func makeHarness(
        responder: @escaping @Sendable (URLRequest) throws -> MockResponse
    ) async throws -> Harness {
        let mock = MockURLProtocol.install(responder)
        let cookies = CookieStore(vault: InMemoryVault())
        try await cookies.load()
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        await userAgents.load()
        let throttle = RecordingThrottle()
        let client = EHClient(
            configuration: try EHClientConfiguration(sessionConfigurator: mock.configurator), cookies: cookies,
            userAgents: userAgents, throttle: throttle
        )
        let service = EHService(client: client, presenter: AlwaysAgree(), ledger: InMemoryNoticeLedger())
        return Harness(service: service, throttle: throttle, mock: mock)
    }

    /// The JSON body of `request` (read from `httpBody` by the mock).
    private static func body(of request: URLRequest) throws -> [String: String] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    @Test(arguments: [EHSite.eh, .ex])
    func postsTheTextAndKeepsTheOrder(site: EHSite) async throws {
        let answer = try Fixtures.data("\(site.rawValue)/api/tagsuggest.json")
        let h = try await Self.makeHarness { _ in MockResponse(body: answer) }
        defer { h.cleanUp() }

        let tags = try await h.service.tagSuggestions("fake", site: site)

        let requests = h.mock.requests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == EHEndpoints.api(site: site))
        #expect(try Self.body(of: request) == ["method": "tagsuggest", "text": "fake"])
        // Compared as Booleans, so that a failure prints no captured tag.
        let matchesTheParser = try tags == APIResponseParser.tagSuggestions(answer)
        #expect(matchesTheParser)
        #expect(tags.count == 10)
    }

    @Test func blankTextSendsNothing() async throws {
        let h = try await Self.makeHarness { _ in MockResponse(body: Data(#"{"tags":[]}"#.utf8)) }
        defer { h.cleanUp() }

        #expect(try await h.service.tagSuggestions("  \n", site: .eh).isEmpty)
        #expect(try await h.service.tagSuggestions("", site: .ex).isEmpty)
        #expect(h.mock.requests().isEmpty)
        #expect(await h.throttle.acquiredURLs.isEmpty)
    }

    /// Quotes and a line break inside the text go into the JSON body as they are (escaped by the encoder) and come
    /// back unchanged; only the ends are trimmed.
    @Test func quotesAndNewlinesAreJSONEncoded() async throws {
        let h = try await Self.makeHarness { _ in MockResponse(body: Data(#"{"tags":[]}"#.utf8)) }
        defer { h.cleanUp() }
        let text = "f:\"a b\nc"

        #expect(try await h.service.tagSuggestions(" \(text)\n", site: .eh).isEmpty)

        let request = try #require(h.mock.requests().first)
        #expect(try Self.body(of: request)["text"] == text)
    }

    @Test func theRequestIsThrottled() async throws {
        let h = try await Self.makeHarness { _ in
            MockResponse(body: Data(#"{"tags":{"1":{"ns":"female","tn":"fake tag"}}}"#.utf8))
        }
        defer { h.cleanUp() }

        let tags = try await h.service.tagSuggestions("fake", site: .eh)

        #expect(tags == [TagRef(namespace: "female", name: "fake tag")])
        #expect(await h.throttle.acquiredURLs == [EHEndpoints.api(site: .eh)])
    }
}
