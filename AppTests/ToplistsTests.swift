import EHModels
import EHNetwork
import Foundation
import SwiftUI
import Testing

@testable import Eros

/// The toplists tab (browse B7): its requests always go to E-Hentai whatever the browsing site, pages use `p`, the list
/// takes no category or search parameters, the toplist picked is remembered, and only a double reselect of the tab
/// refreshes. Requests go to a `StubURLProtocol` that answers an empty result; nothing reaches the network.
///
/// Each test has a minute (`.timeLimit`): some hold a request, a page or a feed's answer until they let it go (a
/// gate, a throttle: neither heeds cancellation), and one that never lets go must fail at the limit, not hang the
/// run (the test process is then ended and started again for the tests after it).
@MainActor @Suite(.timeLimit(.minutes(1))) struct ToplistsTests {
    /// The site's empty result, as little of it as the parser needs.
    private static let noHits = Data(#"<html><body><div class="ido"><p>No hits found</p></div></body></html>"#.utf8)

    /// A stub that answers every request with `noHits`.
    private static func installNoHits() -> StubSession {
        let noHits = noHits
        return StubURLProtocol.install { _ in StubResponse(body: noHits) }
    }

    /// A started environment (in-memory stores) whose requests go to `stub`, through `throttle` when given.
    private static func makeEnvironment(
        stub: StubSession, throttle: (any RequestThrottle)? = nil
    ) async -> AppEnvironment {
        let environment = AppEnvironment(
            uiTesting: true, sessionConfigurator: stub.configurator, userAgentProbe: { "FakeWebKit/1" },
            throttle: throttle
        )
        await environment.start()
        return environment
    }

    /// The URLs `stub` received, oldest first.
    private static func urls(of stub: StubSession) -> [String] {
        stub.requests().compactMap(\.url?.absoluteString)
    }

    /// The idle timeout of `site`'s requests in seconds: `EHClient` gives every URL request the one of its
    /// `EHRequest.site` (E-Hentai 20 s, ExHentai 25 s), so a received request tells the site it was sent for.
    /// Converted the way `EHClient` converts it (`Duration.timeInterval`, internal to EHNetwork), so the two values
    /// match exactly.
    private static func idleTimeout(of site: EHSite) -> TimeInterval {
        let (seconds, attoseconds) = RequestDefaults.timeouts(for: site).urlSession.idle.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    /// A throttle that holds the requests for `held` until their task is cancelled (counted in `cancellations`), and
    /// lets every other request through at once.
    private actor HoldingThrottle: RequestThrottle {
        private let held: URL
        /// The held requests waiting now.
        private(set) var waiting = 0
        private(set) var cancellations = 0

        init(holding held: URL) {
            self.held = held
        }

        func acquire(for url: URL) async throws {
            guard url == held else { return }
            waiting += 1
            defer { waiting -= 1 }
            do {
                while true { try await Task.sleep(for: .seconds(3_600)) }
            } catch {
                cancellations += 1
                throw CancellationError()
            }
        }
    }

    @Test func titlesFollowFlutter() {
        #expect(ToplistPeriod.allCases.map(\.title) == ["Yesterday", "Past Month", "Past Year", "All-Time"])
    }

    /// Under ExHentai as the browsing site, the toplist still goes to e-hentai.org as an E-Hentai request (its
    /// Compact notice, throttle and cache are E-Hentai's; Flutter request.dart:56).
    @Test func toplistsAlwaysRequestEHentai() async throws {
        let stub = Self.installNoHits()
        defer { stub.remove() }
        let environment = await Self.makeEnvironment(stub: stub)
        let page = NavigationStack {
            ToplistsRootView()
        }
        .environment(\.browsingSite, .ex)
        .environment(TabReselectionCenter())
        let host = try HostedViews.show(page, environment: environment)
        defer { HostedViews.hide(host) }

        #expect(await eventually { !stub.requests().isEmpty })
        let request = try #require(stub.requests().first)
        #expect(request.url?.host() == "e-hentai.org")
        #expect(request.url == URL(string: "https://e-hentai.org/toplist.php?tl=15"))
        // The URL and its host cannot tell the site the request was sent for: toplist.php is on e-hentai.org either
        // way (`ListQuery.url(for:)`). Only the timeout can (in browse B7, a feed moved to `.ex` sent the same URL and
        // failed only on the timeout).
        #expect(Self.idleTimeout(of: .eh) != Self.idleTimeout(of: .ex))
        #expect(request.timeoutInterval == Self.idleTimeout(of: .eh))
        #expect(stub.requests().allSatisfy { $0.url?.host() == "e-hentai.org" })
    }

    @Test func pagesUseP() async {
        let stub = Self.installNoHits()
        defer { stub.remove() }
        let environment = await Self.makeEnvironment(stub: stub)
        let toplists = ToplistsRootModel(settings: environment.settings, service: environment.service)

        await toplists.list.loadFirst()
        await toplists.list.jump(to: .page(1))
        #expect(Self.urls(of: stub) == [
            "https://e-hentai.org/toplist.php?tl=15", "https://e-hentai.org/toplist.php?tl=15&p=1",
        ])
    }

    /// The global category filter does not reach the toplists, and they have no search.
    @Test func noCategoryOrSearchParameters() async throws {
        let stub = Self.installNoHits()
        defer { stub.remove() }
        let environment = await Self.makeEnvironment(stub: stub)
        environment.settings.settings.categoryFilter = CategoryMask(excluding: [.doujinshi, .western])
        let toplists = ToplistsRootModel(settings: environment.settings, service: environment.service)

        await toplists.list.loadFirst()
        await toplists.list.jump(to: .page(2))
        let names = try stub.requests().map { request in
            let url = try #require(request.url)
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        }
        #expect(names == [["tl"], ["tl", "p"]])
    }

    @Test func periodIsRemembered() async {
        let stub = Self.installNoHits()
        defer { stub.remove() }
        let environment = await Self.makeEnvironment(stub: stub)
        #expect(environment.settings.browsing.toplistPeriod == .yesterday)
        let toplists = ToplistsRootModel(settings: environment.settings, service: environment.service)
        #expect(toplists.period == .yesterday)
        let yesterday = toplists.list

        toplists.select(.month)
        #expect(toplists.period == .month)
        #expect(environment.settings.browsing.toplistPeriod == .month)
        #expect(toplists.list !== yesterday)
        await toplists.list.loadFirst()
        #expect(Self.urls(of: stub) == ["https://e-hentai.org/toplist.php?tl=13"])

        // Picking the toplist shown keeps its list.
        let month = toplists.list
        toplists.select(.month)
        #expect(toplists.list === month)

        // A page made later opens on the toplist picked.
        let later = ToplistsRootModel(settings: environment.settings, service: environment.service)
        #expect(later.period == .month)
    }

    /// Picking another toplist while the old one's first page is still on its way cancels that request (held here at
    /// the throttle, so it never reaches the site): the old list takes no page and is idle again, and only the new
    /// toplist is asked for.
    @Test func switchingCancelsTheOldToplist() async {
        let stub = Self.installNoHits()
        defer { stub.remove() }
        let throttle = HoldingThrottle(holding: URL(string: "https://e-hentai.org/toplist.php?tl=15")!)
        let environment = await Self.makeEnvironment(stub: stub, throttle: throttle)
        let toplists = ToplistsRootModel(settings: environment.settings, service: environment.service)
        let yesterday = toplists.list
        let load = Task { await yesterday.loadFirst() }
        #expect(await eventually { await throttle.waiting == 1 })
        #expect(yesterday.status == .loading)

        toplists.select(.month)
        let cancelled = await eventually { await throttle.cancellations == 1 }
        #expect(cancelled)
        // Not cancelled, the old load would wait for an hour.
        guard cancelled else { return }
        await load.value
        #expect(yesterday.status == .idle)
        #expect(yesterday.items.isEmpty)

        await toplists.list.loadFirst()
        #expect(toplists.list.status == .loaded)
        #expect(Self.urls(of: stub) == ["https://e-hentai.org/toplist.php?tl=13"])
    }

    /// A single reselect of the toplists tab is the system's (it scrolls by itself), and another tab's double reselect
    /// is that tab's: neither asks the site. A double reselect of the toplists tab refreshes the list from the site,
    /// once.
    ///
    /// Not observable here: a single reselect that calls the list without refreshing it
    /// (`scrollToTop(refreshing: false)`, a call the page is not meant to make) sends nothing, and the page's model is
    /// its own private state, so this test cannot catch it.
    @Test func onlyADoubleReselectRefreshes() async throws {
        let stub = Self.installNoHits()
        defer { stub.remove() }
        let environment = await Self.makeEnvironment(stub: stub)
        let reselection = TabReselectionCenter()
        let page = NavigationStack {
            ToplistsRootView()
        }
        .environment(reselection)
        let host = try HostedViews.show(page, environment: environment)
        defer { HostedViews.hide(host) }
        #expect(await eventually { stub.requests().count == 1 })

        reselection.send(.scrollToTopAndRefresh, for: .gallery)
        try await Task.sleep(for: .milliseconds(300))
        reselection.send(.scrollToTop, for: .toplists)
        try await Task.sleep(for: .milliseconds(300))
        #expect(stub.requests().count == 1)

        reselection.send(.scrollToTopAndRefresh, for: .toplists)
        #expect(await eventually { stub.requests().count == 2 })
        // The refresh is the barrier: a request the events before it caused late would come by now as a third one.
        try await Task.sleep(for: .milliseconds(300))
        #expect(stub.requests().count == 2)
        #expect(Self.urls(of: stub) == [
            "https://e-hentai.org/toplist.php?tl=15", "https://e-hentai.org/toplist.php?tl=15",
        ])
    }
}
