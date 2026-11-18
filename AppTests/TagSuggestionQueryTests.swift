import EHModels
import Testing

@testable import Eros

/// The texts an injected `suggest` was asked for, oldest first.
@MainActor private final class AskedTexts {
    var all: [String] = []
}

/// Whether an injected `suggest` found its task cancelled.
@MainActor private final class CancellationSeen {
    var value: Bool?
}

/// `TagSuggestionQuery`: an injected `suggest` the test holds back with `Gate`s, or the real service over
/// `FakeTagTable` (StubURLProtocol behind it; nothing reaches the network).
///
/// Each test has a minute (`.timeLimit`): some hold a request, a page or a feed's answer until they let it go (a
/// gate, a throttle: neither heeds cancellation), and one that never lets go must fail at the limit, not hang the
/// run (the test process is then ended and started again for the tests after it).
@MainActor @Suite(.timeLimit(.minutes(1))) struct TagSuggestionQueryTests {
    private static func suggestion(_ name: String) -> TagSuggestion {
        TagSuggestion(tag: TagRef(namespace: "female", name: name), translation: nil)
    }

    @Test func staleSuggestionsAreDropped() async throws {
        let h = await TagSuggestionServiceTests.makeHarness(table: nil, showsTranslations: false)
        defer { h.cleanUp() }
        let held = Gate()
        let asked = AskedTexts()
        let query = TagSuggestionQuery(service: h.suggestions) { text, _ in
            asked.all.append(text)
            if text == "a" { await held.wait() }
            return [Self.suggestion("fake \(text)")]
        }

        query.textDidChange("a", site: .eh)
        let stale = try #require(query.task)
        query.textDidChange("ab", site: .eh)
        await query.task?.value
        #expect(query.suggestions == [Self.suggestion("fake ab")])

        // The answer for "a" comes last, and is dropped.
        held.open()
        await stale.value
        #expect(query.suggestions == [Self.suggestion("fake ab")])
        #expect(asked.all == ["a", "ab"])
        #expect(h.stub.requests().isEmpty)
    }

    @Test func emptyTextClearsSuggestions() async throws {
        let h = await TagSuggestionServiceTests.makeHarness(table: nil, showsTranslations: false)
        defer { h.cleanUp() }
        let held = Gate()
        let asked = AskedTexts()
        let query = TagSuggestionQuery(service: h.suggestions) { text, _ in
            asked.all.append(text)
            if text == "abc" { await held.wait() }
            return [Self.suggestion("fake \(text)")]
        }

        query.textDidChange("ab", site: .eh)
        await query.task?.value
        #expect(query.suggestions == [Self.suggestion("fake ab")])

        // Emptied while an answer is on its way: nothing now, and nothing once it comes.
        query.textDidChange("abc", site: .eh)
        let pending = try #require(query.task)
        query.textDidChange("", site: .eh)
        #expect(query.suggestions.isEmpty)
        held.open()
        await pending.value
        #expect(query.suggestions.isEmpty)
        #expect(asked.all == ["ab", "abc"])

        query.textDidChange("ab", site: .eh)
        await query.task?.value
        query.clear()
        #expect(query.suggestions.isEmpty)
    }

    /// The real service over the local table: applying a suggestion returns the new text at once and clears the list;
    /// the choice is reported in `choiceReport`, so the same word then lists it first, without a request.
    @Test func applyingClearsAndReportsTheChoice() async throws {
        let h = await TagSuggestionServiceTests.makeHarness(
            table: try await FakeTagTable.store(), showsTranslations: true
        )
        defer { h.cleanUp() }
        let query = TagSuggestionQuery(service: h.suggestions)

        query.textDidChange("x fake", site: .eh)
        await query.task?.value
        let chosen = try #require(query.suggestions.last)
        #expect(query.suggestions.first != chosen)

        let text = query.apply(chosen, to: "x fake")
        #expect(text == "x \(chosen.searchTerm) ")
        #expect(query.suggestions.isEmpty)
        let report = try #require(query.choiceReport)
        await report.value

        query.textDidChange("fake", site: .eh)
        await query.task?.value
        #expect(query.suggestions.first == chosen)
        #expect(h.stub.requests().isEmpty)
    }

    /// A query that goes cancels the question it was waiting for.
    @Test func releasingTheQueryCancelsItsQuestion() async throws {
        let h = await TagSuggestionServiceTests.makeHarness(table: nil, showsTranslations: false)
        defer { h.cleanUp() }
        let held = Gate()
        let seen = CancellationSeen()
        var query: TagSuggestionQuery? = TagSuggestionQuery(service: h.suggestions) { _, _ in
            await held.wait()
            seen.value = Task.isCancelled
            return []
        }

        query?.textDidChange("fak", site: .eh)
        let pending = try #require(query?.task)
        query = nil
        held.open()
        await pending.value

        #expect(seen.value == true)
    }
}
