import EHModels
import EHNetwork
import Foundation
import Observation

/// The gallery list layout (`EHModels.ListStyle`). The name clashes with SwiftUI's `ListStyle` protocol; this alias
/// makes the plain name mean the model type throughout the app. Views keep using the method form (`.listStyle(.plain)`),
/// which never names the protocol.
typealias ListStyle = EHModels.ListStyle

nonisolated extension ListStyle {
    /// The name the settings show for this layout.
    var title: String {
        switch self {
        case .list: "List - Medium"
        case .simpleList: "List - Small"
        case .waterfall: "Waterfall"
        case .waterfallLarge: "Waterfall - Large"
        case .grid: "Grid"
        }
    }
}

/// The app's own settings (M2 index §3.4), saved as JSON under `AppSettingsStore.settingsKey`.
///
/// Decoding is lenient: a missing or unreadable key takes its default, so adding a field never drops the settings
/// already stored.
nonisolated struct AppSettings: Codable, Equatable, Sendable {
    /// How gallery lists are laid out.
    var listStyle: ListStyle = .list
    /// The categories the gallery lists hide (`f_cats`).
    var categoryFilter: CategoryMask = []
    /// Whether tags are shown translated (browse B4). On by default when the first preferred language is Chinese.
    var showsTagTranslations: Bool
    /// How favorites.php orders the galleries (browse B8).
    var favoritesOrder: FavoritesOrder = .favoritedTime
    /// Whether a gallery link on the clipboard is offered when the app comes to the front (entry E3).
    var detectsClipboardLinks: Bool = false
    /// Whether the tag database updates itself at launch (browse B4).
    var updatesTagDatabaseOnLaunch: Bool = false
    /// Whether the tag database downloads through the mirror (browse B4).
    var usesTagDatabaseMirror: Bool = false

    /// The defaults; tag translations are on when the first of `preferredLanguages` is Chinese (starts with "zh").
    init(preferredLanguages: [String] = Locale.preferredLanguages) {
        showsTagTranslations = preferredLanguages.first?.hasPrefix("zh") ?? false
    }
}

nonisolated extension AppSettings {
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeIfReadable(&listStyle, forKey: .listStyle)
        container.decodeIfReadable(&categoryFilter, forKey: .categoryFilter)
        container.decodeIfReadable(&showsTagTranslations, forKey: .showsTagTranslations)
        container.decodeIfReadable(&favoritesOrder, forKey: .favoritesOrder)
        container.decodeIfReadable(&detectsClipboardLinks, forKey: .detectsClipboardLinks)
        container.decodeIfReadable(&updatesTagDatabaseOnLaunch, forKey: .updatesTagDatabaseOnLaunch)
        container.decodeIfReadable(&usesTagDatabaseMirror, forKey: .usesTagDatabaseMirror)
    }
}

/// Which favorites the Favorites tab shows (browse B8).
nonisolated enum FavoritesSelection: Codable, Hashable, Sendable {
    /// Every folder (favorites.php without `favcat`).
    case all
    /// One folder, 0–9.
    case folder(Int)
    /// The local favorites.
    case local
}

/// Where each list tab was left (browse B6–B8), saved under `AppSettingsStore.browsingKey`. Decoded as leniently as
/// `AppSettings`.
nonisolated struct BrowsingState: Codable, Equatable, Sendable {
    /// The gallery tab's custom group (browse B6); nil before one was chosen.
    var selectedGroupID: String? = nil
    /// The toplist shown (browse B7).
    var toplistPeriod: ToplistPeriod = .yesterday
    /// The favorites shown (browse B8).
    var favoritesSelection: FavoritesSelection = .all
}

nonisolated extension BrowsingState {
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeIfReadable(&selectedGroupID, forKey: .selectedGroupID)
        container.decodeIfReadable(&toplistPeriod, forKey: .toplistPeriod)
        container.decodeIfReadable(&favoritesSelection, forKey: .favoritesSelection)
    }
}

