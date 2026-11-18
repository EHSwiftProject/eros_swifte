import XCTest

// Helpers every UI test uses (M2 index §3.4). Controls are found by accessibility identifier; tab items and the back
// button are never looked up through `tabBars` or `navigationBars`: on the iPhone Duo the system puts them in a rail
// (tab items under a toolbar, the back button outside the navigation bar), and on iPad the tabs may be a sidebar.

/// A constructed page the app serves for one request while it replays the fixtures (`EROS_FIXTURE_ROUTES`; the app's
/// `FixtureRoute`): `path` is under the fixtures root (`constructed/eh/banned.txt`), `status` any code. With `then`
/// (under the root too), only the first request the route matches gets `path`, every one after gets `then`: a refresh
/// that asks again sees another page.
struct UITestRoute: Encodable {
    var path: String
    var status: Int = 200
    var location: String? = nil
    var then: String? = nil
}

/// The points of a drag UIKit takes before it starts a pan (some 10 pt), and a few more (`scrollUntilVisible`).
private let dragSlop: CGFloat = 16
/// The shortest drag `scrollUntilVisible` makes.
private let shortestDrag: CGFloat = 32

extension XCTestCase {
    /// Launches the app in UI testing mode (`-EROS_UI_TESTING 1`, English): in-memory session, no Keychain access, no
    /// request reaches the site (preflight L19).
    ///
    /// - `replayingFixtures`: `-EROS_FIXTURE_REPLAY 1`, the checked-in fixtures answer the app's requests; one they do
    ///   not match gets a 404 without a body.
    /// - `routes`: keys "METHOD URL" (`"GET https://e-hentai.org/"`), passed as `EROS_FIXTURE_ROUTES`; they go before
    ///   the fixtures. Only read while replaying.
    /// - `arguments`: appended after all of these, as given (later plans' DEBUG switches, e.g.
    ///   `-EROS_UI_TESTING_SESSION 1`).
    @MainActor func launchApp(
        replayingFixtures: Bool = false, routes: [String: UITestRoute] = [:], arguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-EROS_UI_TESTING", "1", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if replayingFixtures {
            app.launchArguments += ["-EROS_FIXTURE_REPLAY", "1"]
        }
        if !routes.isEmpty {
            do {
                app.launchEnvironment["EROS_FIXTURE_ROUTES"] = String(
                    decoding: try JSONEncoder().encode(routes), as: UTF8.self
                )
            } catch {
                XCTFail("Routes could not be encoded: \(error)")
            }
        }
        app.launchArguments += arguments
        app.launch()
        return app
    }

    /// The first element of any type with this accessibility identifier.
    @MainActor func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Taps the tab item of `tab` (an `AppTab.rawValue`), wherever the system placed it (tab bar, sidebar or the Duo
    /// cover-screen rail): the hittable element with the identifier `tab.<rawValue>` (`AppTab.customizationID`).
    /// Waits up to 30 s: the tabs appear once the app has read the WebKit user agent, which a fresh launch on the iPad
    /// Pro 13-inch simulator took 8–10 s to do (iPhone Duo about 1 s).
    @MainActor func selectTab(_ tab: String, in app: XCUIApplication) {
        let identifier = "tab.\(tab)"
        guard let item = firstHittable(app.descendants(matching: .any).matching(identifier: identifier), within: 30)
        else {
            XCTFail("Tab item \(identifier) not found")
            return
        }
        item.tap()
    }

    /// Taps a toolbar item, found by `toolbarItem(_:title:in:)`. Nothing → fails with "Toolbar item <identifier> not
    /// found" and attaches the element tree.
    @MainActor func tapToolbarItem(_ identifier: String, title: String, in app: XCUIApplication) {
        if let item = toolbarItem(identifier, title: title, in: app) {
            item.tap()
            return
        }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "element tree"
        tree.lifetime = .keepAlways
        add(tree)
        XCTFail("Toolbar item \(identifier) not found")
    }

    /// A toolbar item, wherever the toolbar put it: the hittable element `identifier` when the toolbar shows it;
    /// otherwise the toolbar's overflow button ("More") is tapped, then the hittable menu item `identifier`, or else
    /// the only hittable element labelled `title` that is not an image. Waits up to 10 s for the item or the overflow
    /// button, then up to 5 s for the menu item. nil when there is none; an overflow menu it opened stays open.
    ///
    /// On iOS 27.2 a menu item does not carry the identifier its SwiftUI button has, so items in the overflow menu are
    /// found by `title`; while the menu is open the page below is not hittable (docs/spikes/duo-rail.md, M2). A menu
    /// item's symbol may read the same as its title (Search's magnifying glass reads "Search"), so images never count.
    @MainActor func toolbarItem(_ identifier: String, title: String, in app: XCUIApplication) -> XCUIElement? {
        let items = app.descendants(matching: .any).matching(identifier: identifier)
        let overflowButtons = app.buttons.matching(NSPredicate(format: "label == %@", "More"))
        let deadline = Date.now.addingTimeInterval(10)
        var overflow: XCUIElement?
        while overflow == nil {
            if let item = Self.hittable(in: items) { return item }
            overflow = Self.hittable(in: overflowButtons)
            guard overflow == nil, Date.now < deadline else { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let overflow else { return nil }
        overflow.tap()
        // The identifier first, else the title; both on every look, so a menu without identifiers costs no wait.
        let labelled = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title))
        let menuDeadline = Date.now.addingTimeInterval(5)
        while true {
            if let item = Self.hittable(in: items) { return item }
            // Without images: a row's symbol labelled as the row would make two candidates for one item.
            let candidates = labelled.allElementsBoundByIndex.filter {
                $0.exists && $0.elementType != .image && $0.isHittable
            }
            if candidates.count == 1 { return candidates[0] }
            guard Date.now < menuDeadline else { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// The system back button, by its identifier "BackButton" (on the iPhone Duo the system puts it in the rail,
    /// outside the navigation bar, and gives it no label): the hittable one when there is one within 5 s, else the
    /// first (callers wait for it to exist).
    @MainActor func systemBackButton(in app: XCUIApplication) -> XCUIElement {
        let buttons = app.buttons.matching(identifier: "BackButton")
        return firstHittable(buttons, within: 5) ?? buttons.firstMatch
    }

    /// Screenshot of the display the app is currently on.
    ///
    /// On the two-screen iPhone Duo, `app.screenshot()` comes back blank and `XCUIScreen.main` is the cover screen
    /// even while the app runs on the inner screen, so pick the screen whose size matches the app's window.
    @MainActor func screenshotOfDisplayShowing(_ app: XCUIApplication) -> XCUIScreenshot {
        let window = app.windows.firstMatch.frame.size
        func isWindowSized(_ size: CGSize) -> Bool {
            let sameOrientation = abs(size.width - window.width) < 1 && abs(size.height - window.height) < 1
            let rotated = abs(size.width - window.height) < 1 && abs(size.height - window.width) < 1
            return sameOrientation || rotated
        }
        for screen in XCUIScreen.screens {
            let shot = screen.screenshot()
            if isWindowSized(shot.image.size) {
                return shot
            }
        }
        return app.screenshot()
    }

    /// Attaches a screenshot of the display the app is on (`screenshotOfDisplayShowing(_:)`) as `name`, kept whether
    /// the test passes or not.
    @MainActor func attachScreenshot(_ name: String, of app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: screenshotOfDisplayShowing(app))
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// The element to swipe a page on: the app's window. On the two-screen iPhone Duo a gesture made on the application
    /// element goes to the cover screen even while the app runs on the inner screen, so the page there never moves;
    /// one made on an element goes to the screen that shows it.
    @MainActor func pageWindow(of app: XCUIApplication) -> XCUIElement {
        app.windows.firstMatch
    }

    /// Drags the page until `target` is on screen: it exists, can be hit and lies wholly in what shows of the
    /// container it scrolls in below the navigation bars over its top (`PageLayout.shownArea(of:)`,
    /// `PageLayout.topBars(over:in:)`; one taller or wider than that only has to be hittable). Looks again after each
    /// drag (at most `attempts` times); waits briefly first, for a page that is still loading. Rows below the screen of
    /// a lazy form or list are not in the element tree until scrolled near. Returns whether `target` ended up so on
    /// screen; asserts nothing: callers check `target`, or what this returns.
    ///
    /// Each look is one `PageLayout` (a snapshot of the app) and one snapshot of `target`; only the container picked,
    /// the bars that count and `target` once it fits are asked, as elements, whether they can be hit. A look without
    /// the app's snapshot (`PageLayout.isComplete`), or with a bar that changed since it (`PageLayout.Bars.unsure`), is
    /// taken again once, a quarter second later, before anything is concluded or dragged; a second such look is gone on
    /// with as it is (the window's middle, without that bar).
    ///
    /// The container is `container` when given and there, else the one `PageLayout.scrollContainer(for:in:)` picks,
    /// else the window; it is looked for again before every look at `target`. Half open and held sideways, the iPhone
    /// Duo's system moves a sheet left of the fold (x 8–468 of 951), so the window's middle lies outside the sheet's
    /// form.
    ///
    /// A drag goes from the middle of what shows of the container by 0.3 of its height, up, or down once `target` was
    /// last seen above what shows; after each turn half as far as before (0.1 at least). Down, with `target` in the
    /// element tree, no further than it needs (`downDrag(by:to:of:)`): a drag past the top of a list pulls it to
    /// refresh, and one past the top of a sheet's form drags the sheet. It is slow and held at its end, yet the page
    /// glides on once let go: XCTest's drag has no touch between its last move and the lift, so UIKit lets the page go
    /// at the drag's speed (on the cover screen held sideways, 466 pt high, a 140 pt drag at the default 500 pt/s
    /// glided some 190 pt further). The slow 250 pt/s should glide less; a glide past `target` is what the drag back is
    /// for. A swipe glides further still (some 630 pt). XCTest waits for the app to idle after each drag, so `target`
    /// is looked at once the page has stopped. A cut element is not enough: on a rotated display XCTest aims a tap at
    /// it without turning the point with the display. Nor is one under a navigation bar: hittable only through the
    /// strip above the bar, its tap goes to the status bar, which scrolls to the top. That middle lies above a software
    /// keyboard on screen and, in a form or list as wide as the window or a sheet's, clear of the switches at the rows'
    /// trailing end.
    ///
    /// The default `attempts` has room to spare: on that 466 pt screen (0.3 of it is 140 pt) a caller needs three
    /// drags at most, and a turn or two after a glide past `target`; one that scrolls further passes its own.
    @discardableResult @MainActor func scrollUntilVisible(
        _ target: XCUIElement, in app: XCUIApplication, inside container: XCUIElement? = nil, attempts: Int = 8
    ) -> Bool {
        _ = target.waitForExistence(timeout: 3)
        // On the window, not the app: a gesture on the app may go to the Duo's other screen.
        let window = pageWindow(of: app)
        var drags = 0
        // Kept while `target` is out of the tree: a glide may carry a row of a lazy list off above and out of it.
        var isAbove = false
        var lastWentUp: Bool?
        var step: CGFloat = 0.3
        // Whether the look before this drag was already taken again (M2 review F4 M-2).
        var lookedAgain = false
        while true {
            let layout = PageLayout(of: app)
            // Whether `target` is there and where, in one read: two reads may find it gone by the second.
            let frame = (try? target.snapshot())?.frame
            // In the container, not the window's middle: a drag beside a sheet moved off the middle scrolls nothing.
            let scroller = container.flatMap { $0.exists ? $0.frame : nil }
                ?? layout.scrollContainer(for: frame, in: app)
            let area = layout.shownArea(of: scroller)
            let bars = layout.topBars(over: area, in: app)
            if !layout.isComplete || bars == .unsure, !lookedAgain {
                lookedAgain = true
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            lookedAgain = false
            // Below the bars too: a row under one is hittable only through the strip above it, the status bar's.
            let clear = layout.area(area, below: bars)
            // How far above what shows `target` stands, when this look tells: in the tree and across from the area (one
            // beside it, a bar's or a header's, says nothing of which way the container should go).
            var above: CGFloat?
            // Wholly in what shows, not only hittable: XCTest aims a tap at an element the screen's edge cuts wrongly.
            if let frame {
                let fits = frame.width > clear.width || frame.height > clear.height || clear.contains(frame)
                if fits, target.exists, target.isHittable { return true }
                if frame.maxX > area.minX, frame.minX < area.maxX {
                    isAbove = frame.minY < clear.minY
                    if isAbove { above = clear.minY - frame.minY }
                }
            }
            guard drags < attempts else { return false }
            let goesUp = !isAbove
            // Shorter after a turn: drags that pass `target` both ways close in on it instead of repeating.
            if let lastWentUp, lastWentUp != goesUp { step = max(step / 2, 0.1) }
            var distance = area.height * step
            if let above, let frame { distance = downDrag(by: above, to: frame, of: distance) }
            let middle = area.minY + area.height * 0.5
            let end = layout.point(area.midX, middle + (goesUp ? -distance : distance), on: window)
            // Slow, not the default speed: the page is let go at the drag's speed, and glides the less the slower.
            layout.point(area.midX, middle, on: window).press(
                forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3
            )
            lastWentUp = goesUp
            drags += 1
            _ = target.waitForExistence(timeout: 1)
        }
    }

    /// How far `scrollUntilVisible` drags down for a target `above` points above what shows, its frame `frame`: what
    /// brings its top a quarter of its height below the area's top, plus `dragSlop` (UIKit starts a pan only some 10
    /// pt into the drag, and those points move nothing), at least `shortestDrag` (a shorter drag may move nothing at
    /// all), at most `step`, the distance of a drag that need not stop short.
    private func downDrag(by above: CGFloat, to frame: CGRect, of step: CGFloat) -> CGFloat {
        min(step, max(above + frame.height * 0.25 + dragSlop, shortestDrag))
    }

    /// What `element` reads, its label and value joined by a space; "" when it does not exist.
    @MainActor func shown(_ element: XCUIElement) -> String {
        guard element.exists else { return "" }
        return [element.label, element.value as? String ?? ""].joined(separator: " ")
    }

    /// The first element of `query` that is hittable, waiting up to `timeout` seconds for one; nil when none is.
    @MainActor func firstHittable(_ query: XCUIElementQuery, within timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date.now.addingTimeInterval(timeout)
        while true {
            if let element = Self.hittable(in: query) { return element }
            guard Date.now < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// The topmost element of `query` that can be hit and lies wholly in the window below the ceiling, waiting up to
    /// 10 s for one; nil without one. Returned as bound by its index in `query`. Unlike `firstHittable(_:within:)` it
    /// passes over an element the screen's edge cuts: on a rotated display (the iPhone Duo held sideways or upside
    /// down) XCTest aims a tap at a cut element without turning the point with the display, so the tap lands
    /// elsewhere.
    ///
    /// The ceiling is `ceiling`'s bottom while it is there; without `ceiling`, each element's own: the bottom of the
    /// navigation bars over the window's top that span some of it across (`PageLayout.topBars(across:in:)`, less a
    /// point as `scrollUntilVisible` takes it), so a sidebar's or a rail's bar beside the list sets no ceiling for its
    /// rows (M2 review F4 M-1). A row scrolled under the navigation bar is still hittable through the strip above the
    /// bar, and a tap there goes to the status bar, which scrolls the list back to its top.
    ///
    /// Without `ceiling`, a look that cannot tell where the bars are concludes nothing (M2 review F4 M-2): one without
    /// the app's snapshot (`PageLayout.isComplete`), or one where a bar over the element next in line changed since the
    /// snapshot (`PageLayout.Bars.unsure`). It is looked at again a quarter second later, within the same 10 s.
    ///
    /// Each element is read once (whether it is there and where); only those that fit, topmost first, are asked
    /// whether they can be hit.
    @MainActor func firstWhollyVisible(
        _ query: XCUIElementQuery, below ceiling: XCUIElement? = nil, in app: XCUIApplication
    ) -> XCUIElement? {
        let deadline = Date.now.addingTimeInterval(10)
        while true {
            if let found = topmostWhollyVisible(query, below: ceiling, in: app) { return found }
            guard Date.now < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// One look of `firstWhollyVisible(_:below:in:)`: the topmost element of `query` that fits below its ceiling and
    /// can be hit; nil without one, or when the look cannot tell.
    @MainActor private func topmostWhollyVisible(
        _ query: XCUIElementQuery, below ceiling: XCUIElement?, in app: XCUIApplication
    ) -> XCUIElement? {
        let layout = PageLayout(of: app)
        // Without the snapshot no bar is known, and a row under one would pass.
        if ceiling == nil, !layout.isComplete { return nil }
        let window = layout.window
        // Looked at again each time: the ceiling may move or show up while the rows settle.
        let fixedCeiling = ceiling.map { (try? $0.snapshot())?.frame.maxY ?? window.minY }
        let whole = query.allElementsBoundByIndex
            .compactMap { element -> (element: XCUIElement, frame: CGRect)? in
                guard let frame = (try? element.snapshot())?.frame, window.contains(frame) else { return nil }
                return (element, frame)
            }
            .sorted { $0.frame.minY < $1.frame.minY }
        for (element, frame) in whole {
            let top: CGFloat
            if let fixedCeiling {
                top = fixedCeiling
            } else {
                switch layout.topBars(across: frame, in: app) {
                case .bottom(let bottom): top = bottom - 1
                case .none: top = window.minY
                case .unsure: return nil
                }
            }
            if frame.minY >= top, element.exists, element.isHittable { return element }
        }
        return nil
    }

    /// Turns the switch `identifier` on or off, scrolled to first (`scrollUntilVisible`, in `container` when given):
    /// the row's own switch when the system nests one in it, and a tap that did not change it is made once more (a tap
    /// right after a tab switch is now and then dropped, as the tab settings' and clipboard tests found). Fails, with
    /// the element tree, unless it reads so within 5 s of the last tap.
    @MainActor func setSwitch(
        _ identifier: String, on: Bool, inside container: XCUIElement? = nil, in app: XCUIApplication
    ) {
        let toggle = app.switches.matching(identifier: identifier).firstMatch
        scrollUntilVisible(toggle, in: app, inside: container)
        XCTAssertTrue(toggle.exists, "No switch \(identifier)")
        let wanted = on ? "1" : "0"
        let reads = NSPredicate(format: "value == %@", wanted)
        for _ in 0..<2 where toggle.value as? String != wanted {
            let inner = toggle.switches.firstMatch
            (inner.exists ? inner : toggle).tap()
            // XCTWaiter, not a polling loop: it keeps the run loop going while it waits.
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: reads, object: toggle)], timeout: 5)
        }
        if toggle.value as? String != wanted {
            attachElementTree(of: app)
        }
        XCTAssertEqual(toggle.value as? String, wanted, "The switch \(identifier) did not turn \(on ? "on" : "off")")
    }

    @MainActor private static func hittable(in query: XCUIElementQuery) -> XCUIElement? {
        query.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
    }
}

/// One look at the app's element tree, a snapshot of the app (`XCUIElement.snapshot()`): what `scrollUntilVisible`
/// and `firstWhollyVisible` measure against, all from the same moment and read here rather than with a query each (a
/// query per container, keyboard and bar took 15–30 queries a look, and an element read by two queries may be gone by
/// the second).
///
/// The window is the app's first, as `pageWindow(of:)`. Its scroll containers and navigation bars keep their place
/// among the window's elements of their type (`Part.index`, the element tree's order, which a query's indexes follow),
/// so the one a rule picks can be asked, as an element, whether it can be hit; a snapshot cannot tell. Each part is
/// asked at most once a look.
///
/// A snapshot may fail (on a busy host it can time out): the look then knows the window's frame alone and says so
/// (`isComplete`), and the failure is kept in the result bundle as an activity, "App snapshot failed". So is a bar
/// that would count but is no longer the bar the snapshot saw ("Navigation bar changed since the app snapshot",
/// `Bars.unsure`). Callers look again rather than measure against what is missing (M2 review F4 M-2).
struct PageLayout {
    /// A scroll container or a navigation bar of the window.
    struct Part {
        let type: XCUIElement.ElementType
        /// Its index among the window's elements of `type`.
        let index: Int
        let frame: CGRect
    }

    /// What the navigation bars over a place say (`topBars(over:in:)`, `topBars(across:in:)`).
    enum Bars: Equatable {
        /// None counts.
        case none
        /// The bottom of the one that counts.
        case bottom(CGFloat)
        /// One that would count, unless one higher already does, is no longer the bar this look saw (the element tree
        /// changed since, e.g. a large title collapsed): whether it can be hit is not known.
        case unsure
    }

    /// The window's frame.
    let window: CGRect
    /// The window's scroll views, collection views and tables.
    let scrollers: [Part]
    /// The window's navigation bars.
    let navigationBars: [Part]
    /// The first software keyboard's frame anywhere in the app (`app.keyboards.firstMatch`; it is in a window of its
    /// own); nil without one. On the iPhone Duo it stays in the tree below the screen.
    let keyboard: CGRect?
    /// Whether the snapshot of the app was had, with a window in it. Without it, `window` is the window's frame as a
    /// query gives it, and there are no scroll containers, bars or keyboard.
    let isComplete: Bool
    /// What the parts asked so far answered, for this look.
    private let answers = Answers()

    @MainActor init(of app: XCUIApplication) {
        var window: (any XCUIElementSnapshot)?
        var keyboard: CGRect?
        var failure = "the app's snapshot has no window"
        // Depth first, children in order: the order of the element tree, and of a query's matches.
        var pending: [any XCUIElementSnapshot] = []
        do {
            pending = [try app.snapshot()]
        } catch {
            failure = String(describing: error)
        }
        while let node = pending.popLast(), window == nil || keyboard == nil {
            if window == nil, node.elementType == .window { window = node }
            if keyboard == nil, node.elementType == .keyboard { keyboard = node.frame }
            pending += node.children.reversed()
        }
        self.keyboard = keyboard
        guard let window else {
            XCTContext.runActivity(named: "App snapshot failed") { activity in
                activity.add(XCTAttachment(string: failure))
            }
            // The window's frame alone, as the queries give it.
            self.window = app.windows.firstMatch.frame
            scrollers = []
            navigationBars = []
            isComplete = false
            return
        }
        self.window = window.frame
        var counts: [XCUIElement.ElementType: Int] = [:]
        var scrollers: [Part] = []
        var navigationBars: [Part] = []
        var inside = Array(window.children.reversed())
        while let node = inside.popLast() {
            let type = node.elementType
            switch type {
            case .collectionView, .scrollView, .table, .navigationBar:
                let part = Part(type: type, index: counts[type, default: 0], frame: node.frame)
                counts[type, default: 0] += 1
                if type == .navigationBar { navigationBars.append(part) } else { scrollers.append(part) }
            default:
                break
            }
            inside += node.children.reversed()
        }
        self.scrollers = scrollers
        self.navigationBars = navigationBars
        isComplete = true
    }

    /// The point `x`, `y` (in the window's coordinates) as a coordinate of `window`, the app's window element.
    @MainActor func point(_ x: CGFloat, _ y: CGFloat, on window: XCUIElement) -> XCUICoordinate {
        window.coordinate(withNormalizedOffset: CGVector(
            dx: (x - self.window.minX) / self.window.width, dy: (y - self.window.minY) / self.window.height
        ))
    }

    /// The frame within the window of the scroll container that `scrollUntilVisible` drags for a target at `target`
    /// (nil while it is out of the element tree): of the scroll views, collection views and tables that show in the
    /// window and span the target's middle across (any while it is out of the tree) and can be hit, the one taking up
    /// least of the window. nil without one. Only the candidates in turn, smallest first, are asked whether they can be
    /// hit: usually the first is. One no longer as this look saw it counts as one that cannot be hit.
    ///
    /// The page below a sheet cannot be hit: the sheet or the region that dismisses it covers the page's middle.
    /// Least, all the same: a sheet's form rather than a page that can still be hit beside it.
    @MainActor func scrollContainer(for target: CGRect?, in app: XCUIApplication) -> CGRect? {
        let candidates = scrollers
            .compactMap { part -> (part: Part, area: CGRect)? in
                let area = part.frame.intersection(window)
                guard !area.isEmpty else { return nil }
                if let target, target.midX < area.minX || target.midX > area.maxX { return nil }
                return (part, area)
            }
            .sorted { $0.area.width * $0.area.height < $1.area.width * $1.area.height }
        return candidates.first { hit($0.part, in: app) == .hittable }?.part.frame
    }

    /// What shows of the container at `container` (the window when nil, or when it lies outside the window): its frame
    /// within the window, less the part a software keyboard covers from below.
    func shownArea(of container: CGRect?) -> CGRect {
        var area = window
        if let container {
            let inWindow = container.intersection(window)
            if !inWindow.isEmpty { area = inWindow }
        }
        // Cut at the keyboard's top: a drag started on it would type, and a row under it cannot be tapped.
        if let keyboard {
            let top = keyboard.minY
            if top > area.minY, top < area.maxY { area.size.height = top - area.minY }
        }
        return area
    }

    /// The navigation bars over the top of `area`. A bar counts when it lies within `area` across, reaches into its
    /// upper half and can be hit: the page's own bar under a sheet is wider than the sheet's form, or covered. Of
    /// several, the highest bottom, so a bar counted wrongly cannot cut a sheet's first rows; only the bars that pass
    /// the rest, highest bottom first, are asked whether they can be hit (`bars(_:in:)`).
    @MainActor func topBars(over area: CGRect, in app: XCUIApplication) -> Bars {
        bars(navigationBars.filter { bar in
            let frame = bar.frame
            let across = frame.minX >= area.minX - 1 && frame.maxX <= area.maxX + 1
            return across && frame.maxY > area.minY && frame.minY < area.midY
        }, in: app)
    }

    /// The navigation bars over the top of the window in the column of `frame` (M2 review F4 M-1): a bar counts when it
    /// spans some of `frame` across, reaches into the window's upper half and can be hit; of several, the highest
    /// bottom, as `topBars(over:in:)`. A sidebar's bar, or a rail's, beside the list sets nothing for its rows.
    @MainActor func topBars(across frame: CGRect, in app: XCUIApplication) -> Bars {
        bars(navigationBars.filter { bar in
            bar.frame.maxX > frame.minX && bar.frame.minX < frame.maxX
                && bar.frame.maxY > window.minY && bar.frame.minY < window.midY
        }, in: app)
    }

    /// `area` from the bottom `bars` give down (less a point: a list's first row starts right at its bar's bottom);
    /// `area` itself without one, or when it leaves nothing.
    func area(_ area: CGRect, below bars: Bars) -> CGRect {
        guard case .bottom(let top) = bars, top - 1 > area.minY, top - 1 < area.maxY else { return area }
        return CGRect(x: area.minX, y: top - 1, width: area.width, height: area.maxY - top + 1)
    }

    /// Of `candidates`, highest bottom first, the first that can be hit; unsure when one before it is no longer the
    /// bar this look saw, since that one might have counted.
    @MainActor private func bars(_ candidates: [Part], in app: XCUIApplication) -> Bars {
        for bar in candidates.sorted(by: { $0.frame.maxY < $1.frame.maxY }) {
            switch hit(bar, in: app) {
            case .hittable:
                return .bottom(bar.frame.maxY)
            case .notHittable:
                continue
            case .changed:
                XCTContext.runActivity(named: "Navigation bar changed since the app snapshot") { activity in
                    activity.add(XCTAttachment(string: "navigation bar \(bar.index) at \(bar.frame)"))
                }
                return .unsure
            }
        }
        return .none
    }

    /// What asking a part whether it can be hit found.
    enum Hit {
        case hittable, notHittable
        /// The window's element of the part's type at its index is gone or has another frame: the tree changed since
        /// this look.
        case changed
    }

    /// Whether `part` can be hit now: the window's element of its type at its index, checked to be the one this look
    /// saw. Asked once a look; later calls give the first answer.
    @MainActor private func hit(_ part: Part, in app: XCUIApplication) -> Hit {
        let key = Answers.Key(type: part.type, index: part.index)
        if let known = answers.hits[key] { return known }
        let element = app.windows.firstMatch.descendants(matching: part.type).element(boundBy: part.index)
        let hit: Hit = if !element.exists || element.frame != part.frame {
            .changed
        } else {
            element.isHittable ? .hittable : .notHittable
        }
        answers.hits[key] = hit
        return hit
    }

    /// The answers of one look, kept by reference so that its lookups need not be mutating.
    private final class Answers {
        struct Key: Hashable {
            let type: XCUIElement.ElementType
            let index: Int
        }

        var hits: [Key: Hit] = [:]
    }
}
