import Observation

/// What reselecting the current tab asks of its root page (Flutter `TabHomeController.onTap`,
/// tabhome_controller.dart:235-285): the first reselect scrolls to the top; a second one within
/// `TabReselectionTracker.window` scrolls to the top and refreshes.
///
/// Probe (browse B2 Step 4, iPhone Duo cover screen, iOS 27.2, before the app did anything about it):
/// - the system scrolls the root page's list to the top on every reselect by itself, so `.scrollToTop` only opens the
///   window: a root page must not scroll for it (it may count it or keep state);
/// - the `TabView` selection binding's setter runs once per tap on the selected tab's item, with the selected value,
///   which is how `RootTabView` sees reselects;
/// - on a pushed page the system goes back to the root page by itself and empties the stack's path binding, so
///   `TabRootView` leaves the path alone.
///
/// `.scrollToTopAndRefresh` is the app's own: the root page scrolls to the top itself, then refreshes. Flutter's tap on
/// the navigation title is not carried over: the title is the title menu's (M2 index §7), and the system's tap on the
/// status bar still scrolls to the top.
nonisolated enum TabReselection: Equatable, Sendable {
    case scrollToTop
    case scrollToTopAndRefresh
}

/// Tells reselects from tab switches, and a double reselect from two single ones (Flutter `doubleTapBar` with
/// `awaitComplete: false`): a reselect opens a window of `window`; another reselect of the same tab inside it is a
/// refresh and closes the window. Switching tabs closes it too. Settings ignores reselects (Flutter leaves the last tab
/// alone).
nonisolated struct TabReselectionTracker: Sendable {
    static let window: Duration = .milliseconds(800)

    /// The tab and time of the reselect whose window is open.
    private var opened: (tab: AppTab, at: ContinuousClock.Instant)?

    /// A tap on the item of `tab` while `current` is selected, at `now`: nil for a tab switch or a reselect of
    /// Settings, else what the reselect asks for.
    mutating func tap(_ tab: AppTab, current: AppTab, at now: ContinuousClock.Instant) -> TabReselection? {
        guard tab == current, tab != .settings else {
            opened = nil
            return nil
        }
        if let opened, opened.tab == tab, now - opened.at < Self.window {
            self.opened = nil
            return .scrollToTopAndRefresh
        }
        opened = (tab, now)
        return .scrollToTop
    }
}

/// One reselect of `tab`; `serial` tells two equal actions apart, so every reselect is a change.
nonisolated struct TabReselectionEvent: Equatable, Sendable {
    let tab: AppTab
    let action: TabReselection
    let serial: Int
}

/// Where `RootTabView` posts reselects (it owns one and hands it down the environment) and the tabs' pages watch
/// `latest` for theirs.
@MainActor @Observable final class TabReselectionCenter {
    private(set) var latest: TabReselectionEvent?
    @ObservationIgnored private var serial = 0

    func send(_ action: TabReselection, for tab: AppTab) {
        serial += 1
        latest = TabReselectionEvent(tab: tab, action: action, serial: serial)
    }
}
