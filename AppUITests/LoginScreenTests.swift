import XCTest

/// UI tests of the login screen, in UI testing mode (`-EROS_UI_TESTING 1`): an in-memory session, no Keychain, the
/// web login page is about:blank and every site request fails offline, so nothing reaches the site.
///
/// Controls and tab items are found by accessibility identifier with the shared helpers (`UITestSupport.swift`), never
/// through `tabBars` or `navigationBars`: on the iPhone Duo the system puts them in a rail.
final class LoginScreenTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLoginOffersThreeMethods() {
        let app = launchApp()
        openLogin(in: app)
        let method = element("login.method", in: app)
        for title in ["Password", "Cookie", "Web"] {
            XCTAssertTrue(method.buttons[title].exists, "Segment \(title) not found")
        }
        XCTAssertEqual(method.buttons.count, 3)
    }

    @MainActor
    func testSubmitIsDisabledUntilFieldsAreFilled() {
        let app = launchApp()
        openLogin(in: app)
        let submit = element("login.submit", in: app)
        XCTAssertTrue(submit.waitForExistence(timeout: 5), "Log In button not found")
        XCTAssertFalse(submit.isEnabled)

        type("fake-user", into: "login.username", in: app)
        XCTAssertFalse(submit.isEnabled, "Log In is enabled without a password")
        type("fake-password", into: "login.password", in: app)
        XCTAssertTrue(submit.isEnabled, "Log In is still disabled with both fields filled")
    }

    @MainActor
    func testCookieFieldsValidateBeforeSending() {
        let app = launchApp()
        openLogin(in: app)
        select("Cookie", in: app)
        let submit = element("login.submit", in: app)
        XCTAssertTrue(submit.waitForExistence(timeout: 5), "Log In button not found")
        XCTAssertFalse(submit.isEnabled)

        type("abc", into: "login.memberID", in: app)
        type(String(repeating: "0", count: 32), into: "login.passHash", in: app)
        XCTAssertTrue(submit.isEnabled)
        tapOnceSettled(submit)

        // The fields are checked before the login begins, without the WebView store (`CookieCredentials.validate()`,
        // M2 review L006): the alert does not wait for WebKit, which on a busy simulator took over 5 s to clear.
        let alert = app.alerts["Login Failed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "No Login Failed alert")
        XCTAssertTrue(alert.staticTexts["ipb_member_id must be a number."].exists, "Unexpected alert message")
    }

    @MainActor
    func testClosingTheWebLoginChangesNothing() {
        let app = launchApp()
        openLogin(in: app)
        select("Web", in: app)
        let open = element("login.web.open", in: app)
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Open Login Page not found")
        XCTAssertTrue(open.isEnabled, "Web login is disabled although the WebKit user agent was read")
        open.tap()

        let closeWeb = element("login.web.close", in: app)
        XCTAssertTrue(closeWeb.waitForExistence(timeout: 5), "Web login sheet did not appear")
        closeWeb.tap()
        XCTAssertTrue(closeWeb.waitForNonExistence(timeout: 5), "Web login sheet is still shown")
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Login sheet is gone")

        let close = element("login.close", in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Login sheet close button not found")
        close.tap()
        XCTAssertTrue(element("account.login", in: app).waitForExistence(timeout: 5), "Still signed out: Log In expected")
        XCTAssertFalse(element("account.logout", in: app).exists, "Signed in after closing the web login")
    }

    /// A cookie login with made-up values signs in offline (the profile run fails without the network, the profile
    /// page is about:blank); Log Out asks first, and confirming signs out.
    @MainActor
    func testLogOutAsksFirst() {
        let app = launchApp()
        openLogin(in: app)
        select("Cookie", in: app)
        type("1234567", into: "login.memberID", in: app)
        type("0123456789abcdef0123456789abcdef", into: "login.passHash", in: app)
        tapOnceSettled(element("login.submit", in: app))
        // 30 s, as the cookie field check's: the login first clears the WebView store, which on a busy simulator took
        // over 15 s (M2 review L036). The tree tells a sheet still logging in from one showing Login Failed.
        if !element("login.method", in: app).waitForNonExistence(timeout: 30) {
            attachElementTree(of: app)
            XCTFail("Login sheet did not close")
            return
        }

        let logOut = element("account.logout", in: app)
        XCTAssertTrue(logOut.waitForExistence(timeout: 5), "Log Out not found")
        XCTAssertEqual(element("account.name", in: app).label, "Logged In")
        XCTAssertTrue(element("account.avatar", in: app).exists, "Avatar not shown")
        logOut.tap()
        let confirm = element("account.logout.confirm", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "No confirmation")
        XCTAssertFalse(element("account.login", in: app).exists, "Signed out before confirming")
        confirm.tap()
        XCTAssertTrue(element("account.login", in: app).waitForExistence(timeout: 5), "Still signed in")
        XCTAssertFalse(element("account.logout", in: app).exists)
    }

    // MARK: - Helpers

    /// Settings tab → Log In → the login sheet.
    @MainActor
    private func openLogin(in app: XCUIApplication) {
        selectTab("settings", in: app)
        XCTAssertTrue(element("settings.root", in: app).waitForExistence(timeout: 5), "Settings page did not appear")
        let login = element("account.login", in: app)
        XCTAssertTrue(login.waitForExistence(timeout: 5), "Log In not found")
        login.tap()
        XCTAssertTrue(element("login.method", in: app).waitForExistence(timeout: 5), "Login sheet did not appear")
    }

    /// Selects the segment `title` of the login method picker.
    @MainActor
    private func select(_ title: String, in app: XCUIApplication) {
        let segment = element("login.method", in: app).buttons[title]
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "Segment \(title) not found")
        segment.tap()
    }

    /// Taps `element` once its frame has stayed the same for half a second (up to 5 s). On the iPad simulator the
    /// software keyboard can hide and show again while text is typed, moving the login sheet; a tap computed before
    /// such a move lands where the button no longer is.
    @MainActor
    private func tapOnceSettled(_ element: XCUIElement) {
        _ = settledFrame(of: element)
        element.tap()
    }

    /// `element`'s frame once it has stayed the same for half a second (up to 5 s).
    @MainActor
    private func settledFrame(of element: XCUIElement) -> CGRect {
        let deadline = Date.now.addingTimeInterval(5)
        var frame = element.frame
        while Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let next = element.frame
            if next == frame { break }
            frame = next
        }
        return frame
    }

    /// Taps the field and types `text`. On the iPad simulator the software keyboard can hide or show around the tap
    /// and move the login sheet: a tap that went out before the move may miss the field, which then has no keyboard
    /// focus to type into (full run 2026-11-09, `testLogOutAsksFirst`). So the field is tapped once the sheet is still,
    /// and again, up to three times, whenever it moved meanwhile; tapping a field that already has focus only moves
    /// the caret.
    @MainActor
    private func type(_ text: String, into identifier: String, in app: XCUIApplication) {
        let field = element(identifier, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Field \(identifier) not found")
        for _ in 0..<3 {
            let before = settledFrame(of: field)
            field.tap()
            if settledFrame(of: field) == before { break }
        }
        field.typeText(text)
    }
}
