import EHModels
import EHStore
import Foundation
import Testing

@Suite struct TagTranslationQueryTests {
    private static let allFake = [
        "female:fake long", "female:fake tag", "other:fake other", "cosplayer:fake cosplayer",
    ]

    /// An in-memory store with the gzip sample imported as "v1"; `fullText: false` forces the `LIKE` path.
    private static func store(fullText: Bool) async throws -> TagTranslationStore {
        let store = try TagTranslationStore(inMemory: true, allowsFullTextSearch: fullText)
        #expect(await store.usesFullTextSearch == fullText)
        #expect(try await store.replaceAll(with: TagSamples.gzip(), version: "v1") == 8)
        return store
    }

    private func ids(_ translations: [TagTranslation]) -> [String] {
        translations.map { "\($0.namespace):\($0.key)" }
    }

    @Test(arguments: [true, false]) func searchMatchesKeysAndNames(_ fullText: Bool) async throws {
        let store = try await Self.store(fullText: fullText)
        let fake = Self.allFake
        #expect(ids(try await store.search("fake", limit: 10)) == fake)
        #expect(ids(try await store.search("FAKE", limit: 10)) == fake)
        #expect(ids(try await store.search("fake", limit: 2)) == Array(fake.prefix(2)))
        #expect(ids(try await store.search("fake tag", limit: 10)) == ["female:fake tag"])
        #expect(ids(try await store.search("示例标", limit: 10)) == ["female:fake tag"])
        #expect(ids(try await store.search("女性", limit: 10)) == ["female:shared"])  // rows:female is never offered
    }

    @Test(arguments: [true, false]) func shortQueriesStillMatch(_ fullText: Bool) async throws {
        let store = try await Self.store(fullText: fullText)
        #expect(ids(try await store.search("示例", limit: 10)) == Self.allFake)
        #expect(ids(try await store.search("共享", limit: 10)) == ["female:shared", "other:shared"])
        #expect(ids(try await store.search("其他", limit: 10)) == ["other:fake other", "other:shared"])
    }

    @Test(arguments: [true, false]) func specialCharactersAreLiteral(_ fullText: Bool) async throws {
        let store = try TagTranslationStore(inMemory: true, allowsFullTextSearch: fullText)
        #expect(await store.usesFullTextSearch == fullText)
        // The sample, plus two made-up tags whose keys hold a `LIKE` wildcard.
        var file = try #require(try JSONSerialization.jsonObject(with: TagSamples.json()) as? [String: Any])
        var namespaces = try #require(file["data"] as? [Any])
        namespaces.append([
            "namespace": "female",
            "data": ["50% fake": ["name": "示例百分"], "a_b fake": ["name": "示例下划线"]],
        ])
        file["data"] = namespaces
        #expect(try await store.replaceAll(with: JSONSerialization.data(withJSONObject: file), version: "v1") == 10)
        // Each hits its own tag only: "%" and "_" match themselves, never any character.
        #expect(ids(try await store.search("50%", limit: 10)) == ["female:50% fake"])
        #expect(ids(try await store.search("a_b", limit: 10)) == ["female:a_b fake"])
        for query in ["\"", "fake\" OR \"x", "5%", "a%b", "fake_tag", "fake%tag", "*", "NEAR(fake", "f:fake", "\\"] {
            #expect(try await store.search(query, limit: 10) == [], "query: \(query)")
        }
    }

    @Test func overlongQueryReturnsNothing() async throws {
        let store = try await Self.store(fullText: true)
        #expect(try await store.search(String(repeating: "a", count: 10_000), limit: 10) == [])
        #expect(try await store.search(String(repeating: "示", count: 257), limit: 10) == [])
    }

    @Test func emptyQueryOrNoLimit() async throws {
        let store = try await Self.store(fullText: true)
        #expect(try await store.search("  ", limit: 10) == [])
        #expect(try await store.search("fake", limit: 0) == [])
        #expect(try await store.search("fake", limit: -1) == [])
    }

    @Test func markUsedMovesToTheFront() async throws {
        let store = try await Self.store(fullText: true)
        try await store.markUsed(TagRef(namespace: "o", name: "fake other"))
        try await store.markUsed(TagRef(namespace: "female", name: "fake tag"))
        #expect(ids(try await store.search("fake", limit: 10)) == [
            "female:fake tag", "other:fake other", "female:fake long", "cosplayer:fake cosplayer",
        ])
    }

    @Test func markUsedIgnoresUnknownTags() async throws {
        let store = try await Self.store(fullText: true)
        try await store.markUsed(TagRef(namespace: "female", name: "missing"))
        #expect(ids(try await store.search("fake", limit: 10)) == Self.allFake)
    }

    @Test func usageSurvivesReimport() async throws {
        let store = try await Self.store(fullText: true)
        try await store.markUsed(TagRef(namespace: "o", name: "fake other"))
        _ = try await store.replaceAll(with: TagSamples.gzip(), version: "v2")
        #expect(ids(try await store.search("fake", limit: 10)).first == "other:fake other")
    }

    @Test func translatedIntroTranslatesBacktickTags() async throws {
        let store = try await Self.store(fullText: true)
        #expect(try await store.translatedIntro("示例介绍，参见 `other:fake other` 与 `missing tag`。")
            == "示例介绍，参见  `其他示例 (other:fake other)`  与 `missing tag`。")
    }

    @Test func translatedIntroUsesPlainNamesAndAbbreviations() async throws {
        let store = try await Self.store(fullText: true)
        #expect(try await store.translatedIntro("看 `female:fake long` 和 `f:fake tag`")
            == "看  `长示例 (female:fake long)`  和  `示例标签 (f:fake tag)` ")
    }

    @Test func introsWithoutKnownTagsAreUnchanged() async throws {
        let store = try await Self.store(fullText: true)
        for intro in ["", "没有反引号", "`missing tag`", "`未闭合" + String(repeating: "a", count: 5_000)] {
            #expect(try await store.translatedIntro(intro) == intro)
        }
    }
}
