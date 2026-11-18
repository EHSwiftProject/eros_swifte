import XCTest

/// UI tests for the tab container (browse B2): the visible and hidden tabs, the Tab Bar settings, the routed stack and
/// reselecting a tab.
///
/// Tab items, rows and the back button are found by accessibility identifier with the shared helpers
/// (`UITestSupport.swift`), never via `tabBars` or `navigationBars`: on the iPhone Duo the system moves them into a
/// vertical rail (tab items sit under a toolbar, the back button outside the navigation bar), and on iPad the tabs may
/// render as a sidebar. Menu items carry no identifier on iOS 27.2, so they are found by title.
///
/// The gallery tab opens on its first group, Popular, a single page; the tests on the list pick the Gallery group (the
/// front page) in the title menu first (browse B6).
final class TabContainerTests: XCTestCase {
    /// The tabs shown by default (`TabConfiguration.default`), as `AppTab.rawValue`; each root page is `<raw>.root`.
    private static let visibleTabs = ["gallery", "favorites", "toplists", "download", "settings"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testVisibleTabsAreSelectable() {
        let app = launchApp()
        for tab in Self.visibleTabs {
            selectTab(tab, in: app)
            XCTAssertTrue(element("\(tab).root", in: app).waitForExistence(timeout: 5), "Root page of \(tab) did not appear")
        }
    }

    @MainActor
    func testHistoryStartsHiddenAndOpensFromGallery() {
        let app = launchApp()
        selectTab("gallery", in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 5), "Gallery root page did not appear")
        XCTAssertFalse(element("tab.history", in: app).exists, "History has a tab item")
        // On the bar or in the overflow menu, where it has no identifier: a five-tab rail on the cover screen held
        // sideways leaves room for one toolbar item, the overflow button. The screenshot then shows the open menu.
        guard let entry = toolbarItem("hiddenTabs.history", title: "History", in: app) else {
            attachElementTree(of: app)
            XCTFail("No hidden History entry")
            return
        }
        attachScreenshot("b2-gallery", of: app)

        entry.tap()
        XCTAssertTrue(element("history.root", in: app).waitForExistence(timeout: 5), "History page did not open")
        attachScreenshot("b2-history", of: app)

        goBack(in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 5), "Gallery did not reappear")
        XCTAssertTrue(element("history.root", in: app).waitForNonExistence(timeout: 5), "History is still shown")
    }

    @MainActor
    func testTabSettingsShowAndHideTabs() {
        let app = launchApp()
        openTabSettings(in: app)
        let history = app.switches.matching(identifier: "tabSettings.toggle.history").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5), "No History switch")
        XCTAssertFalse(history.isEnabled, "History can be turned on while four tabs are shown")

        setTab("favorites", shown: false, in: app)
        XCTAssertTrue(element("tab.favorites", in: app).waitForNonExistence(timeout: 5), "Favorites kept its tab item")
        XCTAssertTrue(wait(for: history, toBeEnabled: true), "History cannot be turned on with three tabs shown")

        selectTab("gallery", in: app)
        tapToolbarItem("hiddenTabs.menu", title: "Hidden Tabs", in: app)
        XCTAssertNotNil(hittableMenuItem("Favorites", in: app), "The hidden tabs menu has no Favorites")
        let historyItem = hittableMenuItem("History", in: app)
        XCTAssertNotNil(historyItem, "The hidden tabs menu has no History")
        attachScreenshot("b2-hiddenMenu", of: app)
        historyItem?.tap()
        XCTAssertTrue(element("history.root", in: app).waitForExistence(timeout: 5), "History did not open from the menu")
        goBack(in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 5), "Gallery did not reappear")

        selectTab("settings", in: app)
        setTab("history", shown: true, in: app)
        XCTAssertTrue(element("tab.history", in: app).waitForExistence(timeout: 5), "History got no tab item")
        attachScreenshot("b2-tabSettings", of: app)
        selectTab("history", in: app)
        XCTAssertTrue(element("history.root", in: app).waitForExistence(timeout: 5), "The History tab did not open")

        selectTab("gallery", in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 5), "Gallery did not reappear")
        // Looked for before the overflow menu may open below, on the page's own toolbar.
        XCTAssertFalse(element("hiddenTabs.menu", in: app).exists, "The hidden tabs menu is still shown")
        // On the bar or in the overflow menu, where it has no identifier: with five tabs the cover screen's sideways
        // rail leaves room for one toolbar item, the overflow button.
        XCTAssertTrue(
            toolbarOffers("hiddenTabs.favorites", title: "Favorites", in: app), "No hidden Favorites entry"
        )
    }

    @MainActor
    func testTheLastVisibleTabCannotBeHidden() {
        let app = launchApp()
        openTabSettings(in: app)
        for tab in ["favorites", "toplists", "download"] {
            setTab(tab, shown: false, in: app)
        }
        let gallery = app.switches.matching(identifier: "tabSettings.toggle.gallery").firstMatch
        XCTAssertTrue(wait(for: gallery, toBeEnabled: false), "The last visible tab can be hidden")
        XCTAssertEqual(gallery.value as? String, "1")
        XCTAssertTrue(app.switches.matching(identifier: "tabSettings.toggle.history").firstMatch.isEnabled)
    }

    @MainActor
    func testDraggingReordersTheTabs() {
        let app = launchApp()
        openTabSettings(in: app)
        let gallery = app.switches.matching(identifier: "tabSettings.toggle.gallery").firstMatch
        let history = app.switches.matching(identifier: "tabSettings.toggle.history").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5), "No History switch")
        XCTAssertLessThan(gallery.frame.minY, history.frame.minY)

        drag(tabSettingsRow("History", in: app), titled: "History", above: gallery, in: app)
        XCTAssertEqual(tabSettingsOrder(in: app).first, "history", "The list does not start with History")

        // History is hidden: moving it leaves the tab items as they were, identifiers included.
        XCTAssertEqual(tabItemOrder(in: app), Self.visibleTabs, "The tab items changed")
    }

    /// Moving a shown tab moves its tab item at once, without a relaunch.
    @MainActor
    func testDraggingAVisibleTabReordersTheTabItems() {
        let app = launchApp()
        openTabSettings(in: app)
        XCTAssertEqual(tabItemOrder(in: app), Self.visibleTabs, "Unexpected tab items before reordering")
        let gallery = app.switches.matching(identifier: "tabSettings.toggle.gallery").firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 5), "No Gallery switch")

        drag(tabSettingsRow("Toplists", in: app), titled: "Toplists", above: gallery, in: app)
        XCTAssertEqual(tabSettingsOrder(in: app).first, "toplists", "The list does not start with Toplists")

        let expected = ["toplists", "gallery", "favorites", "download", "settings"]
        let deadline = Date.now.addingTimeInterval(5)
        while tabItemOrder(in: app) != expected, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        attachScreenshot("b2-reorderedTabs", of: app)
        XCTAssertEqual(tabItemOrder(in: app), expected, "The tab items did not follow the new order")

        // Back on the gallery, the tabs still work in their new places.
        selectTab("gallery", in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 5), "Gallery did not open")
        selectTab("toplists", in: app)
        XCTAssertTrue(element("toplists.root", in: app).waitForExistence(timeout: 5), "Toplists did not open")
    }

    /// A hidden tab's page pushed onto the gallery's stack goes once that tab is shown: its root lives in its own tab
    /// then, never twice.
    @MainActor
    func testShowingAHiddenTabDropsItsPage() {
        let app = launchApp()
        selectTab("gallery", in: app)
        tapToolbarItem("hiddenTabs.history", title: "History", in: app)
        XCTAssertTrue(element("history.root", in: app).waitForExistence(timeout: 5), "History page did not open")

        openTabSettings(in: app)
        setTab("favorites", shown: false, in: app)
        setTab("history", shown: true, in: app)

        selectTab("gallery", in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 5), "The gallery is not at its root")
        XCTAssertFalse(element("history.root", in: app).exists, "History's page is still on the gallery's stack")
        XCTAssertFalse(systemBackButton(in: app).exists, "The gallery's stack still has a page")
    }

    /// Rotating the device is no tap on a tab item (on the real list since browse
    /// B4b): a reselect, single or double, would pop the gallery's stack to its root, so
    /// the pushed placeholder must stay through the rotations; and back on the list, it was not scrolled to the top.
    /// The Duo's folding and unfolding cannot be automated; entry E4 checks it by hand.
    ///
    /// The rotations start from the orientation the launch is in (`rotations(from:)`) and end there, as does the
    /// teardown: the posture under test may hold the device sideways or upside down, and the checks after the
    /// rotations belong to that posture.
    @MainActor
    func testRotatingDoesNotReselect() {
        let app = launchApp(replayingFixtures: true)
        let start = Self.validOrientation(XCUIDevice.shared.orientation)
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = start }
        // Picked, not taken for granted as the tab the launch shows.
        selectTab("gallery", in: app)
        selectGroup("Gallery", from: "Popular", in: app)
        guard let first = firstGalleryItem(in: app) else {
            XCTFail("No gallery on the front page")
            return
        }
        scrollAway(from: first, in: app)
        // A row wholly on screen below the navigation bar: after the swipes the top row may be half off it, and on a
        // rotated display a tap on such a row lands elsewhere; one under the bar is tapped through the status bar,
        // which scrolls the list to its top.
        guard let shown = firstWhollyVisibleGalleryItem(in: app) else {
            XCTFail("No gallery on screen after scrolling")
            return
        }
        shown.tap()
        let detail = element("route.placeholder.gallery", in: app)
        guard detail.waitForExistence(timeout: 5) else {
            // The tree tells a tap that landed elsewhere (another tab selected) from a push that did not come.
            attachElementTree(of: app)
            XCTFail("Gallery placeholder did not appear")
            return
        }

        for orientation in Self.rotations(from: start) {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 1.5)
        }
        XCTAssertTrue(detail.exists, "Rotating popped the gallery's stack (a reselect)")

        goBack(in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 5), "The gallery did not reappear")
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5), "Gallery placeholder is still shown after going back")
        XCTAssertFalse(first.exists && first.isHittable, "The list is back at its top after rotating")
    }

    @MainActor
    func testGalleryPushesDetailAndReturns() {
        let app = launchApp(replayingFixtures: true)
        selectTab("gallery", in: app)
        selectGroup("Gallery", from: "Popular", in: app)

        guard let item = firstGalleryItem(in: app) else {
            XCTFail("No gallery on the front page")
            return
        }
        item.tap()

        let detail = element("route.placeholder.gallery", in: app)
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "Gallery placeholder did not appear")
        attachScreenshot("b2-placeholder", of: app)

        goBack(in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 5), "Gallery did not reappear")
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5), "Gallery placeholder is still shown after going back")
    }

    /// Reselecting the tab brings the list back to its top (B2's probe: the system scrolls the root page's list
    /// itself); on the real list since browse B4b.
    @MainActor
    func testReselectingTheTabScrollsToTop() {
        let app = launchApp(replayingFixtures: true)
        selectTab("gallery", in: app)
        selectGroup("Gallery", from: "Popular", in: app)
        guard let first = firstGalleryItem(in: app) else {
            XCTFail("No gallery on the front page")
            return
        }
        scrollAway(from: first, in: app)

        selectTab("gallery", in: app)
        XCTAssertTrue(wait(for: first, toBeHittable: true), "Reselecting the tab did not scroll to the top")
    }

    /// Probe (Step 4), then the behaviour B2 keeps: reselecting the tab goes back to its root page.
    @MainActor
    func testReselectingPopsToRoot() {
        let app = launchApp(replayingFixtures: true)
        selectTab("gallery", in: app)
        selectGroup("Gallery", from: "Popular", in: app)
        guard let openDetail = firstGalleryItem(in: app) else {
            XCTFail("No gallery on the front page")
            return
        }
        openDetail.tap()
        let detail = element("route.placeholder.gallery", in: app)
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "Gallery placeholder did not appear")

        selectTab("gallery", in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 5), "Reselecting did not pop to root")
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5), "Gallery placeholder is still shown")

        // The tab's path was emptied too: one more push needs one back to return.
        openDetail.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "Gallery placeholder did not appear again")
        goBack(in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 5), "One back did not return to root")
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5), "Gallery placeholder is still shown after going back")
    }

    // MARK: - Helpers

    /// `orientation` when it is a portrait or landscape one, else portrait (face up or down, unknown): the orientation
    /// to start the rotations from and to restore.
    @MainActor private static func validOrientation(_ orientation: UIDeviceOrientation) -> UIDeviceOrientation {
        orientation.isPortrait || orientation.isLandscape ? orientation : .portrait
    }

    /// Four rotations from `start` back to it, each one turning the screen: to both landscape sides from a portrait
    /// start; to portrait, then the other landscape side, from a landscape start. A fixed list would leave a turn out
    /// (landscape left to landscape left) and end away from the posture under test.
    @MainActor private static func rotations(from start: UIDeviceOrientation) -> [UIDeviceOrientation] {
        guard start.isLandscape else { return [.landscapeLeft, start, .landscapeRight, start] }
        let otherSide: UIDeviceOrientation = start == .landscapeLeft ? .landscapeRight : .landscapeLeft
        return [.portrait, start, otherSide, start]
    }

    /// Swipes the gallery list up until `first` is no longer hittable (at most 5 swipes), and checks that it is not.
    @MainActor private func scrollAway(from first: XCUIElement, in app: XCUIApplication) {
        let list = element("gallery.root", in: app)
        var swipes = 0
        while first.exists && first.isHittable, swipes < 5 {
            list.swipeUp()
            swipes += 1
        }
        XCTAssertFalse(first.exists && first.isHittable, "The first gallery is still on screen after scrolling")
    }

    /// Settings → Tab Bar.
    @MainActor private func openTabSettings(in app: XCUIApplication) {
        selectTab("settings", in: app)
        let row = element("settings.tabBar", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "No Tab Bar row in Settings")
        row.tap()
        XCTAssertTrue(
            app.switches.matching(identifier: "tabSettings.toggle.gallery").firstMatch.waitForExistence(timeout: 5),
            "Tab Bar settings did not open"
        )
    }

    /// Turns the switch of `tab` on the Tab Bar page on or off and waits for it to show that.
    @MainActor private func setTab(_ tab: String, shown: Bool, in app: XCUIApplication) {
        let toggle = app.switches.matching(identifier: "tabSettings.toggle.\(tab)").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "No switch for \(tab)")
        let wanted = shown ? "1" : "0"
        // A tap that comes right after a tab switch is now and then dropped (browse B4b, Duo: the switch was there,
        // enabled and unchanged 5 s later), so a switch that did not change is tapped once more.
        for _ in 0..<2 where toggle.value as? String != wanted {
            // The row's own switch, when the system nests one in it.
            let inner = toggle.switches.firstMatch
            (inner.exists ? inner : toggle).tap()
            let deadline = Date.now.addingTimeInterval(5)
            while toggle.value as? String != wanted, Date.now < deadline {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        if toggle.value as? String != wanted {
            attachElementTree(of: app)
        }
        XCTAssertEqual(toggle.value as? String, wanted, "The switch for \(tab) did not change")
    }

    /// The row of `title` on the Tab Bar page: its switch, labelled with the tab's title.
    @MainActor private func tabSettingsRow(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// The tabs on the Tab Bar page, top to bottom (`AppTab.rawValue`).
    @MainActor private func tabSettingsOrder(in app: XCUIApplication) -> [String] {
        ["gallery", "favorites", "toplists", "download", "history"]
            .map { (tab: $0, y: app.switches.matching(identifier: "tabSettings.toggle.\($0)").firstMatch.frame.minY) }
            .sorted { $0.y < $1.y }
            .map(\.tab)
    }

    /// The tab items that carry their identifier, in the order shown: top to bottom in the Duo rail, leading to
    /// trailing in a tab bar (`AppTab.rawValue`). Copies of one item count once: on the iPad (iOS 27.2) a tab bar item
    /// is two nested buttons with the same identifier and frame (browse B4b, element tree of the full run). Only
    /// copies with the same identifier and the same frame (within 1 pt) merge, so a tab shown twice in two places
    /// still shows; which copy is kept does not matter, so the result does not depend on the element tree's order.
    @MainActor private func tabItemOrder(in app: XCUIApplication) -> [String] {
        let found = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab."))
            .allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            .map { (tab: String($0.identifier.dropFirst("tab.".count)), frame: $0.frame) }
        var items: [(tab: String, frame: CGRect)] = []
        for item in found where !items.contains(where: { $0.tab == item.tab && Self.sameFrame($0.frame, item.frame) }) {
            items.append(item)
        }
        return items.sorted {
            abs($0.frame.minY - $1.frame.minY) < 1 ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }.map(\.tab)
    }

    /// Whether two frames are the same within 1 pt on every edge.
    private static func sameFrame(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) <= 1 && abs(first.minY - second.minY) <= 1
            && abs(first.maxX - second.maxX) <= 1 && abs(first.maxY - second.maxY) <= 1
    }

    @MainActor private func wait(for element: XCUIElement, toBeEnabled enabled: Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(5)
        while element.isEnabled != enabled {
            guard Date.now < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return true
    }

    @MainActor private func wait(for element: XCUIElement, toBeHittable hittable: Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(5)
        while (element.exists && element.isHittable) != hittable {
            guard Date.now < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return true
    }
}
