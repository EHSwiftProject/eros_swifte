import EHFixtures
import EHModels
import EHNetwork
import EHNetworkTesting
import EHParsing
import Foundation
import Synchronization
import Testing

/// `EHService.favorites` (browse B8): favorites.php in the Compact view, then in the order the app asks for. A page in
/// another order is resent with `inline_set=fs_f` or `fs_p` once the user agreed (asked through the shared prompt and
/// ledger doubles of `ServiceTestSupport.swift`), or kept as the site sent it when they declined. Every request goes to
/// `MockURLProtocol` and is answered from the constructed favorites page (its order control shows Favorited); nothing
/// reaches the network.
@Suite struct FavoritesServiceTests {
    /// The constructed page: Compact, ordered by Favorited.
    private static let favorites = try! Fixtures.string("constructed/eh/list-favorites.html")

    /// The page's order control as the fixture has it (Favorited selected).
    private static let favoritedControl =
        #"<option value="p">Posted</option><option value="f" selected="selected">Favorited</option>"#

    /// The page ordered by Posted.
    private static let posted = favorites.replacingOccurrences(
        of: favoritedControl,
        with: #"<option value="p" selected="selected">Posted</option><option value="f">Favorited</option>"#
    )

    /// The page without its order control.
    private static let unordered = favorites.replacingOccurrences(
        of: #"Fake order: <select onchange="fakeOrder(this.value)">"# + favoritedControl + "</select>", with: ""
    )

