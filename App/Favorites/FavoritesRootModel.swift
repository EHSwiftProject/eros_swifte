import EHModels
import EHNetwork
import EHStore
import Foundation
import Observation

/// The pages of favorites.php (one folder, or all of them when `folder` is nil), through
/// `EHService.favorites(folder:search:position:order:site:refresh:)`: in the Compact view, then in `order`.
///
/// - Every page is handed to `onPage` (the root model takes the folders' names and the site's order from it).
/// - A page in another order than the one asked for is the site's, kept because the user declined to change it: the
///   feed asks for the pages after it in that order, so the same list does not ask again. The root model may set the
///   order too (`ask(in:)`), to keep every list on the order the site shows.
/// - `search` is sent as `f_search` (search Q2 searches the favorites with it).
/// - Once retired (`retire()`, its list was dropped) it asks the site nothing more: every call throws
///   `CancellationError` (dropped silently by the list), and a page that comes in afterwards is not reported.
@MainActor final class FavoritesFeed: ListFeed {
    /// The order the next page is asked in.
    private(set) var order: FavoritesOrder

    private let folder: Int?
    private let search: String?
    private let site: EHSite
    private let service: EHService
    private let onPage: @MainActor (GalleryListPage) -> Void
    private var isRetired = false

    init(
        folder: Int?, order: FavoritesOrder, site: EHSite, service: EHService, search: String? = nil,
        onPage: @escaping @MainActor (GalleryListPage) -> Void
    ) {
        self.folder = folder
        self.order = order
        self.site = site
        self.service = service
        self.search = search
        self.onPage = onPage
    }

    func page(at position: ListPosition, refresh: Bool) async throws -> ListPageResult {
        guard !isRetired else { throw CancellationError() }
        let result = try await service.favorites(
            folder: folder, search: search, position: position, order: order, site: site, refresh: refresh
        )
        guard !isRetired else { throw CancellationError() }
        // The root model sets the same order on every feed it keeps (`ask(in:)`, from `onPage`); the feed switches by
        // itself too, so a feed without a root model (search Q2's) does not ask again either.
        if let shown = result.page.favoritesOrder { order = shown }
        onPage(result.page)
        return result
    }

    /// Asks for the next pages in `order`.
    func ask(in order: FavoritesOrder) {
        self.order = order
    }

    /// The feed's list was dropped: nothing more is asked of the site, and nothing more is reported.
    func retire() {
        isRetired = true
    }
}

/// The local favorites could not be read: there is no user data store (`AppEnvironment.userData` could not be
/// opened), or reading it threw (`ListFailure.localFavoritesUnavailable(canRetry:)`).
nonisolated struct LocalFavoritesUnavailable: Error, Equatable {
    /// A read that threw (the store is there: a busy or failed read) may work next time; a store that never opened
    /// will not (it is opened once, at launch).
    let canRetry: Bool
}

/// The local favorites (`UserDataStore.localFavorites()`): all of them on the first page, newest first; every other
/// position is an empty page, so the list ends there. Never from the cache. Without a store, or when reading it
/// throws, every page throws `LocalFavoritesUnavailable` (one that can be tried again when a read threw): the list
/// says the favorites could not be loaded, as the gallery's groups do, rather than showing none (which would read as
/// if they were all gone).
struct LocalFavoritesFeed: ListFeed {
    /// Reads every local favorite; nil without a store.
    private let read: (@Sendable () async throws -> [GallerySummary])?

    init(store: UserDataStore?) {
        if let store {
            self.init(read: { @Sendable in try await store.localFavorites() })
        } else {
            self.init(read: nil)
        }
    }

    /// A feed over `read` instead of a store (tests: a read that throws).
    init(read: (@Sendable () async throws -> [GallerySummary])?) {
        self.read = read
    }

