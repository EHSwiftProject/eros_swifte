import XCTest

/// UI tests for `eros://` links (entry E2), opened through the system as another app would (`openExternally`), always
/// while the app the test launched runs: one the system launched itself would not be in UI testing mode. The tag list
/// is replayed from the checked-in fixture whose URL gives `language:chinese` (`eh/list/tag.html`); the gallery link
/// opens its placeholder; the other links are made up.
final class SchemeLinkTests: XCTestCase {
    /// How long the cold launch test holds the tabs back. Its second "window passed" check comes once
    /// `openExternally` has returned: `system.open`, the 2 s it always waits for a confirmation the simulators never
    /// show and the wait for the foreground, all after `XCUIApplication.launch()` has returned (24.6 s into a run on a
    /// loaded iPhone). With 8 s, an idle Duo had about 5 s between that check and the tabs; under a heavy host load
    /// that is too little.
    private static let coldLaunchDelay: TimeInterval = 12

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A link in the host form, opened once the tabs show, pushes the tag list onto the Gallery tab.
    @MainActor
    func testSchemeLinkWhileRunningOpensTheTagList() throws {
        let app = launchApp(replayingFixtures: true)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 30), "The tabs did not show")

        openExternally(try XCTUnwrap(URL(string: "eros://e-hentai.org/tag/language:chinese")), in: app)
        expectList(titled: "language:chinese", in: app)
        attachScreenshot("e2-scheme-tag-list", of: app)
    }

    /// A link in the open form, opened while `LaunchGate` still waits (the launch holds off its tabs for
    /// `coldLaunchDelay`, `-EROS_UI_TESTING_LAUNCH_DELAY`), is pushed once the tabs show, and once only: one back
    /// reaches the gallery's root page. The tabs must not be there yet when the link goes out, nor once it has been
    /// opened, or the test would not tell anything.
    @MainActor
    func testSchemeLinkBeforeLaunchFinishesIsOpened() throws {
        let url = try XCTUnwrap(URL(string: "eros://open?url=https%3A%2F%2Fe-hentai.org%2Fg%2F1234%2F0123456789%2F"))
        let delay = Self.coldLaunchDelay
        let app = launchApp(replayingFixtures: true, arguments: ["-EROS_UI_TESTING_LAUNCH_DELAY", "\(Int(delay))"])
        let tabs = element("tab.gallery", in: app)
        XCTAssertFalse(tabs.exists, "The window passed: the tabs showed before the link was opened")

        openExternally(url, in: app)
        XCTAssertFalse(tabs.exists, "The window passed: the tabs showed while the link was being opened")
        // The tabs come the delay later than in a plain launch, so the wait for them gets that much more.
        expectPlaceholder("route.placeholder.gallery", describedAs: "Gallery 1234", within: 30 + delay, in: app)
        attachScreenshot("e2-scheme-cold-gallery", of: app)

        goBack(in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 5), "Back did not reach the gallery")
        XCTAssertTrue(
            element("route.placeholder.gallery", in: app).waitForNonExistence(timeout: 5),
            "A placeholder is still shown: the link was pushed more than once"
        )
        expectSelectedTab("gallery", in: app)
    }

    /// A link that is no site link says so; OK takes the alert away and leaves the page as it was.
    @MainActor
    func testUnknownSchemeLinkSaysSo() throws {
        let app = launchApp(replayingFixtures: true)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 30), "The tabs did not show")

        openExternally(try XCTUnwrap(URL(string: "eros://example.com/")), in: app)
        let alert = app.alerts["Can't Open Link"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "No Can't Open Link alert")
        let message = "Eros-SE opens links to galleries, image pages, tags, uploaders and searches on e-hentai.org and "
            + "exhentai.org."
        XCTAssertTrue(alert.staticTexts[message].exists, "Unexpected alert message")
        let ok = alert.buttons["OK"]
        XCTAssertTrue(ok.exists, "The alert has no OK button")
        attachScreenshot("e2-scheme-unopenable", of: app)

        ok.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "The alert stayed")
        XCTAssertTrue(element("gallery.root", in: app).exists, "The gallery's root page is gone")
        XCTAssertFalse(app.buttons.matching(identifier: "BackButton").firstMatch.exists, "Something was pushed")
    }
}
