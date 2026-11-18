import EHModels
import EHNetwork
import EHStore
import Foundation
import Observation
import Synchronization
import Testing

@testable import Eros

/// `FavoritesRootModel` and its feeds (browse B8): local favorites only while logged out, the folders' names from the
/// pages, the order the user chose to keep, the selection, and dropping the cloud lists when the order or the
/// session's identity changes. Requests go to a `StubURLProtocol` that answers the
/// constructed favorites page (ordered by Favorited) from the Debug bundle's fixtures; nothing reaches the network.
///
/// Each test has a minute (`.timeLimit`): some hold a request, a page or a feed's answer until they let it go (a
/// gate, a throttle: neither heeds cancellation), and one that never lets go must fail at the limit, not hang the
/// run (the test process is then ended and started again for the tests after it).
@MainActor @Suite(.timeLimit(.minutes(1))) struct FavoritesRootModelTests {
    /// The constructed favorites page: Compact, ordered by Favorited, five galleries, ten folders, a next cursor.
    private static let favoritesPage: Data = {
        let root = Bundle.main.resourceURL!.appending(path: FixtureReplay.bundleDirectory, directoryHint: .isDirectory)
        return try! Data(contentsOf: root.appending(path: "constructed/eh/list-favorites.html"))
    }()

    /// The folders of the constructed page, in order.
    private static let folderNames = (0..<10).map { "Fake Folder \($0)" }
    private static let folderCounts = [1, 11, 1, 111, 1, 1, 1, 11, 1, 1]

    private static let loggedOut = SessionIdentity(isLoggedIn: false, memberID: nil)
    private static let member = SessionIdentity(isLoggedIn: true, memberID: "1234567")
    private static let otherMember = SessionIdentity(isLoggedIn: true, memberID: "7654321")

    /// Set from an observation's `onChange`, which may run on any thread.
    private final class ChangeFlag: Sendable {
        private let state = Mutex(false)

        func set() {
            state.withLock { $0 = true }
        }

        var isSet: Bool { state.withLock { $0 } }
    }

    /// Records every question and answers each with `answer`.
    private actor CountingPresenter: SiteSettingPresenter {
        private let answer: Bool
        private(set) var changes: [SiteSettingChange] = []

        init(answer: Bool) {
            self.answer = answer
        }

        func confirm(_ change: SiteSettingChange, site: EHSite) async -> Bool {
            changes.append(change)
            return answer
        }
    }

    /// The favorites page with the site's order control on Posted.
    private static let postedPage: Data = {
        let favorited = #"<option value="p">Posted</option><option value="f" selected="selected">Favorited</option>"#
        let posted = #"<option value="p" selected="selected">Posted</option><option value="f">Favorited</option>"#
        let text = String(decoding: favoritesPage, as: UTF8.self)
        precondition(text.contains(favorited), "The constructed page's order control changed")
        return Data(text.replacing(favorited, with: posted).utf8)
    }()

    /// Records every question and answers them in turn from `answers` (then declines).
    private actor ScriptedPresenter: SiteSettingPresenter {
        private var answers: [Bool]
        private(set) var changes: [SiteSettingChange] = []

        init(answers: [Bool]) {
            self.answers = answers
        }

        func confirm(_ change: SiteSettingChange, site: EHSite) async -> Bool {
            changes.append(change)
            return answers.isEmpty ? false : answers.removeFirst()
        }
    }

    /// Holds the requests of folder 1 until `open()`; lets every other through at once.
    private actor HeldFolderThrottle: RequestThrottle {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        var holds: Bool { !waiting.isEmpty }

        func acquire(for url: URL) async throws {
            if url.query()?.contains("favcat=1") == true, !isOpen {
                await withCheckedContinuation { waiting.append($0) }
            }
            try Task.checkCancellation()
        }

        func open() {
            isOpen = true
            let held = waiting
            waiting = []
            for continuation in held { continuation.resume() }
        }
    }

    /// A stub that answers every request with the favorites page.
    private static func installFavorites() -> StubSession {
        let page = favoritesPage
        return StubURLProtocol.install { _ in StubResponse(body: page) }
    }

    /// An environment (in-memory stores) whose requests go to `stub` through `throttle` when given; started when a stub
    /// is given.
    private static func makeEnvironment(
        stub: StubSession? = nil, throttle: (any RequestThrottle)? = nil
    ) async -> AppEnvironment {
        let environment = AppEnvironment(
            uiTesting: true, sessionConfigurator: stub?.configurator ?? .none, userAgentProbe: { "FakeWebKit/1" },
            throttle: throttle
        )
        if stub != nil || throttle != nil { await environment.start() }
        return environment
    }

    /// A model on E-Hentai over `environment`'s settings and store, whose service asks `presenter` (the environment's
    /// own service when nil).
    private static func makeModel(
        _ environment: AppEnvironment, presenter: CountingPresenter? = nil, userData: UserDataStore? = nil
    ) -> FavoritesRootModel {
        let service = presenter.map {
            EHService(client: environment.client, presenter: $0, ledger: InMemoryNoticeLedger())
        } ?? environment.service
        return FavoritesRootModel(
            service: service, userData: userData ?? environment.userData, settings: environment.settings, site: .eh
        )
    }

    /// The URLs `stub` received, oldest first.
    private static func urls(of stub: StubSession) -> [String] {
        stub.requests().compactMap(\.url?.absoluteString)
    }

    @Test func loggedOutOffersOnlyLocal() async {
        let environment = await Self.makeEnvironment()
        environment.settings.browsing.favoritesSelection = .folder(2)
        let favorites = Self.makeModel(environment)
        favorites.updateSession(Self.loggedOut)
        #expect(!favorites.isLoggedIn)
        #expect(favorites.selection == .local)
        #expect(favorites.title(for: favorites.selection) == "Local Favorites")

        // Picked while logged out, a folder is remembered for later but not shown.
        favorites.select(.all)
        #expect(favorites.selection == .local)
        #expect(environment.settings.browsing.favoritesSelection == .all)

        favorites.updateSession(Self.member)
        #expect(favorites.isLoggedIn)
        #expect(favorites.selection == .all)
        favorites.updateSession(Self.loggedOut)
        #expect(favorites.selection == .local)
    }

    @Test func folderNamesComeFromThePage() async {
        let stub = Self.installFavorites()
        defer { stub.remove() }
        let environment = await Self.makeEnvironment(stub: stub)
        let favorites = Self.makeModel(environment)
        favorites.updateSession(Self.member)
        #expect(favorites.folders == nil)
        #expect(favorites.title(for: .folder(3)) == "Favorites 3")
        #expect(favorites.menuTitle(for: .folder(3)) == "Favorites 3")
        #expect(favorites.menuTitle(for: .all) == "All Favorites")

        let all = favorites.model(for: .all)
        await all.loadFirst()
        #expect(all.items.count == 5)
        #expect(favorites.folders?.map(\.name) == Self.folderNames)
        #expect(favorites.folders?.map(\.count) == Self.folderCounts)
        #expect(favorites.title(for: .all) == "All Favorites")
        #expect(favorites.title(for: .folder(3)) == "Fake Folder 3")
        #expect(favorites.menuTitle(for: .folder(3)) == "Fake Folder 3 (111)")
        #expect(favorites.menuTitle(for: .all) == "All Favorites (\(Self.folderCounts.reduce(0, +)))")
        #expect(favorites.menuTitle(for: .local) == "Local Favorites")
        #expect(Self.urls(of: stub) == ["https://e-hentai.org/favorites.php"])
    }

    /// The first page comes in the site's order and the user declines to change it: that order is kept, so the next
    /// page, a list made before and one made after are all asked in it, and nothing is asked again.
    @Test func declinedOrderKeepsTheSitesOrderForLaterPages() async throws {
        let stub = Self.installFavorites()
        defer { stub.remove() }
        let environment = await Self.makeEnvironment(stub: stub)
        environment.settings.settings.favoritesOrder = .postedTime
        let presenter = CountingPresenter(answer: false)
        let favorites = Self.makeModel(environment, presenter: presenter)
        favorites.updateSession(Self.member)
        let earlier = favorites.model(for: .folder(1))

        let all = favorites.model(for: .all)
        await all.loadFirst()
        #expect(await presenter.changes == [.favoritesOrder(.postedTime)])
        #expect(favorites.keptSiteOrder == .favoritedTime)
        #expect(all.items.count == 5)

        let last = try #require(all.items.last)
        await all.itemAppeared(last.id)
        await earlier.loadFirst()
        await favorites.model(for: .folder(5)).loadFirst()
        #expect(await presenter.changes.count == 1)
        #expect(favorites.keptSiteOrder == .favoritedTime)
        #expect(environment.settings.settings.favoritesOrder == .postedTime)
        #expect(Self.urls(of: stub) == [
            "https://e-hentai.org/favorites.php",
            "https://e-hentai.org/favorites.php?next=900001-1111111111",
            "https://e-hentai.org/favorites.php?favcat=1",
            "https://e-hentai.org/favorites.php?favcat=5",
        ])
    }

    /// A new order drops the cloud lists and the order kept: the list shown next is a new one, asked in the new order.
    @Test func changingTheOrderReloads() async {
        let stub = Self.installFavorites()
        defer { stub.remove() }
        let environment = await Self.makeEnvironment(stub: stub)
        environment.settings.settings.favoritesOrder = .postedTime
        let presenter = CountingPresenter(answer: false)
        let favorites = Self.makeModel(environment, presenter: presenter)
        favorites.updateSession(Self.member)
        let all = favorites.model(for: .all)
        let folder = favorites.model(for: .folder(4))
        let local = favorites.model(for: .local)
        await all.loadFirst()
        #expect(favorites.keptSiteOrder == .favoritedTime)

        environment.settings.settings.favoritesOrder = .favoritedTime
        favorites.orderChanged()
        #expect(favorites.keptSiteOrder == nil)
        let newAll = favorites.model(for: .all)
        #expect(newAll !== all)
        #expect(favorites.model(for: .folder(4)) !== folder)
        #expect(favorites.model(for: .local) === local)
        await newAll.loadFirst()
        #expect(newAll.items.count == 5)
        #expect(await presenter.changes == [.favoritesOrder(.postedTime)])
        #expect(favorites.keptSiteOrder == nil)
        #expect(Self.urls(of: stub) == ["https://e-hentai.org/favorites.php", "https://e-hentai.org/favorites.php"])
    }

    /// Picking an order in the order menu (`pick(_:)`): another order is written to the settings and
    /// reloads the cloud lists; the order already picked changes nothing, unless the site's order is kept, when it
    /// reloads them too, so they ask for it again.
    @Test func pickingAnOrderReloadsWhenItShould() async {
        let stub = Self.installFavorites()
        defer { stub.remove() }
        let environment = await Self.makeEnvironment(stub: stub)
        let presenter = CountingPresenter(answer: false)
        let favorites = Self.makeModel(environment, presenter: presenter)
        favorites.updateSession(Self.member)
        #expect(environment.settings.settings.favoritesOrder == .favoritedTime)
        #expect(favorites.shownOrder == .favoritedTime)

        // The order already picked, nothing kept: nothing changes.
        let first = favorites.model(for: .all)
        favorites.pick(.favoritedTime)
        #expect(environment.settings.settings.favoritesOrder == .favoritedTime)
        #expect(favorites.model(for: .all) === first)

        // Another order: written, and the cloud lists are new.
        favorites.pick(.postedTime)
        #expect(environment.settings.settings.favoritesOrder == .postedTime)
        #expect(favorites.shownOrder == .postedTime)
        let posted = favorites.model(for: .all)
        #expect(posted !== first)

        // The page comes ordered by Favorited and the user declines, so the site's order is kept: the menu ticks the
        // order the list is in (U8), so the user's own order is the other item, whose pick always reaches the model;
        // picking it reloads.
        await posted.loadFirst()
        #expect(favorites.keptSiteOrder == .favoritedTime)
        #expect(favorites.shownOrder == .favoritedTime)
        #expect(environment.settings.settings.favoritesOrder == .postedTime)
        favorites.pick(.postedTime)
        #expect(environment.settings.settings.favoritesOrder == .postedTime)
        #expect(favorites.keptSiteOrder == nil)
        #expect(favorites.shownOrder == .postedTime)
        #expect(favorites.model(for: .all) !== posted)
        #expect(await presenter.changes == [.favoritesOrder(.postedTime)])
    }

    /// B8's reason for keeping one site order across the lists (L091a): two lists ask in Posted; the first page comes
    /// in Favorited and the user declines (the site's order is kept), then the second list's page, asked before that,
    /// comes in Favorited too and the user agrees (the site switches to Posted, nothing is kept). The first list's next
    /// page then asks in Posted as well: no third question, and no request switching the site back to Favorited.
    @Test func oneDeclinedAndOneAgreedQuestionDoNotGoBackAndForth() async throws {
        let siteOrder = Mutex(FavoritesOrder.favoritedTime)
        let favorited = Self.favoritesPage
        let posted = Self.postedPage
        let stub = StubURLProtocol.install { request in
            let query = request.url?.query() ?? ""
            if query.contains("inline_set=fs_p") { siteOrder.withLock { $0 = .postedTime } }
            if query.contains("inline_set=fs_f") { siteOrder.withLock { $0 = .favoritedTime } }
            return StubResponse(body: siteOrder.withLock { $0 } == .postedTime ? posted : favorited)
        }
        defer { stub.remove() }
        let throttle = HeldFolderThrottle()
        let environment = await Self.makeEnvironment(stub: stub, throttle: throttle)
        environment.settings.settings.favoritesOrder = .postedTime
        let presenter = ScriptedPresenter(answers: [false, true])
        let favorites = FavoritesRootModel(
            service: EHService(client: environment.client, presenter: presenter, ledger: InMemoryNoticeLedger()),
            userData: environment.userData, settings: environment.settings, site: .eh
        )
        favorites.updateSession(Self.member)
        let all = favorites.model(for: .all)
        let folder = favorites.model(for: .folder(1))
        // The folder's first page is asked for in Posted now, and held on its way.
        let folderLoad = Task { await folder.loadFirst() }
        #expect(await eventually { await throttle.holds })

        await all.loadFirst()
        #expect(await presenter.changes == [.favoritesOrder(.postedTime)])
        #expect(favorites.keptSiteOrder == .favoritedTime)

        await throttle.open()
        await folderLoad.value
        #expect(await presenter.changes == [.favoritesOrder(.postedTime), .favoritesOrder(.postedTime)])
        #expect(favorites.keptSiteOrder == nil)
        #expect(siteOrder.withLock { $0 } == .postedTime)

        let last = try #require(all.items.last)
        await all.itemAppeared(last.id)
        #expect(await presenter.changes.count == 2)
        #expect(favorites.keptSiteOrder == nil)
        #expect(siteOrder.withLock { $0 } == .postedTime)
        #expect(Self.urls(of: stub).filter { $0.contains("inline_set") } == [
            "https://e-hentai.org/favorites.php?favcat=1&inline_set=fs_p",
        ])
        #expect(Self.urls(of: stub).last == "https://e-hentai.org/favorites.php?next=900001-1111111111")
    }

    /// Without the user data store the local favorites say they could not be loaded (A-M4), as the gallery's groups
    /// do, rather than `No Galleries`, which reads as if they were all gone.
    @Test func localFavoritesWithoutAStoreFail() async {
        let environment = await Self.makeEnvironment()
        let favorites = FavoritesRootModel(
            service: environment.service, userData: nil, settings: environment.settings, site: .eh
        )
        favorites.updateSession(Self.loggedOut)
        let local = favorites.model(for: favorites.selection)
        await local.loadFirst()
        let noStore = ListFailure.localFavoritesUnavailable(canRetry: false)
        #expect(local.status == .failed(noStore))
        #expect(local.items.isEmpty)
        #expect(noStore.message == "Local favorites could not be loaded.")
        // Without a store, trying again cannot help: no button (M2 re-review F3 M-3).
        #expect(noStore.action == nil)
    }

    /// A read of the store that throws (the store is there) may work next time: the failure offers Try Again, and
    /// trying again loads the favorites (M2 re-review F3 M-3).
    @Test func aLocalFavoritesReadThatThrowsOffersTryAgain() async throws {
        struct ReadFailed: Error {}
        let fails = Mutex(true)
        let feed = LocalFavoritesFeed {
            if fails.withLock({ $0 }) { throw ReadFailed() }
            return [makeItem(900001)]
        }
        await #expect(throws: LocalFavoritesUnavailable(canRetry: true)) {
            try await feed.page(at: .first, refresh: false)
        }
        let model = GalleryListModel(feed: feed)
        await model.loadFirst()
        #expect(model.status == .failed(.localFavoritesUnavailable(canRetry: true)))
        #expect(ListFailure(LocalFavoritesUnavailable(canRetry: true)) == .localFavoritesUnavailable(canRetry: true))
        #expect(ListFailure.localFavoritesUnavailable(canRetry: true).action == .tryAgain)
        #expect(ListFailure.localFavoritesUnavailable(canRetry: true).message == "Local favorites could not be loaded.")

        // What Try Again does (`GalleryListView`).
        fails.withLock { $0 = false }
        await model.reload()
        #expect(model.status == .loaded)
        #expect(model.items.map(\.id.gid) == [900001])
    }

    /// Another member drops every cloud list, the folders and the order kept; the old list is no longer held, and
    /// asked again (the shown list's view reloads it on the same change) it sends nothing. The same identity again
    /// changes nothing, and the local list stays.
    @Test func identityChangeDropsCloudModels() async throws {
        let stub = Self.installFavorites()
        defer { stub.remove() }
        let environment = await Self.makeEnvironment(stub: stub)
        environment.settings.settings.favoritesOrder = .postedTime
        let favorites = Self.makeModel(environment, presenter: CountingPresenter(answer: false))
        favorites.updateSession(Self.member)
        var first: GalleryListModel? = favorites.model(for: .all)
        weak let released = first
        await first?.loadFirst()
        #expect(favorites.folders != nil)
        #expect(favorites.keptSiteOrder == .favoritedTime)
        let local = favorites.model(for: .local)

        favorites.updateSession(Self.member)
        #expect(favorites.model(for: .all) === first)
        #expect(favorites.folders != nil)

        favorites.updateSession(Self.otherMember)
        #expect(favorites.folders == nil)
        #expect(favorites.keptSiteOrder == nil)
        #expect(favorites.model(for: .local) === local)
        let replacement = favorites.model(for: .all)
        #expect(replacement !== first)

        let sent = stub.requests().count
        await first?.reload()
        #expect(stub.requests().count == sent)
        #expect(first?.status == .idle)
        first = nil
        #expect(released == nil, "The model still holds the dropped list")
    }

    /// A cloud list that is dropped while its first page is on its way (held at the throttle here) has that request
    /// cancelled, whether the order or the session's identity changed.
    @Test(arguments: [false, true])
    func droppedListsStopTheirRequests(byIdentity: Bool) async {
        let throttle = SuspendingThrottle()
        let environment = await Self.makeEnvironment(throttle: throttle)
        let favorites = Self.makeModel(environment)
        favorites.updateSession(Self.member)
        let all = favorites.model(for: .all)
        let load = Task { await all.loadFirst() }
        #expect(await eventually { await throttle.waiting == 1 })

        if byIdentity {
            favorites.updateSession(Self.otherMember)
        } else {
            favorites.orderChanged()
        }
        let cancelled = await eventually { await throttle.cancellations == 1 }
        #expect(cancelled)
        // Not cancelled, the load would wait for an hour.
        guard cancelled else { return }
        await load.value
        #expect(all.status == .idle)
        #expect(favorites.model(for: .all) !== all)
    }

    /// Dropping the cloud lists is itself observed: a page that shows a cloud list is told when
    /// the list it shows is dropped, also when nothing else it reads changes (another member while logged in, before
    /// any page came: `isLoggedIn`, `folders` and `keptSiteOrder` stay as they were), and then shows a new list. A new
    /// order goes the same way.
    @Test(arguments: [true, false])
    func droppingTheShownListRedrawsThePage(byIdentity: Bool) async {
        let environment = await Self.makeEnvironment()
        let favorites = Self.makeModel(environment)
        favorites.updateSession(Self.member)
        let shown = favorites.model(for: favorites.selection)
        let redraw = ChangeFlag()
        withObservationTracking {
            _ = favorites.model(for: favorites.selection)
        } onChange: {
            redraw.set()
        }

        if byIdentity {
            favorites.updateSession(Self.otherMember)
        } else {
            favorites.orderChanged()
        }
        #expect(redraw.isSet, "The page was not told that the list it shows was dropped")
        #expect(favorites.model(for: favorites.selection) !== shown)
    }

    /// Switching to another selection while a cloud list's first page is on its way leaves that list alone: its request
    /// is not cancelled (held at the throttle here), its page is taken, and switching back shows the same list without
    /// asking the site again.
    @Test func switchingAwayLetsALoadFinish() async {
        let stub = Self.installFavorites()
        defer { stub.remove() }
        let throttle = GatedThrottle()
        let environment = await Self.makeEnvironment(stub: stub, throttle: throttle)
        let favorites = Self.makeModel(environment)
        favorites.updateSession(Self.member)
        let all = favorites.model(for: favorites.selection)
        let load = Task { await all.loadFirst() }
        #expect(await eventually { await throttle.urls.count == 1 })

        favorites.select(.folder(2))
        #expect(favorites.model(for: favorites.selection) !== all)
        await throttle.open()
        await load.value
        #expect(all.status == .loaded)
        #expect(all.items.count == 5)

        favorites.select(.all)
        #expect(favorites.model(for: favorites.selection) === all)
        await all.loadFirst()
        #expect(Self.urls(of: stub) == ["https://e-hentai.org/favorites.php"])
    }

    @Test func localFavoritesComeFromTheStore() async throws {
        let environment = await Self.makeEnvironment()
        let store = try UserDataStore(inMemory: true)
        try await store.addLocalFavorite(makeItem(900001))
        try await store.addLocalFavorite(makeItem(900002))
        let favorites = Self.makeModel(environment, userData: store)
        favorites.updateSession(Self.loggedOut)

        let local = favorites.model(for: favorites.selection)
        await local.loadFirst()
        #expect(local.status == .loaded)
        #expect(local.items.map(\.id.gid) == [900002, 900001])
        #expect(local.footer == .end)
        #expect(local.navigation == .none)

        let feed = LocalFavoritesFeed(store: store)
        let first = try await feed.page(at: .first, refresh: false)
        #expect(!first.isFromCache)
        #expect(first.page.items.count == 2)
        #expect(first.page.nextCursor == nil)
        let other = try await feed.page(at: .next("900001"), refresh: true)
        #expect(other.page.items.isEmpty)
        #expect(!other.isFromCache)
        await #expect(throws: LocalFavoritesUnavailable(canRetry: false)) {
            try await LocalFavoritesFeed(store: nil).page(at: .first, refresh: false)
        }
    }

    @Test func selectionIsRemembered() async {
        let environment = await Self.makeEnvironment()
        let favorites = Self.makeModel(environment)
        favorites.updateSession(Self.member)
        #expect(favorites.selection == .all)

        favorites.select(.folder(3))
        #expect(favorites.selection == .folder(3))
        #expect(environment.settings.browsing.favoritesSelection == .folder(3))
        #expect(favorites.title(for: favorites.selection) == "Favorites 3")

        let later = Self.makeModel(environment)
        later.updateSession(Self.member)
        #expect(later.selection == .folder(3))
        favorites.select(.local)
        #expect(later.selection == .local)
    }

    /// The search text a feed is made with reaches the request (`f_search`; search Q2 searches the favorites with it).
    @Test func searchReachesTheRequest() async throws {
        let stub = Self.installFavorites()
        defer { stub.remove() }
        let environment = await Self.makeEnvironment(stub: stub)
        var pages = 0
        let feed = FavoritesFeed(
            folder: 6, order: .favoritedTime, site: .eh, service: environment.service, search: "fake search"
        ) { _ in pages += 1 }
        _ = try await feed.page(at: .first, refresh: true)
        #expect(pages == 1)
        let url = try #require(stub.requests().first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items == [
            URLQueryItem(name: "f_search", value: "fake search"), URLQueryItem(name: "favcat", value: "6"),
        ])
    }
}
