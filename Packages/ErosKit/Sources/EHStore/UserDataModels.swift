import Foundation
import SwiftData

// The SwiftData models of `UserDataStore`. They are internal and never leave the actor: callers see EHModels values.

/// A named flag: a row with the name means the flag is set.
@Model
final class StoredFlag {
    #Unique<StoredFlag>([\.name])

    var name: String

    init(name: String) {
        self.name = name
    }
}

/// A custom group in its place in the list; `payload` is the JSON of a `CustomGroup`.
@Model
final class StoredGroup {
    #Unique<StoredGroup>([\.uuid])

    var uuid: String
    var position: Int
    var payload: Data

    init(uuid: String, position: Int, payload: Data) {
        self.uuid = uuid
        self.position = position
        self.payload = payload
    }
}

/// The record of a deleted group (kept for the WebDAV sync); `payload` is the JSON of the group as it was deleted.
@Model
final class StoredDeletedGroup {
    #Unique<StoredDeletedGroup>([\.uuid])

    var uuid: String
    var sequence: Int
    var payload: Data

    init(uuid: String, sequence: Int, payload: Data) {
        self.uuid = uuid
        self.sequence = sequence
        self.payload = payload
    }
}

/// A quick search in its place in the list (`position` counts from 0).
@Model
final class StoredQuickSearch {
    #Unique<StoredQuickSearch>([\.text])

    var text: String
    var position: Int

    init(text: String, position: Int) {
        self.text = text
        self.position = position
    }
}

/// A search history entry; the larger `sequence`, the newer.
@Model
final class StoredSearch {
    #Unique<StoredSearch>([\.text])

    var text: String
    var sequence: Int

    init(text: String, sequence: Int) {
        self.text = text
        self.sequence = sequence
    }
}

/// A local favorite; the larger `sequence`, the newer. `payload` is the JSON of a `GallerySummary`.
@Model
final class StoredLocalFavorite {
    #Unique<StoredLocalFavorite>([\.gid])

    var gid: Int
    var sequence: Int
    var payload: Data

    init(gid: Int, sequence: Int, payload: Data) {
        self.gid = gid
        self.sequence = sequence
        self.payload = payload
    }
}

extension UserDataStore {
    /// Every model kept in the user data store; a new model is added to this list.
    static var schema: Schema {
        Schema([
            StoredFlag.self, StoredGroup.self, StoredDeletedGroup.self,
            StoredQuickSearch.self, StoredSearch.self, StoredLocalFavorite.self
        ])
    }
}
