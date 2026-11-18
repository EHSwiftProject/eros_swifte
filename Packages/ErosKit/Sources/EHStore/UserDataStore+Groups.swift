import EHModels
import Foundation
import SwiftData

/// Errors of the user data store that the UI reports to the user.
public enum UserDataError: Error, Equatable {
    /// A group name that is empty after trimming whitespace.
    case emptyGroupName
}

extension UserDataStore {
    private static let groupsSeededFlag = "groupsSeeded"

    // MARK: Public API

    /// The custom groups in order. The first read writes `seed()` into the store and sets the `groupsSeeded` flag;
    /// once the flag exists the store is only read and `seed` is not called, even when the list is empty.
    public func groups(seed: @Sendable () -> [CustomGroup]) throws -> [CustomGroup] {
        if try !isSeeded() {
            let seeds = seed()
            try write { context in
                for (index, group) in seeds.enumerated() {
                    context.insert(StoredGroup(uuid: group.uuid, position: index, payload: try Self.encode(group)))
                }
                Self.markSeeded(in: context)
            }
        }
        return try storedGroups().compactMap { Self.decode($0.payload) }
    }

    /// Saves a group: same uuid replaces in place, else same name replaces in place (taking the new uuid), else the
    /// group goes to the end. The name is trimmed and `lastEditTime` is set to now.
    ///
    /// - Throws: `UserDataError.emptyGroupName` when the name is blank; the store is then unchanged.
    public func saveGroup(_ group: CustomGroup) throws {
        var group = group
        group.name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !group.name.isEmpty else { throw UserDataError.emptyGroupName }
        group.lastEditTime = Int(Date().timeIntervalSince1970 * 1000)
        let payload = try Self.encode(group)
        try write { context in
            let rows = try Self.rows(in: context)
            if let row = rows.first(where: { $0.uuid == group.uuid }) {
                row.payload = payload
            } else if let row = rows.first(where: { Self.decode($0.payload)?.name == group.name }) {
                row.uuid = group.uuid
                row.payload = payload
            } else {
                context.insert(StoredGroup(uuid: group.uuid, position: rows.count, payload: payload))
            }
            Self.markSeeded(in: context)
        }
    }

    /// Deletes a group and records it as deleted (the newest record last). An unknown uuid does nothing.
    public func deleteGroup(uuid: String) throws {
        try write { context in
            let rows = try Self.rows(in: context)
            guard let row = rows.first(where: { $0.uuid == uuid }) else { return }
            let records = try context.fetch(FetchDescriptor<StoredDeletedGroup>())
            let next = (records.map(\.sequence).max() ?? 0) + 1
            if let old = records.first(where: { $0.uuid == uuid }) {
                old.payload = row.payload
                old.sequence = next
            } else {
                context.insert(StoredDeletedGroup(uuid: uuid, sequence: next, payload: row.payload))
            }
            context.delete(row)
            for (index, remaining) in rows.filter({ $0 !== row }).enumerated() { remaining.position = index }
            Self.markSeeded(in: context)
        }
    }

    /// Reorders the groups like `move(fromOffsets:toOffset:)`; `lastEditTime` stays as it is.
    public func moveGroups(fromOffsets: IndexSet, toOffset: Int) throws {
        try write { context in
            let rows = try Self.rows(in: context)
            // Rows whose payload cannot be read keep their slot; only the readable ones are reordered.
            let readable = rows.filter { Self.decode($0.payload) != nil }
            var moved = ListMove.move(readable, fromOffsets: fromOffsets, toOffset: toOffset).makeIterator()
            for (index, row) in rows.enumerated() {
                let target = Self.decode(row.payload) == nil ? row : moved.next() ?? row
                target.position = index
            }
            Self.markSeeded(in: context)
        }
    }

    /// The deletion records (the groups as they were deleted), oldest first.
    public func deletedGroups() throws -> [CustomGroup] {
        let descriptor = FetchDescriptor<StoredDeletedGroup>(sortBy: [SortDescriptor(\.sequence)])
        return try modelContext.fetch(descriptor).compactMap { Self.decode($0.payload) }
    }

    // MARK: Internals

    private func isSeeded() throws -> Bool {
        let name = Self.groupsSeededFlag
        let descriptor = FetchDescriptor<StoredFlag>(predicate: #Predicate { $0.name == name })
        return try !modelContext.fetch(descriptor).isEmpty
    }

    private func storedGroups() throws -> [StoredGroup] {
        try Self.rows(in: modelContext)
    }

    private static func rows(in context: ModelContext) throws -> [StoredGroup] {
        try context.fetch(FetchDescriptor<StoredGroup>(sortBy: [SortDescriptor(\.position)]))
    }

    private static func markSeeded(in context: ModelContext) {
        let name = groupsSeededFlag
        let descriptor = FetchDescriptor<StoredFlag>(predicate: #Predicate { $0.name == name })
        if (try? context.fetch(descriptor))?.isEmpty ?? true {
            context.insert(StoredFlag(name: name))
        }
    }

    private static func encode(_ group: CustomGroup) throws -> Data {
        try JSONEncoder().encode(group)
    }

    /// Nil when the payload cannot be read (a future format): such rows are skipped, never deleted, never thrown.
    private static func decode(_ payload: Data) -> CustomGroup? {
        try? JSONDecoder().decode(CustomGroup.self, from: payload)
    }
}
