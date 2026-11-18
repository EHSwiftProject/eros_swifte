import EHModels
import EHNetwork
import EHParsing
import Foundation
import Synchronization
import SwiftUI
import Testing

@testable import Eros

/// `GalleryListView` on a window of its own over a `ScriptedFeed`: what it shows for the model's states, the pause
/// banner, the reload when the session's identity changes and the tag names after the tag database changed.
///
/// Each test has a minute (`.timeLimit`): some hold a request, a page or a feed's answer until they let it go (a
/// gate, a throttle: neither heeds cancellation), and one that never lets go must fail at the limit, not hang the
/// run (the test process is then ended and started again for the tests after it).
@MainActor @Suite(.timeLimit(.minutes(1))) struct GalleryListViewTests {
    /// A clock the test moves, for the environment's breaker.
    private final class MovableClock: Sendable {
        private let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

        var now: Date { date.withLock { $0 } }

        func advance(by seconds: TimeInterval) {
            date.withLock { $0 = $0.addingTimeInterval(seconds) }
        }
    }

    /// A started environment (in-memory stores, offline) with `breaker` when given.
    private static func makeEnvironment(breaker: SiteBreaker? = nil) async -> AppEnvironment {
        let environment = AppEnvironment(uiTesting: true, userAgentProbe: { "FakeWebKit/1" }, breaker: breaker)
        await environment.start()
        return environment
    }

    /// The list over `model` in a navigation stack, on a window of its own.
    private static func show(_ model: GalleryListModel, environment: AppEnvironment) throws -> UIHostingController<AnyView> {
        try HostedViews.show(NavigationStack { GalleryListView(model: model, style: .list) }, environment: environment)
    }

    private static func identifiers(_ host: UIHostingController<AnyView>) -> [String] {
        HostedViews.identifiers(in: host.view)
    }

    /// The accessibility element labelled `label` in `host`, waiting up to 5 s for it.
    private static func element(labelled label: String, in host: UIHostingController<AnyView>) async -> NSObject? {
        var found: NSObject?
        _ = await eventually {
            found = HostedViews.elements(in: host.view).first { $0.accessibilityLabel == label }
            return found != nil
        }
        return found
    }

    // MARK: - What the model's state shows

    @Test func phaseFollowsTheModel() {
        #expect(GalleryListPhase.of(status: .idle, itemCount: 0) == .loading)
        #expect(GalleryListPhase.of(status: .loading, itemCount: 0) == .loading)
        // A jump (or a reload) in flight keeps the items shown.
        #expect(GalleryListPhase.of(status: .loading, itemCount: 3) == .list)
        #expect(GalleryListPhase.of(status: .loaded, itemCount: 3) == .list)
        #expect(GalleryListPhase.of(status: .loaded, itemCount: 0) == .empty)
        #expect(GalleryListPhase.of(status: .failed(.network), itemCount: 0) == .failed(.network))
    }

    /// A ban or a 429 while both sites are paused reads as the pause, with its end; anything else as itself.
    @Test func failuresDuringAPauseShowThePause() {
        let pause = SitePause(reason: .tooManyRequests, until: Date(timeIntervalSince1970: 1_800_000_060))
        let earlier = SitePause(reason: .tooManyRequests, until: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(ListFailure.siteIssue(.tooManyRequests).shown(during: pause) == .paused(pause))
        #expect(ListFailure.siteIssue(.banned(remaining: nil)).shown(during: pause) == .paused(pause))
        #expect(ListFailure.paused(earlier).shown(during: pause) == .paused(pause))
        #expect(ListFailure.paused(earlier).shown(during: nil) == .paused(earlier))
        #expect(ListFailure.siteIssue(.tooManyRequests).shown(during: nil) == .siteIssue(.tooManyRequests))
        #expect(ListFailure.network.shown(during: pause) == .network)
    }

    /// B3 hand-over (a): a jump in flight keeps the items shown (no first-load spinner, no empty state), and once it
    /// failed the header shows the failure with Try Again above the same items.
    @Test func aJumpKeepsTheShownItems() async throws {
        let environment = await Self.makeEnvironment()
        let feed = ScriptedFeed()
        feed.answer(.first, makePage([900_001, 900_002]))
        let gate = Gate()
        feed.fail(.seek("2024-01-01"), EHNetworkError.transport(.notConnectedToInternet), gate: gate)
        let model = GalleryListModel(feed: feed)
        let host = try Self.show(model, environment: environment)
        defer { HostedViews.hide(host) }
        #expect(await eventually { Self.identifiers(host).contains("gallery.item.900001") })

        let jump = Task { await model.jump(to: .seek("2024-01-01")) }
        #expect(await eventually { gate.hasWaiters })
        #expect(model.status == .loading)
        #expect(await eventually { Self.identifiers(host).contains("gallery.header.loading") })
        var identifiers = Self.identifiers(host)
        #expect(identifiers.contains("gallery.item.900001"))
        #expect(!identifiers.contains("gallery.loading"))
        #expect(!identifiers.contains("gallery.empty"))
        #expect(!identifiers.contains("gallery.failure"))

        gate.open()
        await jump.value
        #expect(model.refreshFailure == .network)
        #expect(await eventually { Self.identifiers(host).contains("gallery.refreshFailure.tryAgain") })
        identifiers = Self.identifiers(host)
        #expect(identifiers.contains("gallery.refreshFailure"))
        #expect(identifiers.contains("gallery.item.900001"))
        #expect(!identifiers.contains("gallery.failure"))
    }

    /// U9: an empty list centers No Galleries in the height it shows, rather than at the top of the content (it stays
    /// in the scroll view, so pull to refresh still works on it). The window is 700 high; before, the title stood
    /// about 200 from its top.
    @Test func noGalleriesStandsInTheMiddle() async throws {
        let environment = await Self.makeEnvironment()
        let feed = ScriptedFeed()
        feed.answer(.first, makePage([]))
        let model = GalleryListModel(feed: feed)
        let host = try Self.show(model, environment: environment)
        defer { HostedViews.hide(host) }
        #expect(await eventually { Self.identifiers(host).contains("gallery.empty") })
        let title = try #require(await Self.element(labelled: "No Galleries", in: host))
        let window = try #require(host.view.window)
        let middle = HostedViews.frame(of: title, in: window).midY
        #expect(middle > window.bounds.height * 0.42, "No Galleries stands at \(middle) of \(window.bounds.height)")
        #expect(middle < window.bounds.height * 0.75, "No Galleries stands at \(middle) of \(window.bounds.height)")
    }

    /// B3 hand-over (b): an empty list whose refresh failed shows the failure and Try Again, not only No Galleries.
    @Test func anEmptyListShowsItsRefreshFailure() async throws {
        let environment = await Self.makeEnvironment()
        let feed = ScriptedFeed()
        feed.answer(.first, makePage([]))
        feed.fail(.first, EHNetworkError.transport(.notConnectedToInternet))
        let model = GalleryListModel(feed: feed)
        let host = try Self.show(model, environment: environment)
        defer { HostedViews.hide(host) }
        #expect(await eventually { Self.identifiers(host).contains("gallery.empty") })

        await model.refresh()
        #expect(model.status == .loaded)
        #expect(model.refreshFailure == .network)
        #expect(await eventually { Self.identifiers(host).contains("gallery.refreshFailure.tryAgain") })
        #expect(Self.identifiers(host).contains("gallery.refreshFailure"))
        #expect(HostedViews.label(of: "gallery.refreshFailure", in: host.view)?.contains("Could not reach the server.") == true)
    }

    /// A first page that failed shows the failure and its action, also inside a page that is one accessibility
    /// container identified as a whole (the gallery tab's `gallery.root`): both identifiers stay.
    @Test func aFailedFirstPageOffersItsAction() async throws {
        let environment = await Self.makeEnvironment()
        let feed = ScriptedFeed()
        feed.fail(.first, ParseError.loginRequired)
        feed.fail(.first, EHNetworkError.transport(.notConnectedToInternet))
        let model = GalleryListModel(feed: feed)
        let page = NavigationStack {
            GalleryListView(model: model, style: .list)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("gallery.root")
        }
        let host = try HostedViews.show(page, environment: environment)
        defer { HostedViews.hide(host) }
        #expect(await eventually { Self.identifiers(host).contains("gallery.failure.logIn") })
        var identifiers = Self.identifiers(host)
        #expect(identifiers.contains("gallery.failure"))
        #expect(identifiers.contains("gallery.root"))
        #expect(!identifiers.contains("gallery.failure.tryAgain"))

        // Try Again of a failure that offers it reloads.
        await model.reload()
        #expect(model.status == .failed(.network))
        #expect(await eventually { Self.identifiers(host).contains("gallery.failure.tryAgain") })
        identifiers = Self.identifiers(host)
        #expect(identifiers.contains("gallery.failure"))
        #expect(!identifiers.contains("gallery.failure.logIn"))
    }

    // MARK: - Pause banner

    @Test func pauseBannerFollowsTheSitePause() async throws {
        let clock = MovableClock()
        let breaker = SiteBreaker(now: { clock.now })
        let environment = await Self.makeEnvironment(breaker: breaker)
        let feed = ScriptedFeed()
        feed.answer(.first, makePage([900_001]))
        let model = GalleryListModel(feed: feed)
        let host = try Self.show(model, environment: environment)
        defer { HostedViews.hide(host) }
        #expect(await eventually { Self.identifiers(host).contains("gallery.item.900001") })
        #expect(!Self.identifiers(host).contains("gallery.pauseBanner"))

        _ = try #require(await breaker.record(.tooManyRequests, at: URL(string: "https://e-hentai.org/")!))
        #expect(await eventually { environment.sitePause != nil })
        #expect(await eventually { Self.identifiers(host).contains("gallery.pauseBanner") })
        #expect(HostedViews.label(of: "gallery.pauseBanner", in: host.view)?.contains("Requests are paused until") == true)
        #expect(Self.identifiers(host).contains("gallery.item.900001"))

        // The pause's end has come: the breaker clears it, `sitePause` goes nil and the banner with it.
        clock.advance(by: 61)
        #expect(await breaker.current() == nil)
        #expect(await eventually { environment.sitePause == nil })
        #expect(await eventually { !Self.identifiers(host).contains("gallery.pauseBanner") })
        #expect(Self.identifiers(host).contains("gallery.item.900001"))
    }

    // MARK: - Session identity

    /// Logging in reloads the list once, and so does logging out.
    @Test func identityChangeReloadsTheList() async throws {
        let environment = await Self.makeEnvironment()
        let feed = ScriptedFeed()
        feed.answer(.first, makePage([900_001]))
        feed.answer(.first, makePage([900_002]))
        feed.answer(.first, makePage([900_003]))
        let model = GalleryListModel(feed: feed)
        let host = try Self.show(model, environment: environment)
        defer { HostedViews.hide(host) }
        #expect(await eventually { Self.identifiers(host).contains("gallery.item.900001") })

        // Reading the same session again is no change.
        await environment.refreshSession()
        try await Task.sleep(for: .milliseconds(300))
        #expect(feed.calls == [.init(.first, false)])

        try await environment.cookies.set(
            [CookieNames.memberID: "1234567", CookieNames.passHash: "0123456789abcdef0123456789abcdef"], for: [.eh, .ex]
        )
        await environment.refreshSession()
        #expect(environment.isLoggedIn)
        #expect(await eventually { feed.calls == [.init(.first, false), .init(.first, true)] })
        #expect(await eventually {
            let identifiers = Self.identifiers(host)
            return identifiers.contains("gallery.item.900002") && !identifiers.contains("gallery.item.900001")
        })

        // Logging out: the session is emptied, read again, and the list reloads once more.
        try await environment.cookies.reset()
        await environment.refreshSession()
        #expect(!environment.isLoggedIn)
        #expect(await eventually {
            feed.calls == [.init(.first, false), .init(.first, true), .init(.first, true)]
        })
        #expect(await eventually {
            let identifiers = Self.identifiers(host)
            return identifiers.contains("gallery.item.900003") && !identifiers.contains("gallery.item.900002")
        })
        try await Task.sleep(for: .milliseconds(300))
        #expect(feed.calls.count == 3)
    }

    // MARK: - Tag names (B4a hand-over)

    /// A made-up translation of `female:fake tag` other than `TagNameCacheTests.smallDatabase`'s.
    private static let changedDatabase = Data(
        #"{"data":[{"namespace":"female","data":{"fake tag":{"name":"改后名"}}}]}"#.utf8
    )

    /// A list whose items have `female:fake tag`, over a started environment with translations shown or not and the
    /// tag database holding `TagNameCacheTests.smallDatabase`.
    private static func showTaggedList(
        showsTranslations: Bool
    ) async throws -> (environment: AppEnvironment, host: UIHostingController<AnyView>) {
        let environment = await Self.makeEnvironment()
        environment.settings.settings.showsTagTranslations = showsTranslations
        let store = try #require(environment.tagTranslations)
        _ = try await store.replaceAll(with: TagNameCacheTests.smallDatabase, version: "v1 test")
        var page = makePage([900_001])
        page.items[0].tags = [ListTag(tag: TagRef(raw: "female:fake tag"), colors: nil)]
        let feed = ScriptedFeed()
        feed.answer(.first, page)
        let host = try Self.show(GalleryListModel(feed: feed), environment: environment)
        return (environment, host)
    }

    /// The list reads the names of its tags from the database; once the names were cleared after the database
    /// changed (`TagNameCache.removeAll()`), it reads them again. A name that comes from the database only when it
    /// was asked proves each read: the first one, and the changed one after the clear (the cache still holds the
    /// first until then, and never asks twice by itself).
    @Test func tagsAreTranslatedAgainAfterTheDatabaseChanges() async throws {
        let (environment, host) = try await Self.showTaggedList(showsTranslations: true)
        defer { HostedViews.hide(host) }
        #expect(await eventually { Self.labelsContain("示例标签", in: host) })

        let store = try #require(environment.tagTranslations)
        _ = try await store.replaceAll(with: Self.changedDatabase, version: "v2 test")
        try await Task.sleep(for: .milliseconds(300))
        #expect(environment.tagNames.name(for: TagRef(raw: "female:fake tag")) == "示例标签")

        environment.tagNames.removeAll()
        #expect(await eventually { Self.labelsContain("改后名", in: host) })
        #expect(!Self.labelsContain("示例标签", in: host))
    }

    /// With translations off the list reads no names (the database has one, which a read would have cached); turning
    /// them on reads it.
    @Test func tagsAreNotPrefetchedWhileTranslationsAreOff() async throws {
        let (environment, host) = try await Self.showTaggedList(showsTranslations: false)
        defer { HostedViews.hide(host) }
        #expect(await eventually { Self.labelsContain("fake tag", in: host) })
        try await Task.sleep(for: .milliseconds(500))
        #expect(environment.tagNames.name(for: TagRef(raw: "female:fake tag")) == nil)

        environment.settings.settings.showsTagTranslations = true
        #expect(await eventually { environment.tagNames.name(for: TagRef(raw: "female:fake tag")) == "示例标签" })
        #expect(await eventually { Self.labelsContain("示例标签", in: host) })
    }

    private static func labelsContain(_ text: String, in host: UIHostingController<AnyView>) -> Bool {
        HostedViews.elements(in: host.view).contains { $0.accessibilityLabel?.contains(text) == true }
    }
}
