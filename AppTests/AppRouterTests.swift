import EHModels
import EHNetwork
import SwiftUI
import Testing

@testable import Eros

/// `AppRouter` and `AppRoute`: one navigation path per tab.
@MainActor @Suite struct AppRouterTests {
    private static let gallery = AppRoute.gallery(GalleryID(gid: 1, token: "0000000000"), .eh)

    @Test func startsOnTheGivenTab() {
        #expect(AppRouter().selectedTab == .gallery)
        #expect(AppRouter(selectedTab: .toplists).selectedTab == .toplists)
    }

    @Test func pushGoesOntoTheSelectedTab() {
        let router = AppRouter()
        router.selectedTab = .toplists
        router.push(Self.gallery)
        #expect(router.path(for: .toplists).wrappedValue.count == 1)
        for tab in AppTab.allCases where tab != .toplists {
            #expect(router.path(for: tab).wrappedValue.isEmpty)
        }
    }

    /// The results of an image search, made up.
    private static let imageSearchResults = ImageSearchResults(
        result: ImageLookupResult(resultURL: URL(string: "https://e-hentai.org/?f_shash=0")!, page: GalleryListPage(
            items: [], skippedRowCount: 0, displayMode: nil, previousCursor: nil, nextCursor: nil, pageIndex: nil,
            pageCount: nil, resultSummary: nil, filteredCount: nil, similarityScanDisabled: false,
            favoriteFolders: [], favoritesOrder: nil
        )),
        site: .eh
    )

    /// The image search's pages go by value onto the stack of the tab given, the one selected when the user tapped
    /// (search Q5): its path gets one more, the other tabs' stay as they were.
    @Test func imageSearchPagesGoOntoTheSelectedTab() {
        let router = AppRouter()
        router.push(Self.gallery)
        router.selectedTab = .favorites
        router.push(.search("language:chinese", .eh))
        router.push(ImageSearchRoute.search(.eh), onto: router.selectedTab)
        #expect(router.path(for: .favorites).wrappedValue.count == 2)
        router.push(ImageSearchRoute.results(Self.imageSearchResults), onto: router.selectedTab)
        #expect(router.path(for: .favorites).wrappedValue.count == 3)
        #expect(router.path(for: .gallery).wrappedValue.count == 1)
        for tab in AppTab.allCases where tab != .favorites && tab != .gallery {
            #expect(router.path(for: tab).wrappedValue.isEmpty)
        }
    }

    /// A search's results go to the tab the search was started on, even when another tab was selected meanwhile (the
    /// user switched tabs, or an external link opened elsewhere).
    @Test func imageSearchResultsGoToTheTabTheSearchStartedOn() {
        let router = AppRouter()
        router.selectedTab = .gallery
        router.push(ImageSearchRoute.search(.eh), onto: router.selectedTab)
        let started = router.selectedTab
        router.selectedTab = .toplists
        router.push(Self.gallery)
        router.push(ImageSearchRoute.results(Self.imageSearchResults), onto: started)
        #expect(router.path(for: .gallery).wrappedValue.count == 2)
        #expect(router.path(for: .toplists).wrappedValue.count == 1)
        #expect(router.selectedTab == .toplists)
    }

    @Test func pathsAreKeptPerTab() {
        let router = AppRouter()
        router.push(Self.gallery)
        router.push(.search("language:chinese", .eh))
        router.selectedTab = .favorites
        router.push(.imagePage(imageKey: "0000000000", gid: 1, page: 2, site: .ex))
        router.selectedTab = .gallery
        #expect(router.path(for: .gallery).wrappedValue.count == 2)
        #expect(router.path(for: .favorites).wrappedValue.count == 1)

        // The binding writes the tab's path.
        router.path(for: .download).wrappedValue.append(Self.gallery)
        #expect(router.path(for: .download).wrappedValue.count == 1)
        router.path(for: .gallery).wrappedValue = NavigationPath()
        #expect(router.path(for: .gallery).wrappedValue.isEmpty)
        #expect(router.path(for: .favorites).wrappedValue.count == 1)
    }

    @Test func routesCompareByValue() {
        func list(_ title: String) -> AppRoute {
            .list(ListQuery(source: .front, search: "language:chinese", excludedCategories: 5), title: title, site: .eh)
        }
        #expect(list("Chinese") == list("Chinese"))
        #expect(list("Chinese").hashValue == list("Chinese").hashValue)
        #expect(list("Chinese") != list("Other"))
        #expect(AppRoute.search("a", .eh) != AppRoute.search("a", .ex))
        #expect(Self.gallery == AppRoute.gallery(GalleryID(gid: 1, token: "0000000000"), .eh))
    }

    @Test func pagesOfTabsNowShownAreDropped() {
        let router = AppRouter()
        // Gallery: a route, History's page, then a route pushed from that page (as a NavigationLink does).
        router.push(Self.gallery)
        router.push(TabPage(tab: .history), onto: .gallery)
        router.path(for: .gallery).wrappedValue.append(AppRoute.search("a", .eh))
        // Favorites: Download's page. Toplists: History's page and a route above it.
        router.push(TabPage(tab: .download), onto: .favorites)
        router.push(TabPage(tab: .history), onto: .toplists)
        router.path(for: .toplists).wrappedValue.append(Self.gallery)

        router.dropTabPages(of: [.gallery, .history, .toplists, .settings])
        #expect(router.path(for: .gallery).wrappedValue.count == 1)
        #expect(router.path(for: .toplists).wrappedValue.isEmpty)
        // Download is still hidden: its page stays.
        #expect(router.path(for: .favorites).wrappedValue.count == 1)

        router.dropTabPages(of: [.download])
        #expect(router.path(for: .favorites).wrappedValue.isEmpty)
    }

    @Test func aPagePoppedMeanwhileIsForgotten() {
        let router = AppRouter()
        router.push(TabPage(tab: .history), onto: .gallery)
        // The system's back button empties the path; then a route takes the same place.
        router.path(for: .gallery).wrappedValue = NavigationPath()
        router.push(Self.gallery)

        router.dropTabPages(of: [.history])
        #expect(router.path(for: .gallery).wrappedValue.count == 1)
    }

    @Test func aTabPageGoesOntoTheGivenTab() {
        let router = AppRouter()
        router.selectedTab = .favorites
        router.push(TabPage(tab: .history), onto: .gallery)
        #expect(router.path(for: .gallery).wrappedValue.count == 1)
        #expect(router.path(for: .favorites).wrappedValue.isEmpty)
    }
}
