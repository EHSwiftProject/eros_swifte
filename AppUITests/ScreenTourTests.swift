import XCTest

/// A tour of the M2 screens for the iPhone Duo checks (entry E4; the plan's table T1–T12):
/// each page, sheet, menu and alert is opened, the element that shows it is there waited for, and a screenshot of it
/// attached as `T<n>-<name>`, kept always. Nothing here checks a layout: the screenshots are looked at by hand, posture
/// by posture. Each group of pages has a launch of its own, so a page that does not open loses only the rest of its
/// group.
///
/// Every launch but T10's replays the checked-in fixtures; what each one asks for:
/// - The gallery tab's root, the Popular group: GET https://e-hentai.org/popular → eh/list/popular.html; the Gallery
///   group: GET https://e-hentai.org/ → eh/list/front.html. The covers are not replayed and show their placeholders.
/// - T4: GET https://e-hentai.org/toplist.php?tl=15 → eh/list/toplist-yesterday.html.
/// - T5 logged in: the made-up session of `-EROS_UI_TESTING_SESSION 1`, favorites.php and `?favcat=0` routed to
///   constructed/eh/list-favorites.html (as `FavoritesTests`). Its order menu is only opened.
/// - T6: POST https://e-hentai.org/api.php (tagsuggest) → eh/api/tagsuggest.json while text is typed; the search for
///   `eros0fixture0nohit` → eh/list/search-empty.html.
/// - T8: the tag and uploader lists → eh/list/tag.html, eh/list/uploader.html (`language:chinese`, `x392`); the gallery
///   and image page links open their placeholders.
/// - T9: the clipboard is the UI testing one, holding the tag link of `-EROS_UI_TESTING_CLIPBOARD_URL`.
/// - T10 replays nothing: every site request fails offline, and the web login page is about:blank. Nothing is typed.
/// - T11, T12: GET https://e-hentai.org/ and GET https://e-hentai.org/popular routed to a constructed failure, one
///   launch per failure.
final class ScreenTourTests: XCTestCase {
    /// The list styles besides the default (List - Medium): their `ListStyle` raw value, the List Mode menu's title
    /// and the screenshot's name.
    private static let otherListStyles = [
        ("simpleList", "List - Small", "T1-list-small"), ("waterfall", "Waterfall", "T1-waterfall"),
        ("waterfallLarge", "Waterfall - Large", "T1-waterfall-large"), ("grid", "Grid", "T1-grid"),
    ]
    /// The tag link of the checked-in fixture `eh/list/tag.html`, in the clipboard for T9.
    private static let clipboardLink = "https://e-hentai.org/tag/language:chinese"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// T1 the gallery tab's root in the five list styles; T2 the group title menu, Manage Groups and the group editor;
    /// T3 the category filter (the editor's Categories page) and the Jump/Seek sheet.
    @MainActor
    func testTourT1toT3() {
        let app = launchApp(replayingFixtures: true)
        selectGroup("Gallery", from: "Popular", in: app)
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery on the front page")
        captureList("list", as: "T1-list-medium", in: app)
        for (style, title, name) in Self.otherListStyles {
            chooseListMode(title, in: app)
            selectTab("gallery", in: app)
            captureList(style, as: name, in: app)
        }
        chooseListMode("List - Medium", in: app)
        selectTab("gallery", in: app)
        XCTAssertTrue(element("gallery.list.list", in: app).waitForExistence(timeout: 10), "No list")

        openTitleMenu("Gallery", offering: "Manage Groups", in: app)
        attachScreenshot("T2-group-menu", of: app)
        tapMenuItem("Manage Groups", in: app)
        capture("T2-group-management", showing: "groups.management", in: app)
        goBack(in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 10), "Back did not reach the gallery")
        openTitleMenu("Gallery", offering: "Edit Group", in: app)
        tapMenuItem("Edit Group", in: app)
        capture("T2-group-editor", showing: "group.name", in: app)

