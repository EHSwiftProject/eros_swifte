import XCTest

/// UI tests for the offer to open a site link found in the clipboard (entry E3). A UI test launch never reads the real
/// clipboard: the app's is a fixed one whose change count stays the same and whose URL is the one
/// `-EROS_UI_TESTING_CLIPBOARD_URL` gives, here the tag link of the checked-in fixture `eh/list/tag.html`
/// (`language:chinese`), whose list the replay serves. The app leaves for the background and comes back with
/// `sendToBackgroundAndBack`.
final class ClipboardLinkTests: XCTestCase {
    private static let link = "https://e-hentai.org/tag/language:chinese"
    private static let footer = "When Eros-SE returns to the foreground, it offers to open an E-Hentai or ExHentai link "
        + "found in the clipboard."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Clipboard Detection is off by default, so coming back offers nothing. Once it is on in Settings, coming back
    /// offers the link, and Open opens its list on the Gallery tab. Coming back once more, the clipboard unchanged,
    /// offers nothing.
    @MainActor
    func testClipboardLinkIsOfferedAfterReturning() {
        let app = launchApp(replayingFixtures: true, arguments: ["-EROS_UI_TESTING_CLIPBOARD_URL", Self.link])
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 30), "The tabs did not show")
        let offer = app.alerts["Open Link?"]

        // 1) Off by default.
        sendToBackgroundAndBack(app)
        XCTAssertFalse(offer.waitForExistence(timeout: 5), "A link was offered with Clipboard Detection off")

        // 2) Clipboard Detection on, in the General section of Settings.
        selectTab("settings", in: app)
        XCTAssertTrue(element("settings.root", in: app).waitForExistence(timeout: 10), "Settings did not open")
        let toggle = app.switches.matching(identifier: "settings.clipboardLinks").firstMatch
        turnOn(toggle, in: app)
        let footer = app.staticTexts.matching(NSPredicate(format: "label == %@", Self.footer)).firstMatch
        scrollUntilVisible(footer, in: app)
        XCTAssertTrue(footer.exists, "The General section has no footer")
        XCTAssertTrue(toggle.isHittable, "The switch went off screen")
        attachScreenshot("e3-settings-clipboard", of: app)

        // 3) Coming back offers the link. Should the app have been launched again on the way, the new launch would
        //    show the Gallery tab, with Clipboard Detection off.
        XCTAssertEqual(toggle.value as? String, "1", "Clipboard Detection is not on before leaving")
        sendToBackgroundAndBack(app)
        if !offer.waitForExistence(timeout: 10) {
            let selected = selectedTabItems(in: app).sorted()
            let settingsShown = element("settings.root", in: app).exists
            attachElementTree(of: app)
            XCTFail(
                "No Open Link? alert after coming back. Selected tab items \(selected): tab.settings unless the app "
                    + "was launched again (then tab.gallery); Settings shown: \(settingsShown)"
            )
        }
        XCTAssertTrue(offer.staticTexts[Self.link].exists, "The alert does not show the link")
        let open = offer.buttons["Open"]
        XCTAssertTrue(open.exists, "The alert has no Open button")
        XCTAssertTrue(offer.buttons["Cancel"].exists, "The alert has no Cancel button")
        attachScreenshot("e3-clipboard-offer", of: app)

        open.tap()
        XCTAssertTrue(offer.waitForNonExistence(timeout: 5), "The alert stayed")
        expectList(titled: "language:chinese", in: app)
        attachScreenshot("e3-clipboard-opened", of: app)

        // 4) The clipboard has not changed: nothing is offered, and the list is still there (no new launch).
        sendToBackgroundAndBack(app)
        XCTAssertFalse(offer.waitForExistence(timeout: 5), "The unchanged clipboard was offered again")
        XCTAssertTrue(element("route.list", in: app).exists, "The list is gone: the app was launched again")
        expectSelectedTab("gallery", in: app)
    }

    /// Scrolls to the switch `toggle` (off) and turns it on, the row's own switch when the system nests one in it; a
    /// tap that did not change it is made once more. Fails unless it reads on within 5 s of the last tap.
    @MainActor private func turnOn(_ toggle: XCUIElement, in app: XCUIApplication) {
        scrollUntilVisible(toggle, in: app)
        XCTAssertTrue(toggle.exists, "No Clipboard Detection switch")
        XCTAssertEqual(toggle.value as? String, "0", "Clipboard Detection is on by default")
        let on = NSPredicate(format: "value == %@", "1")
        for _ in 0..<2 where toggle.value as? String != "1" {
            let inner = toggle.switches.firstMatch
            (inner.exists ? inner : toggle).tap()
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: on, object: toggle)], timeout: 5)
        }
        XCTAssertEqual(toggle.value as? String, "1", "Clipboard Detection did not turn on")
    }
}
