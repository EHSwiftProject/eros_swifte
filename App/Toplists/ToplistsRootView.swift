import EHModels
import EHNetwork
import Observation
import SwiftUI

nonisolated extension ToplistPeriod {
    /// The toplist's name (Flutter's `tolist_*` strings, in English): the page's title and its title menu's item.
    var title: String {
        switch self {
        case .yesterday: "Yesterday"
        case .month: "Past Month"
        case .year: "Past Year"
        case .allTime: "All-Time"
        }
    }
}

/// The toplist shown on the toplists tab and its one list: picking another toplist remembers it
/// (`BrowsingState.toplistPeriod`), cancels what the old list has in flight (`GalleryListModel.cancel()`) and makes a
/// new list. No list is kept for the toplists not shown: the old one is let go, and its tasks
/// end once their cancelled requests have, so a change of the session's identity needs nothing here
/// (`GalleryListView` reloads the list shown).
///
/// Every toplist is asked of E-Hentai (`QueryFeed` on `.eh`), whatever the browsing site: toplist.php is only there,
/// so its Compact notice, throttle and cache are E-Hentai's (Flutter request.dart:56). The list takes no category
/// filter and no search (`ListQuery.url(for:)` leaves them out of a toplist anyway).
@MainActor @Observable final class ToplistsRootModel {
    private(set) var period: ToplistPeriod
    /// The list of `period`; a new one whenever another toplist is picked.
    private(set) var list: GalleryListModel

    @ObservationIgnored private let settings: AppSettingsStore
    @ObservationIgnored private let service: EHService

    /// Opens on the toplist last picked (Yesterday at first).
    init(settings: AppSettingsStore, service: EHService) {
        self.settings = settings
        self.service = service
        let period = settings.browsing.toplistPeriod
        self.period = period
        list = Self.makeList(period, service: service)
    }

    /// Shows `period`, remembered for the next launch, with a new list, after cancelling the old list's requests in
    /// flight; the toplist shown keeps its list.
    func select(_ period: ToplistPeriod) {
        guard period != self.period else { return }
        self.period = period
        settings.browsing.toplistPeriod = period
        list.cancel()
        list = Self.makeList(period, service: service)
    }

    private static func makeList(_ period: ToplistPeriod, service: EHService) -> GalleryListModel {
        GalleryListModel(feed: QueryFeed(query: ListQuery(source: .toplist(period)), site: .eh, service: service))
    }
}

/// The toplists tab's root page (Flutter's toplist view): the list of the toplist picked, titled with its name, in the
/// list style of the settings, with the list's page jump in the toolbar (`listJumpControls`, B5).
///
/// - The title menu (`toolbarTitleMenu`, M2 index §7) picks the toplist (`Toplist`: Yesterday, Past Month, Past Year,
///   All-Time; items `toplist.menu.<rawValue>`).
/// - Its galleries open on the browsing site (`GalleryListView` reads `browsingSite`), though the list itself is always
///   asked of E-Hentai (`ToplistsRootModel`).
/// - A double reselect of the toplists tab scrolls the list to the top and refreshes it
///   (`refreshesOnDoubleReselect(_:model:)`); a single one is left to the system (`TabReselection`).
///
/// The page is one accessibility container, so the identifier `TabRootContent` gives it (`toplists.root`) stays on the
/// page while the list's own identifiers stay on its parts.
struct ToplistsRootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ToplistsPage(environment: environment)
            .accessibilityElement(children: .contain)
    }
}

/// The page over its model. The model is made once, with the page (`State(initialValue:)` needs the settings and the
/// service, which only the environment has, so this view takes them from its parent).
private struct ToplistsPage: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var toplists: ToplistsRootModel

    init(environment: AppEnvironment) {
        _toplists = State(initialValue: ToplistsRootModel(
            settings: environment.settings, service: environment.service
        ))
    }

    var body: some View {
        content
            .navigationTitle(toplists.period.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                Picker("Toplist", selection: selection) {
                    ForEach(ToplistPeriod.allCases, id: \.self) { period in
                        Text(period.title)
                            .tag(period)
                            .accessibilityIdentifier("toplist.menu.\(period.rawValue)")
                    }
                }
            }
            .refreshesOnDoubleReselect(.toplists) {
                toplists.list
            }
    }

    private var content: some View {
        let model = toplists.list
        return GalleryListView(model: model, style: environment.settings.settings.listStyle)
            .listJumpControls(model)
            .id(model.id)
    }

    /// The toplist shown, as the title menu's picker sets it.
    private var selection: Binding<ToplistPeriod> {
        let toplists = toplists
        return Binding {
            toplists.period
        } set: { period in
            toplists.select(period)
        }
    }
}
