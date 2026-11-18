import EHModels
import EHStore
import Observation

/// The translated names of the tags a list shows, read from the tag database ahead of the views (a view cannot wait
/// on the store). `name(for:)` is synchronous and observable: a view that read a name before its prefetch finished
/// shows the translation as soon as it is in.
///
/// A tag the database does not know is remembered as such until `removeAll()`, so scrolling a list never asks twice.
@MainActor @Observable final class TagNameCache {
    private let store: TagTranslationStore?
    /// Plain translated names, by tag.
    private var names: [TagRef: String] = [:]
    /// The tags already asked for, translated or not.
    @ObservationIgnored private var asked: Set<TagRef> = []
    /// Bumped by `removeAll()`: a view reads it (`.task(id:)`) to prefetch its tags again after the names were
    /// cleared. An answer that was read before the bump is dropped.
    private(set) var generation = 0

    init(store: TagTranslationStore?) {
        self.store = store
    }

    /// The translated name of `tag` (`TagTranslation.plainName`), or nil until it was prefetched or when it has none.
    func name(for tag: TagRef) -> String? {
        names[tag]
    }

    /// The names read before they are written to `names` together: every view that shows a tag depends on `names`,
    /// so each write draws all of them again (a page of 25 items has about 250 tags).
    static let batchSize = 50

    /// Reads the names of the tags not asked for yet. The store's interface is synchronous inside its actor, so this
    /// waits while an import holds it (a few seconds); the caller's view keeps showing the original names meanwhile.
    ///
    /// The names found go into `names` `batchSize` at a time and at the end, not one by one. It stops when its task
    /// is cancelled (`.task(id:)` moved on to other items) or the names were cleared (`removeAll()`): the tags not
    /// read yet stay unasked, and the names read before a clear are dropped (they may come from the database before
    /// the update).
    func prefetch(_ tags: [TagRef]) async {
        guard let store else { return }
        let started = generation
        var found: [TagRef: String] = [:]
        for tag in tags where !asked.contains(tag) {
            guard !Task.isCancelled, started == generation else { break }
            asked.insert(tag)
            let translation: TagTranslation?
            do {
                translation = try await store.translation(for: tag)
            } catch {
                // A failed read says nothing about the tag: ask again at the next prefetch.
                if started == generation { asked.remove(tag) }
                continue
            }
            if let name = translation?.plainName, !name.isEmpty {
                found[tag] = name
            }
            if found.count >= Self.batchSize {
                take(found, readIn: started)
                found = [:]
            }
        }
        take(found, readIn: started)
    }

    /// Writes `found` into `names` at once, unless the names were cleared since generation `started`.
    private func take(_ found: [TagRef: String], readIn started: Int) {
        guard !found.isEmpty, started == generation else { return }
        names.merge(found) { _, new in new }
    }

    /// Forgets every name and every answer (the tag database changed).
    func removeAll() {
        generation += 1
        names = [:]
        asked = []
    }
}
