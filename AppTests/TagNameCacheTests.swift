import EHModels
import EHStore
import Foundation
import Observation
import Testing

@testable import Eros

/// `TagNameCache` over an in-memory store holding one made-up translation.
@MainActor @Suite struct TagNameCacheTests {
    static let fakeTag = TagRef(raw: "female:fake tag")

    /// A db.raw.json with the one tag `female:fake tag`, its name holding a Markdown image like the real database.
    nonisolated static let smallDatabase = Data(
        #"{"data":[{"namespace":"female","data":{"fake tag":{"name":"![图](https://example.invalid/a.png) 示例标签"}}}]}"#
            .utf8
    )

    static func makeStore() async throws -> TagTranslationStore {
        let store = try TagTranslationStore(inMemory: true)
        _ = try await store.replaceAll(with: smallDatabase, version: "v0 test")
        return store
    }

    @Test func prefetchedTagsAreTranslated() async throws {
        let cache = TagNameCache(store: try await Self.makeStore())
        #expect(cache.name(for: Self.fakeTag) == nil)
        await cache.prefetch([Self.fakeTag, TagRef(raw: "female:unknown tag")])
        #expect(cache.name(for: Self.fakeTag) == "示例标签")
        #expect(cache.name(for: TagRef(raw: "female:unknown tag")) == nil)
    }

    @Test func missingStoreTranslatesNothing() async {
        let cache = TagNameCache(store: nil)
        await cache.prefetch([Self.fakeTag])
        #expect(cache.name(for: Self.fakeTag) == nil)
    }

    @Test func removeAllForgetsAndLooksUpAgain() async throws {
        let store = try await Self.makeStore()
        let cache = TagNameCache(store: store)
        await cache.prefetch([Self.fakeTag])
        #expect(cache.name(for: Self.fakeTag) == "示例标签")
        let before = cache.generation
        cache.removeAll()
        #expect(cache.generation == before + 1)
        #expect(cache.name(for: Self.fakeTag) == nil)
        await cache.prefetch([Self.fakeTag])
        #expect(cache.name(for: Self.fakeTag) == "示例标签")
    }

    @Test func untranslatedTagsAreRememberedUntilRemoveAll() async throws {
        let store = try TagTranslationStore(inMemory: true)
        let cache = TagNameCache(store: store)
        await cache.prefetch([Self.fakeTag])
        #expect(cache.name(for: Self.fakeTag) == nil)
        // The translation arrives later; the cache keeps its answer until it is cleared.
        _ = try await store.replaceAll(with: Self.smallDatabase, version: "v1 test")
        await cache.prefetch([Self.fakeTag])
        #expect(cache.name(for: Self.fakeTag) == nil)
        cache.removeAll()
        await cache.prefetch([Self.fakeTag])
        #expect(cache.name(for: Self.fakeTag) == "示例标签")
    }

    /// A prefetch whose task was cancelled (`.task(id:)` moved on to the next items) stops before the tags it has not
    /// read (L068b); they are not taken as asked, so the next prefetch reads them.
    @Test func aCancelledPrefetchStopsAndLeavesTheRestUnasked() async throws {
        let cache = TagNameCache(store: try await Self.makeStore())
        let prefetch = Task { await cache.prefetch([Self.fakeTag]) }
        prefetch.cancel()
        await prefetch.value
        #expect(cache.name(for: Self.fakeTag) == nil)

        await cache.prefetch([Self.fakeTag])
        #expect(cache.name(for: Self.fakeTag) == "示例标签")
    }

    /// Many tags at once (a page of 25 items with about ten tags each) are all readable after one prefetch, the names
    /// written in batches rather than one by one.
    @Test func aLargePrefetchReadsEveryTag() async throws {
        let store = try TagTranslationStore(inMemory: true)
        let entries = (0..<120).map { #""fake tag \#($0)":{"name":"示例\#($0)"}"# }.joined(separator: ",")
        let database = Data(#"{"data":[{"namespace":"female","data":{\#(entries)}}]}"#.utf8)
        _ = try await store.replaceAll(with: database, version: "v0 test")
        let cache = TagNameCache(store: store)
        let tags = (0..<120).map { TagRef(raw: "female:fake tag \($0)") }

        await cache.prefetch(tags)
        #expect(tags.enumerated().allSatisfy { cache.name(for: $1) == "示例\($0)" })
    }

    /// The names go in `batchSize` at a time (L068b, M2 re-review F3 M-9a): every view that shows a tag observes them,
    /// and one prefetch of 120 translated tags tells those views three times (50, 50, 20), not 120.
    @Test func aLargePrefetchWritesTheNamesInBatches() async throws {
        let store = try TagTranslationStore(inMemory: true)
        let entries = (0..<120).map { #""fake tag \#($0)":{"name":"示例\#($0)"}"# }.joined(separator: ",")
        let database = Data(#"{"data":[{"namespace":"female","data":{\#(entries)}}]}"#.utf8)
        _ = try await store.replaceAll(with: database, version: "v0 test")
        let cache = TagNameCache(store: store)
        let tags = (0..<120).map { TagRef(raw: "female:fake tag \($0)") }
        // A view showing one tag that is read last.
        let changes = ChangeCounter { _ = cache.name(for: tags[119]) }

        await cache.prefetch(tags)
        #expect(cache.name(for: tags[119]) == "示例119")
        #expect(TagNameCache.batchSize == 50)
        #expect(changes.count == 3)
    }

    /// Counts the changes that what `read` reads is told of, from now on: each registration of
    /// `withObservationTracking` tells one change, so it registers again as it is told (on the main actor, where
    /// `TagNameCache` changes).
    @MainActor private final class ChangeCounter {
        private(set) var count = 0
        private let read: @MainActor () -> Void

        init(_ read: @escaping @MainActor () -> Void) {
            self.read = read
            observe()
        }

        private func observe() {
            withObservationTracking {
                read()
            } onChange: { [weak self] in
                MainActor.assumeIsolated {
                    self?.count += 1
                    self?.observe()
                }
            }
        }
    }
}
