import EHModels
import EHNetwork
import Foundation
import Observation

/// Where a list's first page (or the page jumped to) stands.
nonisolated enum ListStatus: Equatable {
    /// Nothing asked yet, or the first load was dropped (cancelled, or its session ended).
    case idle
    /// The list is being replaced: the first load, a reload or a jump. Items shown so far stay until the page comes.
    case loading
    /// The list is shown; it may be empty (`No Galleries` with the site's summary).
    case loaded
    /// Replacing the list failed while nothing was shown.
    case failed(ListFailure)
}

/// What the end of a list shows.
nonisolated enum ListFooter: Equatable {
    /// Nothing: the next page loads when the last item appears (`GalleryListModel.itemAppeared(_:lookahead:)`).
    case none
    /// The next page is on its way.
    case loading
    /// The next page failed; only `GalleryListModel.retryMore()` asks for it again.
    case failed(ListFailure)
    /// `GalleryListModel.emptyPageLimit` pages in a row brought nothing new: the Load More button (`loadMore()`).
    case loadMore
    /// There is no next page.
    case end
}

/// Where a list can go from what it holds: a cursor list by the last page's next cursor and the first page's previous
/// one, a numbered list (toplists) by the index of its last page.
nonisolated enum ListNavigation: Equatable {
    case none
    case cursor(next: String?, previous: String?)
    case numbered(index: Int, count: Int)
}

/// A gallery list over a `ListFeed`, apart from any view: the first page (from the cache when it has it, then asked of
/// the site again in the background), pull to refresh, reload, jumps, the next pages and their failures.
///
/// - One task replaces the list at a time (the first page, a refresh, a reload, a jump, a previous page after a jump):
///   a new one cancels the one running, whose answer is then dropped. One task loads next pages at a time.
/// - Next pages: a cursor list asks for `.next(cursor)` of its last page, a numbered one (both `pageIndex` and
///   `pageCount` known) for `.page(index + 1)`; always from the site. A position in flight or loaded is not asked for
///   again (a page that leads back to a loaded cursor ends the list); a failed one only by `retryMore()`.
/// - A page that brings no new item (all rows filtered, or already shown) while there is a next page is followed by
///   that page by itself, up to `emptyPageLimit` such pages in a row; then the list stops at `ListFooter.loadMore`,
///   and `loadMore()` starts the count again.
/// - Failures are `ListFailure`s. One that `ListFailure(_:)` drops (a cancellation, the page of an ended session)
///   changes nothing: the list stays as it was (a first load that showed nothing is idle again).
@MainActor @Observable final class GalleryListModel {
    /// The pages in a row that may bring nothing new before the list stops at `ListFooter.loadMore`.
    static let emptyPageLimit = 3

    /// The model's own, for its life: a page gives a new list a new view by it (`.id(model.id)`), never by the
    /// object's address, which a later model may be given once this one is gone.
    let id = UUID()

    private(set) var items: [GallerySummary] = []
    private(set) var status: ListStatus = .idle
    private(set) var footer: ListFooter = .none
    /// A failed pull to refresh while items are shown (a failed jump while the list is shown too): they stay. Cleared
    /// by the next page that replaces the list or comes before it.
    private(set) var refreshFailure: ListFailure?
    /// The silent refresh after a first page that came from the cache is out.
    private(set) var isRefreshingInBackground = false
    /// `ListSummary.text` of the first (or jumped-to) page.
    private(set) var summary: String?
    /// Updated with every page.
    private(set) var navigation: ListNavigation = .none
    /// The list starts at a page jumped to (any position but `.first`): pulling to refresh brings the page before it
    /// (a cursor list) or that page again (a numbered list), until a cursor list reaches its first page.
    private(set) var isAfterJump = false
    /// One more on every `scrollToTop(refreshing:)`; the view scrolls to the top when it changes.
    private(set) var scrollToTopSignal = 0

