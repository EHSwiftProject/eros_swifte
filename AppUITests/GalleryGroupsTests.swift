import XCTest

/// UI tests for the gallery tab's custom groups (browse B6) over the replayed fixtures: the title menu, switching
/// groups, the group editor and its keyword sheet, the management page (adding, deleting, reordering) and the empty
/// state. The default groups are Popular (`/popular`), Gallery (`/`), Watched (`/watched`, a constructed page) and
/// Anthology; Anthology's search is not replayed, so no test shows it.
final class GalleryGroupsTests: XCTestCase {
    /// The watched list is not among the captured fixtures: a constructed page answers it.
    private static let routes = [
        "GET https://e-hentai.org/watched": UITestRoute(path: "constructed/eh/list-watched.html"),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDefaultGroupsAreListed() {
        let app = launch()
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery in the Popular group")
        openTitleMenu("Popular", offering: "Manage Groups", in: app)
        for title in ["Popular", "Gallery", "Watched", "Anthology", "Edit Group", "Manage Groups"] {
            XCTAssertNotNil(hittableMenuItem(title, in: app), "The title menu has no \(title)")
        }
        attachScreenshot("b6-titleMenu", of: app)
    }

    @MainActor
    func testSwitchingGroupsLoadsTheirList() {
        let app = launch()
        guard let popular = topGalleryIdentifier(in: app) else { return }

        selectGroup("Gallery", from: "Popular", in: app)
        waitForTopGallery(in: app, "The Gallery group did not load its list") { $0 != popular }
        guard let gallery = topGalleryIdentifier(in: app) else { return }
        // The rail with the hidden tabs and the list's jumps (`listJumpControls`) on a list that has a cursor.
        attachScreenshot("b6-galleryGroup", of: app)

        selectGroup("Watched", from: "Gallery", in: app)
        waitForTopGallery(in: app, "The Watched group did not load its list") { $0 != gallery && $0 != popular }
    }

    /// The new group's list is its search: its top gallery is neither Popular's nor the front page's (the Gallery
    /// group's), which a group whose text got lost would show.
    @MainActor
    func testAddingAGroupWithATextLoadsItsSearch() {
        let app = launch()
        guard let popular = topGalleryIdentifier(in: app) else { return }
        selectGroup("Gallery", from: "Popular", in: app)
        waitForTopGallery(in: app, "The Gallery group did not load its list") { $0 != popular }
        guard let front = topGalleryIdentifier(in: app) else { return }
        openManagement(from: "Gallery", in: app)
        openNewGroup(in: app)
        let name = element("group.name", in: app)
        name.tap()
        // Return ends the editing: a software keyboard (iPhone, iPad) would cover the rows below.
        name.typeText("Chinese Test\n")
        addText("language:chinese", screenshot: "b6-keyword", in: app)
        let text = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "group.searchText", "language:chinese"))
        XCTAssertTrue(text.firstMatch.waitForExistence(timeout: 5), "The text is not among the group's texts")
        attachScreenshot("b6-editor", of: app)
        save(in: app)

