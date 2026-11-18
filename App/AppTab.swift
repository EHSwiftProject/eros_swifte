/// The top-level tabs of the app, in display order.
///
/// Titles follow the English copy of the Flutter app. The type is plain data,
/// so it opts out of the target's default main-actor isolation.
nonisolated enum AppTab: String, CaseIterable, Identifiable {
    case gallery
    case favorites
    case toplists
    case download
    case history
    case settings

    var id: Self { self }

    /// The user-facing tab title.
    var title: String {
        switch self {
        case .gallery: "Gallery"
        case .favorites: "Favorites"
        case .toplists: "Toplists"
        case .download: "Download"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    /// The SF Symbol shown for the tab.
    var systemImage: String {
        switch self {
        case .gallery: "square.stack.3d.up"
        case .favorites: "heart"
        case .toplists: "list.number"
        case .download: "arrow.down.circle"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    /// Stable identifier of the tab item (`tab.<rawValue>`): its accessibility identifier, which UI tests look it up
    /// by.
    var customizationID: String { "tab.\(rawValue)" }

    /// The tab's name in Flutter's `tabConfig` (`EHRoutes`, route/routes.dart:48-53), which `TabConfiguration`
    /// stores.
    var routeName: String {
        switch self {
        case .gallery: "/gallery"
        case .favorites: "/favorite"
        case .toplists: "/toplist"
        case .download: "/download"
        case .history: "/history"
        case .settings: "/setting"
        }
    }

    /// The tab named `routeName` in Flutter's `tabConfig`; nil for any other name.
    init?(routeName: String) {
        guard let tab = Self.allCases.first(where: { $0.routeName == routeName }) else { return nil }
        self = tab
    }
}