    @ObservationIgnored private let feed: any ListFeed
    /// The task replacing the list, if any; see `replace(_:)`.
    @ObservationIgnored private var replacing: Task<Void, Never>?
    /// One more for every replacing task: a task whose turn has passed changes nothing.
    @ObservationIgnored private var replaceTurn = 0
    /// The task loading next pages, if any.
    @ObservationIgnored private var appending: Task<Void, Never>?
    /// One more whenever the list is replaced: a next page asked for the list before is dropped.
    @ObservationIgnored private var listVersion = 0
    /// One more on every page taken in: the silent refresh is dropped when another page came in meanwhile.
    @ObservationIgnored private var contentVersion = 0
    /// The next-page positions in flight or loaded since the list was replaced.
    @ObservationIgnored private var requested: Set<ListPosition> = []
    /// The next-page position that failed (`ListFooter.failed`), for `retryMore()`.
    @ObservationIgnored private var failedPosition: ListPosition?
    /// Pages in a row that brought nothing new.
    @ObservationIgnored private var emptyRun = 0
    /// The gids in `items`.
    @ObservationIgnored private var gids: Set<Int> = []
    /// The list (maybe empty) is on screen: a page took its place since the model was made or cleared. A failed
    /// replacement then leaves it and sets `refreshFailure`, however many replacements overlapped (each one in flight
    /// shows `.loading`, so the status before the latest one does not tell).
    @ObservationIgnored private var isShowingList = false
    @ObservationIgnored private var bounds = Bounds()

    /// Where the pages of the list begin and end.
    private struct Bounds {
        /// A cursor list: the first page's `prev` and the last page's `next`.
        var previous: String?
        var next: String?
        /// A numbered list: the first and last pages' indexes, and how many pages there are.
        var firstIndex: Int?
        var lastIndex: Int?
        var count: Int?
    }

    /// What replaces the list, or comes before it.
    private enum Replacement {
        /// `.first`, from the cache when it has it (then asked of the site again in the background).
        case first
        /// Pull to refresh: `.first`, or the page jumped to of a numbered list, from the site; the list stays shown
        /// meanwhile.
        case refresh(ListPosition)
        /// `.first` from the site, after everything was dropped.
        case reload
        /// `position` from the site.
        case jump(ListPosition)
        /// The page before the first one (after a jump), put in front.
        case previous(String)
    }

    init(feed: any ListFeed) {
        self.feed = feed
    }

    // MARK: - Replacing the list

    /// The first page, with `refresh: false`: an answer from the cache is shown, then asked of the site again in the
    /// background (`isRefreshingInBackground`); the site's answer takes its place unless pages came in meanwhile. A
    /// first page from the site is not asked for twice. Nothing happens once the list is loading or loaded.
    func loadFirst() async {
        switch status {
        case .loading, .loaded: return
        case .idle, .failed: break
        }
        await replace(.first)
    }

    /// Pull to refresh, from the site. After a jump: the page before the first one, put in front (a cursor list; once
    /// it has none before it, the list is no longer after a jump), or the page jumped to again (a numbered list).
    /// Otherwise the first page. A failure while the list is shown leaves it and sets `refreshFailure`.
    func refresh() async {
        if isAfterJump {
            if let index = bounds.firstIndex, bounds.count != nil {
                await replace(.refresh(.page(index)))
                return
            }
            if let previous = bounds.previous {
                await replace(.previous(previous))
                return
            }
        }
        await replace(.refresh(.first))
    }

    /// Drops everything, then the first page from the site (the session changed, Try Again).
    func reload() async {
        clear()
        await replace(.reload)
    }

    /// The page at `position`, from the site, in place of the list; `summary` follows it. Any position but `.first`
    /// puts the list after a jump. A `.page(n)` outside `0..<count` of a numbered list (or below 0) sends nothing.
    func jump(to position: ListPosition) async {
        if case .page(let number) = position {
            guard number >= 0 else { return }
            if let count = bounds.count, number >= count { return }
        }
        await replace(.jump(position))
    }

    /// `scrollToTopSignal` goes up by one; `refreshing`: then `refresh()`.
    func scrollToTop(refreshing: Bool) async {
        scrollToTopSignal += 1
        if refreshing { await refresh() }
    }

    /// Cancels the task replacing the list and the one loading next pages, if any: for a model that is let go (the
    /// toplists tab when another toplist is picked). A request they wait for is cancelled, and its failure dropped as
    /// any cancellation is (`ListFailure(_:)`): the list stays as it was, a first load that showed nothing is idle
    /// again. A page that came before the cancellation is still taken.
    func cancel() {
        replacing?.cancel()
        appending?.cancel()
    }

    // MARK: - Next pages

    /// The item `id` is on screen: when it is one of the last `lookahead` items, the next page (once).
    func itemAppeared(_ id: GalleryID, lookahead: Int = 1) async {
        guard status == .loaded, footer == .none, appending == nil else { return }
        guard let index = items.lastIndex(where: { $0.id == id }), index >= items.count - max(lookahead, 1) else {
            return
        }
        guard let position = nextPosition, !requested.contains(position) else { return }
        await append(from: position)
    }

