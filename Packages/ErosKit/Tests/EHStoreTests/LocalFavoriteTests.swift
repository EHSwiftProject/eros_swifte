import EHModels
import EHStore
import Foundation
import Testing

@Suite struct LocalFavoriteTests {
    static func seededStore() async throws -> UserDataStore {
        let store = try UserDataStore(inMemory: true)
        try await store.addLocalFavorite(fakeSummary(gid: 900_001))
        try await store.addLocalFavorite(fakeSummary(gid: 900_002))
        return store
    }

    @Test func newFavoritesGoFirst() async throws {
        let store = try await Self.seededStore()
        #expect(try await store.localFavorites().map(\.id.gid) == [900_002, 900_001])
    }

    @Test func duplicateGIDChangesNothing() async throws {
        let store = try await Self.seededStore()
        let before = try await store.localFavorites()
        try await store.addLocalFavorite(fakeSummary(gid: 900_001, title: "Changed"))
        #expect(try await store.localFavorites() == before)
    }

    @Test func removeIgnoresTheToken() async throws {
        let store = try await Self.seededStore()
        try await store.removeLocalFavorite(GalleryID(gid: 900_001, token: "ffffffffff"))
        #expect(try await store.localFavorites().map(\.id.gid) == [900_002])
        try await store.removeLocalFavorite(GalleryID(gid: 999_999, token: "0123456789"))
        #expect(try await store.localFavorites().map(\.id.gid) == [900_002])
    }

    @Test func addAfterRemoveGoesFirst() async throws {
        let store = try await Self.seededStore()
        try await store.removeLocalFavorite(GalleryID(gid: 900_002, token: "0123456789"))
        try await store.addLocalFavorite(fakeSummary(gid: 900_003))
        #expect(try await store.localFavorites().map(\.id.gid) == [900_003, 900_001])
    }

    /// Every field but the account's own survives a reopen (see `accountFieldsAreNotStored`).
    @Test func summariesRoundTrip() async throws {
        let summary = fakeSummary(gid: 900_001)
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "UserData.store")
            do {
                let first = try UserDataStore(storeURL: url)
                try await first.addLocalFavorite(summary)
                _ = try await first.localFavorites()
            }
            let second = try UserDataStore(storeURL: url)
            #expect(try await second.localFavorites() == [Self.withoutAccountFields(summary)])
        }
    }

    /// The account's favorite category, its name, the note and its own rating (the stars when `isRatedByUser`) belong
    /// to the account signed in when the gallery was added; local favorites outlive a logout, so they are not stored.
    /// The own rating is not kept as the average either: the row would show it as the gallery's average to the next
    /// account, so the rating becomes 0, "the page shows none".
    @Test func accountFieldsAreNotStored() async throws {
        let summary = fakeSummary(gid: 900_001)
        let accountBound = summary.favoriteSlot != nil && summary.favoriteName != nil && summary.favoriteNote != nil
            && summary.isRatedByUser && summary.rating > 0
        #expect(accountBound)
        let store = try UserDataStore(inMemory: true)
        try await store.addLocalFavorite(summary)
        let stored = try #require(try await store.localFavorites().first)
        #expect(stored.favoriteSlot == nil)
        #expect(stored.favoriteName == nil)
        #expect(stored.favoriteNote == nil)
        #expect(stored.isRatedByUser == false)
        #expect(stored.rating == 0)
        #expect(stored == Self.withoutAccountFields(summary))

        // The average a row shows without an own rating is the gallery's, and stays.
        var averaged = fakeSummary(gid: 900_002)
        averaged.isRatedByUser = false
        try await store.addLocalFavorite(averaged)
        let kept = try #require(try await store.localFavorites().first { $0.id.gid == 900_002 })
        #expect(kept.rating == averaged.rating)
        #expect(kept.isRatedByUser == false)
    }

    /// `summary` with the fields of the signed-in account cleared, as `addLocalFavorite` stores it.
    private static func withoutAccountFields(_ summary: GallerySummary) -> GallerySummary {
        var summary = summary
        summary.favoriteSlot = nil
        summary.favoriteName = nil
        summary.favoriteNote = nil
        if summary.isRatedByUser { summary.rating = 0 }
        summary.isRatedByUser = false
        return summary
    }
}
