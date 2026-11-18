import SwiftUI

/// The app's root container: a system `TabView` that adapts between a tab bar and a sidebar. Placement of tab items
/// (tab bar, sidebar or the iPhone Duo cover-screen rail) is left entirely to the system. Every tab item carries
/// `AppTab.customizationID` (`tab.<rawValue>`) as its accessibility identifier, which UI tests look it up by.
///
/// The tabs are the user's (`TabConfiguration.visibleTabs`, Settings last): the app keeps their order and visibility
/// itself (browse B2), not the system's tab customization, which the iPhone ignores. Each shows its `TabRootView`. The
/// selection is `AppRouter.selectedTab`; one that is no longer shown becomes the first tab shown, and every stack
/// drops the pages of the tabs now shown (`AppRouter.dropTabPages(of:)`). A tap on the selected tab's item goes to
/// `TabReselectionTracker`, and what it makes of it to the `TabReselectionCenter` this view owns and hands down the
/// environment.
///
/// Once it is up, and whenever the shown tabs change, it attaches the router to them after that selection fix
/// (`AppRouter.attach(shownTabs:owner:)`, entry E1), as an owner of its own (`routerOwner`; every window has its
/// `RootTabView`, and they share the router): a link opened from outside goes onto a shown tab's stack, and one that
/// came before the tabs showed (while `LaunchGate` waited) goes now. It detaches as that owner when it goes, so the
/// router stays attached while another window shows the tabs, and attaches again when it comes back (a full-screen
/// page over the tabs makes them go and come back without a change of the shown tabs, which `onChange(initial:)`
/// would not see; `attach` delivers nothing twice). All three sit outside `.id(visible)`: inside, the old `TabView`
/// going would detach the router right after a change of the shown tabs attached it again.
///
/// The `TabView` is made anew whenever the shown tabs or their order change (iOS 27.2): one
/// that is given its tabs in a new order draws them wrong (on the Duo rail, moving Toplists first showed Favorites'
/// symbol twice and no Gallery, the tab items staying in the old order), and a tab item added to a `TabView` already
/// made gets no accessibility identifier. Being made anew costs each tab's root page its view state; the stacks keep
/// their pages, since the paths are the router's (Settings' Tab Bar page is one of them, so the user stays there).
///
/// It also hosts the app's alerts (`alertHost()`) and shows the site setting questions (`SiteSettingNoticeCenter`) as
/// a system alert with two buttons (user decision 2026-11-05), above any sheet, the "Can't Open Link" alert for a
/// URL the router could not open (`unopenableLinkAlert()`, entry E2) and the "Open Link?" alert for a site link found
/// in the clipboard (`clipboardOfferAlert()`, entry E3).
struct RootTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var reselection = TabReselectionCenter()
    @State private var tracker = TabReselectionTracker()
    /// Who this view is to the router, which every window's `RootTabView` attaches to.
    @State private var routerOwner = UUID()

    var body: some View {
        let visible = environment.settings.tabs.visibleTabs
        TabView(selection: selection(among: visible)) {
            ForEach(visible) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    TabRootView(tab: tab)
                }
                .accessibilityIdentifier(tab.customizationID)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .id(visible)
        .environment(reselection)
        .onChange(of: visible, initial: true) { _, visible in
            attachRouter(to: visible)
        }
        .onAppear { attachRouter(to: visible) }
        .onDisappear { environment.router.detach(owner: routerOwner) }
        .alertHost()
        .siteSettingNoticeAlert()
        .unopenableLinkAlert()
        .clipboardOfferAlert()
    }

    /// The selection fixed (the first of `visible` when the selected tab is not among them), every stack without the
    /// pages of the tabs now shown, then the router attached to `visible` as this view's owner. Running it again
    /// changes nothing.
    private func attachRouter(to visible: [AppTab]) {
        let router = environment.router
        if !visible.contains(router.selectedTab), let first = visible.first {
            router.selectedTab = first
        }
        router.dropTabPages(of: visible)
        router.attach(shownTabs: visible, owner: routerOwner)
    }

    /// `router.selectedTab` (the first of `visible` while it is not among them); setting the tab already selected is a
    /// reselect.
    private func selection(among visible: [AppTab]) -> Binding<AppTab> {
        let router = environment.router
        let reselection = reselection
        func current() -> AppTab {
            visible.contains(router.selectedTab) ? router.selectedTab : (visible.first ?? .settings)
        }
        return Binding(
            get: { current() },
            set: { tab in
                if let action = tracker.tap(tab, current: current(), at: .now) {
                    reselection.send(action, for: tab)
                }
                if router.selectedTab != tab {
                    router.selectedTab = tab
                }
            }
        )
    }
}
