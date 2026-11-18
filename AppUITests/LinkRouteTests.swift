import XCTest

/// UI tests for opening a site link from outside the app (entry E1). The link is passed with
/// `-EROS_UI_TESTING_ROUTE <url>`, which the app opens while it launches, before its tabs show: so it also waits for
/// them. The tag and uploader lists are replayed from the checked-in fixtures (`eh/list/tag.html`,
/// `eh/list/uploader.html`, `ex/list/uploader.html`; their URLs give `language:chinese` and `x392`); the gallery and
/// image page links open their placeholders.
///
/// The pages are checked with the helpers the external open tests share (`SystemUITestSupport.swift`: titles by label
/// or identifier). Every link opens on the Gallery tab, which stays selected after going back: its tab item is the
/// selected one (`expectSelectedTab`).
final class LinkRouteTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTagLinkOpensTheTagList() {
        let app = launch(opening: "https://e-hentai.org/tag/language:chinese")
        expectList(titled: "language:chinese", in: app)
        attachScreenshot("e1-tag", of: app)

        goBack(in: app)
        XCTAssertTrue(element("gallery.root", in: app).waitForExistence(timeout: 5), "Back did not reach the gallery")
        XCTAssertTrue(element("route.list", in: app).waitForNonExistence(timeout: 5), "The list is still shown")
        XCTAssertNotNil(firstGalleryItem(in: app), "The gallery's root page shows no gallery")
        expectSelectedTab("gallery", in: app)
        attachScreenshot("e1-backToRoot", of: app)
    }

    @MainActor
    func testUploaderLinkOpensTheUploaderList() {
        let app = launch(opening: "https://e-hentai.org/uploader/x392")
        expectList(titled: "x392", in: app)
        attachScreenshot("e1-uploader", of: app)
    }

    /// The list loads from exhentai.org: e-hentai.org's uploader page answers with a page that lists nothing (the
    /// login-required one), so a list that went to the wrong site shows no gallery.
    @MainActor
    func testExUploaderLinkOpensTheExList() {
        let app = launch(
            opening: "https://exhentai.org/uploader/x392",
            routes: [
                "GET https://e-hentai.org/uploader/x392": UITestRoute(path: "constructed/eh/list-login-required.html"),
            ]
        )
        expectList(titled: "x392", in: app)
        XCTAssertFalse(element("gallery.failure", in: app).exists, "The list failed")
        attachScreenshot("e1-exUploader", of: app)
    }

    @MainActor
    func testGalleryLinkOpensThePlaceholder() {
        let app = launch(opening: "https://e-hentai.org/g/1234/0123456789/")
        expectPlaceholder("route.placeholder.gallery", describedAs: "Gallery 1234", in: app)
        attachScreenshot("e1-galleryPlaceholder", of: app)
    }

    @MainActor
    func testImagePageLinkOpensThePlaceholder() {
        let app = launch(opening: "https://exhentai.org/s/0123456789/1234-5")
        expectPlaceholder("route.placeholder.imagePage", describedAs: "Gallery 1234, page 5", in: app)
        attachScreenshot("e1-imagePagePlaceholder", of: app)
    }

    // MARK: - Helpers

    /// Launches the app replaying the fixtures (with `routes` first), opening `link` as it starts.
    @MainActor private func launch(opening link: String, routes: [String: UITestRoute] = [:]) -> XCUIApplication {
        launchApp(replayingFixtures: true, routes: routes, arguments: ["-EROS_UI_TESTING_ROUTE", link])
    }
}
