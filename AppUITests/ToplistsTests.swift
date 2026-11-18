import XCTest

/// UI tests for the toplists tab (browse B7) over the replayed fixtures: the four toplists (`toplist.php?tl=15`, `13`,
/// `12` and `11`), Yesterday's second page (`tl=15&p=1`), and Jump to Page with its range check. Every replayed toplist
/// page has 50 galleries and says there are 200 pages; the four first pages start with four different galleries.
final class ToplistsTests: XCTestCase {
    /// The toplists in the title menu's order (`ToplistPeriod.title`).
    private static let titles = ["Yesterday", "Past Month", "Past Year", "All-Time"]
    /// How many galleries a replayed toplist page has; Yesterday's second page has as many others.
    private static let galleriesPerPage = 50

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testToplistShowsYesterday() {
        let app = openToplists()
        XCTAssertNotNil(titleMenuButton("Yesterday", in: app), "The toplists page is not titled Yesterday")
        guard topGalleryIdentifier(in: app) != nil else { return }
        // Jump to Page, once the list knows its pages: on the bar (the Duo rail) or in its overflow menu, which then
        // stays open for the screenshot.
        XCTAssertTrue(toolbarOffers("jump.page", title: "Jump to Page", in: app), "The toolbar offers no Jump to Page")
        // The rail with Jump to Page and the hidden History tab.
        attachScreenshot("b7-yesterday", of: app)
    }

    /// U10 check (M2 review B.2-6): the title tapped while the first page is still on its way (every replayed answer
    /// held 15 s: room for the launch and the tab switch on a busy host, M2 review F4 M-8) opens the title menu, and
    /// the menu stays open when the page comes in and Jump to Page joins the toolbar.
    @MainActor
    func testTheTitleMenuOpenedDuringTheFirstPageStaysOpen() {
        let app = launchApp(replayingFixtures: true, arguments: ["-EROS_FIXTURE_REPLAY_DELAY", "15"])
        selectTab("toplists", in: app)
        XCTAssertTrue(element("toplists.root", in: app).waitForExistence(timeout: 10), "The toplists page did not open")
        XCTAssertTrue(element("gallery.loading", in: app).exists, "The first page came before the title was tapped")
        guard let title = titleMenuButton("Yesterday", in: app) else {
            XCTFail("The toplists page is not titled Yesterday")
            return
        }
        title.tap()
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Past Month")).firstMatch
        let opened = item.waitForExistence(timeout: 3)
        attachScreenshot("u10-titleMenuWhileLoading", of: app)
        XCTAssertTrue(opened, "The title tapped while the first page loads opened no menu")
        XCTAssertTrue(
            element("gallery.loading", in: app).exists, "The first page came before the menu opened: no check made"
        )
        // The page comes in (15 s after it was asked for) behind the open menu: its galleries drawn, then Jump to Page
        // in the toolbar, the change that might close the menu. Jump to Page is waited for on the bar only (up to
        // 5 s): in the overflow menu of a short screen the tree has it only once that menu opens. Then the menu is
        // given a second to close, as it would on that change: the wait ends early if it does.
        XCTAssertTrue(
            element("gallery.loading", in: app).waitForNonExistence(timeout: 30), "The first page did not come"
        )
        let galleries = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "gallery.item.")).firstMatch
        XCTAssertTrue(galleries.waitForExistence(timeout: 10), "The first page shows no gallery")
        _ = element("jump.page", in: app).waitForExistence(timeout: 5)
        _ = item.waitForNonExistence(timeout: 1)
        attachScreenshot("u10-titleMenuAfterThePage", of: app)
        XCTAssertTrue(item.exists && item.isHittable, "The title menu closed when the first page came in")
    }

    @MainActor
    func testSwitchingPeriodsLoadsEach() {
        let app = openToplists()
        guard let yesterday = topGalleryIdentifier(in: app) else { return }
        var seen: Set<String> = [yesterday]
        var current = "Yesterday"
        for title in Self.titles.dropFirst() {
            openTitleMenu(current, offering: title, in: app)
            if current == "Yesterday" {
                for item in Self.titles {
                    XCTAssertNotNil(hittableMenuItem(item, in: app), "The title menu has no \(item)")
                }
                attachScreenshot("b7-titleMenu", of: app)
            }
            guard let item = hittableMenuItem(title, in: app) else {
                attachElementTree(of: app)
                XCTFail("The title menu has no \(title)")
                return
            }
            item.tap()
            XCTAssertNotNil(titleMenuButton(title, in: app), "The toplists page is not titled \(title)")
            let shown = seen
            waitForTopGallery(in: app, "\(title) did not load its list") { !shown.contains($0) }
            guard let top = topGalleryIdentifier(in: app) else { return }
            seen.insert(top)
            current = title
        }
    }

    @MainActor
    func testScrollingLoadsPageTwo() {
        let app = openToplists()
        guard topGalleryIdentifier(in: app) != nil else { return }
        // Every gallery of the first page passes by on the way to its end; one more is from the second page (p=1).
        // Stops as soon as it is there: the third page is not among the replayed requests.
        let swiped = swipeUntilMoreGalleries(
            than: Self.galleriesPerPage, in: "toplists.root", maxSwipes: 80, app: app
        )
        XCTAssertGreaterThan(
            swiped.seen, Self.galleriesPerPage,
            "Only \(swiped.seen) galleries after \(swiped.swipes) swipes (\(swiped.first) at first): page two did"
                + " not load"
        )
    }

    @MainActor
    func testJumpToPageTwo() {
        let app = openToplists()
        guard let first = topGalleryIdentifier(in: app) else { return }
        openPageJump(in: app)
        let range = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Page range 1 - 200"))
        XCTAssertTrue(range.firstMatch.waitForExistence(timeout: 5), "The sheet does not give the page range")
        let text = element("jump.pageText", in: app)
        text.tap()
        text.typeText("2")
        attachScreenshot("b7-pageSheet", of: app)
        tapGo(afterTypingIn: text, sheetTitle: "Jump to Page", in: app)
        waitForTopGallery(in: app, "Page two did not come") { $0 != first }
        XCTAssertNotNil(
            titledToolbarItem("jump.backToFirst", title: "Back to First Page", in: app),
            "No Back to First Page after the jump"
        )
    }

    @MainActor
    func testOutOfRangePagesCannotBeSent() {
        let app = openToplists()
        guard topGalleryIdentifier(in: app) != nil else { return }
        openPageJump(in: app)
        let go = element("jump.go", in: app)
        XCTAssertTrue(go.waitForExistence(timeout: 5), "No Go")
        XCTAssertFalse(go.isEnabled, "Go is enabled without a page")

        let text = element("jump.pageText", in: app)
        text.tap()
        for input in ["0", "99999", "201"] {
            text.typeText(input)
            XCTAssertEqual(text.value as? String, input, "The page field does not show \(input)")
            XCTAssertFalse(go.isEnabled, "Go is enabled for page \(input)")
            text.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: input.count))
        }
        // The last page is in range.
        text.typeText("200")
        XCTAssertTrue(go.isEnabled, "Go is disabled for the last page")
    }

    // MARK: - Helpers

    /// Launches the app over the replayed fixtures and opens the toplists tab.
    @MainActor private func openToplists() -> XCUIApplication {
        let app = launchApp(replayingFixtures: true)
        selectTab("toplists", in: app)
        XCTAssertTrue(element("toplists.root", in: app).waitForExistence(timeout: 10), "The toplists page did not open")
        return app
    }
}
