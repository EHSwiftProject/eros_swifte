import EHStore
import Foundation
import Testing

@Suite struct QuickSearchStoreTests {
    static func store(with texts: [String]) async throws -> UserDataStore {
        let store = try UserDataStore(inMemory: true)
        for text in texts { _ = try await store.addQuickSearch(text) }
        return store
    }

    @Test func addTrimsAndRejects() async throws {
        let store = try UserDataStore(inMemory: true)
        #expect(try await store.addQuickSearch(" l:\"fake language\" ") == true)
        #expect(try await store.addQuickSearch("l:\"fake language\"") == false)
        #expect(try await store.addQuickSearch("   ") == false)
        #expect(try await store.addQuickSearch("o:\"fake other\"") == true)
        #expect(try await store.quickSearches() == ["l:\"fake language\"", "o:\"fake other\""])
    }

    @Test func comparisonIsCaseSensitive() async throws {
        let store = try await Self.store(with: ["abc"])
        #expect(try await store.addQuickSearch("ABC") == true)
        #expect(try await store.quickSearches() == ["abc", "ABC"])
    }

    @Test func removeAndMove() async throws {
        let store = try await Self.store(with: ["a", "b", "c"])
        try await store.moveQuickSearches(fromOffsets: [2], toOffset: 0)
        #expect(try await store.quickSearches() == ["c", "a", "b"])
        try await store.removeQuickSearch(" a ")
        #expect(try await store.quickSearches() == ["c", "b"])
        try await store.removeQuickSearch("zzz")
        #expect(try await store.quickSearches() == ["c", "b"])
    }

    @Test func addAfterRemoveAppendsAtTheEnd() async throws {
        let store = try await Self.store(with: ["a", "b", "c"])
        try await store.removeQuickSearch("a")
        _ = try await store.addQuickSearch("d")
        #expect(try await store.quickSearches() == ["b", "c", "d"])
    }

    @Test func mergeCountsNewEntries() async throws {
        let store = try await Self.store(with: ["a"])
        #expect(try await store.mergeQuickSearches([" a", "b", "b ", "", "c"]) == 2)
        #expect(try await store.quickSearches() == ["a", "b", "c"])
    }

    @Test func quickSearchesPersist() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "UserData.store")
            do {
                let first = try UserDataStore(storeURL: url)
                _ = try await first.addQuickSearch("示例 検索 🔍")
                _ = try await first.addQuickSearch("fake b")
                _ = try await first.addQuickSearch("fake c")
                try await first.moveQuickSearches(fromOffsets: [2], toOffset: 0)
                _ = try await first.quickSearches()
            }
            let second = try UserDataStore(storeURL: url)
            #expect(try await second.quickSearches() == ["fake c", "示例 検索 🔍", "fake b"])
        }
    }
}