        let categories = element("group.categories", in: app)
        XCTAssertTrue(categories.waitForExistence(timeout: 5), "The editor has no Categories row")
        categories.tap()
        capture("T3-category-filter", showing: "category.manga", in: app)
        goBack(in: app)
        XCTAssertTrue(categories.waitForExistence(timeout: 5), "The editor did not come back")
        tapToolbarItem("group.close", title: "Close", in: app)
        XCTAssertTrue(element("group.name", in: app).waitForNonExistence(timeout: 10), "The editor did not close")
        openJumpSeek(in: app)
        attachScreenshot("T3-jump-seek", of: app)
    }

    /// T4 the toplists tab and its title menu; T5 the favorites tab logged out (the local favorites), then, launched
    /// again with a session, All Favorites, its folders in the title menu and its order menu.
    @MainActor
    func testTourT4toT5() {
        let app = launchApp(replayingFixtures: true)
        selectTab("toplists", in: app)
        XCTAssertTrue(element("toplists.root", in: app).waitForExistence(timeout: 10), "The toplists did not open")
        XCTAssertNotNil(firstGalleryItem(in: app), "The toplist shows no gallery")
        attachScreenshot("T4-toplists", of: app)
        openTitleMenu("Yesterday", offering: "Past Month", in: app)
        attachScreenshot("T4-toplist-menu", of: app)
        // Picking the toplist shown closes the menu.
        tapMenuItem("Yesterday", in: app)

        selectTab("favorites", in: app)
        XCTAssertTrue(element("favorites.root", in: app).waitForExistence(timeout: 10), "The favorites did not open")
        capture("T5-favorites-local", showing: "gallery.empty", in: app)

        let favorites = UITestRoute(path: "constructed/eh/list-favorites.html")
        let loggedIn = launchApp(
            replayingFixtures: true,
            routes: [
                "GET https://e-hentai.org/favorites.php": favorites,
                "GET https://e-hentai.org/favorites.php?favcat=0": favorites,
            ],
            arguments: ["-EROS_UI_TESTING_SESSION", "1"]
        )
        selectTab("favorites", in: loggedIn)
        XCTAssertTrue(
            element("favorites.root", in: loggedIn).waitForExistence(timeout: 10), "The favorites did not open"
        )
        XCTAssertNotNil(firstGalleryItem(in: loggedIn), "The favorites show no gallery")
        attachScreenshot("T5-favorites-all", of: loggedIn)
        // The menu's first row, All Favorites with the sum of the folders' counts (as `FavoritesTests`): a short
        // screen (the cover screen held sideways) shows only the first rows, so the last, Local Favorites, may be
        // missing from the element tree until the menu is scrolled.
        openTitleMenu("All Favorites", offering: FavoritesFixtureMenu.items[0], in: loggedIn)
        attachScreenshot("T5-favorites-folders", of: loggedIn)
        // Picking the folder shown (All Favorites, with its count) closes the menu.
        let all = loggedIn.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)", "All Favorites (", "tab."
        ))
        guard let shown = firstHittable(all, within: 5) else {
            attachElementTree(of: loggedIn)
            XCTFail("The title menu has no All Favorites")
            return
        }
        shown.tap()
        tapToolbarItem("favorites.order", title: "Favorites Order", in: loggedIn)
        XCTAssertNotNil(hittableMenuItem("Use Favorited", in: loggedIn), "The order menu did not open")
        attachScreenshot("T5-favorites-order", of: loggedIn)
    }

    /// T6 the search page with tag suggestions and with its history, the quick search page, the image search page,
    /// and the search filters with the advanced options on.
    @MainActor
    func testTourT6() {
        let app = openSearch()
        let field = focusedSearchField(in: app)
        field.typeText("fak")
        capture("T6-search-suggestions", showing: "search.suggestion", in: app)
        clear(field, in: app)
        field.typeText("eros0fixture0nohit\n")
        XCTAssertTrue(element("gallery.empty", in: app).waitForExistence(timeout: 30), "The search did not run")
        clear(field, in: app)
        capture("T6-search-history", showing: "search.history", in: app)

        openFromToolbar("search.quickSearch", title: "Quick Search", showing: "quickSearch.root", in: app)
        capture("T6-quick-search", showing: "quickSearch.root", in: app)
        goBack(in: app)
        XCTAssertTrue(element("search.root", in: app).waitForExistence(timeout: 10), "Back did not reach the search")

        openFromToolbar("search.imageSearch", title: "Image Search", showing: "imageSearch.root", in: app)
        capture("T6-image-search", showing: "imageSearch.root", in: app)
        goBack(in: app)
        XCTAssertTrue(element("search.root", in: app).waitForExistence(timeout: 10), "Back did not reach the search")

        tapToolbarItem("search.filter", title: "Filter", in: app)
        capture("T6-search-filters", showing: "searchFilter.root", in: app)
        setSwitch("searchFilter.advanced", on: true, in: app)
        capture("T6-advanced-search", showing: "advanced.torrents", in: app)
    }

    /// T7 the Settings tab's root (its General section with Clipboard Detection's footer, its Tag Translations
    /// section) and the Tab Bar page; History turned on there, then its tab.
    ///
    /// History is looked for in the same launch: since browse B2 a tab shown later carries its identifier
    /// at once (`TabContainerTests.testTabSettingsShowAndHideTabs`), and a new launch would show the tabs of the
    /// defaults again (`AppEnvironment.forLaunch()` empties the UI testing settings). A tab item now and then lacks
    /// its identifier (all of them, then); so History's is looked for by its title too.
    @MainActor
    func testTourT7() {
        let app = launchApp(replayingFixtures: true)
        selectTab("settings", in: app)
        XCTAssertTrue(element("settings.root", in: app).waitForExistence(timeout: 10), "Settings did not open")
        XCTAssertNil(historyTabItem(within: 0, in: app), "History has a tab item before it is turned on")
        let footer = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "When Eros-SE returns to the foreground"
        )).firstMatch
        scrollUntilVisible(footer, in: app)
        XCTAssertTrue(element("settings.clipboardLinks", in: app).exists, "No Clipboard Detection")
        XCTAssertTrue(footer.exists, "The General section has no footer")
        attachScreenshot("T7-settings-general", of: app)

        let tabBar = element("settings.tabBar", in: app)
        // Back to the row if the drag to the footer glided past it, until it shows whole below the navigation bar:
        // held sideways it was left cut by the top edge (12 of its 52 pt), and XCTest aims a tap at a cut row without
        // turning the point with the display; under the bar, the tap would go to the status bar. Checked by the same
        // rule as the drags stop on, so a drag that gave up with the row under the bar fails here.
        let shown = scrollUntilVisible(tabBar, in: app)
        XCTAssertTrue(
            shown,
            "The Tab Bar row is not wholly on screen below the bars: "
                + (tabBar.exists ? "\(tabBar.frame) in \(pageWindow(of: app).frame)" : "not in the element tree")
        )
        tabBar.tap()
        capture("T7-tab-settings", showing: "tabSettings.toggle.gallery", in: app)
        setSwitch("tabSettings.toggle.download", on: false, in: app)
        let history = app.switches.matching(identifier: "tabSettings.toggle.history").firstMatch
        let enabled = Date.now.addingTimeInterval(5)
        while !history.isEnabled, Date.now < enabled {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(history.isEnabled, "History cannot be turned on with Download hidden")
        setSwitch("tabSettings.toggle.history", on: true, in: app)
        guard let historyTab = historyTabItem(within: 10, in: app) else {
            attachElementTree(of: app)
            XCTFail("History got no tab item")
            return
        }
        attachScreenshot("T7-tabs-with-history", of: app)

        goBack(in: app)
        let mirror = element("settings.tagDatabase.mirror", in: app)
        scrollUntilVisible(mirror, in: app)
        XCTAssertTrue(mirror.exists, "No Use Download Mirror")
        XCTAssertTrue(element("settings.tagDatabase.version", in: app).exists, "No tag database version")
        attachScreenshot("T7-settings-tag-translations", of: app)

        historyTab.tap()
        capture("T7-history", showing: "history.root", in: app)
        expectSelectedTab("history", in: app)
    }

    /// T8 the pages that site links opened from outside push (`eros://`, through the system): a tag list, an uploader
    /// list, the gallery and image page placeholders; T9 Can't Open Link, and Open Link? for the clipboard's link.
    @MainActor
    func testTourT8toT9() throws {
        let app = launchApp(replayingFixtures: true, arguments: ["-EROS_UI_TESTING_CLIPBOARD_URL", Self.clipboardLink])
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 30), "The tabs did not show")

        openExternally(try XCTUnwrap(URL(string: "eros://e-hentai.org/tag/language:chinese")), in: app)
        expectList(titled: "language:chinese", in: app)
        attachScreenshot("T8-tag-list", of: app)
        backToGallery(in: app)
        openExternally(try XCTUnwrap(URL(string: "eros://e-hentai.org/uploader/x392")), in: app)
        expectList(titled: "x392", in: app)
        attachScreenshot("T8-uploader-list", of: app)
        backToGallery(in: app)
        openExternally(try XCTUnwrap(URL(string: "eros://e-hentai.org/g/1234/0123456789/")), in: app)
        expectPlaceholder("route.placeholder.gallery", describedAs: "Gallery 1234", in: app)
        attachScreenshot("T8-gallery-placeholder", of: app)
        backToGallery(in: app)
        openExternally(try XCTUnwrap(URL(string: "eros://exhentai.org/s/0123456789/1234-5")), in: app)
        expectPlaceholder("route.placeholder.imagePage", describedAs: "Gallery 1234, page 5", in: app)
        attachScreenshot("T8-image-page-placeholder", of: app)
        backToGallery(in: app)

        openExternally(try XCTUnwrap(URL(string: "eros://example.com/")), in: app)
        let unopenable = app.alerts["Can't Open Link"]
        XCTAssertTrue(unopenable.waitForExistence(timeout: 10), "No Can't Open Link alert")
        attachScreenshot("T9-cant-open-link", of: app)
        unopenable.buttons["OK"].tap()
        XCTAssertTrue(unopenable.waitForNonExistence(timeout: 5), "The alert stayed")

        selectTab("settings", in: app)
        XCTAssertTrue(element("settings.root", in: app).waitForExistence(timeout: 10), "Settings did not open")
        setSwitch("settings.clipboardLinks", on: true, in: app)
        sendToBackgroundAndBack(app)
        let offer = app.alerts["Open Link?"]
        XCTAssertTrue(offer.waitForExistence(timeout: 10), "No Open Link? alert after coming back")
        attachScreenshot("T9-open-link", of: app)
        offer.buttons["Cancel"].tap()
        XCTAssertTrue(offer.waitForNonExistence(timeout: 5), "The alert stayed")
    }

    /// T10 the login sheet's three methods and the web login sheet, only opened: nothing is typed or sent.
    @MainActor
    func testTourT10() {
        let app = launchApp()
        selectTab("settings", in: app)
        XCTAssertTrue(element("settings.root", in: app).waitForExistence(timeout: 10), "Settings did not open")
        let login = element("account.login", in: app)
        XCTAssertTrue(login.waitForExistence(timeout: 5), "No Log In")
        login.tap()
        XCTAssertTrue(element("login.method", in: app).waitForExistence(timeout: 5), "The login sheet did not open")
        capture("T10-login-password", showing: "login.username", in: app)
        selectLoginMethod("Cookie", in: app)
        capture("T10-login-cookie", showing: "login.memberID", in: app)
        selectLoginMethod("Web", in: app)
        capture("T10-login-web", showing: "login.web.open", in: app)
        element("login.web.open", in: app).tap()
        capture("T10-web-login", showing: "login.web.close", in: app)

        element("login.web.close", in: app).tap()
        XCTAssertTrue(element("login.web.close", in: app).waitForNonExistence(timeout: 5), "The web login stayed")
        let close = element("login.close", in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The login sheet has no Close")
        close.tap()
        XCTAssertTrue(login.waitForExistence(timeout: 5), "The login sheet stayed")
    }

    /// T11 the list's Log In Again failure; T12 the pause banner of a ban and of too many requests. Each failure is a
    /// launch of its own, the front page and Popular both routed to it.
    @MainActor
    func testListFailureScreens() {
        let loginRequired = UITestRoute(path: "constructed/eh/list-login-required.html")
        var app = launchApp(replayingFixtures: true, routes: Self.listRoutes(loginRequired))
        XCTAssertTrue(element("gallery.failure", in: app).waitForExistence(timeout: 30), "No failure")
        capture("T11-login-required", showing: "gallery.failure.logIn", in: app)

        let banned = UITestRoute(path: "constructed/eh/banned.txt")
        app = launchApp(replayingFixtures: true, routes: Self.listRoutes(banned))
        capture("T12-banned", showing: "gallery.pauseBanner", within: 30, in: app)

        app = launchApp(
            replayingFixtures: true,
            routes: Self.listRoutes(UITestRoute(path: "constructed/eh/http-429.html", status: 429))
        )
        capture("T12-too-many-requests", showing: "gallery.pauseBanner", within: 30, in: app)
    }

    // MARK: - Helpers

    /// The front page and Popular, both answered by `route`.
    private static func listRoutes(_ route: UITestRoute) -> [String: UITestRoute] {
        ["GET https://e-hentai.org/": route, "GET https://e-hentai.org/popular": route]
    }

    /// Taps the toolbar item `identifier` (on the bar or in its overflow menu) and waits 5 s for the page `root` to
    /// appear. When it does not (on the iPad a tap on a menu item now and then does nothing, and the menu may be
    /// open still or closed), the item is found again, the open menu's entry first, and tapped once more. The caller
    /// then waits for `root` as the check.
    @MainActor private func openFromToolbar(
        _ identifier: String, title: String, showing root: String, in app: XCUIApplication
    ) {
        guard let first = titledToolbarItem(identifier, title: title, in: app) else { return }
        first.tap()
        if element(root, in: app).waitForExistence(timeout: 5) { return }
        // A slow push shows up by now; only a page that is still missing gets the second tap, which is recorded
        // in the result bundle as an activity so the times it was needed can be counted. A lookup that finds
        // nothing ends here without a failure: the caller's wait for `root` is the check.
        if element(root, in: app).exists { return }
        let labelled = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title))
        // Without images, as `toolbarItem`: a row's symbol may read the same as the row's title.
        let open = labelled.allElementsBoundByIndex.filter { $0.exists && $0.elementType != .image && $0.isHittable }
        guard let again = open.count == 1 ? open[0] : toolbarItem(identifier, title: title, in: app) else { return }
        XCTContext.runActivity(named: "Tapped \(title) again") { _ in again.tap() }
        _ = element(root, in: app).waitForExistence(timeout: 5)
    }

    /// Waits up to `timeout` seconds for the element `identifier`, which shows the page is there, then attaches a
    /// screenshot named `name`.
    @MainActor private func capture(
        _ name: String, showing identifier: String, within timeout: TimeInterval = 10, in app: XCUIApplication
    ) {
        XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: timeout), "\(name): no \(identifier)")
        attachScreenshot(name, of: app)
    }

    /// The gallery list in `style` (`gallery.list.<style>`) with a gallery in it, attached as `name` once the covers'
    /// placeholders have had a moment (the covers are not replayed).
    @MainActor private func captureList(_ style: String, as name: String, in app: XCUIApplication) {
        XCTAssertTrue(element("gallery.list.\(style)", in: app).waitForExistence(timeout: 10), "No \(style) list")
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery in the \(style) list")
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(name, of: app)
    }

    /// Settings → List Mode → `title`.
    @MainActor private func chooseListMode(_ title: String, in app: XCUIApplication) {
        selectTab("settings", in: app)
        let picker = element("settings.listMode", in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "No List Mode row in Settings")
        picker.tap()
        tapMenuItem(title, in: app)
    }

    /// Taps the open menu's item `title` (`hittableMenuItem(_:in:)`); fails with the element tree without one.
    @MainActor private func tapMenuItem(_ title: String, in app: XCUIApplication) {
        guard let item = hittableMenuItem(title, in: app) else {
            attachElementTree(of: app)
            XCTFail("The menu has no \(title)")
            return
        }
        item.tap()
    }

    /// History's tab item, waited for up to `timeout` seconds: the hittable `tab.history`, or, while no tab item
    /// carries its identifier, the hittable button titled History that is no hidden tab's entry. nil without one.
    @MainActor private func historyTabItem(within timeout: TimeInterval, in app: XCUIApplication) -> XCUIElement? {
        let identified = app.descendants(matching: .any).matching(identifier: "tab.history")
        let anyTab = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab."))
        let titled = app.buttons.matching(NSPredicate(
            format: "label == %@ AND NOT (identifier BEGINSWITH %@)", "History", "hiddenTabs."
        ))
        let deadline = Date.now.addingTimeInterval(timeout)
        while true {
            if let item = identified.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                return item
            }
            let tabsLackIdentifiers = !anyTab.allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
            if tabsLackIdentifiers,
               let item = titled.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                return item
            }
            guard Date.now < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Back from a page an outside link pushed to the gallery tab's root.
    @MainActor private func backToGallery(in app: XCUIApplication) {
        goBack(in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 10), "Back did not reach the gallery")
    }

    /// Picks the method `title` of the login sheet's picker (`login.method`).
    @MainActor private func selectLoginMethod(_ title: String, in app: XCUIApplication) {
        let segment = element("login.method", in: app).buttons[title]
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "No \(title) method")
        segment.tap()
    }
}
