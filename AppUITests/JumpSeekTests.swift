import XCTest

/// UI tests for the list jumps (browse B5) on the gallery tab's front page from the replayed fixtures: the Jump/Seek
/// sheet, its input checks and Back to First Page. The replayed front page has a next cursor and no previous one, so a
/// seek towards Previous asks for `?seek=2024-01-01` (`eh/list/front-seek.html`). The tab opens on its first group,
/// Popular, which has no cursors; every test picks the Gallery group (the front page) in the title menu first (B6).
final class JumpSeekTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSeekingADateLoadsThatPage() {
        let app = launchApp(replayingFixtures: true)
        selectGroup("Gallery", from: "Popular", in: app)
        guard let before = topGalleryIdentifier(in: app) else { return }
        openJumpSeek(in: app)
        attachScreenshot("b5-sheet", of: app)
        seek("2024-01-01", in: app)
        waitForTopGallery(changingFrom: before, in: app)
        guard titledToolbarItem("jump.backToFirst", title: "Back to First Page", in: app) != nil else { return }
        // With the overflow menu open when the item is in it.
        attachScreenshot("b5-afterJump", of: app)
    }

    /// U10 (M2 review B.2-5): the date picker shows today while nothing is picked, and picking that day, already
    /// marked in its calendar, sends nothing (iOS 27.2; checked 2026-11-17 on the iPhone, result bundle
    /// f3-green-iphone1): Today beside the picker writes today into the field.
    @MainActor
    func testTodayFillsTheField() {
        let app = launchApp(replayingFixtures: true)
        selectGroup("Gallery", from: "Popular", in: app)
        guard topGalleryIdentifier(in: app) != nil else { return }
        openJumpSeek(in: app)
        let today = element("jumpSeek.today", in: app)
        XCTAssertTrue(today.waitForExistence(timeout: 5), "No Today")
        XCTAssertEqual(today.label, "Today")
        today.tap()
        let expected = Date.now.formatted(
            Date.ISO8601FormatStyle(dateSeparator: .dash, timeZone: .current).year().month().day()
        )
        let field = element("jump.text", in: app)
        let filled = NSPredicate(format: "value == %@", expected)
        let result = XCTWaiter.wait(for: [expectation(for: filled, evaluatedWith: field)], timeout: 5)
        attachScreenshot("u10-today", of: app)
        XCTAssertEqual(result, .completed, "Today left the field as \(String(describing: field.value))")
        XCTAssertTrue(element("jump.go", in: app).isEnabled, "Go is disabled for today")
    }

    @MainActor
    func testBadInputDisablesGo() {
        let app = launchApp(replayingFixtures: true)
        selectGroup("Gallery", from: "Popular", in: app)
        guard topGalleryIdentifier(in: app) != nil else { return }
        openJumpSeek(in: app)
        let go = element("jump.go", in: app)
        XCTAssertTrue(go.waitForExistence(timeout: 5), "No Go")
        XCTAssertEqual(go.label, "Go")
        let error = element("jump.error", in: app)
        XCTAssertFalse(go.isEnabled, "Go is enabled without input")
        XCTAssertEqual(error.label, "Enter an offset or a date.")

        let text = element("jump.text", in: app)
        text.tap()
        let cases = [
            ("abc", "Use 3d, 2w, 6m, 1y or a date such as 2024-01-31."),
            ("2006-01-01", "Enter a date on or after 2007-03-20."),
        ]
        for (input, message) in cases {
            text.typeText(input)
            XCTAssertFalse(go.isEnabled, "Go is enabled for \(input)")
            XCTAssertTrue(error.waitForExistence(timeout: 5), "No error for \(input)")
            XCTAssertEqual(error.label, message, "The error for \(input)")
            text.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: input.count))
        }
        // A good offset enables Go and clears the error.
        text.typeText("3d")
        XCTAssertTrue(go.isEnabled, "Go is disabled for 3d")
        XCTAssertFalse(error.exists, "An error for 3d")
    }

    @MainActor
    func testBackToFirstPageReloads() {
        let app = launchApp(replayingFixtures: true)
        selectGroup("Gallery", from: "Popular", in: app)
        guard let first = topGalleryIdentifier(in: app) else { return }
        openJumpSeek(in: app)
        seek("2024-01-01", in: app)
        waitForTopGallery(changingFrom: first, in: app)
        guard let backToFirst = titledToolbarItem("jump.backToFirst", title: "Back to First Page", in: app) else {
            return
        }
        backToFirst.tap()
        waitForTopGallery(being: first, in: app)
        XCTAssertFalse(
            toolbarOffers("jump.backToFirst", title: "Back to First Page", in: app),
            "Back to First Page is still offered on the first page"
        )
    }

    // MARK: - Helpers

    /// In the open sheet: Previous, `date`, Go; waits for the sheet to close.
    @MainActor private func seek(_ date: String, in app: XCUIApplication) {
        let previous = element("jump.direction", in: app).buttons["Previous"]
        XCTAssertTrue(previous.waitForExistence(timeout: 5), "No Previous in the direction picker")
        previous.tap()
        let text = element("jump.text", in: app)
        text.tap()
        text.typeText(date)
        tapToolbarItem("jump.go", title: "Go", in: app)
        XCTAssertTrue(text.waitForNonExistence(timeout: 10), "The sheet did not close")
    }

    /// Waits up to 30 s for the topmost gallery to be another one than `identifier` (the page jumped to came).
    @MainActor private func waitForTopGallery(changingFrom identifier: String, in app: XCUIApplication) {
        waitForTopGallery(in: app, "The page jumped to did not come") { $0 != identifier }
    }

    /// Waits up to 30 s for the topmost gallery to be `identifier` again (the first page came back).
    @MainActor private func waitForTopGallery(being identifier: String, in app: XCUIApplication) {
        waitForTopGallery(in: app, "The first page did not come back") { $0 == identifier }
    }
}