        XCTAssertTrue(groupRow("Chinese Test", in: app).waitForExistence(timeout: 5), "The group was not added")
        goBack(in: app)
        // Saved, the new group is the one shown.
        XCTAssertNotNil(titleMenuButton("Chinese Test", in: app), "The new group is not shown")
        waitForTopGallery(in: app, "The new group did not load its search") { $0 != popular && $0 != front }
    }

    @MainActor
    func testPopularHidesSearchOptions() {
        let app = launch()
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery in the Popular group")
        openManagement(from: "Popular", in: app)
        openNewGroup(in: app)
        let categories = element("group.categories", in: app)
        XCTAssertTrue(categories.waitForExistence(timeout: 5), "A new gallery group shows no categories")
        // The lazy form builds rows near the screen only: the last ones are made to show before they are expected to
        // go.
        let newText = element("group.newText", in: app)
        let advanced = element("group.advanced", in: app)
        scrollUntilVisible(advanced, in: app)
        XCTAssertTrue(newText.exists, "A new gallery group shows no search texts")
        XCTAssertTrue(advanced.exists, "A new gallery group shows no advanced options")

        let popular = element("group.type", in: app).buttons["Popular"]
        XCTAssertTrue(popular.waitForExistence(timeout: 5), "No Popular in the group types")
        popular.tap()
        XCTAssertTrue(categories.waitForNonExistence(timeout: 5), "A popular group shows the categories")
        XCTAssertTrue(newText.waitForNonExistence(timeout: 5), "A popular group shows the search texts")
        XCTAssertTrue(advanced.waitForNonExistence(timeout: 5), "A popular group shows the advanced options")

        element("group.type", in: app).buttons["Gallery"].tap()
        XCTAssertTrue(categories.waitForExistence(timeout: 5), "A gallery group shows no categories again")
    }

    /// The categories are on a page of their own (a form row would offer the first category's long-press items for
    /// all of them); Show Only Manga hides the nine others, which the editor's row then counts.
    @MainActor
    func testCategoryContextMenuOffersOnlyAndHide() {
        let app = launch()
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery in the Popular group")
        openManagement(from: "Popular", in: app)
        openNewGroup(in: app)
        let row = element("group.categories", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "No Categories row")
        XCTAssertTrue(shown(row).contains("All"), "The Categories row reads \"\(shown(row))\"")
        row.tap()
        let manga = element("category.manga", in: app)
        XCTAssertTrue(manga.waitForExistence(timeout: 10), "The Categories page did not open")
        XCTAssertTrue(element("category.western", in: app).waitForExistence(timeout: 5), "No Western category")
        attachScreenshot("b6-categories", of: app)

        manga.press(forDuration: 1.2)
        // A long-press menu's item may be exposed twice, as the item and its title.
        let showOnly = firstHittableMenuItem("Show Only Manga", in: app)
        if showOnly == nil { attachElementTree(of: app) }
        XCTAssertNotNil(showOnly, "The menu has no Show Only Manga")
        XCTAssertNotNil(firstHittableMenuItem("Hide Only Manga", in: app), "The menu has no Hide Only Manga")
        XCTAssertNil(firstHittableMenuItem("Show Only Misc", in: app), "The menu is another category's")
        attachScreenshot("b6-categoryMenu", of: app)

        showOnly?.tap()
        goBack(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The editor did not come back")
        XCTAssertTrue(shown(row).contains("9 Hidden"), "The Categories row reads \"\(shown(row))\"")
    }

    @MainActor
    func testGroupListModeChangesTheList() {
        let app = launch()
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery in the Popular group")
        selectGroup("Gallery", from: "Popular", in: app)
        XCTAssertTrue(element("gallery.list.list", in: app).waitForExistence(timeout: 30), "No list")
        openTitleMenu("Gallery", offering: "Manage Groups", in: app)
        guard let edit = hittableMenuItem("Edit Group", in: app) else {
            XCTFail("The title menu has no Edit Group")
            return
        }
        edit.tap()
        let mode = element("group.listMode", in: app)
        XCTAssertTrue(mode.waitForExistence(timeout: 5), "No List Mode in the editor")
        mode.tap()
        guard let grid = hittableMenuItem("Grid", in: app) else {
            attachElementTree(of: app)
            XCTFail("No Grid in the List Mode menu")
            return
        }
        grid.tap()
        save(in: app)
        XCTAssertTrue(element("gallery.list.grid", in: app).waitForExistence(timeout: 30), "The list is not a grid")
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery in the grid")
    }

    @MainActor
    func testAGroupWithoutHitsShowsNoGalleries() {
        let app = launch()
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery in the Popular group")
        openManagement(from: "Popular", in: app)
        openNewGroup(in: app)
        let name = element("group.name", in: app)
        name.tap()
        // Return ends the editing: a software keyboard (iPhone, iPad) would cover the rows below.
        name.typeText("No Hits Test\n")
        addText("eros0fixture0nohit", in: app)
        save(in: app)
        goBack(in: app)
        XCTAssertTrue(element("gallery.empty", in: app).waitForExistence(timeout: 30), "No No Galleries")
        XCTAssertFalse(element("gallery.failure", in: app).exists, "The empty result shows as a failure")
        XCTAssertFalse(element("gallery.refreshFailure", in: app).exists, "The empty result shows as a failure")
    }

    @MainActor
    func testDeletingEveryGroupShowsAddGroup() {
        let app = launch()
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery in the Popular group")
        openManagement(from: "Popular", in: app)
        // From the bottom up: the group shown (Popular, the first) goes last, so no other group's list is asked for.
        for name in ["Anthology", "Watched", "Gallery", "Popular"] {
            let row = groupRow(name, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "No row for \(name)")
            row.swipeLeft()
            // A swipe that went all the way deleted the row by itself; otherwise it shows Delete (exposed as the
            // button and its title).
            if !row.waitForNonExistence(timeout: 1) {
                guard let delete = firstHittableMenuItem("Delete", in: app) else {
                    attachElementTree(of: app)
                    XCTFail("Swiping the row of \(name) offers no Delete")
                    return
                }
                delete.tap()
            }
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "The row of \(name) is still there")
        }
        goBack(in: app)
        let add = element("gallery.root", in: app).descendants(matching: .any)
            .matching(identifier: "groups.add").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "No Add Group on the gallery page")
        attachScreenshot("b6-empty", of: app)

        openTitleMenu("Gallery", offering: "Manage Groups", in: app)
        XCTAssertNotNil(hittableMenuItem("Manage Groups", in: app), "The title menu has no Manage Groups")
        XCTAssertFalse(element("groups.edit", in: app).exists, "The title menu offers Edit Group without a group")
    }

    /// As `TabContainerTests.testDraggingReordersTheTabs`: the system reorder control in edit mode. Only Popular is
    /// shown throughout (moving Gallery first keeps the group shown), so only `/popular` is asked for.
    @MainActor
    func testDraggingReordersTheGroups() {
        let app = launch()
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery in the Popular group")
        openManagement(from: "Popular", in: app)
        XCTAssertEqual(rowOrder(in: app), ["Popular", "Gallery", "Watched", "Anthology"], "Unexpected rows")
        tapToolbarItem("groups.management.edit", title: "Edit", in: app)

        let popular = groupRow("Popular", in: app)
        drag(groupRow("Gallery", in: app), titled: "Gallery", above: popular, in: app)
        XCTAssertEqual(Array(rowOrder(in: app).prefix(2)), ["Gallery", "Popular"], "The rows did not move")
        attachScreenshot("b6-manage", of: app)

        goBack(in: app)
        openTitleMenu("Popular", offering: "Manage Groups", in: app)
        var tops: [CGFloat] = []
        for title in ["Gallery", "Popular", "Watched", "Anthology"] {
            guard let item = hittableMenuItem(title, in: app) else {
                XCTFail("The title menu has no \(title)")
                return
            }
            tops.append(item.frame.minY)
        }
        XCTAssertEqual(tops, tops.sorted(), "The title menu does not list Gallery, Popular, Watched, Anthology")
    }

    /// U6 (M2 review B.2-3): held sideways, the management page's Edit and the root page's hidden tabs entry may go to
    /// the overflow menu (low visibility priority) before Add Group and Search do. Both stay reachable, on the bar or
    /// in the menu; the screenshots show the cover screen's rail held sideways (the Duo, closed).
    @MainActor
    func testHeldSidewaysTheRareItemsGiveWayFirst() {
        let app = launch()
        let start = XCUIDevice.shared.orientation
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.orientation = start.isPortrait || start.isLandscape ? start : .portrait
        }
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery in the Popular group")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertNotNil(titleMenuButton("Popular", in: app), "No title after turning")
        attachScreenshot("u6-gallery-sideways", of: app)

        openManagement(from: "Popular", in: app)
        attachScreenshot("u6-manage-sideways", of: app)
        XCTAssertTrue(
            toolbarOffers("groups.management.add", title: "Add Group", in: app), "No Add Group on the management page"
        )
        XCTAssertTrue(toolbarOffers("groups.management.edit", title: "Edit", in: app), "No Edit on the management page")
    }

    // MARK: - Helpers

    @MainActor private func launch() -> XCUIApplication {
        launchApp(replayingFixtures: true, routes: Self.routes)
    }

    /// The title menu of the page titled `title` → Manage Groups; waits for the management page.
    @MainActor private func openManagement(from title: String, in app: XCUIApplication) {
        openTitleMenu(title, offering: "Manage Groups", in: app)
        guard let manage = hittableMenuItem("Manage Groups", in: app) else {
            XCTFail("The title menu has no Manage Groups")
            return
        }
        manage.tap()
        XCTAssertTrue(element("groups.management", in: app).waitForExistence(timeout: 10), "No management page")
    }

    /// On the management page: Add Group; waits for the editor.
    @MainActor private func openNewGroup(in app: XCUIApplication) {
        tapToolbarItem("groups.management.add", title: "Add Group", in: app)
        XCTAssertTrue(element("group.name", in: app).waitForExistence(timeout: 10), "The editor did not open")
    }

    /// In the editor: New Text, `text`, Add (once the typing settled, `settleTyping(inSheetTitled:anchor:in:)`); waits
    /// for the keyword sheet to close. With `screenshot`, the sheet is attached as that once the site's suggestions for
    /// `text` show.
    @MainActor private func addText(_ text: String, screenshot: String? = nil, in app: XCUIApplication) {
        let newText = element("group.newText", in: app)
        scrollUntilVisible(newText, in: app)
        XCTAssertTrue(newText.exists && newText.isHittable, "New Text is not on the screen")
        newText.tap()
        let field = element("keyword.text", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "The keyword sheet did not open")
        field.tap()
        field.typeText(text)
        if let screenshot {
            let suggestion = element("search.suggestion", in: app)
            XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "No suggestions for \(text)")
            attachScreenshot(screenshot, of: app)
        }
        // Once what the typing set off has settled, as in the jump and filter sheets: on the iPad the late keyboard
        // moves the sheet, and a tap aimed before the move misses Add.
        settleTyping(inSheetTitled: "New Text", anchor: element("keyword.add", in: app), in: app)
        tapToolbarItem("keyword.add", title: "Add", in: app)
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "The keyword sheet did not close")
    }

    /// In the editor: Save; waits for the editor to close.
    @MainActor private func save(in app: XCUIApplication) {
        tapToolbarItem("group.save", title: "Save", in: app)
        XCTAssertTrue(element("group.name", in: app).waitForNonExistence(timeout: 10), "The editor did not close")
    }

    /// What the system puts before a row's label in edit mode (iOS 27.2): its delete control, "Remove".
    private static let editModePrefix = "Remove, "

    /// The management page's row of the group `name` (`groups.row`, labelled with the group's name; in edit mode
    /// "Remove, <name>").
    @MainActor private func groupRow(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (label == %@ OR label == %@)", "groups.row", name, Self.editModePrefix + name
        )).firstMatch
    }

    /// The names of the management page's rows, top to bottom.
    @MainActor private func rowOrder(in app: XCUIApplication) -> [String] {
        app.descendants(matching: .any).matching(identifier: "groups.row").allElementsBoundByIndex
            .filter(\.exists)
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { row in
                let label = row.label
                return label.hasPrefix(Self.editModePrefix) ? String(label.dropFirst(Self.editModePrefix.count)) : label
            }
    }
}