    func page(at position: ListPosition, refresh: Bool) async throws -> ListPageResult {
        guard let read else { throw LocalFavoritesUnavailable(canRetry: false) }
        var items: [GallerySummary] = []
        if position == .first {
            do {
                items = try await read()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LocalFavoritesUnavailable(canRetry: true)
            }
        }
        let page = GalleryListPage(
            items: items, skippedRowCount: 0, displayMode: nil, previousCursor: nil, nextCursor: nil, pageIndex: nil,
            pageCount: nil, resultSummary: nil, filteredCount: nil, similarityScanDisabled: false, favoriteFolders: [],
            favoritesOrder: nil
        )
        return ListPageResult(page: page, isFromCache: false)
    }
}

/// The favorites tab's lists (Flutter's favorites tab, favorite_tabbar_controller.dart): all favorites, one of the ten
/// folders, or the local favorites, with a list model kept per selection.
///
/// - Logged out only the local favorites are shown (`selection`); the selection picked is remembered either way
///   (`BrowsingState.favoritesSelection`).
/// - The folders' names and counts come from the latest favorites page (`folders`).
/// - The order: lists ask for `settings.favoritesOrder`. When the user declines to change the site's order, the order
///   the site showed is kept (`keptSiteOrder`): every list asks in it from then on, a list made later too, so nothing
///   is asked again until the order is picked again (`orderChanged()`) or the session's identity changes.
/// - Another identity (`updateSession(_:)`) drops every cloud list, the folders and the order
///   kept; the local list stays. A new order (`pick(_:)`, `orderChanged()`) drops the cloud lists and the order kept. A
///   dropped list is cancelled first and its feed retired, so it asks the site nothing more.
///   Dropping is observed (`listGeneration`): a page showing a cloud list draws again and gets a new one, whatever
///   else changed. Switching the selection keeps the lists of the others.
@MainActor @Observable final class FavoritesRootModel {
    /// Whether the session is logged in, as the last `updateSession(_:)` said.
    private(set) var isLoggedIn = false
    /// From the latest favorites page; nil until one arrives, and again after the identity changed.
    private(set) var folders: [FavoriteFolderSummary]?
    /// The site's order the user chose to keep (declined to change); nil when the lists are in the order asked for.
    private(set) var keptSiteOrder: FavoritesOrder?
    /// One more each time the cloud lists are dropped. `model(for:)` reads it for a cloud selection, so a view that
    /// shows a cloud list depends on it and draws again with a new list once the one it shows is gone, also when no
    /// other value it reads changed (another member before any page came).
    private(set) var listGeneration = 0

    @ObservationIgnored private let service: EHService
    @ObservationIgnored private let userData: UserDataStore?
    @ObservationIgnored private let settings: AppSettingsStore
    @ObservationIgnored private let site: EHSite
    /// The list of each cloud selection (all, a folder) with its feed.
    @ObservationIgnored private var cloud: [FavoritesSelection: (feed: FavoritesFeed, list: GalleryListModel)] = [:]
    @ObservationIgnored private var local: GalleryListModel?
    /// The session's identity last passed to `updateSession(_:)`; nil before the first.
    @ObservationIgnored private var session: SessionIdentity?

    init(service: EHService, userData: UserDataStore?, settings: AppSettingsStore, site: EHSite) {
        self.service = service
        self.userData = userData
        self.settings = settings
        self.site = site
    }

    /// The order the cloud lists are in: the site's while it is kept (`keptSiteOrder`), else the one picked
    /// (`settings.favoritesOrder`). The order menu ticks it, so it never ticks one order while the list shows another.
    var shownOrder: FavoritesOrder {
        keptSiteOrder ?? settings.settings.favoritesOrder
    }

    /// `.local` when logged out; else `BrowsingState.favoritesSelection`.
    var selection: FavoritesSelection {
        isLoggedIn ? settings.browsing.favoritesSelection : .local
    }

    /// Shows `selection` from now on (kept in the settings; a cloud one only once logged in).
    func select(_ selection: FavoritesSelection) {
        settings.browsing.favoritesSelection = selection
    }

