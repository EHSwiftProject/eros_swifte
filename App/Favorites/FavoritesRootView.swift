import EHModels
import EHNetwork
import SwiftUI
import UIKit

extension FavoritesSelection {
    /// The color of the title menu item's heart (Flutter `ThemeColors.favColor`: `a`, the folder's, `l`).
    var heartRGB: ListRGB {
        switch self {
        case .all: FavoriteSlotColors.all
        case .folder(let index): FavoriteSlotColors.rgb(for: index)
        case .local: FavoriteSlotColors.local
        }
    }

    /// The title menu item's heart: `heart.fill` in `heartRGB`, drawn as it is (`alwaysOriginal`), since the system
    /// menu draws a template image in the menu's own color.
    var heartImage: UIImage {
        let heart = UIImage(systemName: "heart.fill") ?? UIImage()
        return heart.withTintColor(heartRGB.uiColor, renderingMode: .alwaysOriginal)
    }

    /// The suffix of the title menu item's identifier (`favorites.menu.all`, `.0`…`.9`, `.local`).
    var menuIdentifier: String {
        switch self {
        case .all: "all"
        case .folder(let index): String(index)
        case .local: "local"
        }
    }
}

/// The favorites tab's root page (Flutter's favorites tab): the list of the favorites picked (`FavoritesRootModel`),
/// titled with its name, in the list style of the settings, with the list's jumps in the toolbar (`listJumpControls`,
/// B5).
///
/// - Logged out: only the local favorites, titled `Local Favorites`, with no title menu and no order.
/// - Logged in: the title menu (`toolbarTitleMenu`, M2 index §7) picks All Favorites, one of the ten folders or Local
///   Favorites, each a `Label` with a heart in its color and the count once a page gave it (items
///   `favorites.menu.all|<0-9>|local`; on iOS 27.2 the system menu drops the identifiers). The
///   cloud lists also get the order menu (`favorites.order`: Use Favorited, Use Posted, ticking the order the list is
///   in, `FavoritesRootModel.shownOrder`), and, while the site's order is kept, a line above the list saying so (clear
///   of the Duo's fold, its background across).
/// - A double reselect of the favorites tab scrolls the list shown to the top and refreshes it
///   (`refreshesOnDoubleReselect(_:model:)`); a single one is left to the system (`TabReselection`).
/// - A change of the session's identity drops the cloud lists (`FavoritesRootModel.updateSession(_:)`);
///   logging in or out switches between the cloud and the local favorites.
/// - The toolbar's Search item (`favorites.search`, search Q2) opens the search page: in the favorites scope, on the
///   folder shown or all of them, while a cloud list is shown (logged in); in the gallery scope with the local
///   favorites.
///
/// The page is one accessibility container, so the identifier `TabRootContent` gives it (`favorites.root`) stays on
/// the page while the list's own identifiers stay on its parts.
struct FavoritesRootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.browsingSite) private var site

    var body: some View {
        FavoritesPage(environment: environment, site: site)
            .id(site)
            .accessibilityElement(children: .contain)
    }
}

/// The page over its model. The model is made once, with the page (`State(initialValue:)` needs the store, the settings
/// and the service, which only the environment has, so this view takes them from its parent), and starts from the
/// session's identity now, so a logged-in page does not show the local favorites first.
private struct FavoritesPage: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.browsingSite) private var site
    @State private var favorites: FavoritesRootModel

    init(environment: AppEnvironment, site: EHSite) {
        let favorites = FavoritesRootModel(
            service: environment.service, userData: environment.userData, settings: environment.settings, site: site
        )
        favorites.updateSession(environment.sessionIdentity)
        _favorites = State(initialValue: favorites)
    }

    var body: some View {
        let selection = favorites.selection
        let model = favorites.model(for: selection)
        GalleryListView(model: model, style: environment.settings.settings.listStyle)
            .listJumpControls(model)
            .id(model.id)
            .safeAreaInset(edge: .top, spacing: 0) {
                keptOrderNote(for: selection)
            }
            .navigationTitle(favorites.title(for: selection))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if favorites.isLoggedIn, selection != .local {
                    ToolbarItem(placement: .primaryAction) {
                        orderMenu
                    }
                }
            }
            .titleMenu(isShown: favorites.isLoggedIn) {
                titleMenu
            }
            .searchEntry(identifier: "favorites.search") {
                searchRequest(for: selection)
            }
            .onChange(of: environment.sessionIdentity, initial: true) { _, identity in
                favorites.updateSession(identity)
            }
            .refreshesOnDoubleReselect(.favorites) {
                favorites.model(for: favorites.selection)
            }
    }

    /// The search the Search item opens: the folder shown, or all favorites, while a cloud list is shown (`selection`
    /// is the local favorites while logged out); the gallery scope with the local favorites.
    private func searchRequest(for selection: FavoritesSelection) -> SearchRequest {
        switch selection {
        case .all: SearchRequest(scope: .favorites, favoritesFolder: nil, site: site)
        case .folder(let index): SearchRequest(scope: .favorites, favoritesFolder: index, site: site)
        case .local: SearchRequest(scope: .gallery, site: site)
        }
    }

    // MARK: - Title menu

    private var titleMenu: some View {
        Picker("Favorites", selection: selection) {
            menuItem(.all)
            ForEach(0..<10, id: \.self) { index in
                menuItem(.folder(index))
            }
            menuItem(.local)
        }
    }

    private func menuItem(_ item: FavoritesSelection) -> some View {
        Label {
            Text(favorites.menuTitle(for: item))
        } icon: {
            Image(uiImage: item.heartImage)
        }
        .tag(item)
        .accessibilityIdentifier("favorites.menu.\(item.menuIdentifier)")
    }

    /// The favorites shown, as the title menu's picker sets it.
    private var selection: Binding<FavoritesSelection> {
        let favorites = favorites
        return Binding {
            favorites.selection
        } set: { selection in
            favorites.select(selection)
        }
    }

    // MARK: - Order

    private var orderMenu: some View {
        Menu {
            Picker("Favorites Order", selection: order) {
                Text("Use Favorited").tag(FavoritesOrder.favoritedTime)
                Text("Use Posted").tag(FavoritesOrder.postedTime)
            }
        } label: {
            Label("Favorites Order", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("favorites.order")
    }

    /// The order the list is in (`FavoritesRootModel.shownOrder`: the site's while it is kept), as the order menu's
    /// picker ticks it; a pick goes to the model, which decides what it reloads (`FavoritesRootModel.pick(_:)`). While
    /// the site's order is kept, the user's own order is the other item, so picking it always changes the selection.
    private var order: Binding<FavoritesOrder> {
        let favorites = favorites
        return Binding {
            favorites.shownOrder
        } set: { order in
            favorites.pick(order)
        }
    }

    /// While the site's order is kept: a line above a cloud list saying which order it is in.
    @ViewBuilder private func keptOrderNote(for selection: FavoritesSelection) -> some View {
        if selection != .local, let kept = favorites.keptSiteOrder {
            (kept == .postedTime
                ? Text("Sorted by posted time; the site setting was not changed.")
                : Text("Sorted by favorited time; the site setting was not changed."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .keepsClearOfFold(alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("favorites.keptOrder")
        }
    }
}
