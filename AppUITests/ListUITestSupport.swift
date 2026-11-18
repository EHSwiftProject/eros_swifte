import XCTest

// Lookups the gallery list tests, the tab container tests, the list jump tests, the gallery group tests and the
// toplists tests share (browse B4b, B5, B6, B7): the list's galleries and swiping for more of them, the items of an
// open menu, found by title (on iOS 27.2 a menu item does not carry its SwiftUI identifier), whether the toolbar offers
// an item, the list's jump sheets, the title menu and its gallery groups, the back button, and dragging a row by its
// reorder control.

/// The title menu of the favorites page over the constructed `list-favorites.html`, shared by the favorites tests and
/// the screen tour.
enum FavoritesFixtureMenu {
    /// The items once the page named the folders: All Favorites with the sum of the counts, the ten folders with
    /// theirs, Local Favorites.
    static let items: [String] = {
        let counts = [1, 11, 1, 111, 1, 1, 1, 11, 1, 1]
        let folders = counts.enumerated().map { "Fake Folder \($0.offset) (\($0.element))" }
        return ["All Favorites (\(counts.reduce(0, +)))"] + folders + ["Local Favorites"]
    }()
}

extension XCTestCase {
    /// The identifiers of the galleries in the element tree now (`gallery.item.<gid>`; a lazy list holds the ones near
    /// the screen only).
    @MainActor func itemIdentifiers(in app: XCUIApplication) -> [String] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "gallery.item."))
            .allElementsBoundByIndex.map(\.identifier)
    }

    /// Swipes the list of the page identified `root` up until more than `count` galleries passed by (all those the
    /// element tree held, `itemIdentifiers(in:)`), at most `maxSwipes` times; stops as soon as there are, since the
    /// page after the next one may not be replayed. Returns how many galleries were seen at first and in all, and how
    /// many swipes it took. Asserts nothing: callers check `seen`.
    @MainActor func swipeUntilMoreGalleries(
        than count: Int, in root: String, maxSwipes: Int, app: XCUIApplication
    ) -> (first: Int, seen: Int, swipes: Int) {
        var seen = Set(itemIdentifiers(in: app))
        let first = seen.count
        var swipes = 0
        while seen.count <= count, swipes < maxSwipes {
            element(root, in: app).swipeUp()
            seen.formUnion(itemIdentifiers(in: app))
            swipes += 1
        }
        return (first, seen.count, swipes)
    }

    /// The identifier of the topmost gallery once the list shows (`firstGalleryItem(in:)`); fails the test without one.
    @MainActor func topGalleryIdentifier(in app: XCUIApplication) -> String? {
        guard let item = firstGalleryItem(in: app) else {
            XCTFail("No gallery in the list")
            return nil
        }
        return item.identifier
    }

    /// The topmost hittable gallery of the gallery list (`gallery.item.<gid>`), waiting up to 30 s for one (the tabs
    /// appear once the app has read the user agent). Returned as the element with its identifier, so it can be looked
    /// for again once it is scrolled away.
    @MainActor func firstGalleryItem(in app: XCUIApplication) -> XCUIElement? {
        let items = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "gallery.item."))
        let deadline = Date.now.addingTimeInterval(30)
        while true {
            let hittable = items.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            if let top = hittable.min(by: { $0.frame.minY < $1.frame.minY }) {
                return element(top.identifier, in: app)
            }
            guard Date.now < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// The topmost hittable gallery that lies wholly in the window below the navigation bars over it
    /// (`firstWhollyVisible(_:in:)` without a ceiling), waiting up to 10 s for one; nil without one. Unlike
    /// `firstGalleryItem(in:)` it passes over a row the screen's edge cuts: on a rotated display (the iPhone Duo held
    /// sideways or upside down) XCTest aims a tap at a cut element without turning the point with the display, so the
    /// tap lands elsewhere (on a tab item, after a swipe left the top row half off the screen). And over a row under
    /// the navigation bar: it is hittable only through the strip above the bar, and a tap there goes to the status
    /// bar, which scrolls the list to its top (the iPhone's `testRotatingDoesNotReselect`). Returned as the element
    /// with its identifier, as `firstGalleryItem(in:)`.
    @MainActor func firstWhollyVisibleGalleryItem(in app: XCUIApplication) -> XCUIElement? {
        let items = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "gallery.item."))
        // The shared lookup, then by identifier rather than index, so the row can be found again once the list moved.
        return firstWhollyVisible(items, in: app).map { element($0.identifier, in: app) }
    }

    /// Waits up to 30 s for the topmost gallery (`firstGalleryItem(in:)`) to have an identifier that meets
    /// `condition`; fails the test with `message` when it does not.
    @MainActor func waitForTopGallery(
        in app: XCUIApplication, _ message: String, until condition: (String) -> Bool
    ) {
        let deadline = Date.now.addingTimeInterval(30)
        while true {
            if let top = firstGalleryItem(in: app)?.identifier, condition(top) { return }
            guard Date.now < deadline else { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail(message)
    }

    /// The only hittable element labelled `title` (a menu item; while a menu is open the page below is not hittable),
    /// waiting up to 5 s for it; nil when there is none or more than one. Tab items (`tab.<rawValue>`) never count:
    /// a menu item may have a tab's title (the gallery group named Gallery). Images never count either: a menu item's
    /// symbol may read the same as its title (Search's magnifying glass reads "Search").
    @MainActor func hittableMenuItem(_ title: String, in app: XCUIApplication) -> XCUIElement? {
        let labelled = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND NOT (identifier BEGINSWITH %@)", title, "tab."
        ))
        let deadline = Date.now.addingTimeInterval(5)
        while true {
            // Without images: a row's symbol labelled as the row would make two of one item.
            let hittable = labelled.allElementsBoundByIndex.filter {
                $0.exists && $0.elementType != .image && $0.isHittable
            }
            if hittable.count == 1 { return hittable[0] }
            guard Date.now < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Whether the toolbar offers an item, on the bar (`identifier`) or in its overflow menu (`title`):
    /// `toolbarItem(_:title:in:)` finds it within its waits (up to 15 s to say no). An overflow menu opened to look
    /// stays open, so look last.
    @MainActor func toolbarOffers(_ identifier: String, title: String, in app: XCUIApplication) -> Bool {
        toolbarItem(identifier, title: title, in: app) != nil
    }

    /// The first hittable element labelled `title`, waiting up to 5 s for one: a menu item the system may expose
    /// twice, as the item and its title (the long-press menu's Share).
    @MainActor func firstHittableMenuItem(_ title: String, in app: XCUIApplication) -> XCUIElement? {
        let labelled = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title))
        let deadline = Date.now.addingTimeInterval(5)
        while true {
            if let item = labelled.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                return item
            }
            guard Date.now < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    // MARK: - List jumps

    /// The toolbar item `identifier`, on the bar or in the overflow menu (`toolbarItem(_:title:in:)`), checked to carry
    /// `title` (the Duo rail shows only the symbol); fails the test without one.
    @MainActor func titledToolbarItem(_ identifier: String, title: String, in app: XCUIApplication) -> XCUIElement? {
        guard let item = toolbarItem(identifier, title: title, in: app) else {
            XCTFail("Toolbar item \(identifier) not found")
            return nil
        }
        XCTAssertEqual(item.label, title, "The title of \(identifier)")
        return item
    }

    /// Opens the Jump/Seek sheet of a cursor list from the toolbar and waits for its text field.
    @MainActor func openJumpSeek(in app: XCUIApplication) {
        guard let open = titledToolbarItem("jump.open", title: "Jump/Seek", in: app) else { return }
        open.tap()
        XCTAssertTrue(element("jump.text", in: app).waitForExistence(timeout: 10), "The Jump/Seek sheet did not open")
    }

    /// Opens the Jump to Page sheet of a numbered list from the toolbar and waits for its page field.
    @MainActor func openPageJump(in app: XCUIApplication) {
        guard let open = titledToolbarItem("jump.page", title: "Jump to Page", in: app) else { return }
        open.tap()
        XCTAssertTrue(
            element("jump.pageText", in: app).waitForExistence(timeout: 10), "The Jump to Page sheet did not open"
        )
    }

    /// Taps Go (`jump.go`) in the open jump sheet titled `title` once what typing into `field` set off has settled
    /// (`settleTyping(inSheetTitled:anchor:in:)`: on the iPad the late keyboard moves the sheet, and the number pad
    /// popover it brings back keeps Go from being hit), then waits up to 10 s for `field` to go (the sheet closed).
    @MainActor func tapGo(afterTypingIn field: XCUIElement, sheetTitle title: String, in app: XCUIApplication) {
        settleTyping(inSheetTitled: title, anchor: element("jump.go", in: app), in: app)
        tapToolbarItem("jump.go", title: "Go", in: app)
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "The sheet did not close")
    }

    // MARK: - Title menu and gallery groups

    /// The button that opens the title menu (`toolbarTitleMenu`) of a page titled `title`: a hittable button labelled
    /// with the title, or the title and the kind of menu ("Gallery, Actions Menu"; iOS 27.2), that is neither a tab
    /// item nor a gallery. Waits up to 30 s: the tabs appear once the app has read the user agent (`selectTab`).
    @MainActor func titleMenuButton(_ title: String, in app: XCUIApplication) -> XCUIElement? {
        let buttons = app.buttons.matching(NSPredicate(
            format: "(label == %@ OR label BEGINSWITH %@) AND NOT (identifier BEGINSWITH %@)"
                + " AND NOT (identifier BEGINSWITH %@)",
            title, "\(title),", "tab.", "gallery."
        ))
        let deadline = Date.now.addingTimeInterval(30)
        while true {
            if let button = buttons.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                return button
            }
            guard Date.now < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Opens the title menu of the page titled `title` and waits up to 5 s for its item `item` (the menu is open once
    /// that shows). A tap the app loses is made once more: on the Duo, a tap on the title right after launch, while
    /// the page's first content came in, opened nothing (browse B6, first full run). That second tap is recorded in the
    /// result bundle as an activity ("Tapped <title> again"), so how often the app loses the first can be counted.
    /// Fails the test (with the element tree) when there is no such title or the menu does not open.
    @MainActor func openTitleMenu(_ title: String, offering item: String, in app: XCUIApplication) {
        let offered = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", item)).firstMatch
        for attempt in 0..<2 {
            // After a tap the title may be there but covered by the menu that tap opened, without `item` in it: the
            // second round looks for the title at once, and a title that is there but cannot be hit fails at once.
            let button: XCUIElement
            if attempt == 0 {
                guard let found = titleMenuButton(title, in: app) else {
                    attachElementTree(of: app)
                    XCTFail("No title menu titled \(title)")
                    return
                }
                button = found
            } else {
                let titled = app.buttons.matching(NSPredicate(
                    format: "(label == %@ OR label BEGINSWITH %@) AND NOT (identifier BEGINSWITH %@)"
                        + " AND NOT (identifier BEGINSWITH %@)",
                    title, "\(title),", "tab.", "gallery."
                )).allElementsBoundByIndex.filter(\.exists)
                guard let hittable = titled.first(where: \.isHittable) else {
                    attachElementTree(of: app)
                    XCTFail(titled.isEmpty
                        ? "Tapping \(title) showed no \(item), and the title is gone"
                        : "Tapping \(title) showed no \(item), and the title cannot be tapped again")
                    return
                }
                button = hittable
            }
            if attempt == 0 {
                button.tap()
            } else {
                XCTContext.runActivity(named: "Tapped \(title) again") { _ in button.tap() }
            }
            if offered.waitForExistence(timeout: 5) { return }
        }
        attachElementTree(of: app)
        XCTFail("The title menu of \(title) did not open")
    }

    /// The gallery tab (browse B6): picks the group `group` in the title menu of the page titled `current`, then waits
    /// for the menu to close (its Manage Groups item to go). Fails the test when the menu or the group is missing. The
    /// page itself is not looked at: what the group loads may put an alert above it.
    @MainActor func selectGroup(_ group: String, from current: String, in app: XCUIApplication) {
        openTitleMenu(current, offering: "Manage Groups", in: app)
        guard let item = hittableMenuItem(group, in: app) else {
            attachElementTree(of: app)
            XCTFail("The title menu has no group \(group)")
            return
        }
        item.tap()
        let manage = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Manage Groups"))
        XCTAssertTrue(manage.firstMatch.waitForNonExistence(timeout: 5), "The title menu did not close")
    }

    // MARK: - Navigation and rows

    /// The system back button (`systemBackButton(in:)`), tapped once it exists.
    @MainActor func goBack(in app: XCUIApplication) {
        let back = systemBackButton(in: app)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "System back button not found")
        back.tap()
    }

    /// Drags `row` (titled `title`) by its reorder control, a button labelled "Reorder <title>", to the top edge of
    /// `target`'s row, until `row` is above `target`; the list has to be in edit mode.
    ///
    /// Under a heavy host load the system now and then drops the synthesized drag: the row is lifted and carried up,
    /// then goes back to its place without a move (the full run on the iPhone 17, browse B2). Up to three attempts,
    /// each checked, so a move the app loses still fails the caller's check after the last one.
    @MainActor func drag(_ row: XCUIElement, titled title: String, above target: XCUIElement, in app: XCUIApplication) {
        let handle = app.buttons.matching(NSPredicate(format: "label == %@", "Reorder \(title)")).firstMatch
        guard row.waitForExistence(timeout: 5), handle.waitForExistence(timeout: 5) else {
            attachElementTree(of: app)
            XCTFail("No reorder handle on the \(title) row")
            return
        }
        for _ in 0..<3 where row.frame.minY >= target.frame.minY {
            handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                forDuration: 1, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)),
                withVelocity: .slow, thenHoldForDuration: 1
            )
            let deadline = Date.now.addingTimeInterval(3)
            while row.frame.minY >= target.frame.minY, Date.now < deadline {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        if row.frame.minY >= target.frame.minY {
            attachElementTree(of: app)
        }
    }

    /// Attaches the app's element tree, kept whether the test passes or not.
    @MainActor func attachElementTree(of app: XCUIApplication) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "element tree"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
