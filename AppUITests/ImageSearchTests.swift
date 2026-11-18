import XCTest

/// UI tests for the image search (search Q5) over the replayed fixtures, in English. Every test opens the search page
/// from the gallery tab (the tab's root, the Popular group: GET https://e-hentai.org/popular → eh/list/popular.html),
/// then the image search page from its toolbar (Image Search, on the bar or in the overflow menu). Neither the Photos
/// picker nor the file browser is opened: `-EROS_UI_TEST_IMAGE 1` has the page pick a made-up 8×8 PNG itself.
///
/// Searching sends what the captured image search did (`ImageSearchTests.resultURL` is the capture's `Location`):
/// - POST https://upld.e-hentai.org/image_lookup.php → eh/list/image-lookup-redirect.html, its 302 and the manifest's
///   `location` (the replay answers by method and address, whatever the image; nothing follows the redirect);
/// - GET of that location → eh/list/image-lookup.html (no galleries, the Similarity Scan notice), or, routed,
///   eh/list/front.html (25 galleries; `testOpeningAResultKeepsTheResults`). A gallery opens its placeholder
///   (`route.placeholder.gallery`), which fetches nothing.
///
/// Screenshots are named `q5-<name>` (the cover-screen checks).
final class ImageSearchTests: XCTestCase {
    /// The `location` of the manifest's eh/list/image-lookup-redirect.html: the captured search's result list.
    private static let resultURL =
        "https://e-hentai.org/?f_shash=b13eca9f4647d5d69ef997acd129cbbd3cd4e37d&fs_from=a.webp"
    /// The launch argument that has the image search page pick its made-up test image.
    private static let testImage = ["-EROS_UI_TEST_IMAGE", "1"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The page starts with Similarity Scan on and the other two switches off, both ways to pick an image, and Search
    /// disabled until one is picked (image-search).
    @MainActor
    func testImageSearchStartsWithOnlySimilarityOn() {
        let app = openImageSearch()
        let switches = [("imageSearch.similar", "1"), ("imageSearch.covers", "0"), ("imageSearch.expunged", "0")]
        for (identifier, value) in switches {
            let toggle = app.switches.matching(identifier: identifier).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "No switch \(identifier)")
            XCTAssertEqual(toggle.value as? String, value, "\(identifier) starts wrong")
        }
        XCTAssertTrue(element("imageSearch.photos", in: app).exists, "No Choose from Photos")
        XCTAssertTrue(element("imageSearch.files", in: app).exists, "No Choose from Files")
        XCTAssertFalse(element("imageSearch.preview", in: app).exists, "A preview without an image")
        let submit = element("imageSearch.submit", in: app)
        XCTAssertTrue(submit.waitForExistence(timeout: 5), "No Search")
        XCTAssertFalse(submit.isEnabled, "Search is enabled without an image")
        attachScreenshot("q5-image-search", of: app)
    }

    /// With the test image picked (image-search-chosen: its preview whole), Search sends the upload and shows the
    /// results page: no galleries, and the note that the site's Similarity Scan was off (image-search-results).
    @MainActor
    func testSearchingTheTestImageShowsTheResult() {
        let app = openImageSearch(arguments: Self.testImage)
        let submit = enabledSubmit(in: app)
        XCTAssertTrue(element("imageSearch.preview", in: app).exists, "No preview of the test image")
        attachScreenshot("q5-image-search-chosen", of: app)

        submit.tap()
        XCTAssertTrue(element("imageSearch.results", in: app).waitForExistence(timeout: 30), "No results page")
        XCTAssertTrue(element("imageSearch.similarityNote", in: app).waitForExistence(timeout: 10), "No note")
        XCTAssertTrue(element("gallery.empty", in: app).waitForExistence(timeout: 10), "The results are not empty")
        attachScreenshot("q5-image-search-results", of: app)
    }

