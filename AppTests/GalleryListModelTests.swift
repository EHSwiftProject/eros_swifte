import EHModels
import EHNetwork
import EHParsing
import Foundation
import Testing

@testable import Eros

/// `GalleryListModel` over a `ScriptedFeed`: the first page and its silent refresh, the next pages, jumps, empty pages,
/// failures and dropped answers. Every gallery is made up (gids from 900001).
///
/// Each test has a minute (`.timeLimit`): some hold a request, a page or a feed's answer until they let it go (a
/// gate, a throttle: neither heeds cancellation), and one that never lets go must fail at the limit, not hang the
/// run (the test process is then ended and started again for the tests after it).
@MainActor @Suite(.timeLimit(.minutes(1))) struct GalleryListModelTests {
    private typealias Call = ScriptedFeed.Call

    private static func id(_ gid: Int) -> GalleryID { makeItem(gid).id }

    private static func gids(_ model: GalleryListModel) -> [Int] { model.items.map(\.id.gid) }

    /// A model whose first page (from the site) is `page`, loaded.
    private static func loaded(_ page: GalleryListPage, feed: ScriptedFeed) async -> GalleryListModel {
        feed.answer(.first, page)
        let model = GalleryListModel(feed: feed)
        await model.loadFirst()
        #expect(model.status == .loaded)
        return model
    }

    // MARK: - The first page

    /// Every model has an id of its own, kept for its life (L093): the pages give a new list a new view by it, rather
    /// than by the object's address, which a later model may be given.
    @Test func everyModelHasItsOwnID() {
        let first = GalleryListModel(feed: ScriptedFeed())
        let second = GalleryListModel(feed: ScriptedFeed())
        #expect(first.id != second.id)
        #expect(first.id == first.id)
    }

    /// Flutter custom_sublist_controller.dart:35-49: a first page from the cache is shown, then asked of the site
    /// again in the background, and the answer takes its place.
    @Test func cachedFirstPageIsRefreshedSilently() async {
        let feed = ScriptedFeed()
        let gate = Gate()
        feed.answer(.first, makePage([900001, 900002], next: "900002"), cached: true)
        feed.answer(.first, makePage([900003, 900001], next: "900001", summary: "Found 3 results."), gate: gate)
        let model = GalleryListModel(feed: feed)

        let load = Task { await model.loadFirst() }
        #expect(await eventually { feed.calls.count == 2 })
        #expect(model.status == .loaded)
        #expect(Self.gids(model) == [900001, 900002])
        #expect(model.isRefreshingInBackground)
        gate.open()
        await load.value
        #expect(feed.calls == [Call(.first, false), Call(.first, true)])
        #expect(Self.gids(model) == [900003, 900001])
        #expect(!model.isRefreshingInBackground)
        #expect(model.summary == "Found 3 results.")
        #expect(model.navigation == .cursor(next: "900001", previous: nil))
    }

    /// Without a cache hit the page is asked for once (Flutter asked twice whenever there was no cache).
    @Test func networkFirstPageIsNotRequestedTwice() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001], next: "900001"), feed: feed)
        #expect(feed.calls == [Call(.first, false)])
        #expect(!model.isRefreshingInBackground)
        // Loaded: asking again sends nothing.
        await model.loadFirst()
        #expect(feed.calls.count == 1)
    }

    /// The next page came in while the silent refresh was out: the refresh's answer would drop it, so it is dropped.
    @Test func silentRefreshKeepsPagesLoadedMeanwhile() async {
        let feed = ScriptedFeed()
        let gate = Gate()
        feed.answer(.first, makePage([900001, 900002], next: "900002"), cached: true)
        feed.answer(.first, makePage([900009], next: "900009"), gate: gate)
        feed.answer(.next("900002"), makePage([900003, 900004], next: "900004"))
        let model = GalleryListModel(feed: feed)

        let load = Task { await model.loadFirst() }
        #expect(await eventually { feed.calls.count == 2 })
        await model.itemAppeared(Self.id(900002))
        #expect(Self.gids(model) == [900001, 900002, 900003, 900004])
        gate.open()
        await load.value
        #expect(Self.gids(model) == [900001, 900002, 900003, 900004])
        #expect(!model.isRefreshingInBackground)
        #expect(feed.calls == [Call(.first, false), Call(.first, true), Call(.next("900002"), true)])
        #expect(model.navigation == .cursor(next: "900004", previous: nil))
        #expect(model.footer == .none)
    }

    /// The silent refresh is silent (index §7; Flutter custom_sublist_controller.dart:39-48 drops its error): when it
    /// fails, the page from the cache stays and no failure is shown.
    @Test func failedSilentRefreshStaysSilent() async {
        let feed = ScriptedFeed()
        feed.answer(.first, makePage([900001, 900002], next: "900002"), cached: true)
        feed.fail(.first, EHNetworkError.transport(.notConnectedToInternet))
        let model = GalleryListModel(feed: feed)
        await model.loadFirst()
        #expect(feed.calls == [Call(.first, false), Call(.first, true)])
        #expect(Self.gids(model) == [900001, 900002])
        #expect(model.status == .loaded)
        #expect(model.refreshFailure == nil)
        #expect(!model.isRefreshingInBackground)
        #expect(model.footer == .none)
    }

    @Test func failedFirstPageShowsTheFailure() async {
        let feed = ScriptedFeed()
        feed.fail(.first, ParseError.loginRequired)
        feed.answer(.first, makePage([900001]))
        let model = GalleryListModel(feed: feed)
        await model.loadFirst()
        #expect(model.status == .failed(.loginRequired))
        #expect(model.items.isEmpty)
        #expect(model.refreshFailure == nil)
        // A failed list loads again when shown again.
        await model.loadFirst()
        #expect(model.status == .loaded)
        #expect(Self.gids(model) == [900001])
    }

    // MARK: - Refreshing

    @Test func pullToRefreshForcesARequest() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001], next: "900001"), feed: feed)
        feed.answer(.first, makePage([900002, 900001], next: "900001", summary: "Found 2 results."))
        await model.refresh()
        #expect(feed.calls == [Call(.first, false), Call(.first, true)])
        #expect(Self.gids(model) == [900002, 900001])
        #expect(model.summary == "Found 2 results.")
        #expect(model.status == .loaded)
    }

    @Test func failedPullKeepsItems() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001], next: "900001"), feed: feed)
        feed.fail(.first, EHNetworkError.transport(.timedOut))
        await model.refresh()
        #expect(Self.gids(model) == [900001])
        #expect(model.status == .loaded)
        #expect(model.refreshFailure == .network)
        feed.answer(.first, makePage([900002]))
        await model.refresh()
        #expect(Self.gids(model) == [900002])
        #expect(model.refreshFailure == nil)
    }

    /// Reloading drops everything first (session change, Try Again), then asks the site.
    @Test func reloadDropsEverything() async {
        let feed = ScriptedFeed()
        let gate = Gate()
        let model = await Self.loaded(makePage([900001], next: "900001", summary: "Found 9 results."), feed: feed)
        feed.answer(.first, makePage([900005]), gate: gate)
        let reload = Task { await model.reload() }
        #expect(await eventually { feed.calls.count == 2 })
        #expect(model.items.isEmpty)
        #expect(model.status == .loading)
        #expect(model.summary == nil)
        #expect(model.navigation == .none)
        gate.open()
        await reload.value
        #expect(feed.calls.last == Call(.first, true))
        #expect(Self.gids(model) == [900005])
        #expect(model.footer == .end)
    }

    @Test func scrollToTopRefreshingRefreshes() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001]), feed: feed)
        await model.scrollToTop(refreshing: false)
        #expect(model.scrollToTopSignal == 1)
        #expect(feed.calls.count == 1)
        feed.answer(.first, makePage([900002]))
        await model.scrollToTop(refreshing: true)
        #expect(model.scrollToTopSignal == 2)
        #expect(feed.calls == [Call(.first, false), Call(.first, true)])
        #expect(Self.gids(model) == [900002])
    }

    // MARK: - Next pages

    @Test func lastItemLoadsTheNextCursor() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001, 900002], next: "123"), feed: feed)
        feed.answer(.next("123"), makePage([900003]))
        // Not the last item: nothing yet.
        await model.itemAppeared(Self.id(900001))
        #expect(feed.calls.count == 1)
        await model.itemAppeared(Self.id(900002))
        #expect(feed.calls == [Call(.first, false), Call(.next("123"), true)])
        #expect(Self.gids(model) == [900001, 900002, 900003])
        #expect(model.footer == .end)
        #expect(model.navigation == .none)
    }

    /// `lookahead` starts the next page before the very last item appears.
    @Test func lookaheadLoadsEarlier() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001, 900002, 900003], next: "900003"), feed: feed)
        feed.answer(.next("900003"), makePage([900004], next: "900004"))
        await model.itemAppeared(Self.id(900001), lookahead: 2)
        #expect(feed.calls.count == 1)
        await model.itemAppeared(Self.id(900002), lookahead: 2)
        #expect(feed.calls.last == Call(.next("900003"), true))
        #expect(model.footer == .none)
    }

    /// Toplists number their pages: the next page is the next number, until the last one.
    @Test func numberedListsLoadByPage() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001], index: 0, count: 3), feed: feed)
        #expect(model.navigation == .numbered(index: 0, count: 3))
        feed.answer(.page(1), makePage([900002], index: 1, count: 3))
        feed.answer(.page(2), makePage([900003], index: 2, count: 3))
        await model.itemAppeared(Self.id(900001))
        await model.itemAppeared(Self.id(900002))
        #expect(feed.calls == [Call(.first, false), Call(.page(1), true), Call(.page(2), true)])
        #expect(model.navigation == .numbered(index: 2, count: 3))
        #expect(model.footer == .end)
        await model.itemAppeared(Self.id(900003))
        #expect(feed.calls.count == 3)

        // A list that starts on its last page asks for nothing more.
        let last = ScriptedFeed()
        let model2 = await Self.loaded(makePage([900011], index: 2, count: 3), feed: last)
        #expect(model2.footer == .end)
        await model2.itemAppeared(Self.id(900011))
        #expect(last.calls.count == 1)
    }

    @Test func sameCursorIsNotRequestedTwice() async {
        let feed = ScriptedFeed()
        let gate = Gate()
        let model = await Self.loaded(makePage([900001, 900002], next: "123"), feed: feed)
        // The site answers with the cursor that was just loaded (a page that leads back to itself).
        feed.answer(.next("123"), makePage([900003], next: "123"), gate: gate)
        let first = Task { await model.itemAppeared(Self.id(900002)) }
        #expect(await eventually { feed.calls.count == 2 })
        #expect(model.footer == .loading)
        await model.itemAppeared(Self.id(900002))
        #expect(feed.calls.count == 2)
        gate.open()
        await first.value
        #expect(model.footer == .end)
        await model.itemAppeared(Self.id(900003))
        #expect(feed.calls.count == 2)
    }

    /// Flutter tabview_controller.dart:228-283 kept a failed cursor as loaded (`lastNext`), so retrying sent nothing.
    @Test func failedLoadMoreRetriesForReal() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001], next: "123"), feed: feed)
        feed.fail(.next("123"), EHNetworkError.transport(.timedOut))
        feed.answer(.next("123"), makePage([900002]))
        await model.itemAppeared(Self.id(900001))
        #expect(model.footer == .failed(.network))
        await model.retryMore()
        #expect(feed.calls == [Call(.first, false), Call(.next("123"), true), Call(.next("123"), true)])
        #expect(Self.gids(model) == [900001, 900002])
        #expect(model.footer == .end)
    }

    @Test func failedLoadMoreDoesNotRetryOnAppear() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001], next: "123"), feed: feed)
        feed.fail(.next("123"), EHNetworkError.httpStatus(500))
        await model.itemAppeared(Self.id(900001))
        #expect(model.footer == .failed(.network))
        await model.itemAppeared(Self.id(900001))
        #expect(feed.calls.count == 2)
        #expect(model.footer == .failed(.network))
    }

    @Test func duplicateItemsAreNotAppended() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001, 900002], next: "a"), feed: feed)
        feed.answer(.next("a"), makePage([900002, 900003], next: "b"))
        await model.itemAppeared(Self.id(900002))
        #expect(Self.gids(model) == [900001, 900002, 900003])
        #expect(model.footer == .none)
    }

    // MARK: - Jumps

    @Test func pageOutOfRangeSendsNothing() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001], index: 0, count: 3), feed: feed)
        await model.jump(to: .page(3))
        await model.jump(to: .page(-1))
        #expect(feed.calls.count == 1)
        #expect(Self.gids(model) == [900001])
        #expect(model.status == .loaded)
        #expect(model.navigation == .numbered(index: 0, count: 3))
        #expect(!model.isAfterJump)
    }

    /// A jump to a numbered page counts as a jump; pulling then asks for that page again.
    @Test func pageJumpSetsIsAfterJump() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001], index: 0, count: 3), feed: feed)
        feed.answer(.page(2), makePage([900003], index: 2, count: 3, summary: "Page 3."))
        feed.answer(.page(2), makePage([900004, 900003], index: 2, count: 3, summary: "Page 3."))
        await model.jump(to: .page(2))
        #expect(model.isAfterJump)
        #expect(Self.gids(model) == [900003])
        #expect(model.summary == "Page 3.")
        #expect(model.navigation == .numbered(index: 2, count: 3))
        await model.refresh()
        #expect(feed.calls == [Call(.first, false), Call(.page(2), true), Call(.page(2), true)])
        #expect(Self.gids(model) == [900004, 900003])
        #expect(model.isAfterJump)
        // Back to the first page: no longer after a jump.
        feed.answer(.first, makePage([900001], index: 0, count: 3))
        await model.jump(to: .first)
        #expect(feed.calls.last == Call(.first, true))
        #expect(!model.isAfterJump)
    }

    @Test func jumpThenPullLoadsThePreviousPage() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900090], next: "900090", summary: "Found 99 results."), feed: feed)
        feed.answer(
            .seek("2024-01-01"),
            makePage([900050, 900051], next: "900051", previous: "900050", summary: "Found 99 results, from 2024.")
        )
        await model.jump(to: .seek("2024-01-01"))
        #expect(feed.calls.last == Call(.seek("2024-01-01"), true))
        #expect(model.isAfterJump)
        #expect(Self.gids(model) == [900050, 900051])
        #expect(model.summary == "Found 99 results, from 2024.")
        #expect(model.navigation == .cursor(next: "900051", previous: "900050"))

        feed.answer(.previous("900050"), makePage([900048, 900049], next: "900049", previous: "900048"))
        await model.refresh()
        #expect(feed.calls.last == Call(.previous("900050"), true))
        #expect(Self.gids(model) == [900048, 900049, 900050, 900051])
        #expect(model.isAfterJump)
        #expect(model.navigation == .cursor(next: "900051", previous: "900048"))

        // The first page of the list: nothing before it.
        feed.answer(.previous("900048"), makePage([900047], next: "900047"))
        await model.refresh()
        #expect(Self.gids(model) == [900047, 900048, 900049, 900050, 900051])
        #expect(!model.isAfterJump)
        #expect(model.navigation == .cursor(next: "900051", previous: nil))
        #expect(model.summary == "Found 99 results, from 2024.")

        feed.answer(.first, makePage([900100]))
        await model.refresh()
        #expect(feed.calls.last == Call(.first, true))
        #expect(Self.gids(model) == [900100])
    }

    /// An offset (a jump or seek from a cursor, the Jump/Seek sheet's position) is a jump like `.seek`: pulling
    /// then loads the page before the one jumped to.
    @Test func offsetJumpBehavesLikeSeek() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900090], next: "900090"), feed: feed)
        let offset = ListPosition.offset(jump: nil, seek: "2024-01-01", from: .next("900090"))
        feed.answer(offset, makePage([900050, 900051], next: "900051", previous: "900050"))
        await model.jump(to: offset)
        #expect(feed.calls.last == Call(offset, true))
        #expect(model.isAfterJump)
        #expect(Self.gids(model) == [900050, 900051])
        #expect(model.navigation == .cursor(next: "900051", previous: "900050"))

        feed.answer(.previous("900050"), makePage([900048, 900049], next: "900049", previous: "900048"))
        await model.refresh()
        #expect(feed.calls.last == Call(.previous("900050"), true))
        #expect(Self.gids(model) == [900048, 900049, 900050, 900051])
        #expect(model.isAfterJump)
    }

    /// A failed jump keeps the list shown, with the failure as a refresh's.
    @Test func failedJumpKeepsTheList() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001], next: "900001"), feed: feed)
        feed.fail(.jump("3d"), EHNetworkError.issue(.tooManyRequests))
        await model.jump(to: .jump("3d"))
        #expect(Self.gids(model) == [900001])
        #expect(model.status == .loaded)
        #expect(model.refreshFailure == .siteIssue(.tooManyRequests))
        #expect(!model.isAfterJump)
    }

    /// A replacement that fails after another one was cancelled in flight (its status `.loading`) still finds the list
    /// shown: the items stay and the failure is a refresh's, never `.failed` over a list that is there.
    @Test func overlappingFailuresKeepTheShownList() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([900001], next: "900001"), feed: feed)

        // A jump in flight, then a pull to refresh that fails.
        let jumpGate = Gate()
        feed.answer(.seek("2024-01-01"), makePage([900050], next: "900050"), gate: jumpGate)
        let jump = Task { await model.jump(to: .seek("2024-01-01")) }
        #expect(await eventually { feed.calls.count == 2 })
        #expect(model.status == .loading)
        feed.fail(.first, EHNetworkError.transport(.timedOut))
        await model.refresh()
        #expect(model.status == .loaded)
        #expect(model.refreshFailure == .network)
        #expect(Self.gids(model) == [900001])
        jumpGate.open()
        await jump.value
        #expect(Self.gids(model) == [900001])
        #expect(model.status == .loaded)
        #expect(!model.isAfterJump)

        // Two jumps, the second fails.
        let firstGate = Gate()
        feed.answer(.seek("2024-02-01"), makePage([900060], next: "900060"), gate: firstGate)
        let first = Task { await model.jump(to: .seek("2024-02-01")) }
        #expect(await eventually { feed.calls.count == 4 })
        feed.fail(.jump("1d"), EHNetworkError.issue(.tooManyRequests))
        await model.jump(to: .jump("1d"))
        #expect(model.status == .loaded)
        #expect(model.refreshFailure == .siteIssue(.tooManyRequests))
        #expect(Self.gids(model) == [900001])
        firstGate.open()
        await first.value
        #expect(Self.gids(model) == [900001])
        #expect(model.status == .loaded)
    }

    // MARK: - Empty pages

    @Test func emptyResultIsNotAnError() async {
        let feed = ScriptedFeed()
        let model = await Self.loaded(makePage([], summary: "Found 0 results."), feed: feed)
        #expect(model.items.isEmpty)
        #expect(model.footer == .end)
        #expect(model.summary == "Found 0 results.")
        #expect(model.navigation == .none)
        #expect(feed.calls.count == 1)
        feed.answer(.first, makePage([900001]))
        await model.refresh()
        #expect(Self.gids(model) == [900001])
    }

    /// A page the site's filters (or later a local one) emptied, with a next page: that page loads by itself.
    @Test func pagesWithOnlyFilteredRowsContinue() async {
        let feed = ScriptedFeed()
        feed.answer(.first, makePage([], next: "a", summary: "Found 30 results.", filtered: 25))
        feed.answer(.next("a"), makePage([900001]))
        let model = GalleryListModel(feed: feed)
        await model.loadFirst()
        #expect(feed.calls == [Call(.first, false), Call(.next("a"), true)])
        #expect(Self.gids(model) == [900001])
        #expect(model.footer == .end)
        #expect(model.summary == "Found 30 results. Filtered 25 galleries from this page.")
    }

    @Test func threeEmptyPagesStopAtLoadMore() async {
        let feed = ScriptedFeed()
        feed.answer(.first, makePage([], next: "a", filtered: 25))
        feed.answer(.next("a"), makePage([], next: "b", filtered: 25))
        feed.answer(.next("b"), makePage([], next: "c", filtered: 25))
        feed.answer(.next("c"), makePage([900001], next: "d"))
        let model = GalleryListModel(feed: feed)
        await model.loadFirst()
        #expect(GalleryListModel.emptyPageLimit == 3)
        #expect(feed.calls == [Call(.first, false), Call(.next("a"), true), Call(.next("b"), true)])
        #expect(model.footer == .loadMore)
        #expect(model.status == .loaded)
        await model.loadMore()
        #expect(feed.calls.last == Call(.next("c"), true))
        #expect(feed.calls.count == 4)
        #expect(Self.gids(model) == [900001])
        #expect(model.footer == .none)
    }

    /// The page loaded by itself after an empty first page is dropped (cancelled): nothing on screen could ask for it
    /// again, so the list offers Load More instead of an empty end.
    @Test func droppedContinuationLeavesLoadMore() async {
        for error: any Error in [CancellationError(), EHNetworkError.cancelled] {
            let feed = ScriptedFeed()
            feed.answer(.first, makePage([], next: "a", filtered: 25))
            feed.fail(.next("a"), error)
            feed.answer(.next("a"), makePage([900001]))
            let model = GalleryListModel(feed: feed)
            await model.loadFirst()
            #expect(model.status == .loaded, Comment(rawValue: "\(error)"))
            #expect(model.items.isEmpty, Comment(rawValue: "\(error)"))
            #expect(model.footer == .loadMore, Comment(rawValue: "\(error)"))
            await model.loadMore()
            #expect(feed.calls == [Call(.first, false), Call(.next("a"), true), Call(.next("a"), true)])
            #expect(Self.gids(model) == [900001], Comment(rawValue: "\(error)"))
            #expect(model.footer == .end, Comment(rawValue: "\(error)"))
        }
    }

    // MARK: - Dropped answers

    /// C5: the page of an ended session is dropped without a word; a first load that showed nothing is idle again.
    @Test func endedSessionPagesAreDropped() async {
        let feed = ScriptedFeed()
        feed.fail(.first, EHNetworkError.sessionEnded)
        let model = GalleryListModel(feed: feed)
        await model.loadFirst()
        #expect(model.status == .idle)
        #expect(model.items.isEmpty)
        #expect(model.footer == .none)

        feed.answer(.first, makePage([900001], next: "a"))
        await model.loadFirst()
        #expect(model.status == .loaded)
        feed.fail(.next("a"), EHNetworkError.sessionEnded)
        await model.itemAppeared(Self.id(900001))
        #expect(Self.gids(model) == [900001])
        #expect(model.footer == .none)
        #expect(model.status == .loaded)
        feed.fail(.first, EHNetworkError.sessionEnded)
        await model.refresh()
        #expect(Self.gids(model) == [900001])
        #expect(model.refreshFailure == nil)
        #expect(model.status == .loaded)
        // The dropped position is asked for again.
        feed.answer(.next("a"), makePage([900002]))
        await model.itemAppeared(Self.id(900001))
        #expect(Self.gids(model) == [900001, 900002])
    }

    @Test func cancelledLoadsChangeNothing() async {
        for error: any Error in [CancellationError(), EHNetworkError.cancelled] {
            let feed = ScriptedFeed()
            feed.fail(.first, error)
            let model = GalleryListModel(feed: feed)
            await model.loadFirst()
            #expect(model.status == .idle, Comment(rawValue: "\(error)"))
            feed.answer(.first, makePage([900001], next: "a"))
            await model.loadFirst()
            feed.fail(.next("a"), error)
            await model.itemAppeared(Self.id(900001))
            #expect(model.footer == .none, Comment(rawValue: "\(error)"))
            feed.fail(.jump("1d"), error)
            await model.jump(to: .jump("1d"))
            #expect(model.status == .loaded, Comment(rawValue: "\(error)"))
            #expect(model.refreshFailure == nil, Comment(rawValue: "\(error)"))
            #expect(Self.gids(model) == [900001], Comment(rawValue: "\(error)"))
            #expect(!model.isAfterJump, Comment(rawValue: "\(error)"))
        }

        // A first load that a pull to refresh replaced: its late answer is dropped.
        let feed = ScriptedFeed()
        let gate = Gate()
        feed.answer(.first, makePage([900001]), gate: gate)
        feed.answer(.first, makePage([900002]))
        let model = GalleryListModel(feed: feed)
        let load = Task { await model.loadFirst() }
        #expect(await eventually { feed.calls.count == 1 })
        await model.refresh()
        #expect(Self.gids(model) == [900002])
        gate.open()
        await load.value
        #expect(Self.gids(model) == [900002])
        #expect(model.status == .loaded)
    }
}
