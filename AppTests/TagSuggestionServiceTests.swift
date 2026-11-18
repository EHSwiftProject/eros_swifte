import EHModels
import EHNetwork
import EHStore
import Foundation
import Testing

@testable import Eros

/// `TagSuggestionService` over an environment's `EHService` (StubURLProtocol answers; nothing reaches the network), a
/// made-up tag table and settings of its own suite.
///
/// Each test has a minute (`.timeLimit`): some hold a request, a page or a feed's answer until they let it go (a
/// gate, a throttle: neither heeds cancellation), and one that never lets go must fail at the limit, not hang the
/// run (the test process is then ended and started again for the tests after it).
@MainActor @Suite(.timeLimit(.minutes(1))) struct TagSuggestionServiceTests {
    /// A tagsuggest answer with two made-up tags, in the order male, female (not sorted by key).
    nonisolated static let apiAnswer = Data(
        #"{"tags":{"9":{"ns":"male","tn":"fake b"},"2":{"ns":"female","tn":"fake a"}}}"#.utf8
    )
    nonisolated static let apiSuggestions = [
        TagSuggestion(tag: TagRef(namespace: "male", name: "fake b"), translation: nil),
        TagSuggestion(tag: TagRef(namespace: "female", name: "fake a"), translation: nil),
    ]

    struct Harness {
        let suggestions: TagSuggestionService
        let stub: StubSession
        let log: SuggestRequestLog
        let environment: AppEnvironment
        let settings: AppSettingsStore

        /// The `text` of every tagsuggest request, oldest first.
        var texts: [String] { log.all }

        func cleanUp() { stub.remove() }
    }

    /// A service whose settings show translations or not, over `table`; the stub answers every request with
    /// `answer`, or fails it with `failure`. `throttle` is what the environment's requests wait for.
    static func makeHarness(
        table: TagTranslationStore?, showsTranslations: Bool, debounce: Duration = .zero,
        answer: Data = apiAnswer, failure: URLError.Code? = nil, throttle: any RequestThrottle = ThrottleRecorder()
    ) async -> Harness {
        let log = SuggestRequestLog()
        let stub = StubURLProtocol.install { request in
            log.record(request)
            if let failure { throw URLError(failure) }
            return StubResponse(body: answer)
        }
        let environment = AppEnvironment(
            uiTesting: true, sessionConfigurator: stub.configurator, userAgentProbe: { "FakeWebKit/1" },
            throttle: throttle
        )
        await environment.start()
        let settings = AppSettingsStore(ownedSuiteNamed: "proj.eros.swifte.tests.suggestions.\(UUID().uuidString)")
        settings.settings.showsTagTranslations = showsTranslations
        let suggestions = TagSuggestionService(
            service: environment.service, translations: table, settings: settings, debounce: debounce
        )
        return Harness(suggestions: suggestions, stub: stub, log: log, environment: environment, settings: settings)
    }

    // MARK: Local table

    @Test func localTableAnswersWhenTranslationsAreOn() async throws {
        let h = await Self.makeHarness(table: try await FakeTagTable.store(), showsTranslations: true)
        defer { h.cleanUp() }

        let result = await h.suggestions.suggestions(for: "x fake", site: .eh)

        #expect(h.stub.requests().isEmpty)
        #expect(Set(result.map(\.tag.raw)) == [
            "female:fake tag", "female:fake second", "other:fake other", "artist:fakeartist",
        ])
        #expect(result.first { $0.tag.name == "fake tag" }?.translation == "示例标签")
        #expect(result.first { $0.tag.name == "fake other" }?.translation == "其他示例")
    }

    @Test func localAnswersAreCappedAt200() async throws {
        let rows: [FakeTagTable.Row] = (0..<250).map { ("female", "fake tag \($0)", "示例标签 \($0)") }
        let h = await Self.makeHarness(table: try await FakeTagTable.store(rows), showsTranslations: true)
        defer { h.cleanUp() }

        #expect(TagSuggestionService.localLimit == 200)
        let result = await h.suggestions.suggestions(for: "fake", site: .eh)
        #expect(result.count == 200)
        #expect(Set(result).count == 200)
        #expect(h.stub.requests().isEmpty)
    }

    /// Rows that differ only in case are one tag (the table looks tags up lowercased): the first one is kept.
    @Test func localAnswersListEachTagOnce() async throws {
        let rows: [FakeTagTable.Row] = [
            ("female", "fake tag", "示例标签"), ("female", "Fake Tag", "示例大写"), ("male", "fake tag", "示例男性"),
        ]
        let h = await Self.makeHarness(table: try await FakeTagTable.store(rows), showsTranslations: true)
        defer { h.cleanUp() }

        let result = await h.suggestions.suggestions(for: "fake", site: .eh)

        // Import order within a namespace is by key bytes, so "Fake Tag" comes first.
        #expect(result.map(\.tag.raw) == ["female:Fake Tag", "male:fake tag"])
        #expect(h.stub.requests().isEmpty)
    }

    @Test func localSearchDropsTheNamespacePrefix() async throws {
        let h = await Self.makeHarness(table: try await FakeTagTable.store(), showsTranslations: true)
        defer { h.cleanUp() }

        let prefixed = await h.suggestions.suggestions(for: "f:fake", site: .eh)
        let plain = await h.suggestions.suggestions(for: "fake", site: .eh)
        let exact = await h.suggestions.suggestions(for: "fake$", site: .eh)

        #expect(!plain.isEmpty)
        #expect(prefixed == plain)
        #expect(exact == plain)
        #expect(await h.suggestions.suggestions(for: "f:", site: .eh).isEmpty)
        #expect(h.stub.requests().isEmpty)
    }

    // MARK: The site

    @Test func apiAnswersWhenTranslationsAreOff() async throws {
        let h = await Self.makeHarness(table: try await FakeTagTable.store(), showsTranslations: false)
        defer { h.cleanUp() }

        let result = await h.suggestions.suggestions(for: "x fak", site: .eh)

        #expect(result == Self.apiSuggestions)
        #expect(h.texts == ["fak"])
        #expect(h.stub.requests().compactMap(\.url) == [EHEndpoints.api(site: .eh)])
    }

    @Test func apiAnswersWhenTheTableIsEmptyOrMissing() async throws {
        let empty = await Self.makeHarness(table: try TagTranslationStore(inMemory: true), showsTranslations: true)
        defer { empty.cleanUp() }
        #expect(await empty.suggestions.suggestions(for: "fak", site: .ex) == Self.apiSuggestions)
        #expect(empty.texts == ["fak"])
        #expect(empty.stub.requests().compactMap(\.url) == [EHEndpoints.api(site: .ex)])

        let missing = await Self.makeHarness(table: nil, showsTranslations: true)
        defer { missing.cleanUp() }
        #expect(await missing.suggestions.suggestions(for: "fak", site: .eh) == Self.apiSuggestions)
        #expect(missing.texts == ["fak"])
    }

    /// An exclusion's "-" is not part of what is asked, nor of what is remembered: "-fak" asks for "fak".
    @Test func theExclusionMinusIsNotAsked() async throws {
        let site = await Self.makeHarness(table: nil, showsTranslations: false)
        defer { site.cleanUp() }
        #expect(await site.suggestions.suggestions(for: "x -fak", site: .eh) == Self.apiSuggestions)
        #expect(await site.suggestions.suggestions(for: "fak", site: .eh) == Self.apiSuggestions)
        #expect(await site.suggestions.suggestions(for: "-", site: .eh).isEmpty)
        #expect(site.texts == ["fak"])

        let local = await Self.makeHarness(table: try await FakeTagTable.store(), showsTranslations: true)
        defer { local.cleanUp() }
        let excluded = await local.suggestions.suggestions(for: "-f:fake", site: .eh)
        let included = await local.suggestions.suggestions(for: "f:fake", site: .eh)
        #expect(!excluded.isEmpty)
        #expect(excluded == included)
        #expect(local.stub.requests().isEmpty)
    }

    @Test func emptyTokenSendsNothing() async throws {
        let h = await Self.makeHarness(table: nil, showsTranslations: false)
        defer { h.cleanUp() }

        #expect(await h.suggestions.suggestions(for: "a ", site: .eh).isEmpty)
        #expect(await h.suggestions.suggestions(for: "", site: .eh).isEmpty)
        #expect(await h.suggestions.suggestions(for: "a \"", site: .eh).isEmpty)
        #expect(h.stub.requests().isEmpty)
    }

    // MARK: Timing and memory

    @Test func debounceDefaultsTo500Milliseconds() async {
        let h = await Self.makeHarness(table: nil, showsTranslations: false)
        defer { h.cleanUp() }
        let service = TagSuggestionService(service: h.environment.service, translations: nil, settings: h.settings)
        #expect(service.debounce == .milliseconds(500))
    }

    @Test func onlyTheLastOfQuickTypingSendsARequest() async throws {
        let h = await Self.makeHarness(table: nil, showsTranslations: false, debounce: .milliseconds(100))
        defer { h.cleanUp() }

        let first = Task { await h.suggestions.suggestions(for: "fa", site: .eh) }
        try await Task.sleep(for: .milliseconds(10))
        first.cancel()
        let last = await h.suggestions.suggestions(for: "fak", site: .eh)

        #expect(await first.value.isEmpty)
        #expect(last == Self.apiSuggestions)
        #expect(h.texts == ["fak"])
    }

    /// Cancelled while waiting, or while the request waits for the throttle: nothing, and nothing remembered.
    @Test func cancelledCallReturnsNothing() async throws {
        let waiting = await Self.makeHarness(table: nil, showsTranslations: false, debounce: .seconds(10))
        defer { waiting.cleanUp() }
        let debounced = Task { await waiting.suggestions.suggestions(for: "fak", site: .eh) }
        debounced.cancel()
        #expect(await debounced.value.isEmpty)
        #expect(waiting.stub.requests().isEmpty)

        let throttle = GatedThrottle()
        let h = await Self.makeHarness(table: nil, showsTranslations: false, throttle: throttle)
        defer { h.cleanUp() }
        let call = Task { await h.suggestions.suggestions(for: "fak", site: .eh) }
        #expect(await eventually { await throttle.urls.count == 1 })
        call.cancel()
        await throttle.open()
        #expect(await call.value.isEmpty)
        #expect(h.stub.requests().isEmpty)

        #expect(await h.suggestions.suggestions(for: "fak", site: .eh) == Self.apiSuggestions)
        #expect(h.texts == ["fak"])
    }

    @Test func sameTokenTwiceSendsOneRequest() async throws {
        let h = await Self.makeHarness(table: nil, showsTranslations: false)
        defer { h.cleanUp() }

        let first = await h.suggestions.suggestions(for: "fak", site: .eh)
        let again = await h.suggestions.suggestions(for: "x fak", site: .eh)
        #expect(first == Self.apiSuggestions)
        #expect(again == first)
        #expect(h.texts == ["fak"])

        // Another site is another question.
        _ = await h.suggestions.suggestions(for: "fak", site: .ex)
        #expect(h.texts == ["fak", "fak"])
    }

    /// A new import gives the table a new version: the same word asks the table again.
    @Test func reimportingTheTableForgetsTheAnswer() async throws {
        let table = try await FakeTagTable.store()
        let h = await Self.makeHarness(table: table, showsTranslations: true)
        defer { h.cleanUp() }
        let before = await h.suggestions.suggestions(for: "fake", site: .eh)
        #expect(before.contains { $0.tag.name == "fake tag" })

        let rows: [FakeTagTable.Row] = [("female", "fake new", "新示例")]
        _ = try await table.replaceAll(with: FakeTagTable.database(rows), version: "v1 test")
        let after = await h.suggestions.suggestions(for: "fake", site: .eh)

        #expect(after == [TagSuggestion(tag: TagRef(namespace: "female", name: "fake new"), translation: "新示例")])
        #expect(h.stub.requests().isEmpty)
    }

    @Test func networkErrorGivesNoSuggestions() async throws {
        let offline = await Self.makeHarness(table: nil, showsTranslations: false, failure: .notConnectedToInternet)
        defer { offline.cleanUp() }
        #expect(await offline.suggestions.suggestions(for: "fak", site: .eh).isEmpty)
        #expect(offline.texts == ["fak"])

        let refused = await Self.makeHarness(
            table: nil, showsTranslations: false, answer: Data(#"{"error":"Fake error"}"#.utf8)
        )
        defer { refused.cleanUp() }
        #expect(await refused.suggestions.suggestions(for: "fak", site: .eh).isEmpty)
        // A failure is not remembered: the same word is asked again.
        #expect(await refused.suggestions.suggestions(for: "fak", site: .eh).isEmpty)
        #expect(refused.texts == ["fak", "fak"])
    }

    @Test func choosingALocalSuggestionMarksItUsed() async throws {
        let h = await Self.makeHarness(table: try await FakeTagTable.store(), showsTranslations: true)
        defer { h.cleanUp() }

        let before = await h.suggestions.suggestions(for: "fake", site: .eh)
        let chosen = try #require(before.last)
        #expect(before.first != chosen)

        await h.suggestions.didChoose(chosen)
        let after = await h.suggestions.suggestions(for: "fake", site: .eh)

        #expect(after.first == chosen)
        #expect(Set(after) == Set(before))
        #expect(h.stub.requests().isEmpty)
    }
}
