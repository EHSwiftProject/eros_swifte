import XCTest

/// UI tests for the search page (search Q2) over the replayed fixtures, in English, so tags are not translated and
/// suggestions come from the site's `tagsuggest`.
///
/// Requests and their fixtures (M2 index §3.4, replay matching):
/// - The gallery tab's root (the Popular group): GET https://e-hentai.org/popular → eh/list/popular.html.
/// - `language:chinese`: GET https://e-hentai.org/?f_search=language:chinese → eh/list/search.html.
/// - `eros0fixture0nohit`: GET https://e-hentai.org/?f_search=eros0fixture0nohit → eh/list/search-empty.html.
/// - Every test that types text also sends POST https://e-hentai.org/api.php (JSON `method` tagsuggest) →
///   eh/api/tagsuggest.json, once the field has held a word for half a second (the replay picks it by method, whatever
///   the word).
///
/// Toolbar items are found by identifier on the bar and by title in its overflow menu (on
/// iOS 27.2 menu items carry no identifier). Screenshots are named `q2-<name>` (the cover-screen checks).
final class SearchScreenTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The Gallery tab's Search item opens the search page with its field (gallery-toolbar). Then, for the rail check,
    /// the page at rest after a search (probe-idle) and with the field focused over the history (probe-focused). Also
    /// sends the `eros0fixture0nohit` search and POST api.php (tagsuggest).
    @MainActor
    func testGalleryToolbarOpensTheSearchPage() {
        let app = launchApp(replayingFixtures: true)
        XCTAssertNotNil(firstGalleryItem(in: app), "The gallery tab shows no gallery")
        attachScreenshot("q2-gallery-toolbar", of: app)
        tapToolbarItem("gallery.search", title: "Search", in: app)
        XCTAssertTrue(element("search.root", in: app).waitForExistence(timeout: 10), "The search page did not open")
        let field = focusedSearchField(in: app)
        XCTAssertTrue(field.exists, "The search page has no search field")

        field.typeText("eros0fixture0nohit\n")
        XCTAssertTrue(element("gallery.empty", in: app).waitForExistence(timeout: 30), "The search did not run")
        attachScreenshot("q2-probe-idle", of: app)

        clear(field, in: app)
        let entry = historyEntry("eros0fixture0nohit", in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "The search is not in the history")
        XCTAssertTrue(element("search.history.clear", in: app).exists, "The history has no Clear")
        attachScreenshot("q2-probe-focused", of: app)
    }

    /// Results, then the history; a history entry is appended to the text without a search. Last, the results' jumps
    /// (browse B5) and Add to Quick Search are offered, on the bar or in its overflow menu (search-overflow, with the
    /// menu open). Also sends POST api.php (tagsuggest) while `language:chinese` is typed.
    @MainActor
    func testSearchShowsResultsAndRecordsHistory() {
        let app = openSearch()
        let field = focusedSearchField(in: app)
        field.typeText("language:chinese\n")
        XCTAssertTrue(element("gallery.list.list", in: app).waitForExistence(timeout: 30), "No results")
        // Nothing covers the results once the search ran.
        XCTAssertNotNil(firstGalleryItem(in: app), "No result can be tapped")
        attachScreenshot("q2-search-results", of: app)

        clear(field, in: app)
        let entry = historyEntry("language:chinese", in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "The search is not in the history")
        attachScreenshot("q2-search-history", of: app)

        // Appended, not searched: a search would trim the trailing space. The row's button covers the whole row, so a
        // tap anywhere in the row is the button's.
        entry.tap()
        let deadline = Date.now.addingTimeInterval(5)
        while fieldText(field) != "language:chinese ", Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertEqual(fieldText(field), "language:chinese ")

        // Searched again, the results come back with their toolbar items, though the search stays presented (the page
        // keeps its toolbar then: `searchPresentationToolbarBehavior(.avoidHidingContent)`).
        field.typeText("\n")
        XCTAssertNotNil(firstGalleryItem(in: app), "No result can be tapped")
        XCTAssertTrue(toolbarOffers("jump.open", title: "Jump/Seek", in: app), "The results offer no Jump/Seek")
        let quickOnBar = element("search.addQuickSearch", in: app)
        if !(quickOnBar.exists && quickOnBar.isHittable) {
            // The overflow menu is open when Jump/Seek was in it; otherwise it opens now.
            let quick = hittableMenuItem("Add to Quick Search", in: app)
                ?? toolbarItem("search.addQuickSearch", title: "Add to Quick Search", in: app)
            XCTAssertNotNil(quick, "The results offer no Add to Quick Search")
        }
        attachScreenshot("q2-search-overflow", of: app)
    }

    /// A tag of a result is appended to the field as its term, and opens nothing. Also sends POST api.php
    /// (tagsuggest) while `language:chinese` is typed.
    @MainActor
    func testTappingATagAppendsIt() {
        let app = openSearch()
        let field = focusedSearchField(in: app)
        field.typeText("language:chinese\n")
        XCTAssertNotNil(firstGalleryItem(in: app), "No result can be tapped")

        let tags = app.descendants(matching: .any).matching(identifier: "list.tag")
        guard let tag = firstHittable(tags, within: 10) else {
            attachElementTree(of: app)
            XCTFail("No result has a tag that can be tapped")
            return
        }
        let raw = tag.value as? String ?? ""
        XCTAssertFalse(raw.isEmpty, "The tag does not carry its raw name")
        tag.tap()
        let expected = Self.tagTerm(raw: raw) + " "
        let deadline = Date.now.addingTimeInterval(10)
        while !fieldText(field).hasSuffix(expected), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(
            fieldText(field).hasSuffix(expected), "The field reads \(fieldText(field)), not …\(expected)"
        )
        XCTAssertTrue(fieldText(field).hasPrefix("language:chinese "), "The text searched is gone")
        XCTAssertFalse(element("route.placeholder.gallery", in: app).exists, "Tapping the tag opened the gallery")
    }

    /// Clear in the history's header asks first; Clear in the question empties the history. Sends the
    /// `eros0fixture0nohit` search, and POST api.php (tagsuggest) while it is typed.
    @MainActor
    func testClearingTheHistoryAsksFirst() {
        let app = openSearch()
        let field = focusedSearchField(in: app)
        field.typeText("eros0fixture0nohit\n")
        XCTAssertTrue(element("gallery.empty", in: app).waitForExistence(timeout: 30), "The search did not run")
        clear(field, in: app)
        let entry = historyEntry("eros0fixture0nohit", in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "The search is not in the history")

        element("search.history.clear", in: app).tap()
        // A system alert with Clear and Cancel (QK64, user decision 2026-11-17), found by its title: its buttons
        // carry no identifiers.
        let question = app.alerts["Clear search history?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5), "Clear did not ask first")
        XCTAssertTrue(question.buttons["Cancel"].exists, "The question has no Cancel")
        let confirm = question.buttons["Clear"]
        guard confirm.exists else {
            attachElementTree(of: app)
            XCTFail("The question has no Clear")
            return
        }
        confirm.tap()
        XCTAssertTrue(question.waitForNonExistence(timeout: 5), "The question did not close")
        // At a regular width the alert took the field's focus, which ends the search and its suggestions: the field
        // is tapped again, so the history shows if there is one.
        searchField(in: app).tap()
        XCTAssertTrue(entry.waitForNonExistence(timeout: 10), "The history was not cleared")
        XCTAssertFalse(element("search.history.clear", in: app).exists, "An empty history still shows its header")
    }

    /// Also sends POST api.php (tagsuggest) while `eros0fixture0nohit` is typed.
    @MainActor
    func testEmptySearchShowsNoGalleries() {
        let app = openSearch()
        focusedSearchField(in: app).typeText("eros0fixture0nohit\n")
        XCTAssertTrue(element("gallery.empty", in: app).waitForExistence(timeout: 30), "No empty result")
    }

    /// Types a made-up word; the site's suggestions come from POST api.php (tagsuggest) → eh/api/tagsuggest.json,
    /// whatever the word. Picking one, the topmost wholly on screen below the search field (the first one but on a
    /// short screen), puts its term in place of the word.
    @MainActor
    func testTypingShowsTagSuggestions() {
        let app = openSearch()
        let field = focusedSearchField(in: app)
        field.typeText("fak")
        let suggestions = app.descendants(matching: .any).matching(identifier: "search.suggestion")
        XCTAssertTrue(suggestions.firstMatch.waitForExistence(timeout: 10), "No suggestions")
        let submit = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "search.submit", "Search “fak”"))
            .firstMatch
        // The last row, below the ten suggestions: a short screen (the cover screen held sideways) holds six or seven
        // rows, and the lazy list leaves the rest out of the element tree until it is scrolled to them.
        if !submit.waitForExistence(timeout: 5) {
            scrollUntilVisible(submit, in: app)
        }
        XCTAssertTrue(submit.exists, "No Search “fak” row")
        attachScreenshot("q2-search-suggestions", of: app)

        // Not the first match: once the list was scrolled, the first rows are gone, cut by the screen's edge, or under
        // the navigation bar with its search field, hittable only through the strip above the bar.
        guard let suggestion = firstWhollyVisible(suggestions, below: field, in: app) else {
            attachElementTree(of: app)
            XCTFail("No suggestion lies wholly on screen")
            return
        }
        let label = suggestion.label
        XCTAssertFalse(label.isEmpty, "The suggestion has no label")
        suggestion.tap()
        let expected = Self.suggestionTerm(label: label) + " "
        let deadline = Date.now.addingTimeInterval(5)
        while fieldText(field) != expected, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertEqual(fieldText(field), expected)
    }

    /// A tap at the edge of a suggestion's row, far from its text, puts the suggestion in place of the word too, and
    /// searches nothing (on iOS 27.2 selecting the row would submit the half typed text). The bottom left corner of
    /// what the row shows, 16 pt left of the text: before the button covered its whole row, a tap there did nothing,
    /// where taps nearer the text still reached the button. Also sends POST api.php (tagsuggest) while `fak` is typed.
    @MainActor
    func testTappingTheEdgeOfASuggestionRowAppliesIt() {
        let app = openSearch()
        let field = focusedSearchField(in: app)
        field.typeText("fak")
        let suggestion = element("search.suggestion", in: app)
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "No suggestions")
        let label = suggestion.label
        let row = app.cells.containing(.any, identifier: "search.suggestion").firstMatch
        XCTAssertTrue(row.exists, "The suggestion is in no row")
        let text = suggestion.staticTexts.firstMatch
        XCTAssertTrue(text.exists, "The suggestion shows no text")

        // From the text, not the cell's leading 1 %: held sideways with the rail on the left, the cell runs on under
        // the rail and the camera's margin (x 0–84), where no tap reaches the row; 16 pt left of the text is 4 pt into
        // the row's leading padding of 20 pt (`wholeRow()`), on whichever side the rail is.
        let edge = text.frame.minX - 16 - row.frame.minX
        row.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: edge, dy: row.frame.height * 0.97)).tap()
        let expected = Self.suggestionTerm(label: label) + " "
        let deadline = Date.now.addingTimeInterval(5)
        while fieldText(field) != expected, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertEqual(fieldText(field), expected)
        let results = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "gallery.list.")).firstMatch
        XCTAssertFalse(results.waitForExistence(timeout: 3), "The half typed text was searched")

        clear(field, in: app)
        let recorded = historyEntry("fak", in: app)
        XCTAssertFalse(recorded.waitForExistence(timeout: 3), "The half typed text is in the history")
    }

    /// A site gallery link offers Open Link, which opens the gallery's placeholder once (nothing is fetched). Also
    /// sends POST api.php (tagsuggest) for what is typed before the text is a link.
    @MainActor
    func testSiteGalleryURLOffersToOpenIt() {
        let app = openSearch()
        focusedSearchField(in: app).typeText("https://e-hentai.org/g/1234/0123456789/")
        let open = element("search.openLink", in: app)
        XCTAssertTrue(open.waitForExistence(timeout: 10), "No Open Link")
        open.tap()
        XCTAssertTrue(
            element("route.placeholder.gallery", in: app).waitForExistence(timeout: 10), "The gallery did not open"
        )
        // Pushed once: one step back is the search page.
        goBack(in: app)
        XCTAssertTrue(
            element("route.placeholder.gallery", in: app).waitForNonExistence(timeout: 5), "The gallery is still shown"
        )
        XCTAssertTrue(element("search.root", in: app).waitForExistence(timeout: 5), "Back did not reach the search")
    }

    /// Add to Quick Search, on the bar or in its overflow menu, then reads In Quick Search and is disabled. Also sends
    /// POST api.php (tagsuggest) while `eros0fixture0nohit` is typed.
    @MainActor
    func testAddToQuickSearchMarksTheText() {
        let app = openSearch()
        focusedSearchField(in: app).typeText("eros0fixture0nohit")
        guard let add = toolbarItem("search.addQuickSearch", title: "Add to Quick Search", in: app) else {
            attachElementTree(of: app)
            XCTFail("No Add to Quick Search")
            return
        }
        XCTAssertTrue(add.isEnabled, "Add to Quick Search is disabled")
        add.tap()
        guard let added = overflowItem("search.addQuickSearch", title: "In Quick Search", in: app) else {
            attachElementTree(of: app)
            XCTFail("The item does not read In Quick Search")
            return
        }
        XCTAssertFalse(added.isEnabled, "In Quick Search can still be tapped")
    }

    /// A search link opened from outside the app (entry E1, `-EROS_UI_TESTING_ROUTE`) shows its results on the search
    /// page: GET https://e-hentai.org/?f_search=eros0fixture0nohit → eh/list/search-empty.html. Nothing is typed.
    @MainActor
    func testSearchLinkOpensTheSearchPage() {
        let app = launchApp(
            replayingFixtures: true,
            arguments: ["-EROS_UI_TESTING_ROUTE", "https://e-hentai.org/?f_search=eros0fixture0nohit"]
        )
        XCTAssertTrue(element("search.root", in: app).waitForExistence(timeout: 30), "The search page did not open")
        XCTAssertTrue(element("gallery.empty", in: app).waitForExistence(timeout: 30), "No empty result")
        XCTAssertEqual(fieldText(searchField(in: app)), "eros0fixture0nohit")
    }

    /// Logged in (`-EROS_UI_TESTING_SESSION 1`), the Favorites tab's Search item opens the search page in the
    /// favorites scope, its scopes shown with the field (search-scopes): GET https://e-hentai.org/favorites.php →
    /// constructed/eh/list-favorites.html (the tab's list). Nothing is typed. The search filters do not apply to the
    /// favorites scope (search Q3): Filter is there but disabled, and enabled in the Gallery scope.
    @MainActor
    func testFavoritesToolbarOpensTheSearchPage() {
        let favorites = UITestRoute(path: "constructed/eh/list-favorites.html")
        let app = launchApp(
            replayingFixtures: true, routes: ["GET https://e-hentai.org/favorites.php": favorites],
            arguments: ["-EROS_UI_TESTING_SESSION", "1"]
        )
        selectTab("favorites", in: app)
        XCTAssertTrue(element("favorites.root", in: app).waitForExistence(timeout: 10), "No favorites page")
        XCTAssertNotNil(firstGalleryItem(in: app), "The favorites show no gallery")
        tapToolbarItem("favorites.search", title: "Search", in: app)
        XCTAssertTrue(element("search.root", in: app).waitForExistence(timeout: 10), "The search page did not open")
        XCTAssertTrue(searchField(in: app).exists, "The search page has no search field")
        let scope = app.buttons.matching(NSPredicate(
            format: "label == %@ AND NOT (identifier BEGINSWITH %@)", "Favorites", "tab."
        ))
        XCTAssertTrue(scope.firstMatch.waitForExistence(timeout: 5), "The search has no Favorites scope")
        XCTAssertTrue(
            scope.allElementsBoundByIndex.contains { $0.isSelected }, "The favorites scope is not the one chosen"
        )
        attachScreenshot("q2-search-scopes", of: app)

        guard let filter = overflowItem("search.filter", title: "Filter", in: app) else {
            attachElementTree(of: app)
            XCTFail("The favorites search has no Filter")
            return
        }
        XCTAssertFalse(filter.isEnabled, "Filter is enabled in the favorites scope")
        // On the bar, the scope can be changed under it (an open overflow menu would cover the scopes).
        guard filter.identifier == "search.filter" else { return }
        let galleryScope = app.buttons.matching(NSPredicate(
            format: "label == %@ AND NOT (identifier BEGINSWITH %@)", "Gallery", "tab."
        ))
        guard let gallery = firstHittable(galleryScope, within: 5) else {
            attachElementTree(of: app)
            XCTFail("The search has no Gallery scope")
            return
        }
        gallery.tap()
        let deadline = Date.now.addingTimeInterval(5)
        while !filter.isEnabled, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(filter.isEnabled, "Filter is disabled in the Gallery scope")
    }

    // MARK: - Helpers

    /// The history row of `text` (`search.history`, labelled with the text).
    @MainActor private func historyEntry(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "search.history", text)).firstMatch
    }

    /// The search term of a tag whose raw name is `raw` (the app's `SearchText.tagTerm(for: TagRef(raw:))`): split at
    /// the first ":", both sides trimmed, quotes dropped from the name; `<namespace>:"<name>$"`, `uploader:"<name>"`
    /// or `"<name>$"`.
    private static func tagTerm(raw: String) -> String {
        let namespace: String?
        let name: String
        if let colon = raw.firstIndex(of: ":") {
            namespace = raw[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            name = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            namespace = nil
            name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let clean = name.replacingOccurrences(of: "\"", with: "")
        switch namespace {
        case "uploader"?: return "uploader:\"\(clean)\""
        case let namespace?: return "\(namespace):\"\(clean)$\""
        case nil: return "\"\(clean)$\""
        }
    }

    /// The term a suggestion labelled `label` ("<short>:<key>") writes (the label and "$"); a
    /// key with a space is quoted (`TagSuggestion.searchTerm`).
    private static func suggestionTerm(label: String) -> String {
        let colon = label.firstIndex(of: ":")
        let key = colon.map { String(label[label.index(after: $0)...]) } ?? label
        guard key.contains(" ") else { return label + "$" }
        let prefix = colon.map { String(label[...$0]) } ?? ""
        return "\(prefix)\"\(key)$\""
    }
}
