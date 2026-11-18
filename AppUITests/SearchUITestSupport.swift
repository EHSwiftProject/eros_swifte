import XCTest

// Lookups the search page's tests share (search Q2, Q3, Q4): opening the page from the
// gallery tab, its search field, waiting for the field's focus before typing, emptying the field, and
// a toolbar item to check, not tap, wherever the toolbar put it.

extension XCTestCase {
    /// The Gallery tab's Search item, tapped once the tab shows a gallery; waits for the search page. `routes` go to
    /// `launchApp(replayingFixtures:routes:arguments:)` (none by default).
    @MainActor func openSearch(routes: [String: UITestRoute] = [:]) -> XCUIApplication {
        let app = launchApp(replayingFixtures: true, routes: routes)
        XCTAssertNotNil(firstGalleryItem(in: app), "The gallery tab shows no gallery")
        tapToolbarItem("gallery.search", title: "Search", in: app)
        XCTAssertTrue(element("search.root", in: app).waitForExistence(timeout: 10), "The search page did not open")
        return app
    }

    /// The page's search field, waiting up to 10 s for it.
    @MainActor func searchField(in app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.firstMatch
        _ = field.waitForExistence(timeout: 10)
        return field
    }

    /// The page's search field once it has the keyboard focus, to type in: the page focuses it from a task after the
    /// push (`SearchModel.start()`), so the focus is waited for, up to 10 s; without it, the field is tapped and the
    /// focus waited for again, up to 10 s, and the test fails without it. The field's own focus, not the keyboard
    /// (`hasKeyboardFocus(_:in:)`): the Duo's keyboard element is there below the screen either way, and a hardware
    /// keyboard shows none.
    @MainActor func focusedSearchField(in app: XCUIApplication) -> XCUIElement {
        let field = searchField(in: app)
        if !waitForKeyboardFocus(field, within: 10, in: app) {
            field.tap()
            XCTAssertTrue(waitForKeyboardFocus(field, within: 10, in: app), "The search field has no keyboard focus")
        }
        return field
    }

    /// The text in `field` ("" while it shows its prompt).
    @MainActor func fieldText(_ field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == field.placeholderValue ? "" : value
    }

    /// Empties `field`, leaving it focused: its clear button, or else the delete key once per character. The clear
    /// button may also take the focus from the field (at a regular width, iPad, iOS 27.2; on the iPhone Duo now and
    /// then), so the field's own focus is watched for 1.5 s after it (`hasKeyboardFocus(_:in:)`): lost, or never
    /// there, the field is tapped once more, and the test fails unless it has the focus within 5 s. Not always
    /// tapped: a tap on a focused, empty field brings up its edit menu over the rows below.
    @MainActor func clear(_ field: XCUIElement, in app: XCUIApplication) {
        let text = fieldText(field)
        field.tap()
        let clearButton = field.descendants(matching: .button)
            .matching(NSPredicate(format: "label == %@", "Clear text")).firstMatch
        if clearButton.waitForExistence(timeout: 2), clearButton.isHittable {
            clearButton.tap()
            if !keepsKeyboardFocus(field, for: 1.5, in: app) {
                field.tap()
                XCTAssertTrue(
                    waitForKeyboardFocus(field, within: 5, in: app),
                    "The search field has no keyboard focus after Clear"
                )
            }
        } else {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count + 2))
        }
    }

    /// Whether `field` has the keyboard focus at every look (every 0.25 s) for `duration` seconds: false as soon as one
    /// look finds it without.
    @MainActor private func keepsKeyboardFocus(
        _ field: XCUIElement, for duration: TimeInterval, in app: XCUIApplication
    ) -> Bool {
        let end = Date.now.addingTimeInterval(duration)
        while true {
            guard hasKeyboardFocus(field, in: app) else { return false }
            guard Date.now < end else { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// A toolbar item titled `title`, to check rather than tap, enabled or not: on the bar, the element `identifier`
    /// labelled `title`, waited for up to 5 s; else the overflow button ("More") is tapped (waited for up to 5 s) and
    /// the first element labelled `title` that is not a tab item is waited for up to 5 s. A disabled menu item may not
    /// be hittable, so it only has to exist. nil when there is none; an overflow menu opened to look stays open.
    ///
    /// On iOS 27.2 a menu item does not carry the identifier its SwiftUI button has, and
    /// `toolbarItem(_:title:in:)` only returns hittable items.
    @MainActor func overflowItem(_ identifier: String, title: String, in app: XCUIApplication) -> XCUIElement? {
        let onBar = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label == %@", identifier, title
        )).firstMatch
        if onBar.waitForExistence(timeout: 5) { return onBar }
        let more = app.buttons.matching(NSPredicate(format: "label == %@", "More"))
        guard let overflow = firstHittable(more, within: 5) else { return nil }
        overflow.tap()
        let item = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND NOT (identifier BEGINSWITH %@)", title, "tab."
        )).firstMatch
        return item.waitForExistence(timeout: 5) ? item : nil
    }
}
