import Foundation
import SwiftUI

/// Which tabs the tab bar shows and in what order: the user's choice, saved by `AppSettingsStore`.
///
/// The JSON is Flutter's `tabConfig` (models/tab_config.dart, tab_item.dart):
/// `{"tabItemList":[{"name":"/gallery","enable":true},…]}`, names from `AppTab.routeName`. Settings is never in the
/// list: it is always shown, last.
///
/// Every value keeps these rules, whether made by `init(tabItemList:)` or decoded (Flutter
/// `TabHomeController.onInit`, tabhome_controller.dart:143-180, plus the four-tab limit):
/// - an unknown name, "/setting" and a repeated name are dropped; a missing tab is appended, turned off; an empty list
///   (after dropping) is `default`, as Flutter keeps its defaults when the saved list is empty;
/// - beyond the first `maximumEnabled` turned-on tabs, the rest are turned off;
/// - with none turned on, Gallery is turned on.
nonisolated struct TabConfiguration: Codable, Equatable, Sendable {
    /// One tab: its `AppTab.routeName` and whether it is shown.
    struct Item: Codable, Equatable, Sendable {
        var name: String
        var enable: Bool

        init(name: String, enable: Bool) {
            self.name = name
            self.enable = enable
        }

        /// Flutter writes `enable` as optional (`TabItem.enable`) and reads a missing one as false.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            enable = (try? container.decodeIfPresent(Bool.self, forKey: .enable)) ?? false
        }
    }

    /// The tabs in the order the user chose, each turned on or off.
    private(set) var tabItemList: [Item]

    /// The tabs the user can show or hide, in Flutter's default order (`kTabNameList`).
    static let configurableTabs: [AppTab] = [.gallery, .favorites, .toplists, .download, .history]

    /// Flutter's `kDefTabMap` in the order of `kTabNameList` (tabhome_controller.dart:69-92): History off.
    static let `default` = TabConfiguration(
        tabItemList: configurableTabs.map { Item(name: $0.routeName, enable: $0 != .history) }
    )

    /// How many tabs can be shown besides Settings (user decision 2026-11-08): more would not fit the iPhone tab bar.
    static let maximumEnabled = 4

    init(tabItemList: [Item]) {
        var seen = Set<String>()
        var items = tabItemList.filter { item in
            guard let tab = AppTab(routeName: item.name), Self.configurableTabs.contains(tab) else { return false }
            return seen.insert(item.name).inserted
        }
        guard !items.isEmpty else {
            self = .default
            return
        }
        for tab in Self.configurableTabs where !seen.contains(tab.routeName) {
            items.append(Item(name: tab.routeName, enable: false))
        }
        var enabled = 0
        for index in items.indices where items[index].enable {
            enabled += 1
            if enabled > Self.maximumEnabled { items[index].enable = false }
        }
        if enabled == 0, let gallery = items.firstIndex(where: { $0.name == AppTab.gallery.routeName }) {
            items[gallery].enable = true
        }
        self.tabItemList = items
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tabItemList: try container.decode([Item].self, forKey: .tabItemList))
    }

    /// Every configurable tab, in the user's order.
    var orderedTabs: [AppTab] { tabItemList.compactMap { AppTab(routeName: $0.name) } }

    /// The tabs the tab bar shows: the turned-on ones in order (Gallery when none is), then Settings.
    var visibleTabs: [AppTab] {
        let enabled = tabItemList.filter(\.enable).compactMap { AppTab(routeName: $0.name) }
        return (enabled.isEmpty ? [.gallery] : enabled) + [.settings]
    }

    /// The turned-off tabs, in order: the gallery, favorites and toplists pages offer them (`HiddenTabsToolbar`).
    var hiddenTabs: [AppTab] {
        let visible = visibleTabs
        return orderedTabs.filter { !visible.contains($0) }
    }

    /// Whether `tab` is shown. Settings always is.
    func isEnabled(_ tab: AppTab) -> Bool {
        tab == .settings || tabItemList.contains { $0.name == tab.routeName && $0.enable }
    }

    /// False for the last turned-on tab, and for Settings; true for a tab that is off.
    func canDisable(_ tab: AppTab) -> Bool {
        guard tab != .settings else { return false }
        return !isEnabled(tab) || enabledCount > 1
    }

    /// False while `maximumEnabled` tabs are on, and for Settings; true for a tab that is on.
    func canEnable(_ tab: AppTab) -> Bool {
        guard tab != .settings else { return false }
        return isEnabled(tab) || enabledCount < Self.maximumEnabled
    }

    /// Turns `tab` on or off; turning off the last one, past the maximum or Settings is ignored.
    mutating func setEnabled(_ enabled: Bool, for tab: AppTab) {
        guard enabled ? canEnable(tab) : canDisable(tab),
            let index = tabItemList.firstIndex(where: { $0.name == tab.routeName })
        else { return }
        tabItemList[index].enable = enabled
    }

    /// Moves tabs as `List`'s `onMove` reports it (`orderedTabs` offsets).
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabItemList.move(fromOffsets: source, toOffset: destination)
    }

    private var enabledCount: Int { tabItemList.count(where: \.enable) }
}
