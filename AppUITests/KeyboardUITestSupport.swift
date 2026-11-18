import XCTest

// Typing into a sheet sets more off than the text, on the iPad simulator (iOS 27.2) most of all: a number pad field
// first gets the system's number pad popover; the typing takes it away, and up to 2 s later the keyboard comes up,
// moves the sheet towards the top and brings the popover back. The popover's dismiss region covers the screen, so
// nothing below it can be hit while it shows: a tap only closes the popover. The jump sheets (browse B5, B7) and the
// search filters (search Q3) wait for all that before they tap anything else.
//
// Whether a field has the keyboard focus is read from the field, not from the keyboard: on the iPhone Duo a keyboard
// element stays in the tree below the screen whether a field has the focus or not, and with a hardware keyboard there
// is none at all.

extension XCTestCase {
    /// Whether `field` has the keyboard focus within `timeout` seconds, checked every 0.25 s
    /// (`hasKeyboardFocus(_:in:)`).
    @MainActor func waitForKeyboardFocus(
        _ field: XCUIElement, within timeout: TimeInterval, in app: XCUIApplication
    ) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while true {
            if hasKeyboardFocus(field, in: app) { return true }
            guard Date.now < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Whether `field` has the keyboard focus now: its snapshot's `hasKeyboardFocus` (what XCTest checks before it
    /// types, "Neither element nor any descendant has keyboard focus"). Should XCTest not offer that key, whether a
    /// software keyboard shows on screen (`keyboardIsOnScreen(in:)`).
    @MainActor func hasKeyboardFocus(_ field: XCUIElement, in app: XCUIApplication) -> Bool {
        guard field.exists else { return false }
        guard field.responds(to: NSSelectorFromString("hasKeyboardFocus")) else { return keyboardIsOnScreen(in: app) }
        return (field.value(forKey: "hasKeyboardFocus") as? Bool) == true
    }

    /// Whether a software keyboard shows on screen: one in the element tree may sit below the window (the iPhone Duo,
    /// or while the simulator takes typing for a hardware keyboard's).
    @MainActor func keyboardIsOnScreen(in app: XCUIApplication) -> Bool {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return false }
        let frame = keyboard.frame
        return frame.height > 100 && frame.minY < app.windows.firstMatch.frame.maxY - 100
    }

    /// Waits for what typing into a field of the open sheet titled `title` set off to settle: the keyboard (up to 5 s;
    /// none comes with a hardware keyboard), then `anchor`, a control of the sheet, to stay put (`waitUntilStill`),
    /// and not before 2.5 s from the start: a keyboard element that is there already (on the iPhone Duo it stays
    /// below the screen) or a sheet that has not moved yet proves nothing while the late keyboard may still come. A
    /// popover still up is then closed with a tap on the sheet's title, the one in the window's upper half (the sheet's
    /// bar), which does nothing in the sheet itself, and `anchor` waited for again.
    @MainActor func settleTyping(inSheetTitled title: String, anchor: XCUIElement, in app: XCUIApplication) {
        let earliest = Date.now.addingTimeInterval(2.5)
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        waitUntilStill(anchor, notBefore: earliest, in: app, step: "\(title) after typing")
        let popover = app.popovers.firstMatch
        guard popover.exists else { return }
        let window = app.windows.firstMatch.frame
        let headings = app.staticTexts.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex
        guard let heading = headings.first(where: { $0.exists && $0.frame.midY < window.midY }) else {
            attachElementTree(of: app)
            XCTFail("The sheet has no title \(title) in the window's upper half")
            return
        }
        // By coordinate: under the popover's dismiss region the title is not hittable, so an element tap would refuse.
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5), "The number pad popover did not close")
        waitUntilStill(anchor, in: app, step: "\(title) after the popover closed")
    }

    /// Waits for `element` to stay put: two reads of its frame 0.5 s apart agree, the later one not before `earliest`.
    /// Gives up `timeout` seconds after `earliest` (or after now, if later); then the element tree is attached, named
    /// after `step`, and the caller goes on: its next checks decide.
    @MainActor func waitUntilStill(
        _ element: XCUIElement, notBefore earliest: Date = .distantPast, timeout: TimeInterval = 5,
        in app: XCUIApplication, step: String
    ) {
        let deadline = max(Date.now, earliest).addingTimeInterval(timeout)
        var last = element.frame
        while Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let now = element.frame
            if now == last, Date.now >= earliest { return }
            last = now
        }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "element tree: \(step), not still after \(Int(timeout)) s"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
