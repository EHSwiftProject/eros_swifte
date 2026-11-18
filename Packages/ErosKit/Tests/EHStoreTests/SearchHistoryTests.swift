import EHStore
import Foundation
import Testing

@Suite struct SearchHistoryTests {
    @Test func newestFirstWithoutDuplicates() async throws {
        let store = try UserDataStore(inMemory: true)
        for text in ["a", "b", "a", " c ", ""] { try await store.recordSearch(text) }
        #expect(try await store.searchHistory() == ["c", "a", "b"])
    }

    @Test func keepsAtMostOneHundred() async throws {
        let store = try UserDataStore(inMemory: true)
        for index in 0...104 { try await store.recordSearch("\(index)") }
        let history = try await store.searchHistory()
        #expect(history.count == 100)
        #expect(history.first == "104")
        #expect(history.last == "5")
    }

    @Test func repeatingAnOldEntryKeepsItFromBeingTrimmed() async throws {
        let store = try UserDataStore(inMemory: true)
        for index in 0..<100 { try await store.recordSearch("\(index)") }
        try await store.recordSearch("0")
        try await store.recordSearch("new")
        let history = try await store.searchHistory()
        #expect(history.count == 100)
        #expect(history.first == "new")
        #expect(history.contains("0"))
        #expect(!history.contains("1"))
    }

    @Test func removeAndClear() async throws {
        let store = try UserDataStore(inMemory: true)
        for text in ["a", "b"] { try await store.recordSearch(text) }
        try await store.removeSearch(" a ")
        #expect(try await store.searchHistory() == ["b"])
        try await store.removeSearch("zzz")
        #expect(try await store.searchHistory() == ["b"])
        try await store.clearSearchHistory()
        #expect(try await store.searchHistory() == [])
    }

    @Test func historyPersists() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "UserData.store")
            do {
                let first = try UserDataStore(storeURL: url)
                for text in ["fake a", "fake b", "fake a"] { try await first.recordSearch(text) }
                _ = try await first.searchHistory()
            }
            let second = try UserDataStore(storeURL: url)
            #expect(try await second.searchHistory() == ["fake a", "fake b"])
        }
    }
}
