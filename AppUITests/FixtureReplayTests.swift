import XCTest

/// UI tests of the fixture replay (`-EROS_FIXTURE_REPLAY 1`, `EROS_FIXTURE_ROUTES`), through the Session Diagnostics
/// page (DEBUG builds only): its front page buttons send the list request the app sends, and the result row tells
/// what came back. Nothing reaches the site: without the replay every request fails offline.
///
/// The page is a lazy `Form`: rows below the screen are not in the element tree, and the Network section (the
/// buttons and their results) comes after the report, so the tests scroll to it.
final class FixtureReplayTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFrontPageComesFromTheFixtures() {
        let app = launchApp(replayingFixtures: true)
        openDiagnostics(in: app).tap()
        expectFrontPageResult(containing: "25 items, Compact: yes", in: app)
    }

    @MainActor
    func testWithoutReplayRequestsStayOffline() {
        let app = launchApp()
        openDiagnostics(in: app).tap()
        expectFrontPageResult(containing: "transport error -1009", in: app)
    }

    /// A route serves a constructed page for the front page: one in the Thumbnail view, so the app asks to switch to
    /// the Compact view; Cancel declines.
    ///
    /// The gallery tab's Gallery group (the front page, browse B6) asks first: that question is declined before the
    /// tabs can be used, and a declined switch changes nothing, so the diagnostics' own request asks again.
    /// The tab opens on its Popular group, which does not ask for the front page, so the test picks Gallery.
    @MainActor
    func testRoutesServeConstructedPages() {
        let app = launchApp(
            replayingFixtures: true,
            routes: ["GET https://e-hentai.org/": UITestRoute(path: "constructed/eh/list-non-compact.html")]
        )
        selectGroup("Gallery", from: "Popular", in: app)
        let launchQuestion = app.alerts["Switch to the Compact view?"]
        XCTAssertTrue(launchQuestion.waitForExistence(timeout: 30), "The gallery's front page asked nothing")
        launchQuestion.buttons["Cancel"].tap()
        XCTAssertTrue(launchQuestion.waitForNonExistence(timeout: 10), "The gallery's question is still shown")
        openDiagnostics(in: app).tap()
        let alert = app.alerts["Switch to the Compact view?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "No Compact view question")
        alert.buttons["Cancel"].tap()
        expectFrontPageResult(containing: "switch declined", in: app)
    }

    /// The overflow menu's copy of the EH front page button (`diagnostics.overflow.front.eh`), through
    /// `tapToolbarItem`'s way into the menu.
    @MainActor
    func testOverflowItemsCanBeTapped() {
        let app = launchApp(replayingFixtures: true)
        // Not scrolled to the page's own "Load EH Front Page": on a phone it stays below the screen, out of the tree.
        openDiagnostics(in: app, scrollingToTheButton: false)
        tapToolbarItem("diagnostics.overflow.front.eh", title: "Load EH Front Page", in: app)
        expectFrontPageResult(containing: "25 items, Compact: yes", in: app)
    }

    /// The replay is turned on by an appended argument alone: `arguments` reach the app as given.
    @MainActor
    func testExtraArgumentsReachTheApp() {
        let app = launchApp(arguments: ["-EROS_FIXTURE_REPLAY", "1"])
        openDiagnostics(in: app).tap()
        expectFrontPageResult(containing: "25 items, Compact: yes", in: app)
    }

    // MARK: - Helpers

    /// Settings tab → Session Diagnostics; once the report is there, scrolls to the EH front page button (unless
    /// `scrollingToTheButton` is false) and returns it.
    @MainActor
    @discardableResult
    private func openDiagnostics(in app: XCUIApplication, scrollingToTheButton: Bool = true) -> XCUIElement {
        selectTab("settings", in: app)
        let diagnostics = element("account.diagnostics", in: app)
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5), "Session Diagnostics not found")
        diagnostics.tap()
        // The report's first row; until it is there the sections above the buttons are still to come. Reading it
        // starts a WebView, which took over 10 s on a fresh iPad simulator.
        let report = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "isLoggedIn"))
        XCTAssertTrue(report.firstMatch.waitForExistence(timeout: 30), "Session report not shown")
        let button = element("diagnostics.front.eh", in: app)
        guard scrollingToTheButton else { return button }
        // Dragged to, not swiped (a glide may leave the button cut by the screen's edge, where a tap on a rotated
        // display lands elsewhere), with more drags than the default: some seven on the cover screen held sideways.
        scrollUntilVisible(button, in: app, attempts: 12)
        XCTAssertTrue(button.exists && button.isHittable, "Load EH Front Page not found")
        return button
    }

    /// Waits up to 10 s for the EH front page result (its label and value) to contain `text`, scrolling down while
    /// the row is not there (it appears below its button).
    @MainActor
    private func expectFrontPageResult(containing text: String, in app: XCUIApplication) {
        let result = element("diagnostics.front.eh.result", in: app)
        let deadline = Date.now.addingTimeInterval(10)
        while !shown(result).contains(text), Date.now < deadline {
            if result.exists {
                Thread.sleep(forTimeInterval: 0.25)
            } else {
                // On the window, not the app: a swipe on the app may go to the Duo's other screen.
                pageWindow(of: app).swipeUp()
            }
        }
        XCTAssertTrue(
            shown(result).contains(text), "EH front page result is \"\(shown(result))\", expected \"\(text)\""
        )
    }
}
