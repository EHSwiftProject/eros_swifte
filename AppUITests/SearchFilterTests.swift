import XCTest

/// UI tests for the search filters (search Q3) over the replayed fixtures, in English: the toolbar's Filter opens the
/// Search Filters sheet, with the search's categories on a page of their own and the
/// advanced options of browse B6's form.
///
/// Requests and their fixtures (M2 index §3.4, replay matching):
/// - The gallery tab's root (the Popular group): GET https://e-hentai.org/popular → eh/list/popular.html.
/// - `language:chinese` without advanced options: GET https://e-hentai.org/?f_search=language:chinese, routed to
///   eh/list/search-empty.html (`testAdvancedOptionsReachTheResults`). Unrouted it would be eh/list/search.html, whose
///   galleries could not be told from the advanced search's: the route matches the plain search only
///   (without `advsearch` the replay drops `f_sfl`, `f_sfu` and `f_sft` on both sides, with it every pair counts).
/// - `language:chinese` with every advanced option: GET https://e-hentai.org/?f_search=language:chinese&advsearch=1
///   &f_sh=on&f_sto=on&f_sr=on&f_srdd=4&f_sp=on&f_spf=20&f_spt=200&f_sft=on&f_sfu=on&f_sfl=on →
///   eh/list/search-advanced.html (the app sends the same name-value set in its own order). The host test
///   `SearchPreferencesTests.everyOptionReachesTheURL` checks the replay answers both as said here.
/// - Every test that types into the search field also sends POST https://e-hentai.org/api.php (JSON `method`
///   tagsuggest) → eh/api/tagsuggest.json (the replay picks it by method).
///
/// The categories reach the request in the host test `SearchModelTests.changingFiltersRerunsTheSearch`: no fixture is
/// a search with `f_cats`. Screenshots are named `q3-<name>` (the cover-screen checks).
final class SearchFilterTests: XCTestCase {
    /// The ten categories' identifiers (`category.<GalleryCategory rawValue>`).
    private static let categories = [
        "doujinshi", "manga", "artistCG", "gameCG", "western", "nonH", "imageSet", "cosplay", "asianPorn", "misc",
    ]
    /// The route key of the search for `language:chinese` without advanced options (the plain search).
    private static let plainSearch = "GET https://e-hentai.org/?f_search=language:chinese"
    /// The switches of browse B6's advanced form.
    private static let formSwitches = [
        "advanced.torrents", "advanced.expunged", "advanced.minimumRating", "advanced.pages",
        "advanced.disableLanguage", "advanced.disableUploader", "advanced.disableTags",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The sheet starts with nothing filtered: every category shown (on the Categories page, then back), the advanced
    /// options off, and once they are on, every switch of the form off. Sends no search.
    @MainActor
    func testFilterSheetStartsWithDefaults() {
        let app = openSearch()
        openFilters(in: app)

        let row = element("searchFilter.categories", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The filters have no Categories row")
        XCTAssertTrue(shown(row).contains("All"), "The Categories row reads \"\(shown(row))\"")
        row.tap()
        XCTAssertTrue(
            element("searchFilter.categoriesPage", in: app).waitForExistence(timeout: 10),
            "The Categories page did not open"
        )
        for category in Self.categories {
            XCTAssertTrue(element("category.\(category)", in: app).waitForExistence(timeout: 5), "No \(category)")
        }
        attachScreenshot("q3-search-filter-categories", of: app)
        goBack(in: app)

        let advanced = app.switches.matching(identifier: "searchFilter.advanced").firstMatch
        XCTAssertTrue(advanced.waitForExistence(timeout: 5), "The filters have no Advanced Options")
        XCTAssertEqual(advanced.value as? String, "0", "The advanced options are on")
        XCTAssertFalse(element("advanced.torrents", in: app).exists, "The advanced form shows while it is off")

        setFormSwitch("searchFilter.advanced", on: true, in: app)
        XCTAssertTrue(element("advanced.torrents", in: app).waitForExistence(timeout: 5), "No advanced form")
        attachScreenshot("q3-search-filter-sheet", of: app)
        for identifier in Self.formSwitches {
            let control = app.switches.matching(identifier: identifier).firstMatch
            scrollUntilVisible(control, in: app, inside: form(in: app))
            XCTAssertTrue(control.exists, "The advanced form has no \(identifier)")
            XCTAssertEqual(control.value as? String, "0", "\(identifier) is on")
        }
    }

    /// Search first: `language:chinese` without advanced options is routed to the empty page. Then every advanced
    /// option (torrents, expunged, a minimum rating of 4, the three default filters disabled, pages typed From 200 and
    /// To 20, which the footnote says will be swapped), and Done: closing the filters runs the search again with them
    /// all, the bounds put right (`f_spf=20&f_spt=200`), which is the captured advanced search, so its galleries show
    /// and the empty page goes. Options that never reach the request would leave the empty page. Also
    /// sends POST api.php (tagsuggest) while `language:chinese` is typed.
    @MainActor
    func testAdvancedOptionsReachTheResults() {
        let app = openSearch(routes: [Self.plainSearch: UITestRoute(path: "eh/list/search-empty.html")])
        let field = focusedSearchField(in: app)
        field.typeText("language:chinese\n")
        let empty = element("gallery.empty", in: app)
        XCTAssertTrue(empty.waitForExistence(timeout: 30), "The plain search did not get the empty page")

        openFilters(in: app)
        setFormSwitch("searchFilter.advanced", on: true, in: app)
        for identifier in ["advanced.torrents", "advanced.expunged", "advanced.minimumRating"] {
            setFormSwitch(identifier, on: true, in: app)
        }
        let rating = element("advanced.minimumRatingValue", in: app)
        XCTAssertTrue(rating.waitForExistence(timeout: 5), "No minimum rating to pick")
        let fourStars = rating.buttons["4 stars"]
        scrollUntilVisible(fourStars, in: app, inside: form(in: app))
        XCTAssertTrue(fourStars.exists, "No 4 stars among the ratings")
        fourStars.tap()
        let picked = Date.now.addingTimeInterval(5)
        while !fourStars.isSelected, Date.now < picked {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(fourStars.isSelected, "4 stars is not the minimum rating")

        setFormSwitch("advanced.pages", on: true, in: app)
        // From focused with its keyboard up (the cover-screen check: the keyboard covers no page field; on the iPhone
        // Duo simulator the software keyboard stays below the screen).
        type("200", into: "advanced.pagesFrom", screenshot: "q3-search-filter-pages", in: app)
        type("20", into: "advanced.pagesTo", in: app)
        for identifier in ["advanced.disableLanguage", "advanced.disableUploader", "advanced.disableTags"] {
            setFormSwitch(identifier, on: true, in: app)
        }
        let swapNote = element("searchFilter.swapNote", in: app)
        scrollUntilVisible(swapNote, in: app, inside: form(in: app))
        XCTAssertTrue(swapNote.exists, "No footnote that the page numbers will be swapped")
        tapDone(in: app)

        XCTAssertNotNil(firstGalleryItem(in: app), "The search with the advanced options shows no gallery")
        XCTAssertTrue(empty.waitForNonExistence(timeout: 10), "The empty page stayed")
        XCTAssertNotNil(
            titledToolbarItem("search.filter", title: "Filter", in: app), "The results offer no Filter"
        )
        attachScreenshot("q3-search-advanced-results", of: app)
    }

    // MARK: - Helpers

    /// The sheet's form (`searchFilter.root`), which its rows are scrolled in: half open and held sideways, the iPhone
    /// Duo's system moves the sheet left of the fold, away from the window's middle.
    @MainActor private func form(in app: XCUIApplication) -> XCUIElement {
        element("searchFilter.root", in: app)
    }

    /// The search page's Filter (`search.filter`, on the bar or in the overflow menu); waits for the sheet.
    @MainActor private func openFilters(in app: XCUIApplication) {
        tapToolbarItem("search.filter", title: "Filter", in: app)
        XCTAssertTrue(
            element("searchFilter.root", in: app).waitForExistence(timeout: 10), "The search filters did not open"
        )
    }

    /// The sheet's Done (`searchFilter.done`; else the one hittable element labelled or
    /// identified Done); waits for the sheet to close.
    @MainActor private func tapDone(in app: XCUIApplication) {
        let done = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR identifier == %@", "searchFilter.done", "Done", "Done"
        ))
        let deadline = Date.now.addingTimeInterval(10)
        var button: XCUIElement?
        while button == nil {
            let hittable = done.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            let byIdentifier = hittable.first { $0.identifier == "searchFilter.done" }
            button = byIdentifier ?? (hittable.count == 1 ? hittable[0] : nil)
            guard button == nil, Date.now < deadline else { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let button else {
            attachElementTree(of: app)
            XCTFail("The search filters have no Done")
            return
        }
        button.tap()
        XCTAssertTrue(
            element("searchFilter.root", in: app).waitForNonExistence(timeout: 10), "The search filters did not close"
        )
    }

    /// Turns the switch `identifier` of the filters on or off (`setSwitch(_:on:inside:in:)`, in the sheet's form).
    @MainActor private func setFormSwitch(_ identifier: String, on: Bool, in app: XCUIApplication) {
        setSwitch(identifier, on: on, inside: form(in: app), in: app)
    }

    /// Types `text` into the page field `identifier` of the filters and checks it, then waits for what the typing set
    /// off to settle (`settleTyping`: on the iPad the number pad popover would keep anything else from being hit).
    ///
    /// `screenshot`: attached before the typing, once the field has the focus and its keyboard is on screen (up to 5 s;
    /// on the iPad the number pad popover counts) and the field is still: on the iOS 27.2 simulator the typing itself
    /// takes the software keyboard away for a while.
    @MainActor private func type(
        _ text: String, into identifier: String, screenshot: String? = nil, in app: XCUIApplication
    ) {
        let field = element(identifier, in: app)
        scrollUntilVisible(field, in: app, inside: form(in: app))
        XCTAssertTrue(field.exists, "No page field \(identifier)")
        field.tap()
        if let screenshot {
            let deadline = Date.now.addingTimeInterval(5)
            while !keyboardIsOnScreen(in: app), !app.popovers.firstMatch.exists, Date.now < deadline {
                Thread.sleep(forTimeInterval: 0.25)
            }
            waitUntilStill(field, in: app, step: "\(identifier) before \(screenshot)")
            attachScreenshot(screenshot, of: app)
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "The page field \(identifier) does not show \(text)")
        settleTyping(inSheetTitled: "Search Filters", anchor: field, in: app)
    }
}