    /// The page in the Thumbnail view, not Compact.
    private static let thumbnail = favorites
        .replacingOccurrences(of: #"<option value="l" selected="selected">"#, with: #"<option value="l">"#)
        .replacingOccurrences(of: #"<option value="t">"#, with: #"<option value="t" selected="selected">"#)

    /// A made-up account in the jars of both sites.
    private static let memberID = 1234567
    private static let passHash = "0123456789abcdef0123456789abcdef"

    private static let orderScope = NoticeScope(kind: .favoritesOrder, site: .eh, memberID: memberID)

    private struct Harness {
        let service: EHService
        let cookies: CookieStore
        let mock: MockSession
        let directory: URL

        /// The URLs the mock received, oldest first.
        func urls() -> [String] { mock.requests().compactMap(\.url?.absoluteString) }

        func cleanUp() {
            mock.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A signed-in service with a response cache in a new temporary directory, asking `presenter` and recording in
    /// `ledger`. The responder gets the 1-based number of the request.
    private static func makeHarness(
        presenter: any SiteSettingPresenter, ledger: any NoticeLedger = InMemoryNoticeLedger(),
        responder: @escaping @Sendable (URLRequest, Int) throws -> MockResponse
    ) async throws -> Harness {
        let count = Mutex(0)
        let mock = MockURLProtocol.install { request in
            let number = count.withLock { value -> Int in
                value += 1
                return value
            }
            return try responder(request, number)
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "eros-favorites-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cookies = CookieStore(vault: InMemoryVault())
        try await cookies.load()
        try await cookies.set(
            [CookieNames.memberID: String(memberID), CookieNames.passHash: passHash], for: [.eh, .ex]
        )
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        await userAgents.load()
        let client = EHClient(
            configuration: try EHClientConfiguration(sessionConfigurator: mock.configurator), cookies: cookies,
            userAgents: userAgents, throttle: RecordingThrottle(), cache: ResponseCache(directory: directory)
        )
        return Harness(
            service: EHService(client: client, presenter: presenter, ledger: ledger), cookies: cookies, mock: mock,
            directory: directory
        )
    }

    /// Answers `page` to a request without `inline_set`, and `resent` to one with it.
    private static func resending(_ page: String, then resent: String) -> @Sendable (URLRequest, Int) -> MockResponse {
        { request, _ in
            let text = request.url?.absoluteString.contains("inline_set") == true ? resent : page
            return MockResponse(body: Data(text.utf8))
        }
    }

    private static func always(_ page: String) -> @Sendable (URLRequest, Int) -> MockResponse {
        { _, _ in MockResponse(body: Data(page.utf8)) }
    }

    /// The variants of the page are what the tests take them for.
    @Test func pageVariantsParseAsExpected() throws {
        #expect(try GalleryListParser.parse(Self.favorites).favoritesOrder == .favoritedTime)
        #expect(try GalleryListParser.parse(Self.posted).favoritesOrder == .postedTime)
        #expect(try GalleryListParser.parse(Self.unordered).favoritesOrder == nil)
        #expect(try ListDisplayMode.detect(in: Self.favorites) == .compact)
        #expect(try ListDisplayMode.detect(in: Self.thumbnail) == .thumbnail)
    }

    @Test func foldersSendFavcat() async throws {
        let h = try await Self.makeHarness(
            presenter: RecordingPresenter(answer: true), responder: Self.always(Self.favorites)
        )
        defer { h.cleanUp() }
        _ = try await h.service.favorites(
            folder: nil, search: nil, position: .first, order: .favoritedTime, site: .eh, refresh: true
        )
        _ = try await h.service.favorites(
            folder: 3, search: nil, position: .first, order: .favoritedTime, site: .eh, refresh: true
        )
        #expect(h.urls() == ["https://e-hentai.org/favorites.php", "https://e-hentai.org/favorites.php?favcat=3"])
        #expect(h.urls().allSatisfy { !$0.contains("f_cats") })
    }

    /// The search text goes out as `f_search` (search Q2 searches the favorites through it).
    @Test func searchIsSent() async throws {
        let h = try await Self.makeHarness(
            presenter: RecordingPresenter(answer: true), responder: Self.always(Self.favorites)
        )
        defer { h.cleanUp() }
        _ = try await h.service.favorites(
            folder: 2, search: "fake search", position: .first, order: .favoritedTime, site: .eh, refresh: true
        )
        let url = try #require(h.mock.requests().first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items == [
            URLQueryItem(name: "f_search", value: "fake search"), URLQueryItem(name: "favcat", value: "2"),
        ])
    }

    @Test func matchingOrderSendsOneRequest() async throws {
        let presenter = RecordingPresenter(answer: true)
        let h = try await Self.makeHarness(presenter: presenter, responder: Self.always(Self.favorites))
        defer { h.cleanUp() }
        let result = try await h.service.favorites(
            folder: nil, search: nil, position: .first, order: .favoritedTime, site: .eh, refresh: false
        )
        #expect(result.page.items.count == 5)
        #expect(result.page.favoritesOrder == .favoritedTime)
        #expect(h.urls().count == 1)
        #expect(await presenter.calls.isEmpty)
    }

    @Test func mismatchedOrderAsksThenResends() async throws {
        let presenter = RecordingPresenter(answer: true)
        let ledger = InMemoryNoticeLedger()
        let h = try await Self.makeHarness(
            presenter: presenter, ledger: ledger, responder: Self.resending(Self.favorites, then: Self.posted)
        )
        defer { h.cleanUp() }
        let result = try await h.service.favorites(
            folder: nil, search: nil, position: .first, order: .postedTime, site: .eh, refresh: false
        )
        let calls = await presenter.calls
        #expect(calls.count == 1)
        #expect(calls.first?.change == .favoritesOrder(.postedTime))
        #expect(calls.first?.site == .eh)
        #expect(h.urls() == [
            "https://e-hentai.org/favorites.php", "https://e-hentai.org/favorites.php?inline_set=fs_p",
        ])
        #expect(result.page.favoritesOrder == .postedTime)
        #expect(!result.isFromCache)
        #expect(await ledger.isAcknowledged(Self.orderScope))
    }

    @Test func favoritedOrderResendsWithFsF() async throws {
        let presenter = RecordingPresenter(answer: true)
        let h = try await Self.makeHarness(
            presenter: presenter, responder: Self.resending(Self.posted, then: Self.favorites)
        )
        defer { h.cleanUp() }
        let result = try await h.service.favorites(
            folder: 3, search: nil, position: .first, order: .favoritedTime, site: .eh, refresh: true
        )
        #expect(await presenter.calls.map { $0.change } == [.favoritesOrder(.favoritedTime)])
        #expect(h.urls() == [
            "https://e-hentai.org/favorites.php?favcat=3",
            "https://e-hentai.org/favorites.php?favcat=3&inline_set=fs_f",
        ])
        #expect(result.page.favoritesOrder == .favoritedTime)
    }

    /// Declining keeps the page as the site sent it (not an error) and changes nothing; the next call asks again.
    @Test func declinedOrderReturnsTheSitesPage() async throws {
        let presenter = RecordingPresenter(answer: false)
        let ledger = InMemoryNoticeLedger()
        let h = try await Self.makeHarness(
            presenter: presenter, ledger: ledger, responder: Self.resending(Self.favorites, then: Self.posted)
        )
        defer { h.cleanUp() }
        let result = try await h.service.favorites(
            folder: nil, search: nil, position: .first, order: .postedTime, site: .eh, refresh: true
        )
        #expect(h.urls() == ["https://e-hentai.org/favorites.php"])
        #expect(result.page.favoritesOrder == .favoritedTime)
        #expect(result.page.items.count == 5)
        #expect(!result.isFromCache)
        #expect(await presenter.calls.count == 1)
        #expect(await !ledger.isAcknowledged(Self.orderScope))

        _ = try await h.service.favorites(
            folder: nil, search: nil, position: .first, order: .postedTime, site: .eh, refresh: true
        )
        #expect(await presenter.calls.count == 2)
        #expect(h.urls().allSatisfy { !$0.contains("inline_set") })
    }

    @Test func acknowledgedOrderResendsWithoutAsking() async throws {
        let presenter = RecordingPresenter(answer: false)
        let h = try await Self.makeHarness(
            presenter: presenter, ledger: InMemoryNoticeLedger(acknowledged: [Self.orderScope]),
            responder: Self.resending(Self.favorites, then: Self.posted)
        )
        defer { h.cleanUp() }
        let result = try await h.service.favorites(
            folder: nil, search: nil, position: .first, order: .postedTime, site: .eh, refresh: true
        )
        #expect(await presenter.calls.isEmpty)
        #expect(h.urls().count == 2)
        #expect(h.urls().last?.contains("inline_set=fs_p") == true)
        #expect(result.page.favoritesOrder == .postedTime)
    }

    /// A numbered page is resent as the first page (Flutter drops `page`); a cursor stays.
    @Test func pagePositionIsDroppedOnResend() async throws {
        let h = try await Self.makeHarness(
            presenter: RecordingPresenter(answer: true), ledger: InMemoryNoticeLedger(acknowledged: [Self.orderScope]),
            responder: Self.resending(Self.favorites, then: Self.posted)
        )
        defer { h.cleanUp() }
        _ = try await h.service.favorites(
            folder: nil, search: nil, position: .page(2), order: .postedTime, site: .eh, refresh: true
        )
        _ = try await h.service.favorites(
            folder: nil, search: nil, position: .next("x"), order: .postedTime, site: .eh, refresh: true
        )
        #expect(h.urls() == [
            "https://e-hentai.org/favorites.php?page=2",
            "https://e-hentai.org/favorites.php?inline_set=fs_p",
            "https://e-hentai.org/favorites.php?next=x",
            "https://e-hentai.org/favorites.php?next=x&inline_set=fs_p",
        ])
    }

    @Test(arguments: [FavoritesOrder.favoritedTime, .postedTime])
    func unknownOrderIsLeftAlone(order: FavoritesOrder) async throws {
        let presenter = RecordingPresenter(answer: true)
        let h = try await Self.makeHarness(presenter: presenter, responder: Self.always(Self.unordered))
        defer { h.cleanUp() }
        let result = try await h.service.favorites(
            folder: nil, search: nil, position: .first, order: order, site: .eh, refresh: true
        )
        #expect(result.page.favoritesOrder == nil)
        #expect(result.page.items.count == 5)
        #expect(h.urls().count == 1)
        #expect(await presenter.calls.isEmpty)
    }

    /// A favorites page that is not Compact goes through the Compact flow first (`dm_l`); only the Compact page's order
    /// is compared.
    @Test func compactComesFirst() async throws {
        let presenter = RecordingPresenter(answer: true)
        let h = try await Self.makeHarness(presenter: presenter) { request, _ in
            let url = request.url?.absoluteString ?? ""
            let text = url.contains("inline_set=fs_p") ? Self.posted
                : url.contains("inline_set=dm_l") ? Self.favorites : Self.thumbnail
            return MockResponse(body: Data(text.utf8))
        }
        defer { h.cleanUp() }
        let result = try await h.service.favorites(
            folder: nil, search: nil, position: .first, order: .postedTime, site: .eh, refresh: false
        )
        #expect(await presenter.calls.map { $0.change } == [
            .compactView(current: .thumbnail), .favoritesOrder(.postedTime),
        ])
        #expect(h.urls() == [
            "https://e-hentai.org/favorites.php",
            "https://e-hentai.org/favorites.php?inline_set=dm_l",
            "https://e-hentai.org/favorites.php?inline_set=fs_p",
        ])
        #expect(result.page.favoritesOrder == .postedTime)
    }

    /// The resent answer is cached under the first request's URL: asked again from the cache, nothing is sent and the
    /// page is the resent one (in the order asked for, so nothing is asked either).
    @Test func resentPageIsCachedUnderTheFirstURL() async throws {
        let presenter = RecordingPresenter(answer: true)
        let h = try await Self.makeHarness(
            presenter: presenter, responder: Self.resending(Self.favorites, then: Self.posted)
        )
        defer { h.cleanUp() }
        let resent = try await h.service.favorites(
            folder: nil, search: nil, position: .first, order: .postedTime, site: .eh, refresh: false
        )
        #expect(h.urls().count == 2)
        let again = try await h.service.favorites(
            folder: nil, search: nil, position: .first, order: .postedTime, site: .eh, refresh: false
        )
        #expect(h.urls().count == 2)
        #expect(again.page == resent.page)
        #expect(again.page.favoritesOrder == .postedTime)
        #expect(again.isFromCache)
        #expect(await presenter.calls.count == 1)
    }

    /// The session ends while the question is open: after "Continue" nothing is resent, and the page of the ended
    /// session is dropped (`.sessionEnded`).
    @Test func sessionEndedWhileAskingSendsNoResend() async throws {
        let presenter = GatedPresenter()
        let ledger = InMemoryNoticeLedger()
        let h = try await Self.makeHarness(
            presenter: presenter, ledger: ledger, responder: Self.resending(Self.favorites, then: Self.posted)
        )
        defer { h.cleanUp() }
        let service = h.service
        let list = Task {
            try await service.favorites(
                folder: nil, search: nil, position: .first, order: .postedTime, site: .eh, refresh: false
            )
        }
        defer { list.cancel() }
        #expect(await waitUntil { await presenter.isWaiting })
        try await h.cookies.reset()
        await presenter.answerAll(true)
        let outcome = await list.result
        var failure: EHNetworkError?
        if case .failure(let error) = outcome { failure = error as? EHNetworkError }
        #expect(failure == .sessionEnded)
        #expect(h.mock.requests().count == 1)
        #expect(h.urls().allSatisfy { !$0.contains("inline_set") })
        #expect(await !ledger.isAcknowledged(Self.orderScope))
    }

    /// The session ends while the question is open and the answer is "Cancel": the page of the ended session is
    /// dropped too, not handed on as the site's order.
    @Test func sessionEndedWhileAskingDropsADeclinedPage() async throws {
        let presenter = GatedPresenter()
        let h = try await Self.makeHarness(
            presenter: presenter, responder: Self.resending(Self.favorites, then: Self.posted)
        )
        defer { h.cleanUp() }
        let service = h.service
        let list = Task {
            try await service.favorites(
                folder: nil, search: nil, position: .first, order: .postedTime, site: .eh, refresh: false
            )
        }
        defer { list.cancel() }
        #expect(await waitUntil { await presenter.isWaiting })
        try await h.cookies.reset()
        await presenter.answerAll(false)
        let outcome = await list.result
        var failure: EHNetworkError?
        if case .failure(let error) = outcome { failure = error as? EHNetworkError }
        #expect(failure == .sessionEnded)
        #expect(h.mock.requests().count == 1)
    }

    @Test func isFromCacheFollowsTheResponse() async throws {
        let h = try await Self.makeHarness(
            presenter: RecordingPresenter(answer: true), responder: Self.resending(Self.favorites, then: Self.posted)
        )
        defer { h.cleanUp() }
        let first = try await h.service.favorites(
            folder: nil, search: nil, position: .first, order: .favoritedTime, site: .eh, refresh: false
        )
        let cached = try await h.service.favorites(
            folder: nil, search: nil, position: .first, order: .favoritedTime, site: .eh, refresh: false
        )
        #expect(!first.isFromCache)
        #expect(cached.isFromCache)
        #expect(h.urls().count == 1)

        // The cached page is in the other order: the resend's page comes from the site.
        let resent = try await h.service.favorites(
            folder: nil, search: nil, position: .first, order: .postedTime, site: .eh, refresh: false
        )
        #expect(h.urls().count == 2)
        #expect(h.urls().last?.contains("inline_set=fs_p") == true)
        #expect(!resent.isFromCache)
        #expect(resent.page.favoritesOrder == .postedTime)
    }
}
