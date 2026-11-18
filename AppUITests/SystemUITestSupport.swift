import XCTest

// Helpers the tests of opening links from outside the app share (entry E1–E3; E4 adds to them): opening a URL through
// the system as another app would, sending the app to the background and back, and what the page such an open pushes
// shows. Titles are found by label or identifier (`FavoritesTests`): iPadOS 27.2 draws no plain inline title under its
// tab bar, and the navigation bar's identifier is its title on every device.

/// The tabs' titles (`AppTab.title`) and raw values, for `expectSelectedTab` when the tab items lack their identifiers.
/// Keep it in step with `AppTab.title`.
private let tabsByTitle = [
    "Gallery": "gallery", "Favorites": "favorites", "Toplists": "toplists", "Download": "download",
    "History": "history", "Settings": "settings",
]

extension XCTestCase {
    /// Opens `url` through the system (`XCUIDevice.shared.system.open(_:)`), as another app or Safari would, while
    /// `app` runs. When the system first asks whether to open the link, taps SpringBoard's Open button (looked for for
    /// 2 s; none → goes on), then waits up to 10 s for `app` to be in the foreground. The button is SpringBoard's, so
    /// it reads in the simulator's system language, not the app's: "Open", or "打开" on the Chinese simulators these
    /// tests run on.
    ///
    /// Only for an app a UI test launched (`launchApp`) and that still runs: one the system launches itself is not in
    /// UI testing mode and would reach the site. So an `app` that is not running fails the test instead of opening.
    @MainActor func openExternally(_ url: URL, in app: XCUIApplication) {
        guard app.state == .runningForeground || app.state == .runningBackground else {
            XCTFail("The app is not running (state \(app.state.rawValue)): the system would launch it outside UI tests")
            return
        }
        XCUIDevice.shared.system.open(url)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons
            .matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if open.waitForExistence(timeout: 2) {
            open.tap()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The app did not come back to the foreground")
    }

    /// Waits for the list page (`route.list`) pushed above a tab's root (the back button shows), titled `title`, with
    /// a gallery in it, on the Gallery tab (`expectSelectedTab`). The tabs show once the app has read the user agent
    /// (`selectTab`), hence the first long wait.
    @MainActor func expectList(titled title: String, in app: XCUIApplication) {
        let list = element("route.list", in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 30), "The list page did not open")
        expectTitle(title, in: app)
        let item = list.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "gallery.item.")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 30), "The list shows no gallery")
        XCTAssertTrue(systemBackButton(in: app).waitForExistence(timeout: 5), "The list has no back button")
        expectSelectedTab("gallery", in: app)
    }

    /// Waits up to `timeout` seconds for the placeholder page `identifier`, which reads `description`, pushed above a
    /// tab's root, on the Gallery tab. 30 s by default, as long as the tabs may take to show (`selectTab`).
    @MainActor func expectPlaceholder(
        _ identifier: String, describedAs description: String, within timeout: TimeInterval = 30,
        in app: XCUIApplication
    ) {
        XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: timeout), "\(identifier) did not open")
        let described = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", description))
        XCTAssertTrue(described.firstMatch.waitForExistence(timeout: 5), "The page does not read \(description)")
        XCTAssertTrue(systemBackButton(in: app).waitForExistence(timeout: 5), "The page has no back button")
        expectSelectedTab("gallery", in: app)
    }

    /// Waits up to 5 s for the tab item of `tab` (an `AppTab.rawValue`) to be the only selected one: of the hittable
    /// tab items (`tab.<rawValue>`, wherever the system placed them, as `selectTab` finds them), the selected ones are
    /// all `tab`'s. Fails with the element tree otherwise.
    ///
    /// Now and then no tab item carries its identifier, the items being there and selected as they should (the iPhone
    /// in entry E1, the Duo in E2): while no hittable element has a `tab.`
    /// identifier, the tab items are the hittable buttons labelled with a tab's title (`AppTab.title`) instead.
    @MainActor func expectSelectedTab(_ tab: String, in app: XCUIApplication) {
        let deadline = Date.now.addingTimeInterval(5)
        var selected: Set<String> = []
        while true {
            selected = selectedTabItems(in: app)
            if selected == ["tab.\(tab)"] { return }
            guard Date.now < deadline else { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        attachElementTree(of: app)
        XCTFail("The selected tab items are \(selected.sorted()), not tab.\(tab)")
    }

    /// The identifiers (`tab.<rawValue>`) of the selected tab items now, as `expectSelectedTab` reads them: of the
    /// hittable elements with a `tab.` identifier, or, while there is none, of the hittable buttons labelled with a
    /// tab's title.
    @MainActor func selectedTabItems(in app: XCUIApplication) -> Set<String> {
        let items = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab."))
        let hittable = items.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        guard hittable.isEmpty else { return Set(hittable.filter(\.isSelected).map(\.identifier)) }
        let titled = app.buttons.matching(NSPredicate(format: "label IN %@", Array(tabsByTitle.keys)))
        let titledItems = titled.allElementsBoundByIndex.filter { $0.exists && $0.isHittable && $0.isSelected }
        return Set(titledItems.compactMap { tabsByTitle[$0.label].map { "tab.\($0)" } })
    }

    /// Sends `app` to the background and brings it back (`activate()`), waiting up to 10 s for the foreground: its
    /// scene goes `.background`, then `.inactive`, then `.active`, as when the user returns to it (entry E3).
    ///
    /// The Home button first, given 3 s to take the app off the foreground. On the closed iPhone Duo it does nothing:
    /// the app stays on the cover screen and its scene stays `.active` (entry E3 probed it: for 6 s after the press
    /// neither the app's state nor its scene phase changed). Then the system Settings app is opened instead, as
    /// switching to another app does, and the app is given 10 s to be in the background. Should the system have ended
    /// the app meanwhile, `activate()` launches it again with the same launch arguments; a caller that must know checks
    /// what a new launch would have reset (the selected tab, the settings of the UI testing suite).
    @MainActor func sendToBackgroundAndBack(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        if !waitUntilInBackground(app, within: 3) {
            XCTContext.runActivity(named: "The Home button left the app in the foreground: opening Settings") { _ in
                XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()
            }
            XCTAssertTrue(
                waitUntilInBackground(app, within: 10),
                "The app did not go to the background (state \(app.state.rawValue))"
            )
        }
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The app did not come back to the foreground")
    }

    /// Whether `app` is in the background, suspended or not, within `timeout` seconds. Waits with `XCTWaiter`, which
    /// keeps the main run loop going: XCTest learns of the app's state changes there, so reading `state` between
    /// `Thread.sleep`s keeps giving the old value (an entry E3 probe kept reading the app as in the foreground for 3 s
    /// after the Settings app had come forward).
    @MainActor private func waitUntilInBackground(_ app: XCUIApplication, within timeout: TimeInterval) -> Bool {
        let states = [XCUIApplication.State.runningBackground, .runningBackgroundSuspended].map(\.rawValue)
        let inBackground = XCTNSPredicateExpectation(predicate: NSPredicate(format: "state IN %@", states), object: app)
        return XCTWaiter().wait(for: [inBackground], timeout: timeout) == .completed
    }

    /// The page's navigation title: its text, or the navigation bar named after it. A gallery or one of its tags may
    /// read the same, so those do not count.
    @MainActor func expectTitle(_ title: String, in app: XCUIApplication) {
        let titled = app.descendants(matching: .any).matching(NSPredicate(
            format: "(label == %@ OR identifier == %@) AND NOT (identifier BEGINSWITH %@) AND identifier != %@",
            title, title, "gallery.item.", "list.tag"
        ))
        XCTAssertTrue(titled.firstMatch.waitForExistence(timeout: 5), "The page is not titled \(title)")
    }
}
