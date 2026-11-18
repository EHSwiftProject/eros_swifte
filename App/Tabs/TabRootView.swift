import SwiftUI

/// A hidden tab's root page pushed onto the current tab's stack (`HiddenTabsToolbar`, through
/// `AppRouter.push(_:onto:)`, which keeps track of it: once the tab is shown, the page goes). Plain data, compared by
/// value.
nonisolated struct TabPage: Hashable, Sendable {
    let tab: AppTab
}

/// What a tab item shows (settings too): the tab's `RoutedStack` around its root page (`TabRootContent`). The gallery,
/// favorites and toplists roots offer the hidden tabs (`HiddenTabsToolbar`, Flutter default_tabview_controller.dart:
/// 230-343), each pushed onto this stack as a `TabPage`. Reselecting the tab on a pushed page needs nothing here: the
/// system goes back to the root and empties the path itself (`TabReselection`).
struct TabRootView: View {
    /// The roots that offer the hidden tabs.
    static let offersHiddenTabs: Set<AppTab> = [.gallery, .favorites, .toplists]

    @Environment(AppEnvironment.self) private var environment
    private let tab: AppTab

    init(tab: AppTab) {
        self.tab = tab
    }

    var body: some View {
        let router = environment.router
        RoutedStack(tab: tab) {
            TabRootContent(tab: tab)
                .toolbar {
                    if Self.offersHiddenTabs.contains(tab) {
                        HiddenTabsToolbar(hidden: environment.settings.tabs.hiddenTabs) { hidden in
                            router.push(TabPage(tab: hidden), onto: tab)
                        }
                    }
                }
                .navigationDestination(for: TabPage.self) { page in
                    TabRootContent(tab: page.tab)
                }
        }
        // The Duo's fold, read once on the whole page for every page of the stack (`keepsClearOfFold`, D2).
        .foldReader()
    }
}

/// A tab's root page without its stack, identified `<rawValue>.root`: Settings' form, the gallery's custom groups
/// (`GalleryRootView`, browse B6), the favorites (`FavoritesRootView`, browse B8), the toplists (`ToplistsRootView`,
/// browse B7), or the temporary `TabScaffold` of the others (downloads and history come in M5 and M3).
struct TabRootContent: View {
    private let tab: AppTab

    init(tab: AppTab) {
        self.tab = tab
    }

    var body: some View {
        content.accessibilityIdentifier("\(tab.rawValue).root")
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .settings:
            SettingsRootView()
        case .gallery:
            GalleryRootView()
        case .favorites:
            FavoritesRootView()
        case .toplists:
            ToplistsRootView()
        case .download, .history:
            TabScaffold(tab: tab)
        }
    }
}

/// The hidden tabs, in the navigation placement: one hidden tab is its own button (`hiddenTabs.<rawValue>`); two or
/// more are a menu (`hiddenTabs.menu`); none, nothing. Every item is a `Label`, so the Duo rail shows its symbol and
/// the menu its symbol and title. Low visibility priority (U6): on the Duo's cover screen held sideways, where five
/// tabs leave the rail room for one item above them, it goes to the overflow menu before Search does.
struct HiddenTabsToolbar: ToolbarContent {
    private let hidden: [AppTab]
    private let open: (AppTab) -> Void

    init(hidden: [AppTab], open: @escaping (AppTab) -> Void) {
        self.hidden = hidden
        self.open = open
    }

    var body: some ToolbarContent {
        if hidden.count == 1, let tab = hidden.first {
            ToolbarItem(placement: .navigation) {
                Button {
                    open(tab)
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .accessibilityIdentifier("hiddenTabs.\(tab.rawValue)")
            }
            .visibilityPriority(.low)
        } else if hidden.count > 1 {
            ToolbarItem(placement: .navigation) {
                Menu {
                    ForEach(hidden) { tab in
                        Button {
                            open(tab)
                        } label: {
                            Label(tab.title, systemImage: tab.systemImage)
                        }
                    }
                } label: {
                    Label("Hidden Tabs", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("hiddenTabs.menu")
            }
            .visibilityPriority(.low)
        }
    }
}