nonisolated extension KeyedDecodingContainer {
    /// Replaces `value` with the one stored under `key`; leaves it as it is when the key is missing or its value does
    /// not decode.
    fileprivate func decodeIfReadable<Value: Decodable>(_ value: inout Value, forKey key: Key) {
        if let decoded = try? decodeIfPresent(Value.self, forKey: key) {
            value = decoded
        }
    }

    /// An optional is replaced only by a value that decodes (an explicit null clears it).
    fileprivate func decodeIfReadable<Wrapped: Decodable>(_ value: inout Wrapped?, forKey key: Key) {
        guard contains(key) else { return }
        if (try? decodeNil(forKey: key)) == true {
            value = nil
        } else if let decoded = try? decode(Wrapped.self, forKey: key) {
            value = decoded
        }
    }
}

/// The app's settings, tab configuration and browsing state, each saved as JSON in `defaults` on every change and
/// read back at init (data that cannot be read gives the defaults).
///
/// `AppEnvironment` owns the one the app uses: `UserDefaults.standard` in the app; in UI testing the suite
/// `proj.eros.swifte.uitesting`, emptied at every launch; in hosted tests a random suite per environment unless the test
/// passes its own. A store made with `init(ownedSuiteNamed:)` owns its suite and removes it when it goes (so a test
/// that changes an environment's settings leaves nothing in the host app's container); one given defaults never
/// removes them.
@MainActor @Observable final class AppSettingsStore {
    static let settingsKey = "eros.settings"
    static let tabConfigurationKey = "eros.tabConfiguration"
    static let browsingKey = "eros.browsingState"

    var settings: AppSettings {
        didSet { save(settings, forKey: Self.settingsKey) }
    }

    var tabs: TabConfiguration {
        didSet { save(tabs, forKey: Self.tabConfigurationKey) }
    }

    var browsing: BrowsingState {
        didSet { save(browsing, forKey: Self.browsingKey) }
    }

    /// The suite this store made and removes when it goes (`init(ownedSuiteNamed:)`); nil for given defaults.
    @ObservationIgnored let ownedSuiteName: String?
    /// Where the settings are saved. Read-only for others: `AppEnvironment` saves the search preferences there too
    /// (search Q2), so they live and go with these settings.
    @ObservationIgnored let defaults: UserDefaults

    /// A store over `defaults`, which it never removes.
    convenience init(defaults: UserDefaults) {
        self.init(defaults: defaults, ownedSuiteName: nil)
    }

    /// A store over the suite `name` (`UserDefaults.standard` should the suite be refused, then not removed), removed
    /// with everything in it when the store goes.
    convenience init(ownedSuiteNamed name: String) {
        if let suite = UserDefaults(suiteName: name) {
            self.init(defaults: suite, ownedSuiteName: name)
        } else {
            self.init(defaults: .standard, ownedSuiteName: nil)
        }
    }

    private init(defaults: UserDefaults, ownedSuiteName: String?) {
        self.defaults = defaults
        self.ownedSuiteName = ownedSuiteName
        settings = Self.load(AppSettings.self, forKey: Self.settingsKey, from: defaults) ?? AppSettings()
        tabs = Self.load(TabConfiguration.self, forKey: Self.tabConfigurationKey, from: defaults) ?? .default
        browsing = Self.load(BrowsingState.self, forKey: Self.browsingKey, from: defaults) ?? BrowsingState()
    }

    deinit {
        // The domain is removed by name, through any instance; `UserDefaults` is thread-safe.
        if let ownedSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: ownedSuiteName)
        }
    }

    private static func load<Value: Decodable>(_ type: Value.Type, forKey key: String, from defaults: UserDefaults)
        -> Value?
    {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save(_ value: some Encodable, forKey key: String) {
        // These types always encode; a failure would leave the previous value stored.
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