    /// The next page that failed, again.
    func retryMore() async {
        guard case .failed = footer, appending == nil, let position = failedPosition else { return }
        await append(from: position)
    }

    /// The Load More button: the next page, counting pages that bring nothing new from 0 again.
    func loadMore() async {
        guard footer == .loadMore, appending == nil, let position = nextPosition, !requested.contains(position) else {
            return
        }
        emptyRun = 0
        await append(from: position)
    }

    // MARK: - Private: replacing

    /// Runs `replacement` as the one replacing task (cancelling the one running) and waits for it. The status it
    /// shows meanwhile is set at once: `.loading`, except for a refresh of a list that is shown (`.loaded`, also when
    /// it cancels a jump in flight).
    private func replace(_ replacement: Replacement) async {
        replacing?.cancel()
        replaceTurn += 1
        let turn = replaceTurn
        let before = status
        isRefreshingInBackground = false
        switch replacement {
        case .first, .reload, .jump: status = .loading
        case .refresh, .previous: status = isShowingList ? .loaded : .loading
        }
        let task = Task { await self.run(replacement, turn: turn, before: before) }
        replacing = task
        await task.value
        if replaceTurn == turn { replacing = nil }
    }

    private func run(_ replacement: Replacement, turn: Int, before: ListStatus) async {
        let (position, refresh): (ListPosition, Bool) = switch replacement {
        case .first: (.first, false)
        case .refresh(let target), .jump(let target): (target, true)
        case .reload: (.first, true)
        case .previous(let cursor): (.previous(cursor), true)
        }
        let result: ListPageResult
        do {
            result = try await feed.page(at: position, refresh: refresh)
        } catch {
            guard turn == replaceTurn else { return }
            fail(error, before: before)
            return
        }
        guard turn == replaceTurn else { return }
        if case .previous = replacement {
            prepend(result.page)
            return
        }
        var added = adopt(result.page, afterJump: position != .first)
        if case .first = replacement, result.isFromCache {
            // Shown from the cache: asked of the site again, and that answer takes its place unless another page came
            // in meanwhile (it would be dropped with the cached page).
            isRefreshingInBackground = true
            let shown = contentVersion
            // Silent: a failure is dropped and the page from the cache stays (index §7; Flutter
            // custom_sublist_controller.dart:39-48 drops it too).
            let fresh = try? await feed.page(at: .first, refresh: true)
            guard turn == replaceTurn else { return }
            isRefreshingInBackground = false
            guard shown == contentVersion else { return }
            if let fresh { added = adopt(fresh.page, afterJump: false) }
        }
        // Nothing on screen could ask for this page again: dropped, it leaves the Load More button.
        if let next = step(after: added) { await append(from: next, restoring: (.loadMore, nil)) }
    }

    /// After a replacing task failed. While the list is shown (`isShowingList`) it stays `.loaded`, and a failure that
    /// is not dropped sets `refreshFailure`. Otherwise a dropped one leaves the status from before (`before`; a load
    /// that showed nothing and was cancelled in flight is idle), and any other one fails the list.
    private func fail(_ error: any Error, before: ListStatus) {
        let failure = ListFailure(error)
        if isShowingList {
            status = .loaded
            if let failure { refreshFailure = failure }
        } else if let failure {
            status = .failed(failure)
        } else {
            status = before == .loading ? .idle : before
        }
    }

    /// `page` as the whole list; returns how many items it brought. Next pages of the list before are dropped.
    @discardableResult
    private func adopt(_ page: GalleryListPage, afterJump: Bool) -> Int {
        appending?.cancel()
        appending = nil
        listVersion += 1
        contentVersion += 1
        requested = []
        failedPosition = nil
        emptyRun = 0
        gids = []
        items = page.items.filter { gids.insert($0.id.gid).inserted }
        if let index = page.pageIndex, let count = page.pageCount {
            bounds = Bounds(firstIndex: index, lastIndex: index, count: count)
        } else {
            bounds = Bounds(previous: page.previousCursor, next: page.nextCursor)
        }
        summary = ListSummary.text(resultSummary: page.resultSummary, filteredCount: page.filteredCount)
        isAfterJump = afterJump
        refreshFailure = nil
        isShowingList = true
        status = .loaded
        footer = nextPosition == nil ? .end : .none
        updateNavigation()
        return items.count
    }

