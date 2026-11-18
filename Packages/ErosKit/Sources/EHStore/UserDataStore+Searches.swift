import Foundation
import SwiftData

extension UserDataStore {
    /// The search history keeps this many entries; the oldest go first.
    private static let historyLimit = 100

    // MARK: Quick searches

    /// The quick searches in order.
    public func quickSearches() throws -> [String] {
        try Self.quickRows(in: modelContext).map(\.text)
    }

    /// Appends a quick search. The text is trimmed and compared exactly (case-sensitive).
    ///
    /// - Returns: false when the trimmed text is empty or already there; the store is then unchanged.
    public func addQuickSearch(_ text: String) throws -> Bool {
        try mergeQuickSearches([text]) > 0
    }

    /// Removes the quick search equal to the trimmed text; an unknown text does nothing.
    public func removeQuickSearch(_ text: String) throws {
        let text = Self.trimmed(text)
        try write { context in
            let rows = try Self.quickRows(in: context)
            guard let row = rows.first(where: { $0.text == text }) else { return }
            context.delete(row)
            for (index, remaining) in rows.filter({ $0 !== row }).enumerated() { remaining.position = index }
        }
    }

    /// Reorders the quick searches like `move(fromOffsets:toOffset:)`.
    public func moveQuickSearches(fromOffsets: IndexSet, toOffset: Int) throws {
        try write { context in
            let rows = try Self.quickRows(in: context)
            for (index, row) in ListMove.move(rows, fromOffsets: fromOffsets, toOffset: toOffset).enumerated() {
                row.position = index
            }
        }
    }

    /// Adds many quick searches (an import): each is trimmed and handled like `addQuickSearch`, so a repeat inside
    /// the batch counts once.
    ///
    /// - Returns: The number of searches that were new.
    public func mergeQuickSearches(_ texts: [String]) throws -> Int {
        try write { context in
            let rows = try Self.quickRows(in: context)
            var known = Set(rows.map(\.text))
            var next = rows.count
            for text in texts.map(Self.trimmed) where !text.isEmpty && known.insert(text).inserted {
                context.insert(StoredQuickSearch(text: text, position: next))
                next += 1
            }
            return next - rows.count
        }
    }

    // MARK: Search history

    /// The search history, newest first, at most 100 entries.
    public func searchHistory() throws -> [String] {
        let descriptor = FetchDescriptor<StoredSearch>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        return try modelContext.fetch(descriptor).prefix(Self.historyLimit).map(\.text)
    }

    /// Records a search: the text is trimmed (empty is ignored) and goes to the front, an older equal entry moves.
    /// Beyond 100 entries the oldest are deleted.
    public func recordSearch(_ text: String) throws {
        let text = Self.trimmed(text)
        guard !text.isEmpty else { return }
        try write { context in
            // Oldest first, so the newest sequence is the last one.
            let rows = try context.fetch(FetchDescriptor<StoredSearch>(sortBy: [SortDescriptor(\.sequence)]))
            let next = (rows.last?.sequence ?? 0) + 1
            if let index = rows.firstIndex(where: { $0.text == text }) {
                rows[index].sequence = next
            } else {
                context.insert(StoredSearch(text: text, sequence: next))
                // The new entry is the newest, so what is over the limit is the oldest of the old ones.
                for row in rows.prefix(max(0, rows.count + 1 - Self.historyLimit)) { context.delete(row) }
            }
        }
    }

    /// Removes the history entry equal to the trimmed text; an unknown text does nothing.
    public func removeSearch(_ text: String) throws {
        let text = Self.trimmed(text)
        try write { context in
            for row in try context.fetch(FetchDescriptor<StoredSearch>()) where row.text == text {
                context.delete(row)
            }
        }
    }

    /// Deletes the whole search history.
    public func clearSearchHistory() throws {
        try write { context in
            try context.delete(model: StoredSearch.self)
        }
    }

    // MARK: Internals

    private static func quickRows(in context: ModelContext) throws -> [StoredQuickSearch] {
        try context.fetch(FetchDescriptor<StoredQuickSearch>(sortBy: [SortDescriptor(\.position)]))
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
