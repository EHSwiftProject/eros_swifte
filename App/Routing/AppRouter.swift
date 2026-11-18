import EHModels
import Foundation
import Observation
import SwiftUI

/// Where an external open put its route: the tab whose stack it went onto (`AppRouter.lastDelivery`).
nonisolated struct RouteDelivery: Equatable {
    let tab: AppTab
    let route: AppRoute
}

/// The selected tab and one navigation path per tab (M2 index §3.4). A tab's path is kept while other tabs are
/// selected. `AppEnvironment.router` is the app's; `RootTabView` binds the selection, each tab's `RoutedStack` its path.
///
/// External opens (entry E1; the `eros://` links of E2 and the clipboard of E3) go through `open(_:)` and
/// `open(url:)`: the route goes onto the stack of the target tab (`targetTab(shownTabs:selected:)`), which is selected.
/// Pages that follow a link themselves push onto the current stack instead (`NavigationLink(value: AppRoute(link))`).
///
/// The app has one router, which every window shares (`AppEnvironment` is the app's): the windows show the same
/// selection and stacks. The app allows one window (`UIApplicationSupportsMultipleScenes` false, user decision
/// 2026-11-17); the owners below stay, so that more windows would still be served. Each window's `RootTabView`
/// attaches as an owner of its own (`attach(shownTabs:owner:)`, once it is up and whenever the shown tabs change) and
/// detaches when it goes. The router is attached while any owner is, and an external link goes to the tabs of the
/// last attach. While no owner is, a route waits in `pending`, the last one only, so a link that came while the app
/// was still launching is opened once its tabs are there.
@MainActor @Observable final class AppRouter {
    var selectedTab: AppTab
    /// The last route opened while no window showed the tabs (the first attach delivers it); nil once delivered.
    private(set) var pending: AppRoute?
    /// The last route an external open put onto a stack, and which (for tests).
    private(set) var lastDelivery: RouteDelivery?
    /// The last URL `open(url:)` could not open, until `dismissUnopenable()`: the "Can't Open Link" alert shows it
    /// (E2).
    private(set) var unopenableURL: URL?
    /// The tabs of the last `attach(shownTabs:owner:)`; nil while detached (before the tabs show, after they all go).
    private(set) var shownTabs: [AppTab]?
    /// The windows' `RootTabView`s that show the tabs now (`attach(shownTabs:owner:)`, `detach(owner:)`).
    private(set) var owners: Set<UUID> = []
    private var paths: [AppTab: NavigationPath] = [:]
    /// Where each stack holds a hidden tab's page (`push(_:onto:)`): its index in the path, in push order. A
    /// `NavigationPath` cannot be read back, so the router keeps this itself; entries a shorter path no longer reaches
    /// (the system's back button, a reselect) are dropped whenever the path is set.
    @ObservationIgnored private var tabPages: [AppTab: [(index: Int, page: TabPage)]] = [:]

    init(selectedTab: AppTab = .gallery) {
        self.selectedTab = selectedTab
    }

    /// The path of `tab`'s stack: empty until something is pushed onto it.
    func path(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(
            get: { self.paths[tab] ?? NavigationPath() },
            set: { self.setPath($0, for: tab) }
        )
    }

    /// Pushes `route` onto the selected tab's stack.
    func push(_ route: AppRoute) {
        paths[selectedTab, default: NavigationPath()].append(route)
    }

    /// Pushes an image search page onto `tab`'s stack, whatever tab is selected now (search Q5): by value, as a route,
    /// never with `navigationDestination(isPresented:)`. Callers pass the tab selected when
    /// the user tapped, so a search's results land on the tab it was started on even when the user, or an external
    /// link, selected another meanwhile. A tab hidden in between keeps the page on its
    /// stack, out of sight; that edge is left as it is.
    func push(_ route: ImageSearchRoute, onto tab: AppTab) {
        paths[tab, default: NavigationPath()].append(route)
    }

    /// Pushes the root page of the hidden tab `page.tab` onto `tab`'s stack (`HiddenTabsToolbar`).
    func push(_ page: TabPage, onto tab: AppTab) {
        var path = paths[tab] ?? NavigationPath()
        tabPages[tab, default: []].append((path.count, page))
        path.append(page)
        paths[tab] = path
    }

    /// On every stack, pops the first page of any of `tabs` and everything above it: once a tab is shown, its root
    /// lives in its own tab item, never a second time on another stack (`RootTabView`, when the shown tabs change).
    func dropTabPages(of tabs: some Sequence<AppTab>) {
        let shown = Set(tabs)
        for (tab, pages) in tabPages {
            guard let first = pages.first(where: { shown.contains($0.page.tab) }), var path = paths[tab] else { continue }
            path.removeLast(path.count - first.index)
            setPath(path, for: tab)
        }
    }

    private func setPath(_ path: NavigationPath, for tab: AppTab) {
        paths[tab] = path
        tabPages[tab]?.removeAll { $0.index >= path.count }
    }

    // MARK: - External opens

    /// Whether some window shows the tabs: an open goes onto a stack at once, rather than waiting in `pending`.
    var isAttached: Bool { !owners.isEmpty }

    /// Opens the page of a site link (`AppRoute(link)`).
    func open(_ link: EHLink) {
        open(AppRoute(link))
    }

    /// Attached: selects the target tab (`targetTab(shownTabs:selected:)`) and pushes `route` onto its stack, above
    /// whatever it shows. Detached: `route` waits in `pending`, replacing any route already there.
    func open(_ route: AppRoute) {
        guard let shownTabs else {
            pending = route
            return
        }
        deliver(route, among: shownTabs)
    }

    /// Opens the site link `url` is, or the one an `eros://` link carries (`ErosURLScheme.link(from:)`, entry E2); any
    /// other URL is kept in `unopenableURL` instead.
    func open(url: URL) {
        guard let link = ErosURLScheme.link(from: url) else {
            unopenableURL = url
            return
        }
        open(link)
    }

    /// Forgets `unopenableURL` (its alert was answered).
    func dismissUnopenable() {
        unopenableURL = nil
    }

    /// `owner` (a window's `RootTabView`) shows the tabs, these ones (again whenever they change): later opens go
    /// onto a stack at once, at these tabs. The route in `pending`, if any, goes when the first owner comes; a route is
    /// delivered once, so attaching again or another owner coming delivers nothing more.
    func attach(shownTabs: [AppTab], owner: UUID) {
        let wasAttached = isAttached
        owners.insert(owner)
        self.shownTabs = shownTabs
        guard !wasAttached, let route = pending else { return }
        pending = nil
        deliver(route, among: shownTabs)
    }

    /// `owner` no longer shows the tabs. Once no owner does, opens wait in `pending` again until the next attach. An
    /// owner that is not attached changes nothing.
    func detach(owner: UUID) {
        guard owners.remove(owner) != nil else { return }
        if owners.isEmpty { shownTabs = nil }
    }

    /// The tab an external open goes to: Gallery when it is shown, else the selected tab when it is shown, else the
    /// first tab shown (the selection may not have caught up with the shown tabs yet).
    nonisolated static func targetTab(shownTabs: [AppTab], selected: AppTab) -> AppTab {
        if shownTabs.contains(.gallery) { return .gallery }
        if shownTabs.contains(selected) { return selected }
        return shownTabs.first ?? selected
    }

    private func deliver(_ route: AppRoute, among shownTabs: [AppTab]) {
        let tab = Self.targetTab(shownTabs: shownTabs, selected: selectedTab)
        selectedTab = tab
        push(route)
        lastDelivery = RouteDelivery(tab: tab, route: route)
    }
}