    /// The list of `selection`: kept until it is dropped (see the type), so switching back shows it as it was.
    func model(for selection: FavoritesSelection) -> GalleryListModel {
        let folder: Int?
        switch selection {
        case .local:
            if let local { return local }
            let list = GalleryListModel(feed: LocalFavoritesFeed(store: userData))
            local = list
            return list
        case .all:
            folder = nil
        case .folder(let index):
            folder = index
        }
        // Read for its observation only: see `listGeneration`.
        _ = listGeneration
        if let cached = cloud[selection] { return cached.list }
        let feed = FavoritesFeed(
            folder: folder, order: keptSiteOrder ?? settings.settings.favoritesOrder, site: site, service: service
        ) { [weak self] page in
            self?.took(page)
        }
        let list = GalleryListModel(feed: feed)
        cloud[selection] = (feed, list)
        return list
    }

    /// `order` was picked in the order menu: it is written to `settings.favoritesOrder` and the cloud lists reload
    /// (`orderChanged()`) when it is another order, or the same one while the site's order is kept (so the lists ask
    /// for it again, and the user is asked again); the order already in force changes nothing.
    func pick(_ order: FavoritesOrder) {
        guard order != settings.settings.favoritesOrder || keptSiteOrder != nil else { return }
        settings.settings.favoritesOrder = order
        orderChanged()
    }

    /// `settings.favoritesOrder` was picked (changed, or picked again while the site's order is kept): the cloud lists
    /// and the order kept go, so the lists shown next ask in the order picked.
    func orderChanged() {
        dropCloudLists()
        keptSiteOrder = nil
    }

    /// The session's identity now (`AppEnvironment.sessionIdentity`; the root page passes every value, the first one
    /// included, which only sets `isLoggedIn`). Another identity than the last drops every cloud list, the folders and
    /// the order kept.
    func updateSession(_ identity: SessionIdentity) {
        let loggedIn = identity.memberID != nil
        if loggedIn != isLoggedIn { isLoggedIn = loggedIn }
        defer { session = identity }
        guard let session, session != identity else { return }
        dropCloudLists()
        folders = nil
        keptSiteOrder = nil
    }

    /// The page's title for `selection`: All Favorites, the folder's name (`Favorites <n>` until a page named it),
    /// Local Favorites.
    func title(for selection: FavoritesSelection) -> String {
        switch selection {
        case .all:
            return "All Favorites"
        case .folder(let index):
            guard let name = summary(ofFolder: index)?.name, !name.isEmpty else { return "Favorites \(index)" }
            return name
        case .local:
            return "Local Favorites"
        }
    }

    /// The title menu's item for `selection`: its title, with the count in parentheses once a page gave it (All
    /// Favorites: the sum of the folders'); a folder not named yet, and the local favorites, without one.
    func menuTitle(for selection: FavoritesSelection) -> String {
        let title = title(for: selection)
        switch selection {
        case .all:
            guard let folders else { return title }
            return "\(title) (\(folders.reduce(0) { $0 + $1.count }))"
        case .folder(let index):
            guard let folder = summary(ofFolder: index), !folder.name.isEmpty else { return title }
            return "\(title) (\(folder.count))"
        case .local:
            return title
        }
    }

    // MARK: - Private

    private func summary(ofFolder index: Int) -> FavoriteFolderSummary? {
        folders?.first { $0.index == index }
    }

    /// A page of a cloud list came in: its folders, and the site's order it shows. An order other than the one picked
    /// is the one the user kept; every list asks in the order the site showed from now on.
    private func took(_ page: GalleryListPage) {
        if !page.favoriteFolders.isEmpty, page.favoriteFolders != folders { folders = page.favoriteFolders }
        guard let shown = page.favoritesOrder else { return }
        let kept = shown == settings.settings.favoritesOrder ? nil : shown
        if kept != keptSiteOrder { keptSiteOrder = kept }
        for entry in cloud.values { entry.feed.ask(in: shown) }
    }

    /// Cancels every cloud list and retires its feed, then lets them go; `listGeneration` tells the views.
    private func dropCloudLists() {
        for entry in cloud.values {
            entry.feed.retire()
            entry.list.cancel()
        }
        cloud = [:]
        listGeneration += 1
    }
}
