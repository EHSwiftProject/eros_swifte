import EHStore
import Foundation
import Observation
import os

/// The quick search page (search Q4; Flutter `quicksearch_controller.dart`, `quick_search_page.dart`): the quick
/// searches of the user data store in their order, their translations, and the page's edits, import and export.
///
/// - A text is added normalized (`SearchText.normalized(_:)`, one line); a blank one, or one already there, is not
///   added, and nothing is said (Flutter).
/// - Removing and moving change `items` at once, for the list's animation, then the store; then the items are read
///   again, the store having the last word. The store removes by text only: the texts at the offsets go one by one, and
///   so does every one for `removeAll()`.
/// - A load that ends after a newer load, or after one of those changes of `items`, changes nothing: it read the store
///   before them.
/// - A failure of the store is logged by the error's domain and code only (`Logger.storeFailure(_:_:)`) and otherwise
///   taken as nothing changed, with no alert (as the search page, search Q2): a failed read keeps the items shown.
/// - `translations` hold the translation of each text that has one (`SearchTermTranslator`), read while tags are shown
///   translated (`AppSettings.showsTagTranslations`); none otherwise.
/// - Without a store (`isAvailable` false) there are no items and nothing can be added or imported.
@MainActor @Observable final class QuickSearchListModel {
    private static let log = Logger(subsystem: "proj.eros.swifte", category: "Search")

    /// The quick searches, in order.
    private(set) var items: [String] = []
    /// The translation of each item that has one, while tags are shown translated.
    private(set) var translations: [String: String] = [:]

    @ObservationIgnored private let userData: UserDataStore?
    @ObservationIgnored private let terms: SearchTermTranslator
    @ObservationIgnored private let settings: AppSettingsStore
    /// One more with every load and every change of `items` made here before the store's: a load that ends after a
    /// newer one, or after such a change, changes nothing.
    @ObservationIgnored private var loads = 0

    init(userData: UserDataStore?, terms: SearchTermTranslator, settings: AppSettingsStore) {
        self.userData = userData
        self.terms = terms
        self.settings = settings
    }

    /// Whether there is a store for the quick searches.
    var isAvailable: Bool {
        userData != nil
    }

    /// Reads the quick searches from the store, then their translations (see the type). Superseded by a newer load or
    /// a change of `items` meanwhile, it changes nothing; when the store cannot be read, the items and translations
    /// shown stay.
    func load() async {
        loads += 1
        let load = loads
        guard let userData else {
            items = []
            translations = [:]
            return
        }
        let texts: [String]
        do {
            texts = try await userData.quickSearches()
        } catch {
            Self.log.storeFailure("Reading the quick searches", error)
            return
        }
        guard load == loads else { return }
        items = texts
        var found: [String: String] = [:]
        if settings.settings.showsTagTranslations {
            for text in texts {
                if let translation = await terms.translation(of: text) { found[text] = translation }
            }
        }
        guard load == loads else { return }
        translations = found
    }

    /// Adds the normalized `text` after the others; false when it is blank, already there, or there is no store.
    func add(_ text: String) async -> Bool {
        let text = SearchText.normalized(text)
        guard let userData, !text.isEmpty else { return false }
        var added = false
        do {
            added = try await userData.addQuickSearch(text)
        } catch {
            Self.log.storeFailure("Adding a quick search", error)
        }
        await load()
        return added
    }

    /// Removes the items at `offsets` (`List.onDelete`).
    func remove(atOffsets offsets: IndexSet) async {
        guard let userData else { return }
        let offsets = IndexSet(offsets.filter(items.indices.contains))
        let texts = offsets.map { items[$0] }
        loads += 1
        items.removeSubranges(RangeSet(offsets, within: items))
        for text in texts {
            do {
                try await userData.removeQuickSearch(text)
            } catch {
                Self.log.storeFailure("Removing a quick search", error)
            }
        }
        await load()
    }

    /// Moves the items as `List.onMove` does.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) async {
        guard let userData else { return }
        loads += 1
        items.moveSubranges(RangeSet(offsets, within: items), to: destination)
        do {
            try await userData.moveQuickSearches(fromOffsets: offsets, toOffset: destination)
        } catch {
            Self.log.storeFailure("Moving the quick searches", error)
        }
        await load()
    }

    /// Removes every quick search the store holds (the ones shown when it cannot be read); the list empties at once.
    func removeAll() async {
        guard let userData else { return }
        let shown = items
        loads += 1
        items = []
        let texts: [String]
        do {
            texts = try await userData.quickSearches()
        } catch {
            Self.log.storeFailure("Reading the quick searches", error)
            texts = shown
        }
        for text in texts {
            do {
                try await userData.removeQuickSearch(text)
            } catch {
                Self.log.storeFailure("Removing a quick search", error)
            }
        }
        await load()
    }

    /// Imports the quick search file at `url` (`fileImporter`): its text, read as UTF-8 while the file's
    /// security-scoped resource is accessed (and all the same when that is refused, as for the app's own and temporary
    /// files), is read as a quick search file (`QuickSearchFile.parse(_:)`), each search
    /// normalized, and merged into the store after the searches there (`mergeQuickSearches(_:)`). Nothing about the
    /// file, its name, path or text, is logged.
    ///
    /// - Returns: The number of searches that were new; 0 without a store (the file is not read), or when the store
    ///   failed (logged, as any failure of the store).
    /// - Throws: When the file cannot be read (`CocoaError.fileReadUnknown`), is not UTF-8 text
    ///   (`CocoaError.fileReadInapplicableStringEncoding`), or is not a quick search file
    ///   (`QuickSearchFileError.missingHeader`). None of them carries the file's name, path or text.
    func importFile(at url: URL) async throws -> Int {
        guard let userData else { return 0 }
        let data = try await Self.contents(of: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let texts = try QuickSearchFile.parse(text).map(SearchText.normalized)
        var added = 0
        do {
            added = try await userData.mergeQuickSearches(texts)
        } catch {
            Self.log.storeFailure("Importing quick searches", error)
        }
        await load()
        return added
    }

    /// The text of the export: `QuickSearchFile.export(_:)` of the items.
    func exportText() -> String {
        QuickSearchFile.export(items)
    }

    /// The bytes of the file at `url`, read off the main actor while its security-scoped resource is accessed (when
    /// that is granted). A failure becomes `CocoaError(.fileReadUnknown)`, which carries no path.
    @concurrent private nonisolated static func contents(of url: URL) async throws -> Data {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw CocoaError(.fileReadUnknown)
        }
    }
}
