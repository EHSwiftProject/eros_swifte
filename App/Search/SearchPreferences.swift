import EHModels
import EHParsing
import Foundation
import Observation

/// The search page's own settings (M2 index §3.4, not part of `AppSettings`): whether the history shows translations,
/// and the advanced search with whether it is used (search Q3 edits them).
///
/// Decoding is lenient, as `AppSettings`'s is: a missing or unreadable field keeps its default.
nonisolated struct SearchPreferences: Codable, Equatable, Sendable {
    /// The history shows each entry translated (`SearchTermTranslator`), while tags are shown translated.
    var translatesHistory = true
    /// The advanced search applies to searches.
    var usesAdvancedSearch = false
    var advancedSearch = AdvancedSearch()

    init() {}

    /// The advanced search a search sends: nil unless it is used and sends anything
    /// (`AdvancedSearchParser.queryItems(for:)` is not empty).
    var effectiveAdvancedSearch: AdvancedSearch? {
        guard usesAdvancedSearch, !AdvancedSearchParser.queryItems(for: advancedSearch).isEmpty else { return nil }
        return advancedSearch
    }

    /// The preferences with the page range put right: a bound below 1 is no bound, and a
    /// From above To is swapped with it. The range itself stays, even with no bound left: it is the Pages switch
    /// (`AdvancedSearchParser` sends `f_sp=on` for any range). Everything else as it is.
    ///
    /// Searches always send this (`SearchModel`); the saved value becomes it only when the
    /// filters close (`SearchModel.filtersDidClose()`), so nothing is swapped while the bounds are typed.
    func normalized() -> SearchPreferences {
        guard let range = advancedSearch.pageRange else { return self }
        var from = Self.pageBound(range.from)
        var to = Self.pageBound(range.to)
        if let lower = from, let upper = to, lower > upper {
            (from, to) = (upper, lower)
        }
        var normalized = self
        normalized.advancedSearch.pageRange = PageRange(from: from, to: to)
        return normalized
    }

    /// Whether `normalized()` swaps the page bounds: both are at least 1 and From is above To. The filters say so
    /// while they are open; the swap waits for them to close, so typing is not turned around.
    var swapsPageBounds: Bool {
        guard let range = advancedSearch.pageRange,
              let from = Self.pageBound(range.from), let to = Self.pageBound(range.to) else { return false }
        return from > to
    }

    /// A page bound as a search keeps it: none below 1.
    private static func pageBound(_ bound: Int?) -> Int? {
        bound.flatMap { $0 >= 1 ? $0 : nil }
    }
}

nonisolated extension SearchPreferences {
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .translatesHistory) {
            translatesHistory = value
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .usesAdvancedSearch) {
            usesAdvancedSearch = value
        }
        if let value = try? container.decodeIfPresent(AdvancedSearch.self, forKey: .advancedSearch) {
            advancedSearch = value
        }
    }
}

/// The search preferences, saved as JSON under `key` on every change and read back at init (data that cannot be read
/// gives the defaults). `AppEnvironment` makes the one the app uses over the defaults of its `settings`
/// (`AppSettingsStore.defaults`), so it lives and goes with them.
@MainActor @Observable final class SearchPreferencesStore {
    static let key = "eros.settings.search"

    var preferences: SearchPreferences {
        didSet {
            // The type always encodes; a failure would leave the previous value stored.
            guard preferences != oldValue, let data = try? JSONEncoder().encode(preferences) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// A store over `defaults`, which it never removes.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        preferences = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(SearchPreferences.self, from: $0) } ?? SearchPreferences()
    }
}
