import XCTest

/// UI tests for the quick search page (search Q4) over the replayed fixtures, in English. Every test opens the search
/// page from the gallery tab (`openSearch()`; the tab's root, the Popular group: GET https://e-hentai.org/popular →
/// eh/list/popular.html), then the quick search page from its toolbar. Neither the system's share sheet nor its file
/// browser is opened.
///
/// - Running the quick search `eros0fixture0nohit`: GET https://e-hentai.org/?f_search=eros0fixture0nohit →
///   eh/list/search-empty.html. The text reaches the search field as the text searched, for which no tag suggestions
///   are asked, and nothing is typed in the search field, so no POST api.php is sent.
/// - Running the quick search `https://e-hentai.org/g/1234/0123456789/` opens the gallery's placeholder
///   (`route.placeholder.gallery`), which fetches nothing (as `SearchScreenTests.testSiteGalleryURLOffersToOpenIt`).
/// - Text is typed only into the field of New Quick Search, which sends nothing.
///
/// Screenshots are named `q4-<name>` (the cover-screen checks).
final class QuickSearchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The search page's Quick Search (search-entry, the item on the bar or in the open overflow menu) opens the page,
    /// empty at first (quick-search-empty); Add asks for the text (quick-search-new, its field focused, before typing)
    /// and adds a row (quick-search-list). Tapping the row goes back and searches its text, which the search page then
    /// knows as a quick search: In Quick Search, disabled.
    @MainActor
    func testAddingAndRunningAQuickSearch() {
        let app = openSearch()
        openQuickSearches(screenshot: "q4-search-entry", in: app)
        XCTAssertTrue(element("quickSearch.empty", in: app).waitForExistence(timeout: 10), "No empty state")
        attachScreenshot("q4-quick-search-empty", of: app)

        addQuickSearch("eros0fixture0nohit", screenshot: "q4-quick-search-new", in: app)
        let row = quickSearchRow("eros0fixture0nohit", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The quick search was not added")
        XCTAssertFalse(element("quickSearch.empty", in: app).exists, "The empty state is still shown")
        attachScreenshot("q4-quick-search-list", of: app)

        row.tap()
        XCTAssertTrue(
            element("quickSearch.root", in: app).waitForNonExistence(timeout: 10), "The quick search page stays"
        )
        XCTAssertTrue(element("search.root", in: app).waitForExistence(timeout: 10), "Not back on the search page")
        let field = searchField(in: app)
        let deadline = Date.now.addingTimeInterval(10)
        while fieldText(field) != "eros0fixture0nohit", Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertEqual(fieldText(field), "eros0fixture0nohit")
        XCTAssertTrue(element("gallery.empty", in: app).waitForExistence(timeout: 30), "The quick search did not run")

        guard let added = overflowItem("search.addQuickSearch", title: "In Quick Search", in: app) else {
            attachElementTree(of: app)
            XCTFail("Back on the search page, the text is not known as a quick search")
            return
        }
        XCTAssertEqual(added.label, "In Quick Search")
        XCTAssertFalse(added.isEnabled, "In Quick Search can still be tapped")
    }

    /// In edit mode (quick-search-edit) a tap on a row's text does nothing: the page stays, nothing is searched. The
    /// row's delete control, then Delete, removes it; the page is empty again.
    @MainActor
    func testEditingDeletesARow() {
        let app = openSearch()
        openQuickSearches(in: app)
        addQuickSearch("fake quick search", in: app)
        let row = quickSearchRow("fake quick search", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The quick search was not added")

        tapToolbarItem("quickSearch.edit", title: "Edit", in: app)
        // The row's delete control is an image on iOS 27.2 (exposed twice), not a button.
        let control = app.images.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "minus.circle.fill", "remove"
        ))
        guard let remove = firstHittable(control, within: 10) else {
            attachElementTree(of: app)
            XCTFail("Edit mode shows no delete control")
            return
        }
        attachScreenshot("q4-quick-search-edit", of: app)

        // The row's text, past the delete control and short of the reorder control: the middle between the two,
        // wherever the row puts them, not an offset measured on one device. The text has no element of its own to tap:
        // the row's button reads as one, labelled with the text (iPhone, iOS 27.2).
        let reorder = app.buttons.matching(NSPredicate(format: "label == %@", "Reorder fake quick search")).firstMatch
        let start = remove.frame.maxX
        let end = reorder.exists ? reorder.frame.minX : row.frame.maxX
        let middle = CGVector(dx: (start + end) / 2 - row.frame.minX, dy: row.frame.height / 2)
        row.coordinate(withNormalizedOffset: .zero).withOffset(middle).tap()
        XCTAssertFalse(
            element("quickSearch.root", in: app).waitForNonExistence(timeout: 3), "A tap in edit mode left the page"
        )
        XCTAssertFalse(element("search.root", in: app).exists, "A tap in edit mode went back to the search page")
        let results = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@ OR identifier BEGINSWITH %@",
            ["gallery.loading", "gallery.empty", "gallery.failure"], "gallery.list."
        ))
        XCTAssertFalse(results.firstMatch.exists, "A tap in edit mode searched the text")
        XCTAssertTrue(row.exists, "The row is gone")

        remove.tap()
        guard let delete = firstHittableMenuItem("Delete", in: app) else {
            attachElementTree(of: app)
            XCTFail("The delete control offers no Delete")
            return
        }
        delete.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "The row is still there")
        XCTAssertTrue(element("quickSearch.empty", in: app).waitForExistence(timeout: 10), "No empty state")
    }

    /// Import and Export (on the bar or in the overflow menu) offers Share, Export to Files, Import and Remove All,
    /// all enabled. Menu items are found by title; Share is exposed twice, as the item and
    /// its symbol, so the first one counts.
    @MainActor
    func testImportExportMenuOffersItsActions() {
        let app = openSearch()
        openQuickSearches(in: app)
        tapToolbarItem("quickSearch.menu", title: "Import and Export", in: app)
        for title in ["Share", "Export to Files", "Import", "Remove All"] {
            let found = title == "Share" ? firstHittableMenuItem(title, in: app) : hittableMenuItem(title, in: app)
            guard let item = found else {
                attachElementTree(of: app)
                XCTFail("Import and Export has no \(title)")
                return
            }
            XCTAssertTrue(item.isEnabled, "\(title) is disabled")
        }
    }

    /// A quick search that is a site gallery link opens the gallery's placeholder once, nothing fetched; one step back
    /// is the search page, the quick search page gone too, and the search page's Quick Search opens it again. The
    /// search page's `runQuickSearch` takes its quick search page off the stack
    /// (`navigationDestination(isPresented:)`), then the gallery's route is pushed onto the tab's path. On iOS 27.2 the
    /// push alone also takes that page off and lets it go (this test passes without the first step), so the first step
    /// is pinned by `testAddingAndRunningAQuickSearch`, where a text is searched on the search page.
    @MainActor
    func testRunningAGalleryLinkOpensItOnce() {
        let link = "https://e-hentai.org/g/1234/0123456789/"
        let app = openSearch()
        openQuickSearches(in: app)
        addQuickSearch(link, in: app)
        let row = quickSearchRow(link, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The link was not added")

        row.tap()
        XCTAssertTrue(
            element("route.placeholder.gallery", in: app).waitForExistence(timeout: 10), "The gallery did not open"
        )
        XCTAssertFalse(element("quickSearch.root", in: app).exists, "The quick search page is still shown")

        goBack(in: app)
        XCTAssertTrue(
            element("route.placeholder.gallery", in: app).waitForNonExistence(timeout: 5),
            "The gallery is still shown: it was pushed twice"
        )
        XCTAssertTrue(element("search.root", in: app).waitForExistence(timeout: 10), "Back did not reach the search")
        XCTAssertFalse(element("quickSearch.root", in: app).exists, "Back reached the quick search page")

        // The search page let its quick search page go: its Quick Search opens it again.
        openQuickSearches(in: app)
    }

    /// Remove All asks first (remove-all-question), in a system alert: its Cancel keeps the quick search, its Remove
    /// All empties the page.
    @MainActor
    func testRemoveAllAsksFirst() {
        let app = openSearch()
        openQuickSearches(in: app)
        addQuickSearch("fake quick search", in: app)
        let row = quickSearchRow("fake quick search", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The quick search was not added")

        let question = askToRemoveAll(in: app)
        attachScreenshot("q4-remove-all-question", of: app)
        let cancel = question.buttons["Cancel"]
        guard cancel.exists else {
            attachElementTree(of: app)
            XCTFail("The question has no Cancel")
            return
        }
        cancel.tap()
        XCTAssertTrue(question.waitForNonExistence(timeout: 5), "The question did not close")
        XCTAssertTrue(row.exists, "Cancel removed the quick search")
        XCTAssertFalse(element("quickSearch.empty", in: app).exists, "Cancel emptied the page")

        let confirm = askToRemoveAll(in: app).buttons["Remove All"]
        guard confirm.exists else {
            attachElementTree(of: app)
            XCTFail("The question has no Remove All")
            return
        }
        confirm.tap()
        XCTAssertTrue(element("quickSearch.empty", in: app).waitForExistence(timeout: 10), "The page is not empty")
        XCTAssertFalse(row.exists, "The quick search is still there")
    }

    // MARK: - Helpers

    /// On the quick search page: Import and Export, then Remove All; returns the question asked, a system alert
    /// (`Remove all quick searches?`, QK64, user decision 2026-11-17) found by its title, waited for up to 5 s.
    @MainActor private func askToRemoveAll(in app: XCUIApplication) -> XCUIElement {
        tapToolbarItem("quickSearch.menu", title: "Import and Export", in: app)
        if let item = hittableMenuItem("Remove All", in: app) {
            item.tap()
        } else {
            attachElementTree(of: app)
            XCTFail("Import and Export has no Remove All")
        }
        let question = app.alerts["Remove all quick searches?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5), "Remove All did not ask first")
        return question
    }

    /// On the search page: Quick Search, checked to carry its title (the Duo rail shows only the symbol), tapped once
    /// `screenshot`, if any, is attached (with the overflow menu open when the item is in it); waits for the page.
    @MainActor private func openQuickSearches(screenshot: String? = nil, in app: XCUIApplication) {
        guard let entry = titledToolbarItem("search.quickSearch", title: "Quick Search", in: app) else {
            attachElementTree(of: app)
            return
        }
        if let screenshot { attachScreenshot(screenshot, of: app) }
        entry.tap()
        XCTAssertTrue(
            element("quickSearch.root", in: app).waitForExistence(timeout: 10), "The quick search page did not open"
        )
    }

    /// On the quick search page: Add, then `text` in New Quick Search's field, tapped first and checked to have the
    /// keyboard focus, then the alert's Add; waits for the alert to go. `screenshot`, if any, is attached with the
    /// field focused, before typing: before the tap when the alert focused the field itself, as a tap on a focused
    /// field brings up its edit menu, which would cover part of the alert.
    @MainActor private func addQuickSearch(_ text: String, screenshot: String? = nil, in app: XCUIApplication) {
        tapToolbarItem("quickSearch.add", title: "Add", in: app)
        let alert = app.alerts.matching(NSPredicate(format: "label == %@", "New Quick Search")).firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "New Quick Search did not open")
        // On iOS 27.2 the alert's field does not carry its SwiftUI identifier (`quickSearch.newText`).
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "New Quick Search has no field")
        var screenshot = screenshot
        if let name = screenshot, waitForKeyboardFocus(field, within: 3, in: app) {
            attachScreenshot(name, of: app)
            screenshot = nil
        }
        field.tap()
        XCTAssertTrue(
            waitForKeyboardFocus(field, within: 5, in: app), "The field of New Quick Search has no keyboard focus"
        )
        if let screenshot { attachScreenshot(screenshot, of: app) }
        field.typeText(text)
        let add = alert.buttons.matching(NSPredicate(format: "label == %@", "Add")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "New Quick Search has no Add")
        let deadline = Date.now.addingTimeInterval(5)
        while !add.isEnabled, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(add.isEnabled, "Add is disabled with \(text) typed")
        add.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 10), "New Quick Search did not close")
    }

    /// What the system puts before a row's label in edit mode (iOS 27.2): its delete control, "Remove".
    private static let editModePrefix = "Remove, "

    /// The quick search page's row of `text` (`quickSearch.row`, labelled with the text; in edit mode
    /// "Remove, <text>").
    @MainActor private func quickSearchRow(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (label == %@ OR label == %@)", "quickSearch.row", text,
            Self.editModePrefix + text
        )).firstMatch
    }
}
