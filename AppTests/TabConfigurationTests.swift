import Foundation
import Testing

@testable import Eros

/// `TabConfiguration`: Flutter's `tabConfig` JSON, the defaults and the rules for showing and hiding tabs.
@Suite struct TabConfigurationTests {
    private typealias Item = TabConfiguration.Item

    private static func decode(_ json: String) throws -> TabConfiguration {
        try JSONDecoder().decode(TabConfiguration.self, from: Data(json.utf8))
    }

    @Test func defaultMatchesFlutter() {
        // kDefTabMap in the order of kTabNameList (tabhome_controller.dart:69-92).
        #expect(TabConfiguration.default.tabItemList == [
            Item(name: "/gallery", enable: true),
            Item(name: "/favorite", enable: true),
            Item(name: "/toplist", enable: true),
            Item(name: "/download", enable: true),
            Item(name: "/history", enable: false),
        ])
        #expect(TabConfiguration.default.visibleTabs == [.gallery, .favorites, .toplists, .download, .settings])
        #expect(TabConfiguration.default.hiddenTabs == [.history])
        #expect(TabConfiguration.maximumEnabled == 4)
    }

    @Test func routeNamesMatchFlutter() {
        // EHRoutes (route/routes.dart:48-53).
        #expect(AppTab.allCases.map(\.routeName) == [
            "/gallery", "/favorite", "/toplist", "/download", "/history", "/setting",
        ])
        for tab in AppTab.allCases {
            #expect(AppTab(routeName: tab.routeName) == tab)
        }
        #expect(AppTab(routeName: "/foo") == nil)
    }

    @Test func flutterJSONRoundTrips() throws {
        let json = """
            {"tabItemList":[{"name":"/toplist","enable":true},{"name":"/gallery","enable":true},\
            {"name":"/history","enable":true},{"name":"/favorite","enable":false},{"name":"/download","enable":false}]}
            """
        let encoded = try JSONEncoder().encode(try Self.decode(json))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["tabItemList"])
        let items = try #require(object["tabItemList"] as? [[String: Any]])
        for item in items {
            #expect(Set(item.keys) == ["name", "enable"])
        }
        #expect(items.map { $0["name"] as? String } == ["/toplist", "/gallery", "/history", "/favorite", "/download"])
        #expect(items.map { $0["enable"] as? Bool } == [true, true, true, false, false])
    }

    @Test func decodingDropsUnknownAndAppendsMissing() throws {
        let configuration = try Self.decode("""
            {"tabItemList":[{"name":"/gallery","enable":true},{"name":"/setting","enable":true},\
            {"name":"/favorite","enable":true},{"name":"/foo","enable":true},{"name":"/toplist","enable":false},\
            {"name":"/download","enable":true}]}
            """)
        #expect(configuration.tabItemList == [
            Item(name: "/gallery", enable: true),
            Item(name: "/favorite", enable: true),
            Item(name: "/toplist", enable: false),
            Item(name: "/download", enable: true),
            Item(name: "/history", enable: false),
        ])
        // The init applies the same rules (a repeated name keeps its first entry).
        #expect(TabConfiguration(tabItemList: [
            Item(name: "/download", enable: true), Item(name: "/download", enable: false),
            Item(name: "/setting", enable: false),
        ]).tabItemList == [
            Item(name: "/download", enable: true),
            Item(name: "/gallery", enable: false),
            Item(name: "/favorite", enable: false),
            Item(name: "/toplist", enable: false),
            Item(name: "/history", enable: false),
        ])
    }

    @Test func visibleTabsEndWithSettings() throws {
        let configuration = try Self.decode("""
            {"tabItemList":[{"name":"/history","enable":true},{"name":"/gallery","enable":false},\
            {"name":"/toplist","enable":true},{"name":"/favorite","enable":false},{"name":"/download","enable":true}]}
            """)
        #expect(configuration.visibleTabs == [.history, .toplists, .download, .settings])
        #expect(configuration.hiddenTabs == [.gallery, .favorites])
    }

    @Test func noEnabledTabFallsBackToGallery() throws {
        let configuration = try Self.decode("""
            {"tabItemList":[{"name":"/favorite","enable":false},{"name":"/gallery","enable":false},\
            {"name":"/toplist","enable":false},{"name":"/download","enable":false},{"name":"/history","enable":false}]}
            """)
        #expect(configuration.visibleTabs == [.gallery, .settings])
        #expect(configuration.hiddenTabs == [.favorites, .toplists, .download, .history])
        #expect(!configuration.canDisable(.gallery))
    }

    @Test func lastEnabledTabCannotBeDisabled() {
        var configuration = TabConfiguration(tabItemList: [
            Item(name: "/gallery", enable: false), Item(name: "/download", enable: true),
        ])
        #expect(configuration.visibleTabs == [.download, .settings])
        #expect(!configuration.canDisable(.download))
        #expect(!configuration.canDisable(.settings))
        configuration.setEnabled(false, for: .download)
        #expect(configuration.visibleTabs == [.download, .settings])

        configuration.setEnabled(true, for: .gallery)
        #expect(configuration.canDisable(.download))
        configuration.setEnabled(false, for: .download)
        #expect(configuration.visibleTabs == [.gallery, .settings])
    }

    @Test func atMostFourTabsBesidesSettings() {
        var configuration = TabConfiguration.default
        #expect(!configuration.canEnable(.history))
        #expect(configuration.canEnable(.gallery))
        configuration.setEnabled(true, for: .history)
        #expect(configuration.visibleTabs == [.gallery, .favorites, .toplists, .download, .settings])

        configuration.setEnabled(false, for: .favorites)
        #expect(configuration.canEnable(.history))
        configuration.setEnabled(true, for: .history)
        #expect(configuration.visibleTabs == [.gallery, .toplists, .download, .history, .settings])
        #expect(!configuration.canEnable(.favorites))
    }

    @Test func decodingKeepsAtMostFourEnabled() throws {
        let configuration = try Self.decode("""
            {"tabItemList":[{"name":"/gallery","enable":true},{"name":"/history","enable":true},\
            {"name":"/favorite","enable":true},{"name":"/toplist","enable":true},{"name":"/download","enable":true}]}
            """)
        #expect(configuration.tabItemList.map(\.enable) == [true, true, true, true, false])
        #expect(configuration.visibleTabs == [.gallery, .history, .favorites, .toplists, .settings])
        #expect(configuration.hiddenTabs == [.download])
    }

    @Test func moveReorders() {
        var configuration = TabConfiguration.default
        configuration.move(fromOffsets: [4], toOffset: 0)
        #expect(configuration.tabItemList.map(\.name) == ["/history", "/gallery", "/favorite", "/toplist", "/download"])
        #expect(configuration.visibleTabs == [.gallery, .favorites, .toplists, .download, .settings])

        configuration.move(fromOffsets: [3], toOffset: 1)
        #expect(configuration.tabItemList.map(\.name) == ["/history", "/toplist", "/gallery", "/favorite", "/download"])
        #expect(configuration.visibleTabs == [.toplists, .gallery, .favorites, .download, .settings])
        #expect(configuration.orderedTabs == [.history, .toplists, .gallery, .favorites, .download])
    }
}