    /// The page before the first one, put in front: its `prev` is the list's now; without one the list is no longer
    /// after a jump.
    private func prepend(_ page: GalleryListPage) {
        let added = page.items.filter { gids.insert($0.id.gid).inserted }
        if !added.isEmpty { items = added + items }
        contentVersion += 1
        bounds.previous = page.previousCursor
        if page.previousCursor == nil { isAfterJump = false }
        refreshFailure = nil
        status = .loaded
        updateNavigation()
    }

    /// Everything dropped, nothing asked: the state of a new model.
    private func clear() {
        cancel()
        appending = nil
        listVersion += 1
        contentVersion += 1
        requested = []
        failedPosition = nil
        emptyRun = 0
        gids = []
        items = []
        bounds = Bounds()
        summary = nil
        isAfterJump = false
        refreshFailure = nil
        isRefreshingInBackground = false
        footer = .none
        isShowingList = false
        status = .idle
        navigation = .none
    }

    // MARK: - Private: next pages

    /// The next page's position, if the list has one: `.page(last + 1)` below the count of a numbered list, else
    /// `.next(cursor)` of the last page.
    private var nextPosition: ListPosition? {
        if let last = bounds.lastIndex, let count = bounds.count {
            return last + 1 < count ? .page(last + 1) : nil
        }
        return bounds.next.map(ListPosition.next)
    }

    /// After a page that brought `added` new items: the footer, and the next page to load by itself, if any (pages
    /// that bring nothing new, up to `emptyPageLimit` in a row).
    private func step(after added: Int) -> ListPosition? {
        guard let next = nextPosition, !requested.contains(next) else {
            footer = .end
            return nil
        }
        guard added == 0 else {
            emptyRun = 0
            footer = .none
            return nil
        }
        emptyRun += 1
        guard emptyRun < Self.emptyPageLimit else {
            footer = .loadMore
            return nil
        }
        return next
    }

    /// Loads next pages from `start` as the one appending task (and waits for it); the footer shows it at once.
    /// `restore`: what a dropped first page leaves; nil, the footer and failed position as they are now (a page the
    /// user asked for).
    private func append(
        from start: ListPosition, restoring restore: (footer: ListFooter, failed: ListPosition?)? = nil
    ) async {
        let restore = restore ?? (footer: footer, failed: failedPosition)
        footer = .loading
        let task = Task { await self.runAppend(from: start, restoring: restore) }
        appending = task
        await task.value
        if appending == task { appending = nil }
    }

    /// The page at `start` and, while pages bring nothing new, the ones after it (`step(after:)`). A failure stops at
    /// `ListFooter.failed`; one that is dropped leaves `restore` for the first page (the footer from before a page the
    /// user asked for; the Load More button for one the list loaded by itself), and the Load More button for the
    /// pages after it.
    private func runAppend(from start: ListPosition, restoring restore: (footer: ListFooter, failed: ListPosition?)) async {
        let version = listVersion
        var position = start
        var restore = restore
        while true {
            requested.insert(position)
            failedPosition = nil
            footer = .loading
            let result: ListPageResult
            do {
                result = try await feed.page(at: position, refresh: true)
            } catch {
                guard version == listVersion else { return }
                requested.remove(position)
                if let failure = ListFailure(error) {
                    failedPosition = position
                    footer = .failed(failure)
                } else {
                    footer = restore.footer
                    failedPosition = restore.failed
                }
                return
            }
            guard version == listVersion else { return }
            let added = take(result.page, at: position)
            guard let next = step(after: added) else { return }
            position = next
            restore = (.loadMore, nil)
        }
    }

    /// A next page at the end of the list; returns how many new items it brought.
    private func take(_ page: GalleryListPage, at position: ListPosition) -> Int {
        let added = page.items.filter { gids.insert($0.id.gid).inserted }
        if !added.isEmpty { items += added }
        contentVersion += 1
        if case .page(let number) = position {
            bounds.lastIndex = page.pageIndex ?? number
            if let count = page.pageCount { bounds.count = count }
        } else {
            bounds.next = page.nextCursor
        }
        updateNavigation()
        return added.count
    }

    private func updateNavigation() {
        if let index = bounds.lastIndex, let count = bounds.count {
            navigation = .numbered(index: index, count: count)
        } else if bounds.next != nil || bounds.previous != nil {
            navigation = .cursor(next: bounds.next, previous: bounds.previous)
        } else {
            navigation = .none
        }
    }
}