    /// A gallery opened from the results comes back to them (image-search-results-items), then to the image search
    /// page with its image still picked and Only Search Covers still on (turned on before the search), then to the
    /// search page: both pages go by value onto the tab's stack, so the
    /// gallery's push leaves them there.
    @MainActor
    func testOpeningAResultKeepsTheResults() {
        let app = openImageSearch(
            routes: ["GET \(Self.resultURL)": UITestRoute(path: "eh/list/front.html")], arguments: Self.testImage
        )
        turnOn("imageSearch.covers", in: app)
        enabledSubmit(in: app).tap()
        XCTAssertTrue(element("imageSearch.results", in: app).waitForExistence(timeout: 30), "No results page")
        guard let item = firstGalleryItem(in: app) else {
            attachElementTree(of: app)
            XCTFail("The results show no gallery")
            return
        }
        attachScreenshot("q5-image-search-results-items", of: app)

        item.tap()
        XCTAssertTrue(
            element("route.placeholder.gallery", in: app).waitForExistence(timeout: 10), "The gallery did not open"
        )
        goBack(in: app)
        XCTAssertTrue(
            element("route.placeholder.gallery", in: app).waitForNonExistence(timeout: 5), "The gallery is still shown"
        )
        XCTAssertTrue(
            element("imageSearch.results", in: app).waitForExistence(timeout: 10), "Back did not reach the results"
        )

        goBack(in: app)
        XCTAssertTrue(
            element("imageSearch.root", in: app).waitForExistence(timeout: 10), "Back did not reach the image search"
        )
        XCTAssertFalse(element("imageSearch.results", in: app).exists, "The results are still shown")
        XCTAssertTrue(element("imageSearch.preview", in: app).exists, "The image picked is gone")
        XCTAssertTrue(element("imageSearch.submit", in: app).isEnabled, "Search is disabled with the image picked")
        let covers = app.switches.matching(identifier: "imageSearch.covers").firstMatch
        XCTAssertEqual(covers.value as? String, "1", "Only Search Covers is off again")

        goBack(in: app)
        XCTAssertTrue(element("search.root", in: app).waitForExistence(timeout: 10), "Back did not reach the search")
        XCTAssertFalse(element("imageSearch.root", in: app).exists, "The image search page is still shown")
    }

    // MARK: - Helpers

    /// Launches with the fixtures replayed (`routes`, `arguments` as given), opens the search page from the gallery
    /// tab, then Image Search from its toolbar (checked to carry its title: the Duo rail shows only the symbol), and
    /// waits for the image search page.
    @MainActor private func openImageSearch(
        routes: [String: UITestRoute] = [:], arguments: [String] = []
    ) -> XCUIApplication {
        let app = launchApp(replayingFixtures: true, routes: routes, arguments: arguments)
        XCTAssertNotNil(firstGalleryItem(in: app), "The gallery tab shows no gallery")
        tapToolbarItem("gallery.search", title: "Search", in: app)
        XCTAssertTrue(element("search.root", in: app).waitForExistence(timeout: 10), "The search page did not open")
        guard let entry = titledToolbarItem("search.imageSearch", title: "Image Search", in: app) else {
            attachElementTree(of: app)
            return app
        }
        entry.tap()
        XCTAssertTrue(
            element("imageSearch.root", in: app).waitForExistence(timeout: 10), "The image search page did not open"
        )
        return app
    }

    /// Search, once the test image is picked and Search is enabled (up to 10 s).
    @MainActor private func enabledSubmit(in app: XCUIApplication) -> XCUIElement {
        let submit = element("imageSearch.submit", in: app)
        XCTAssertTrue(submit.waitForExistence(timeout: 10), "No Search")
        XCTAssertTrue(
            waitUntil(submit, matches: NSPredicate(format: "isEnabled == true"), timeout: 10),
            "Search is disabled with the test image picked"
        )
        return submit
    }

    /// Turns the switch `identifier` on (the row's own switch when the system nests one in it) and waits up to 5 s for
    /// its value to read on.
    @MainActor private func turnOn(_ identifier: String, in app: XCUIApplication) {
        let toggle = app.switches.matching(identifier: identifier).firstMatch
        scrollUntilVisible(toggle, in: app)
        XCTAssertTrue(toggle.exists, "No switch \(identifier)")
        XCTAssertEqual(toggle.value as? String, "0", "\(identifier) is already on")
        let inner = toggle.switches.firstMatch
        (inner.exists ? inner : toggle).tap()
        XCTAssertTrue(
            waitUntil(toggle, matches: NSPredicate(format: "value == %@", "1"), timeout: 5),
            "\(identifier) did not turn on"
        )
    }

    /// Whether `element` matches `predicate` within `timeout` seconds (`XCTNSPredicateExpectation`, no polling).
    @MainActor private func waitUntil(
        _ element: XCUIElement, matches predicate: NSPredicate, timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
