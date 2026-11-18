import EHModels
@testable import EHStore
import Foundation
import SwiftData
import Testing

/// What the public API cannot set up: rows whose payload no longer decodes (written by a later version of the app),
/// and a change that fails half way.
@Suite struct UserDataStoreInternalsTests {
    private struct Failure: Error {}

    /// Not a JSON object, so neither a `CustomGroup` (which reads any object) nor a `GallerySummary`.
    private static let unreadable = Data(#"["a later format"]"#.utf8)

    @Test func unreadableGroupIsSkippedAndKeepsItsPlace() async throws {
        let store = try UserDataStore(inMemory: true)
        try await store.saveGroup(CustomGroup(uuid: "a", name: "Fake A"))
        try await store.saveGroup(CustomGroup(uuid: "b", name: "Fake B"))
        // Between the two, a row the current format cannot read.
        try await store.write { context in
            for row in try context.fetch(FetchDescriptor<StoredGroup>()) where row.uuid == "b" { row.position = 2 }
            context.insert(StoredGroup(uuid: "later", position: 1, payload: Self.unreadable))
        }
        #expect(try await store.groups(seed: { [] }).map(\.uuid) == ["a", "b"])
        // Moving the readable groups leaves the unreadable row where it was, and in the store.
        try await store.moveGroups(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(try await store.groups(seed: { [] }).map(\.uuid) == ["b", "a"])
        let stored = try await store.write { context in
            try context.fetch(FetchDescriptor<StoredGroup>(sortBy: [SortDescriptor(\.position)])).map(\.uuid)
        }
        #expect(stored == ["b", "later", "a"])
    }

    @Test func unreadableFavoriteIsSkippedAndKept() async throws {
        let store = try UserDataStore(inMemory: true)
        try await store.addLocalFavorite(fakeSummary(gid: 900_001))
        try await store.write { context in
            context.insert(StoredLocalFavorite(gid: 900_002, sequence: 2, payload: Self.unreadable))
        }
        try await store.addLocalFavorite(fakeSummary(gid: 900_003))
        #expect(try await store.localFavorites().map(\.id.gid) == [900_003, 900_001])
        let stored = try await store.write { context in
            try context.fetch(FetchDescriptor<StoredLocalFavorite>(sortBy: [SortDescriptor(\.sequence)])).map(\.gid)
        }
        #expect(stored == [900_001, 900_002, 900_003])
        // Adding the unreadable gallery again changes nothing: it is already there.
        try await store.addLocalFavorite(fakeSummary(gid: 900_002))
        #expect(try await store.localFavorites().map(\.id.gid) == [900_003, 900_001])
    }

    /// `write(_:)` rolls a failed change back: nothing of it is saved, and the next change goes through.
    @Test func failedWriteRollsBack() async throws {
        let store = try UserDataStore(inMemory: true)
        await #expect(throws: Failure.self) {
            try await store.write { context in
                context.insert(StoredSearch(text: "fake rolled back", sequence: 1))
                throw Failure()
            }
        }
        #expect(try await store.searchHistory().isEmpty)
        let pending = try await store.write { context in context.hasChanges }
        #expect(!pending)
        try await store.recordSearch("fake kept")
        #expect(try await store.searchHistory() == ["fake kept"])
    }
}
