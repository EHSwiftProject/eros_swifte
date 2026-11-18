import EHModels
import EHParsing
import Foundation

/// A change the app makes to the user's account settings on a site, which the user is asked about first.
public enum SiteSettingChange: Sendable, Hashable { case compactView(current: ListDisplayMode), favoritesOrder(FavoritesOrder) }

/// What one acknowledgement covers: a kind of change, on one site, for one account. The profile (`sp`) is not part
/// of it: Eros-FE is the one profile the app uses.
public struct NoticeScope: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case compactView, favoritesOrder }
    public let kind: Kind; public let site: EHSite; public let memberID: Int?   // nil = not logged in
    public init(kind: Kind, site: EHSite, memberID: Int?) {
        self.kind = kind
        self.site = site
        self.memberID = memberID
    }
}

extension SiteSettingChange {
    /// The kind of change, as the ledger keeps it.
    var kind: NoticeScope.Kind {
        switch self {
        case .compactView: .compactView
        case .favoritesOrder: .favoritesOrder
        }
    }
}

/// Asks the user before the app changes a setting of their account on a site (a write to the account's settings).
public protocol SiteSettingPresenter: Sendable {
    /// Asks once before `change` is made on `site`. true = continue.
    ///
    /// Answering false ("Cancel") sends nothing and changes nothing; the app asks again the next time.
    ///
    /// `EHService` makes at most one call at a time per `NoticeScope`: callers that meet the same change together
    /// share one answer; changes of different sites or accounts are asked separately and may be open together.
    /// When the calling task is cancelled (the service cancels it once no caller is waiting for the answer), the
    /// implementation should take the prompt down and return false.
    func confirm(_ change: SiteSettingChange, site: EHSite) async -> Bool
}

/// Remembers which scopes the user has already agreed to.
public protocol NoticeLedger: Sendable {
    func isAcknowledged(_ scope: NoticeScope) async -> Bool
    func acknowledge(_ scope: NoticeScope) async
}

/// Keeps the acknowledgements in UserDefaults, one Bool per scope under
/// "eros.siteSettingNotice.<kind>.<site>.<member id or anonymous>".
///
/// The key of the former single acknowledgement, "eros.compactNoticeAcknowledged", is neither read, migrated nor
/// removed: every account is asked once per site again.
public actor UserDefaultsNoticeLedger: NoticeLedger {
    private let defaults: UserDefaults

    /// nil, or a suite UserDefaults refuses (such as the app's own bundle identifier): the standard defaults.
    public init(suiteName: String? = nil) {
        defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private static func key(for scope: NoticeScope) -> String {
        let member = scope.memberID.map(String.init) ?? "anonymous"
        return "eros.siteSettingNotice.\(scope.kind.rawValue).\(scope.site.rawValue).\(member)"
    }

    public func isAcknowledged(_ scope: NoticeScope) -> Bool {
        defaults.bool(forKey: Self.key(for: scope))
    }

    public func acknowledge(_ scope: NoticeScope) {
        defaults.set(true, forKey: Self.key(for: scope))
    }
}

/// Keeps the acknowledgements in memory; for tests and UI tests.
public actor InMemoryNoticeLedger: NoticeLedger {
    private var acknowledged: Set<NoticeScope>

    public init(acknowledged: Set<NoticeScope> = []) {
        self.acknowledged = acknowledged
    }

    public func isAcknowledged(_ scope: NoticeScope) -> Bool { acknowledged.contains(scope) }

    public func acknowledge(_ scope: NoticeScope) { acknowledged.insert(scope) }
}

/// Why `EHService.galleryList` did not return a list.
public enum ListServiceError: Error, Equatable {
    /// The page is not in the Compact view and the user declined to switch; nothing was changed on the site.
    case displayModeNotCompact(ListDisplayMode)
    /// The page was still not Compact after one resend with `inline_set=dm_l`; the service never sends a third request.
    case displayModeStillNotCompact(ListDisplayMode)
}
