import XCTest

/// UI tests for the favorites tab (browse B8). Logged out (no session) it shows the local favorites only, which start
/// empty. Logged in (the made-up session of `-EROS_UI_TESTING_SESSION 1`) it lists favorites.php, replayed from the
/// constructed page (`favorites.php` and `?favcat=0`): ordered by Favorited, as the app asks by default, so no question
/// about the order comes up; five galleries, one with a note, and ten folders named `Fake Folder 0`…`9`.
///
/// The other order is picked only to decline the question it brings: agreeing would send `inline_set`, which is not
/// replayed (the order change is covered by `FavoritesServiceTests` on a mock).
final class FavoritesTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLoggedOutShowsOnlyLocalFavorites() {
        let app = launchApp(replayingFixtures: true)
        selectTab("favorites", in: app)
        XCTAssertTrue(
            element("favorites.root", in: app).waitForExistence(timeout: 10), "The favorites page did not open"
        )
        XCTAssertTrue(element("gallery.empty", in: app).waitForExistence(timeout: 10), "No empty local favorites")
        // The navigation title's value: on every device the navigation bar's identifier is its title, so this matches
        // there at least; it does not tell whether the title is drawn (iPadOS 27.2 draws no plain inline title under
        // its tab bar). That the cover screen shows it is checked on the screenshot (b8-local).
        let title = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR identifier == %@", "Local Favorites", "Local Favorites"
        ))
        XCTAssertTrue(title.firstMatch.waitForExistence(timeout: 5), "The page is not titled Local Favorites")
        let titleMenu = app.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@", "Local Favorites", "Local Favorites,"
        ))
        XCTAssertFalse(titleMenu.firstMatch.exists, "The local favorites have a title menu")
        XCTAssertFalse(element("favorites.order", in: app).exists, "The local favorites offer an order")
        attachScreenshot("b8-local", of: app)
    }

    @MainActor
    func testLoggedInListsAllFoldersAndLocal() {
        let app = openLoggedIn()
        // The folders are named once the first page came.
        guard topGalleryIdentifier(in: app) != nil else { return }
        // The first row: a short screen (the cover screen held sideways) shows only the first rows of the menu, and
        // the rows below are not in the element tree until it is scrolled, so each is scrolled to in turn.
        openTitleMenu("All Favorites", offering: FavoritesFixtureMenu.items[0], in: app)
        for item in FavoritesFixtureMenu.items {
            scrollTitleMenu(toShow: item, in: app)
            XCTAssertNotNil(hittableMenuItem(item, in: app), "The title menu has no \(item)")
        }
        attachScreenshot("b8-titleMenu", of: app)
    }

    /// The gallery with a note shows it. The whole gallery is scrolled to (`scrollUntilVisible`), so its note and its
    /// rating row show together for the screenshot, below the bars: no drag after it to leave the note near an edge.
    @MainActor
    func testFavoriteNotesAreShown() {
        let app = openLoggedIn()
        guard topGalleryIdentifier(in: app) != nil else { return }
        let notePredicate = NSPredicate(format: "label BEGINSWITH %@", "Note: ")
        let gallery = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "gallery.item."))
            .containing(notePredicate).firstMatch
        let shown = scrollUntilVisible(gallery, in: app)
        guard gallery.exists else {
            attachElementTree(of: app)
            XCTFail("No gallery shows its note")
            return
        }
        XCTAssertTrue(shown, "The gallery with the note is not wholly on screen below the bars: \(gallery.frame)")
        let note = gallery.descendants(matching: .any).matching(notePredicate).firstMatch
        XCTAssertTrue(note.exists && note.isHittable, "The note is not on screen")
        let rating = gallery.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Rating "))
            .firstMatch
        XCTAssertTrue(rating.exists && gallery.frame.contains(rating.frame), "The gallery shows no rating")
        attachScreenshot("b8-list", of: app)
    }

    @MainActor
    func testOrderMenuOffersBothOrders() {
        let app = openLoggedIn()
        guard topGalleryIdentifier(in: app) != nil else { return }
        tapToolbarItem("favorites.order", title: "Favorites Order", in: app)
        guard let favorited = hittableMenuItem("Use Favorited", in: app) else {
            attachElementTree(of: app)
            XCTFail("The order menu has no Use Favorited")
            return
        }
        XCTAssertNotNil(hittableMenuItem("Use Posted", in: app), "The order menu has no Use Posted")
        XCTAssertTrue(favorited.isSelected, "Use Favorited is not checked")
        attachScreenshot("b8-order", of: app)
    }

    /// Declining to change the site's order keeps it, and a line above the list says so (M2 review L091b). The
    /// replayed page is in Favorited; Use Posted asks for the list again in Posted, the page comes back in Favorited,
    /// and the question whether to change the site's order is answered Cancel: the list stays in Favorited under the
    /// note `favorites.keptOrder`, attached as `b8-keptOrder`. Cancel sends nothing (`inline_set` is not replayed, so
    /// a request with it would end in a failure page).
    @MainActor
    func testDecliningTheSitesOrderKeepsItAndSaysSo() {
        let app = openLoggedIn()
        guard topGalleryIdentifier(in: app) != nil else { return }
        XCTAssertFalse(element("favorites.keptOrder", in: app).exists, "A kept order before any question")
        tapToolbarItem("favorites.order", title: "Favorites Order", in: app)
        guard let posted = hittableMenuItem("Use Posted", in: app) else {
            attachElementTree(of: app)
            XCTFail("The order menu has no Use Posted")
            return
        }
        posted.tap()
        let question = app.alerts["Change the favorites order?"]
        XCTAssertTrue(question.waitForExistence(timeout: 30), "No question about the site's order")
        let cancel = question.buttons["Cancel"]
        guard cancel.exists else {
            attachElementTree(of: app)
            XCTFail("The question has no Cancel")
            return
        }
        cancel.tap()
        XCTAssertTrue(question.waitForNonExistence(timeout: 10), "The question stayed")

        let note = element("favorites.keptOrder", in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 10), "No note that the site's order was kept")
        XCTAssertTrue(shown(note).contains("favorited time"), "The note reads \"\(shown(note))\"")
        XCTAssertNotNil(firstGalleryItem(in: app), "The list shows no gallery under the note")
        XCTAssertFalse(element("gallery.failure", in: app).exists, "The list failed after Cancel")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Another question came up")
        attachScreenshot("b8-keptOrder", of: app)
    }

    // MARK: - Helpers

    /// Drags the open title menu up until its row `title` can be hit, at most twice; nothing when the row can be hit
    /// within 2 s (a menu still coming in has rows that cannot be hit yet, and a drag on a menu with nothing to scroll
    /// might pick a row).
    ///
    /// A drag goes from the row above the lowest one that can be hit to the second row from the top, both wholly in
    /// the menu (the edge rows may be cut, and on a rotated display XCTest aims at a cut element without turning the
    /// point with the display), and is held at its end so the menu stops there. Not a swipe on the menu's list: that
    /// list reaches past the menu's edge, so it is a cut element too. Asserts nothing: callers check the row.
    @MainActor private func scrollTitleMenu(toShow title: String, in app: XCUIApplication) {
        // As `hittableMenuItem`: any element type but the images (a row's symbol is labelled as the row), so a menu
        // whose rows are not buttons is still scrolled.
        func row(_ label: String) -> XCUIElement? {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@ AND NOT (identifier BEGINSWITH %@)", label, "tab."
            )).allElementsBoundByIndex.first { $0.exists && $0.elementType != .image && $0.isHittable }
        }
        /// Whether the row can be hit within 2 s.
        func canHit(_ label: String) -> Bool {
            let deadline = Date.now.addingTimeInterval(2)
            while row(label) == nil {
                guard Date.now < deadline else { return false }
                Thread.sleep(forTimeInterval: 0.25)
            }
            return true
        }
        for _ in 0..<2 where !canHit(title) {
            // In the menu's order, top to bottom.
            let shown = FavoritesFixtureMenu.items.compactMap(row)
            guard shown.count >= 4 else { return }
            shown[shown.count - 2].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                forDuration: 0.05, thenDragTo: shown[1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                withVelocity: .default, thenHoldForDuration: 0.3
            )
        }
    }

    /// Launches the app with the made-up session over the replayed fixtures, the favorites page served for
    /// `favorites.php` and `?favcat=0`, and opens the favorites tab, titled All Favorites, once the first page's
    /// galleries are there. Fails when a question came up with that page (the order matches, so none should): it is
    /// looked for after the galleries exist, before anything needs them to be hittable (a question would cover them).
    @MainActor private func openLoggedIn() -> XCUIApplication {
        let favorites = UITestRoute(path: "constructed/eh/list-favorites.html")
        let app = launchApp(
            replayingFixtures: true,
            routes: [
                "GET https://e-hentai.org/favorites.php": favorites,
                "GET https://e-hentai.org/favorites.php?favcat=0": favorites,
            ],
            arguments: ["-EROS_UI_TESTING_SESSION", "1"]
        )
        selectTab("favorites", in: app)
        XCTAssertTrue(
            element("favorites.root", in: app).waitForExistence(timeout: 10), "The favorites page did not open"
        )
        XCTAssertNotNil(titleMenuButton("All Favorites", in: app), "The favorites page is not titled All Favorites")
        let galleries = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "gallery.item.")).firstMatch
        XCTAssertTrue(galleries.waitForExistence(timeout: 30), "The first page did not come")
        XCTAssertFalse(app.alerts.firstMatch.exists, "A question came up")
        XCTAssertNotNil(topGalleryIdentifier(in: app), "No gallery can be tapped")
        return app
    }
}
