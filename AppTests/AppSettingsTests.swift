import EHModels
import EHNetwork
import Foundation
import Testing

@testable import Eros

/// `AppSettings`, `BrowsingState` and `AppSettingsStore`: the defaults, lenient decoding and saving every change.
/// Every test has a suite of its own, removed at the end.
@MainActor @Suite struct AppSettingsTests {
    /// A fresh, empty suite and its name.
    private static func makeDefaults() throws -> (defaults: UserDefaults, name: String) {
        let name = "proj.eros.swifte.tests.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    @Test func defaultsFollowTheIndex() {
        let settings = AppSettings(preferredLanguages: ["en-US"])
        #expect(settings.listStyle == .list)
        #expect(settings.categoryFilter == [])
        #expect(settings.favoritesOrder == .favoritedTime)
        #expect(!settings.detectsClipboardLinks)
        #expect(!settings.updatesTagDatabaseOnLaunch)
        #expect(!settings.usesTagDatabaseMirror)

        let browsing = BrowsingState()
        #expect(browsing.selectedGroupID == nil)
        #expect(browsing.toplistPeriod == .yesterday)
        #expect(browsing.favoritesSelection == .all)
    }

    @Test func listStylesHaveTheirTitles() {
        #expect(
            ListStyle.allCases.map(\.title)
                == ["List - Medium", "List - Small", "Waterfall", "Waterfall - Large", "Grid"]
        )
    }

    @Test func tagTranslationsDefaultOnForChinese() {
        #expect(AppSettings(preferredLanguages: ["zh-Hans-CN"]).showsTagTranslations)
        #expect(AppSettings(preferredLanguages: ["zh-Hant-TW", "en-US"]).showsTagTranslations)
        #expect(!AppSettings(preferredLanguages: ["en-US"]).showsTagTranslations)
        // Only the first language counts.
        #expect(!AppSettings(preferredLanguages: ["en-US", "zh-Hans-CN"]).showsTagTranslations)
        #expect(!AppSettings(preferredLanguages: []).showsTagTranslations)
    }

    @Test func missingKeysTakeDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"listStyle":"grid"}"#.utf8))
        var expected = AppSettings()
        expected.listStyle = .grid
        #expect(decoded == expected)

        // An unreadable value takes its default too; the readable ones are kept.
        let mixed = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"listStyle":"waterfall","favoritesOrder":"bogus","detectsClipboardLinks":true}"#.utf8)
        )
        #expect(mixed.listStyle == .waterfall)
        #expect(mixed.favoritesOrder == .favoritedTime)
        #expect(mixed.detectsClipboardLinks)

        let browsing = try JSONDecoder().decode(BrowsingState.self, from: Data(#"{"toplistPeriod":13}"#.utf8))
        #expect(browsing == BrowsingState(selectedGroupID: nil, toplistPeriod: .month, favoritesSelection: .all))
    }

    @Test func storeSavesEveryChange() throws {
        let (defaults, name) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppSettingsStore(defaults: defaults)
        store.settings.listStyle = .waterfallLarge
        store.settings.categoryFilter = CategoryMask(rawValue: 5)
        store.settings.showsTagTranslations.toggle()
        store.settings.favoritesOrder = .postedTime
        store.settings.detectsClipboardLinks = true
        store.tabs.setEnabled(false, for: .favorites)
        store.tabs.move(fromOffsets: [4], toOffset: 0)
        store.browsing.selectedGroupID = "group-1"
        store.browsing.toplistPeriod = .month
        store.browsing.favoritesSelection = .folder(3)

        #expect(defaults.data(forKey: "eros.settings") != nil)
        #expect(defaults.data(forKey: "eros.tabConfiguration") != nil)
        #expect(defaults.data(forKey: "eros.browsingState") != nil)

        let reread = AppSettingsStore(defaults: try #require(UserDefaults(suiteName: name)))
        #expect(reread.settings == store.settings)
        #expect(reread.tabs == store.tabs)
        #expect(reread.browsing == store.browsing)
        #expect(reread.tabs.tabItemList.first?.name == "/history")
        #expect(reread.browsing.favoritesSelection == .folder(3))
    }

    @Test func unreadableDataFallsBackToDefaults() throws {
        let (defaults, name) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("not json".utf8), forKey: "eros.settings")
        defaults.set("a string, not data", forKey: "eros.tabConfiguration")
        defaults.set(Data("[1, 2]".utf8), forKey: "eros.browsingState")

        let store = AppSettingsStore(defaults: defaults)
        #expect(store.settings == AppSettings())
        #expect(store.tabs == .default)
        #expect(store.browsing == BrowsingState())
    }

    @Test func eachEnvironmentKeepsItsOwnSettings() throws {
        let first = AppEnvironment(uiTesting: true)
        let second = AppEnvironment(uiTesting: true)
        first.settings.settings.listStyle = .grid
        first.settings.tabs.setEnabled(false, for: .download)
        #expect(second.settings.settings.listStyle == .list)
        #expect(second.settings.tabs == .default)
        let firstSuite = try #require(first.settings.ownedSuiteName)
        #expect(firstSuite.hasPrefix("proj.eros.swifte.tests."))
        #expect(firstSuite != second.settings.ownedSuiteName)

        // Given defaults are the environment's own, and not its to remove.
        let (defaults, name) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let given = AppEnvironment(uiTesting: true, settingsDefaults: defaults)
        given.settings.browsing.toplistPeriod = .allTime
        #expect(given.settings.ownedSuiteName == nil)
        #expect(AppSettingsStore(defaults: defaults).browsing.toplistPeriod == .allTime)
    }

    /// The random suite of an environment made without `settingsDefaults` goes with the environment, so tests that
    /// change its settings leave nothing behind.
    @Test func anEnvironmentRemovesItsOwnSuiteWhenItGoes() throws {
        let suite = try Self.writeSettings(through: AppEnvironment(uiTesting: true))
        #expect(Self.isEmpty(suite))
    }

    /// The same for a store that owns its suite; a store given defaults leaves them alone.
    @Test func aStoreRemovesOnlyTheSuiteItOwns() throws {
        let owned = "proj.eros.swifte.tests.settings.\(UUID().uuidString)"
        do {
            let store = AppSettingsStore(ownedSuiteNamed: owned)
            store.settings.listStyle = .grid
            #expect(store.ownedSuiteName == owned)
            #expect(!Self.isEmpty(owned))
        }
        #expect(Self.isEmpty(owned))

        let (defaults, name) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        do {
            let store = AppSettingsStore(defaults: defaults)
            store.settings.listStyle = .grid
            #expect(store.ownedSuiteName == nil)
        }
        #expect(!Self.isEmpty(name))
    }

    /// Changes a setting through `environment`, checks it reached the environment's own suite, and returns the suite's
    /// name once the environment is gone.
    private static func writeSettings(through environment: AppEnvironment) throws -> String {
        let suite = try #require(environment.settings.ownedSuiteName)
        environment.settings.settings.listStyle = .grid
        #expect(!isEmpty(suite))
        return suite
    }

    /// Whether the suite `name` holds nothing: a removed domain reads back as an empty one, not as nil.
    private static func isEmpty(_ name: String) -> Bool {
        (UserDefaults.standard.persistentDomain(forName: name) ?? [:]).isEmpty
    }
}
