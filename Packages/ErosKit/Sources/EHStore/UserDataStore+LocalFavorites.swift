import EHModels
import Foundation
import SwiftData

extension UserDataStore {
    /// The local favorites, newest first. An entry whose payload cannot be read (a future format) is skipped here but
    /// stays in the store.
    public func localFavorites() throws -> [GallerySummary] {
        let descriptor = FetchDescriptor<StoredLocalFavorite>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        return try modelContext.fetch(descriptor).compactMap {
            try? JSONDecoder().decode(GallerySummary.self, from: $0.payload)
        }
    }

    /// Adds a favorite at the front. When the gallery id is already there nothing changes (it is not moved to the
    /// front and the stored summary is not replaced), like the Flutter app.
    ///
    /// What the row shows of the account signed in now is not stored: its favorite category, the category's name and
    /// its note (`favoriteSlot`, `favoriteName`, `favoriteNote`) are cleared and `isRatedByUser` is false. When the
    /// stars were the account's own rating (`isRatedByUser`), `rating` is that rating and not the average, so it
    /// becomes 0 (the page shows none) rather than being kept as an average; a row without an own rating keeps its
    /// average. Local favorites stay after a logout, and the next account must not see them.
    public func addLocalFavorite(_ summary: GallerySummary) throws {
        var summary = summary
        summary.favoriteSlot = nil
        summary.favoriteName = nil
        summary.favoriteNote = nil
        if summary.isRatedByUser { summary.rating = 0 }
        summary.isRatedByUser = false
        let payload = try JSONEncoder().encode(summary)
        let gid = summary.id.gid
        try write { context in
            let rows = try context.fetch(FetchDescriptor<StoredLocalFavorite>())
            guard !rows.contains(where: { $0.gid == gid }) else { return }
            let next = (rows.map(\.sequence).max() ?? 0) + 1
            context.insert(StoredLocalFavorite(gid: gid, sequence: next, payload: payload))
        }
    }

    /// Removes the favorite with this gallery id; the token is not compared. An unknown id does nothing.
    public func removeLocalFavorite(_ id: GalleryID) throws {
        let gid = id.gid
        try write { context in
            try context.delete(model: StoredLocalFavorite.self, where: #Predicate { $0.gid == gid })
        }
    }
}
