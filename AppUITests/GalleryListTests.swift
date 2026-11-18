import XCTest

/// UI tests for the gallery list (browse B4): the gallery tab's front page from the replayed fixtures, its next page,
/// the five list styles, the long-press menu and the failures the first page can meet. The tab opens on its first
/// group, Popular, a single page; every test picks the Gallery group (the front page) in the title menu first (B6), but
/// the pull to refresh of an empty list, which stays on Popular, routed to an empty page for its first request.
final class GalleryListTests: XCTestCase {
    /// How many galleries the replayed front page (`eh/list/front.html`) has; its next page has as many others.
    private static let frontPageCount = 25

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGalleryShowsTheFrontPage() {
        let app = launchApp(replayingFixtures: true)
        selectGroup("Gallery", from: "Popular", in: app)
        XCTAssertTrue(element("gallery.list.list", in: app).waitForExistence(timeout: 30), "No list")
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery on the front page")
    }

    @MainActor
    func testScrollingToTheEndLoadsTheNextPage() {
        let app = launchApp(replayingFixtures: true)
        selectGroup("Gallery", from: "Popular", in: app)
        let list = element("gallery.list.list", in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 30), "No list")
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery on the front page")
        // Every gallery of the front page passes by on the way to its end; one more is from the next page. Stops as
        // soon as it is there: the next page's own next page is not among the replayed requests.
        let swiped = swipeUntilMoreGalleries(than: Self.frontPageCount, in: "gallery.root", maxSwipes: 40, app: app)
        XCTAssertGreaterThan(
            swiped.seen, Self.frontPageCount,
            "Only \(swiped.seen) galleries after \(swiped.swipes) swipes (\(swiped.first) at first): the next page did"
                + " not load"
        )
    }

    @MainActor
    func testEveryListStyleShowsItems() {
        let app = launchApp(replayingFixtures: true)
        selectGroup("Gallery", from: "Popular", in: app)
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery on the front page")
        let styles = [
            ("list", "List - Medium"), ("simpleList", "List - Small"), ("waterfall", "Waterfall"),
            ("waterfallLarge", "Waterfall - Large"), ("grid", "Grid"),
        ]
        for (style, title) in styles {
            chooseListMode(title, in: app)
            selectTab("gallery", in: app)
            XCTAssertTrue(element("gallery.list.\(style)", in: app).waitForExistence(timeout: 10), "No \(style) list")
            XCTAssertNotNil(firstGalleryItem(in: app), "No gallery in the \(style) list")
            // The covers fail (they are not replayed) and show their placeholders; give the layout a moment.
            Thread.sleep(forTimeInterval: 1)
            attachScreenshot("b4-\(style)", of: app)
        }
    }

    @MainActor
    func testLongPressOffersCopyAndShare() {
        let app = launchApp(replayingFixtures: true)
        selectGroup("Gallery", from: "Popular", in: app)
        guard let item = firstGalleryItem(in: app) else {
            XCTFail("No gallery on the front page")
            return
        }
        item.press(forDuration: 1.2)
        XCTAssertNotNil(firstHittableMenuItem("Copy Link", in: app), "The menu has no Copy Link")
        XCTAssertNotNil(firstHittableMenuItem("Share", in: app), "The menu has no Share")
        attachScreenshot("b4-menu", of: app)
    }

    @MainActor
    func testLoginRequiredOffersLogIn() {
        let app = launchApp(
            replayingFixtures: true,
            routes: ["GET https://e-hentai.org/": UITestRoute(path: "constructed/eh/list-login-required.html")]
        )
        selectGroup("Gallery", from: "Popular", in: app)
        XCTAssertTrue(element("gallery.failure", in: app).waitForExistence(timeout: 30), "No failure")
        let logIn = element("gallery.failure.logIn", in: app)
        XCTAssertTrue(logIn.waitForExistence(timeout: 5), "No Log In button")
        attachScreenshot("b4-loginRequired", of: app)
        logIn.tap()
        XCTAssertTrue(element("login.method", in: app).waitForExistence(timeout: 10), "The login did not open")
    }

    @MainActor
    func testDeclinedCompactNoticeOffersTryAgain() {
        let app = launchApp(
            replayingFixtures: true,
            routes: ["GET https://e-hentai.org/": UITestRoute(path: "constructed/eh/list-non-compact.html")]
        )
        selectGroup("Gallery", from: "Popular", in: app)
        let alert = app.alerts["Switch to the Compact view?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "No Compact view question")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(element("gallery.failure", in: app).waitForExistence(timeout: 10), "No failure")
        XCTAssertTrue(element("gallery.failure.tryAgain", in: app).waitForExistence(timeout: 5), "No Try Again")
    }

    @MainActor
    func testTagsAreNotButtonsByDefault() {
        let app = launchApp(replayingFixtures: true)
        selectGroup("Gallery", from: "Popular", in: app)
        XCTAssertNotNil(firstGalleryItem(in: app), "No gallery on the front page")
        XCTAssertFalse(element("list.tag", in: app).exists, "A list tag is a button without a tag action")
    }

    @MainActor
    func testTooManyRequestsShowsThePauseBanner() {
        let app = launchApp(
            replayingFixtures: true,
            routes: ["GET https://e-hentai.org/": UITestRoute(path: "constructed/eh/http-429.html", status: 429)]
        )
        selectGroup("Gallery", from: "Popular", in: app)
        let banner = element("gallery.pauseBanner", in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "No pause banner")
        XCTAssertTrue(banner.label.contains("Requests are paused until"), "The banner reads \"\(banner.label)\"")
        attachScreenshot("b4-pauseBanner", of: app)
    }

    @MainActor
    func testBanShowsThePauseBanner() {
        let app = launchApp(
            replayingFixtures: true,
            routes: ["GET https://e-hentai.org/": UITestRoute(path: "constructed/eh/banned.txt")]
        )
        selectGroup("Gallery", from: "Popular", in: app)
        let banner = element("gallery.pauseBanner", in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "No pause banner")
        XCTAssertTrue(banner.label.contains("temporarily banned"), "The banner reads \"\(banner.label)\"")
    }

    /// An empty list still pulls to refresh (U9 keeps No Galleries in the list's scroll view; M2 review M-9e), and the
    /// refresh asks the site again (M2 review F4 I-2). Popular's first request gets the empty search page, every one
    /// after the front page (`UITestRoute.then`): galleries show only once the list asked again.
    ///
    /// The pull starts 40 pt below the navigation bars over the empty state (`PageLayout.topBars(across:in:)`; its own
    /// top without one), clear of the bars on any screen (M2 review F4 M-7), and goes down 0.6 of the window's height
    /// (short of its bottom), slow and held: past the refresh control's threshold on the shortest screen too (the
    /// rubber band moves the list some quarter of the pull).
    @MainActor
    func testAnEmptyListPullsToRefresh() {
        let app = launchApp(
            replayingFixtures: true,
            routes: [
                "GET https://e-hentai.org/popular": UITestRoute(
                    path: "eh/list/search-empty.html", then: "eh/list/front.html"
                ),
            ]
        )
        // Popular is where the tab opens; the tab is tapped all the same, as every test does (a single reselect only
        // scrolls to the top: two within 0.8 s would refresh, B2).
        selectTab("gallery", in: app)
        let empty = element("gallery.empty", in: app)
        XCTAssertTrue(empty.waitForExistence(timeout: 30), "Popular shows no empty list")
        XCTAssertTrue(itemIdentifiers(in: app).isEmpty, "Popular shows galleries before the pull")
        let layout = PageLayout(of: app)
        let shown = empty.frame
        var top = shown.minY
        if case .bottom(let bottom) = layout.topBars(across: shown, in: app) { top = bottom }
        let startY = top + 40
        let pull = min(layout.window.height * 0.6, layout.window.maxY - 8 - startY)
        let window = pageWindow(of: app)
        layout.point(shown.midX, startY, on: window).press(
            forDuration: 0.05, thenDragTo: layout.point(shown.midX, startY + pull, on: window), withVelocity: .slow,
            thenHoldForDuration: 0.3
        )
        let gallery = firstGalleryItem(in: app)
        attachScreenshot("m9-afterRefresh", of: app)
        XCTAssertNotNil(
            gallery,
            "No gallery after a pull of \(pull) pt from y \(startY) (window \(layout.window)): the list did not ask"
                + " again (the empty list is \(empty.exists ? "still there" : "gone"))"
        )
        XCTAssertFalse(empty.exists, "The empty list is still there after the refresh")
        XCTAssertFalse(element("gallery.failure", in: app).exists, "The refresh failed")
        XCTAssertFalse(element("gallery.refreshFailure", in: app).exists, "The refresh failed")
    }

    // MARK: - Helpers

    /// Settings → List Mode → `title`.
    @MainActor private func chooseListMode(_ title: String, in app: XCUIApplication) {
        selectTab("settings", in: app)
        let picker = element("settings.listMode", in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "No List Mode row in Settings")
        picker.tap()
        guard let choice = hittableMenuItem(title, in: app) else {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "element tree"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("No \(title) in the List Mode menu")
            return
        }
        choice.tap()
    }
}
