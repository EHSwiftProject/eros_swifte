import EHModels
import EHNetwork
import EHStore
import Foundation
import Observation
import os

/// There is no user data store to save the group in (`AppEnvironment.userData` could not be opened).
nonisolated struct GroupStoreUnavailable: Error {}

/// Where the gallery groups are kept: `UserDataStore`'s group API (the app's store); hosted tests pass one that fails.
nonisolated protocol GroupStore: AnyObject, Sendable {
    func groups(seed: @Sendable () -> [CustomGroup]) async throws -> [CustomGroup]
    func saveGroup(_ group: CustomGroup) async throws
    func deleteGroup(uuid: String) async throws
    func moveGroups(fromOffsets: IndexSet, toOffset: Int) async throws
}

extension UserDataStore: GroupStore {}

/// The gallery tab's custom groups (Flutter `CustomTabbarController`) over the user data store: the groups in order,
/// the one shown, a list model per group, and the edits of the management page and the group editor.
///
/// - The group shown is the one chosen last (`BrowsingState.selectedGroupID`, kept by uuid in the settings), else the
///   first; none without groups. A group saved is shown; deleting the one shown falls back to the first; moving the
///   groups keeps the one shown (Flutter `onReorder`).
/// - The groups never use the global category filter (`AppSettings.categoryFilter`): only their own (M2 index §4).
/// - `model(for:)` keeps one `GalleryListModel` per group, made again once the group was saved (`lastEditTime`). A list
///   let go (its group saved or deleted, or the session's identity changed while another group is shown) is cancelled
///   first (`GalleryListModel.cancel()`), as the toplists and the favorites do: nobody shows it any more, and its
///   requests would hold the site's tokens for nothing.
/// - Once the store has been written (seeding included), loading never seeds the defaults again, even with no groups
///   left (`UserDataStore.groups(seed:)`).
/// - A delete or a move the store refuses is logged and told in an alert (`The groups could not be saved.`, through
///   the app's `AlertCenter`, shown by the `alertHost()` in front), and the groups are read again.
@MainActor @Observable final class GalleryGroupsModel {
    private static let log = Logger(subsystem: "proj.eros.swifte", category: "UserData")

    private(set) var groups: [CustomGroup] = []
    /// The store is missing, or reading it threw: the page says "Groups could not be loaded."
    private(set) var storeFailed = false
    /// `load()` has finished once: until then the page shows that it is loading, not that there are no groups.
    private(set) var isLoaded = false

    @ObservationIgnored private let store: (any GroupStore)?
    @ObservationIgnored private let alerts: AlertCenter
    @ObservationIgnored private let settings: AppSettingsStore
    @ObservationIgnored private let service: EHService
    @ObservationIgnored private let site: EHSite
    @ObservationIgnored private let languageCode: String
    /// The list model of each group, by uuid, with the `lastEditTime` it was made for.
    @ObservationIgnored private var models: [String: (edit: Int?, model: GalleryListModel)] = [:]
    /// The session's identity last passed to `updateSession(_:)`; nil before the first.
    @ObservationIgnored private var session: SessionIdentity?

    /// `languageCode` names the default groups of a first load (`CustomGroup.defaults(languageCode:)`); the app passes
    /// `Locale.preferredLanguages.first ?? "en"`. `alerts` tells the user about writes the store refused (the
    /// environment's).
    init(
        store: (any GroupStore)?, settings: AppSettingsStore, service: EHService, site: EHSite, languageCode: String,
        alerts: AlertCenter
    ) {
        self.store = store
        self.alerts = alerts
        self.settings = settings
        self.service = service
        self.site = site
        self.languageCode = languageCode
    }

    /// The group shown: the one chosen last while it exists, else the first; nil without groups.
    var selected: CustomGroup? {
        if let id = settings.browsing.selectedGroupID, let group = groups.first(where: { $0.uuid == id }) {
            return group
        }
        return groups.first
    }

    /// Whether the page has a title menu: the groups to pick from with Edit Group, or Manage Groups; none while the
    /// store failed without a group to show, rather than an empty menu.
    var offersTitleMenu: Bool {
        selected != nil || !storeFailed
    }

    /// Reads the groups, seeding the defaults on the very first read. Without a store, or when reading throws, the
    /// groups stay as they were and `storeFailed` is set.
    func load() async {
        defer { isLoaded = true }
        guard let store else {
            storeFailed = true
            return
        }
        await read(from: store)
    }

