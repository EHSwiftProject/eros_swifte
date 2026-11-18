import Foundation

/// The semantics of SwiftUI's `move(fromOffsets:toOffset:)`, without importing SwiftUI.
enum ListMove {
    /// Moves the items at `offsets` so that they end up before the item that was at `toOffset`.
    ///
    /// Offsets outside the list are ignored and `toOffset` is clamped to `0...items.count`.
    static func move<T>(_ items: [T], fromOffsets offsets: IndexSet, toOffset: Int) -> [T] {
        let valid = offsets.filter { $0 >= 0 && $0 < items.count }
        guard !valid.isEmpty else { return items }
        let target = min(max(toOffset, 0), items.count)
        let moving = valid.map { items[$0] }
        let removed = Set(valid)
        var remaining = items.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        let insertAt = target - valid.filter { $0 < target }.count
        remaining.insert(contentsOf: moving, at: insertAt)
        return remaining
    }
}