    /// Shows the group `uuid` from now on (kept in the settings).
    func select(_ uuid: String) {
        settings.browsing.selectedGroupID = uuid
    }

    /// The list of `group`: kept while the group is not saved again, so switching back shows it as it was.
    func model(for group: CustomGroup) -> GalleryListModel {
        if let cached = models[group.uuid], cached.edit == group.lastEditTime {
            return cached.model
        }
        drop(group.uuid)
        let model = GalleryListModel(feed: QueryFeed(query: group.listQuery(), site: site, service: service))
        models[group.uuid] = (group.lastEditTime, model)
        return model
    }

    /// The layout of `group`: its own, else the global setting's.
    func style(for group: CustomGroup) -> ListStyle {
        group.listStyle ?? settings.settings.listStyle
    }

    /// Saves `group` (`UserDataStore.saveGroup(_:)`: the same uuid in place, else a group of the same name, else at
    /// the end), reads the groups again, then shows it.
    /// - Throws: `GroupStoreUnavailable` without a store; the store's errors (`UserDataError.emptyGroupName` for a
    ///   blank name), the groups then unchanged.
    func save(_ group: CustomGroup) async throws {
        guard let store else { throw GroupStoreUnavailable() }
        try await store.saveGroup(group)
        await read(from: store)
        select(group.uuid)
    }

    /// Deletes the group `uuid` (Flutter's management page asks nothing first). It goes from `groups` at once; when the
    /// store refuses, see `refused(_:by:)`. Returns whether it was deleted: false without a store or when the store
    /// refused (the group editor then stays open with the alert on it).
    @discardableResult func delete(_ uuid: String) async -> Bool {
        guard let store else { return false }
        groups.removeAll { $0.uuid == uuid }
        drop(uuid)
        do {
            try await store.deleteGroup(uuid: uuid)
            return true
        } catch {
            await refused(error, by: store)
            return false
        }
    }

    /// Moves the groups as `List.onMove` does; the group shown stays shown (it is chosen by uuid first, should it only
    /// have been shown as the first). The order changes in `groups` at once; when the store refuses, see
    /// `refused(_:by:)`.
    func move(fromOffsets: IndexSet, toOffset: Int) async {
        guard let store else { return }
        if let shown = selected { select(shown.uuid) }
        groups.moveSubranges(RangeSet(fromOffsets, within: groups), to: toOffset)
        do {
            try await store.moveGroups(fromOffsets: fromOffsets, toOffset: toOffset)
        } catch {
            await refused(error, by: store)
        }
    }

    /// The session's identity now (`AppEnvironment.sessionIdentity`; the root page passes every value, the first one
    /// included, which is only recorded). Another identity than the last drops the list of every group but the one
    /// shown, so a group shown next loads for the new account. The list shown is kept:
    /// `GalleryListView` reloads it itself.
    func updateSession(_ identity: SessionIdentity) {
        defer { session = identity }
        guard let session, session != identity else { return }
        let shown = selected?.uuid
        for uuid in models.keys where uuid != shown { drop(uuid) }
    }

    // MARK: - Private

    /// Lets the list of the group `uuid` go, cancelling what it has in flight first.
    private func drop(_ uuid: String) {
        models.removeValue(forKey: uuid)?.model.cancel()
    }

    /// A delete or a move `store` refused: the error's domain and code are logged (not its description, which may
    /// show the groups it touched, searched texts among them), the user is told, and the groups are read again, so
    /// they show what the store holds.
    private func refused(_ error: any Error, by store: any GroupStore) async {
        let failure = error as NSError
        let domain = failure.domain
        let code = failure.code
        Self.log.error("Groups could not be saved: \(domain, privacy: .public) \(code, privacy: .public)")
        alerts.present(HostedAlert(title: "The groups could not be saved.", actions: [.init("OK")]))
        await read(from: store)
    }

    /// The groups read from `store` (seeding the defaults on its very first read); the lists of groups no longer
    /// there, or saved since their list was made, are dropped. When reading throws, the groups stay as they were and
    /// `storeFailed` is set.
    private func read(from store: any GroupStore) async {
        let languageCode = languageCode
        do {
            groups = try await store.groups(seed: { CustomGroup.defaults(languageCode: languageCode) })
            storeFailed = false
        } catch {
            storeFailed = true
            return
        }
        let edits = Dictionary(groups.map { ($0.uuid, $0.lastEditTime) }, uniquingKeysWith: { first, _ in first })
        for (uuid, cached) in models where edits[uuid] != .some(cached.edit) {
            drop(uuid)
        }
    }
}
