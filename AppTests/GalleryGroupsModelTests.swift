import EHModels
import EHNetwork
import EHStore
import Foundation
import Testing

@testable import Eros

/// `GalleryGroupsModel` over an in-memory `UserDataStore`: the default groups, the selection, the cached list models,
/// the group styles and requests, and the session's identity. Requests go to a
/// `StubURLProtocol` that answers an empty result; nothing reaches the network.
///
/// Each test has a minute (`.timeLimit`): some hold a request, a page or a feed's answer until they let it go (a
/// gate, a throttle: neither heeds cancellation), and one that never lets go must fail at the limit, not hang the
/// run (the test process is then ended and started again for the tests after it).
@MainActor @Suite(.timeLimit(.minutes(1))) struct GalleryGroupsModelTests {
    /// The site's empty result, as little of it as the parser needs.
    private static let noHits = Data(#"<html><body><div class="ido"><p>No hits found</p></div></body></html>"#.utf8)

    /// An environment (in-memory stores, offline unless `stub` answers), started when a stub is given.
    private static func makeEnvironment(stub: StubSession? = nil) async -> AppEnvironment {
        let environment = AppEnvironment(
            uiTesting: true, sessionConfigurator: stub?.configurator ?? .none, userAgentProbe: { "FakeWebKit/1" }
        )
        if stub != nil { await environment.start() }
        return environment
    }

    /// A model over `store` with `environment`'s settings, service and alerts, on E-Hentai.
    private static func makeModel(
        store: (any GroupStore)?, environment: AppEnvironment, languageCode: String = "en"
    ) -> GalleryGroupsModel {
        GalleryGroupsModel(
            store: store, settings: environment.settings, service: environment.service, site: .eh,
            languageCode: languageCode, alerts: environment.alerts
        )
    }

    /// A group store that reads and saves through an in-memory `UserDataStore` and refuses every delete and move.
    private actor RefusingGroupStore: GroupStore {
        struct Refused: Error {}

        private let base: UserDataStore

        init(base: UserDataStore) {
            self.base = base
        }

        func groups(seed: @Sendable () -> [CustomGroup]) async throws -> [CustomGroup] {
            try await base.groups(seed: seed)
        }

        func saveGroup(_ group: CustomGroup) async throws {
            try await base.saveGroup(group)
        }

        func deleteGroup(uuid: String) async throws {
            throw Refused()
        }

        func moveGroups(fromOffsets: IndexSet, toOffset: Int) async throws {
            throw Refused()
        }
    }

    /// The query items of the last request `stub` received.
    private static func lastQuery(of stub: StubSession) throws -> [String: String] {
        let url = try #require(stub.requests().last?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func firstLoadSeedsTheDefaultGroups() async throws {
        let environment = await Self.makeEnvironment()
        let english = Self.makeModel(store: try UserDataStore(inMemory: true), environment: environment)
        #expect(!english.isLoaded)
        await english.load()
        #expect(english.isLoaded)
        #expect(!english.storeFailed)
        #expect(english.groups.map(\.name) == ["Popular", "Gallery", "Watched", "Anthology"])
        #expect(english.groups.map(\.listType) == [.popular, .gallery, .watched, .gallery])
        #expect(english.selected?.name == "Popular")
        #expect(english.offersTitleMenu)

        let chinese = Self.makeModel(
            store: try UserDataStore(inMemory: true), environment: environment, languageCode: "zh-Hans-CN"
        )
        await chinese.load()
        #expect(chinese.groups.count == 5)
        #expect(chinese.groups[3].name == "汉语")
    }

    @Test func selectionIsRememberedByUUID() async throws {
        let environment = await Self.makeEnvironment()
        let store = try UserDataStore(inMemory: true)
        let first = Self.makeModel(store: store, environment: environment)
        await first.load()
        let watched = try #require(first.groups.first { $0.listType == .watched })
        first.select(watched.uuid)
        #expect(first.selected?.uuid == watched.uuid)
        #expect(environment.settings.browsing.selectedGroupID == watched.uuid)

        let second = Self.makeModel(store: store, environment: environment)
        await second.load()
        #expect(second.selected?.uuid == watched.uuid)
        #expect(second.selected?.name == "Watched")
    }

    @Test func deletedSelectionFallsBackToTheFirst() async throws {
        let environment = await Self.makeEnvironment()
        let groups = Self.makeModel(store: try UserDataStore(inMemory: true), environment: environment)
        await groups.load()
        let watched = try #require(groups.groups.first { $0.listType == .watched })
        groups.select(watched.uuid)

        #expect(await groups.delete(watched.uuid))
        #expect(groups.groups.map(\.name) == ["Popular", "Gallery", "Anthology"])
        #expect(groups.selected?.name == "Popular")
    }

    @Test func deletingEveryGroupLeavesAnEmptyState() async throws {
        let environment = await Self.makeEnvironment()
        let store = try UserDataStore(inMemory: true)
        let groups = Self.makeModel(store: store, environment: environment)
        await groups.load()
        for group in groups.groups {
            await groups.delete(group.uuid)
        }
        #expect(groups.groups.isEmpty)
        #expect(groups.selected == nil)
        // Manage Groups is still there to add one.
        #expect(groups.offersTitleMenu)

        // The store was written: loading again does not seed the defaults again.
        await groups.load()
        #expect(groups.groups.isEmpty)
        #expect(groups.selected == nil)
        let reloaded = Self.makeModel(store: store, environment: environment)
        await reloaded.load()
        #expect(reloaded.groups.isEmpty)

        let added = CustomGroup(uuid: "fake-group-added", name: "Added Test", searchText: ["female:fake tag"])
        try await groups.save(added)
        #expect(groups.groups.map(\.name) == ["Added Test"])
        #expect(groups.selected?.uuid == "fake-group-added")
        #expect(environment.settings.browsing.selectedGroupID == "fake-group-added")
    }

    @Test func savingAGroupRebuildsItsModel() async throws {
        let noHits = Self.noHits
        let stub = StubURLProtocol.install { _ in StubResponse(body: noHits) }
        defer { stub.remove() }
        let environment = await Self.makeEnvironment(stub: stub)
        let groups = Self.makeModel(store: try UserDataStore(inMemory: true), environment: environment)
        await groups.load()
        var gallery = try #require(groups.groups.first { $0.listType == .gallery })
        let before = groups.model(for: gallery)
        #expect(groups.model(for: gallery) === before, "The model is not cached")

        gallery.searchText = ["female:fake tag"]
        try await groups.save(gallery)
        let saved = try #require(groups.groups.first { $0.uuid == gallery.uuid })
        #expect(saved.searchText == ["female:fake tag"])
        let after = groups.model(for: saved)
        #expect(after !== before)
        #expect(groups.model(for: saved) === after)

        await after.loadFirst()
        let url = try #require(stub.requests().last?.url)
        #expect(url.host() == "e-hentai.org")
        #expect(url.path() == "/")
        #expect(try Self.lastQuery(of: stub)["f_search"] == "female:fake tag")
    }

    @Test func groupStyleFollowsGlobalWhenUnset() async throws {
        let environment = await Self.makeEnvironment()
        let groups = Self.makeModel(store: try UserDataStore(inMemory: true), environment: environment)
        let unset = CustomGroup(uuid: "fake-unset", name: "Unset Test")
        let global = CustomGroup(uuid: "fake-global", name: "Global Test", listModeValue: "global")
        let own = CustomGroup(uuid: "fake-own", name: "Own Test", listModeValue: ListStyle.waterfall.rawValue)

        environment.settings.settings.listStyle = .grid
        #expect(groups.style(for: unset) == .grid)
        #expect(groups.style(for: global) == .grid)
        #expect(groups.style(for: own) == .waterfall)

        environment.settings.settings.listStyle = .simpleList
        #expect(groups.style(for: unset) == .simpleList)
        #expect(groups.style(for: own) == .waterfall)
    }

    @Test func groupsIgnoreTheGlobalCategoryFilter() async throws {
        let noHits = Self.noHits
        let stub = StubURLProtocol.install { _ in StubResponse(body: noHits) }
        defer { stub.remove() }
        let environment = await Self.makeEnvironment(stub: stub)
        environment.settings.settings.categoryFilter = CategoryMask(rawValue: 1023)
        let groups = Self.makeModel(store: try UserDataStore(inMemory: true), environment: environment)
        await groups.load()

        let filtered = CustomGroup(uuid: "fake-cats", name: "Categories Test", cats: 5)
        try await groups.save(filtered)
        let saved = try #require(groups.groups.first { $0.uuid == "fake-cats" })
        await groups.model(for: saved).loadFirst()
        #expect(try Self.lastQuery(of: stub)["f_cats"] == "5")

        let gallery = try #require(groups.groups.first { $0.listType == .gallery })
        await groups.model(for: gallery).loadFirst()
        #expect(try Self.lastQuery(of: stub)["f_cats"] == nil)
        #expect(stub.requests().count == 2)
    }

    @Test func missingStoreShowsTheFailure() async {
        let environment = await Self.makeEnvironment()
        let groups = Self.makeModel(store: nil, environment: environment)
        await groups.load()
        #expect(groups.storeFailed)
        #expect(groups.isLoaded)
        #expect(groups.groups.isEmpty)
        #expect(groups.selected == nil)
        // Nothing to pick and nothing to manage: no title menu at all (L080a), rather than an empty one.
        #expect(!groups.offersTitleMenu)
        await #expect(throws: GroupStoreUnavailable.self) {
            try await groups.save(CustomGroup(uuid: "fake-group", name: "Store Test"))
        }
        #expect(await groups.delete("fake-group") == false)
    }

    @Test func movingGroupsKeepsTheOrder() async throws {
        let environment = await Self.makeEnvironment()
        let store = try UserDataStore(inMemory: true)
        let groups = Self.makeModel(store: store, environment: environment)
        await groups.load()
        groups.select(groups.groups[1].uuid)
        #expect(groups.selected?.name == "Gallery")

        await groups.move(fromOffsets: [3], toOffset: 0)
        #expect(groups.groups.map(\.name) == ["Anthology", "Popular", "Gallery", "Watched"])
        #expect(groups.selected?.name == "Gallery")

        let reloaded = Self.makeModel(store: store, environment: environment)
        await reloaded.load()
        #expect(reloaded.groups.map(\.name) == ["Anthology", "Popular", "Gallery", "Watched"])
        #expect(reloaded.selected?.name == "Gallery")
    }

    /// A delete or a move the store refuses: the groups go back to what the store holds, and the user is told (through
    /// the app's alerts, once per failure).
    @Test func refusedWritesRollBackAndTell() async throws {
        let environment = await Self.makeEnvironment()
        let store = RefusingGroupStore(base: try UserDataStore(inMemory: true))
        let groups = Self.makeModel(store: store, environment: environment)
        await groups.load()
        let names = ["Popular", "Gallery", "Watched", "Anthology"]
        #expect(groups.groups.map(\.name) == names)
        #expect(environment.alerts.current == nil)

        // Refused: the editor keeps its sheet (L081b).
        #expect(await groups.delete(groups.groups[1].uuid) == false)
        #expect(groups.groups.map(\.name) == names)
        #expect(!groups.storeFailed)
        let deleteAlert = try #require(environment.alerts.current)
        #expect(deleteAlert.title == "The groups could not be saved.")
        #expect(deleteAlert.actions.map(\.title) == ["OK"])
        environment.alerts.dismiss(deleteAlert.id)

        await groups.move(fromOffsets: [3], toOffset: 0)
        #expect(groups.groups.map(\.name) == names)
        #expect(environment.alerts.current?.title == "The groups could not be saved.")
        #expect(environment.alerts.queuedCount == 1)
    }

    /// Without a group chosen the first one is shown; moving another group first keeps that one shown.
    @Test func movingGroupsKeepsTheShownGroup() async throws {
        let environment = await Self.makeEnvironment()
        let groups = Self.makeModel(store: try UserDataStore(inMemory: true), environment: environment)
        await groups.load()
        #expect(environment.settings.browsing.selectedGroupID == nil)
        #expect(groups.selected?.name == "Popular")

        await groups.move(fromOffsets: [1], toOffset: 0)
        #expect(groups.groups.map(\.name) == ["Gallery", "Popular", "Watched", "Anthology"])
        #expect(groups.selected?.name == "Popular")
    }

    // MARK: - Session identity

    /// Another identity drops the cached lists of the groups not shown: shown next, they load for the new account.
    /// The shown group's list stays (`GalleryListView` reloads it itself), and the same identity again changes nothing.
    @Test func identityChangeRebuildsTheOtherGroupsModels() async throws {
        let environment = await Self.makeEnvironment()
        let groups = Self.makeModel(store: try UserDataStore(inMemory: true), environment: environment)
        await groups.load()
        let shown = try #require(groups.selected)
        let other = try #require(groups.groups.first { $0.listType == .gallery })
        let loggedOut = SessionIdentity(isLoggedIn: false, memberID: nil)
        let member = SessionIdentity(isLoggedIn: true, memberID: "1234567")

        groups.updateSession(loggedOut)
        let shownModel = groups.model(for: shown)
        let otherModel = groups.model(for: other)
        groups.updateSession(loggedOut)
        #expect(groups.model(for: other) === otherModel, "The same identity dropped a list")

        groups.updateSession(member)
        #expect(groups.model(for: shown) === shownModel)
        let afterLogin = groups.model(for: other)
        #expect(afterLogin !== otherModel)

        groups.updateSession(loggedOut)
        #expect(groups.model(for: shown) === shownModel)
        #expect(groups.model(for: other) !== afterLogin)
    }

    // MARK: - Dropped lists

    /// How a group's list is let go.
    enum Drop: CaseIterable, Sendable {
        /// Another session's identity (the list is not the one shown).
        case identity
        /// The group was saved: its list is made again.
        case save
        /// The group was deleted.
        case delete
    }

    /// A list that is let go while its first page waits at the throttle has that request cancelled (A-M1), as the
    /// toplists and the favorites do: nobody shows it any more, and it would hold the site's tokens for nothing. The
    /// list is idle again; the group's next list is a new one.
    @Test(arguments: Drop.allCases)
    func droppedListsAreCancelled(_ drop: Drop) async throws {
        let throttle = SuspendingThrottle()
        let environment = AppEnvironment(
            uiTesting: true, userAgentProbe: { "FakeWebKit/1" }, throttle: throttle
        )
        await environment.start()
        let groups = Self.makeModel(store: try UserDataStore(inMemory: true), environment: environment)
        await groups.load()
        groups.updateSession(SessionIdentity(isLoggedIn: false, memberID: nil))
        var gallery = try #require(groups.groups.first { $0.listType == .gallery })
        let list = groups.model(for: gallery)
        let load = Task { await list.loadFirst() }
        #expect(await eventually { await throttle.waiting == 1 })

        switch drop {
        case .identity:
            groups.updateSession(SessionIdentity(isLoggedIn: true, memberID: "1234567"))
        case .save:
            gallery.searchText = ["female:fake tag"]
            try await groups.save(gallery)
        case .delete:
            #expect(await groups.delete(gallery.uuid))
        }
        let cancelled = await eventually { await throttle.cancellations == 1 }
        #expect(cancelled, "\(drop): the dropped list's request was not cancelled")
        // Not cancelled, the load would wait for an hour.
        guard cancelled else { return }
        await load.value
        #expect(list.status == .idle)
        if let kept = groups.groups.first(where: { $0.uuid == gallery.uuid }) {
            #expect(groups.model(for: kept) !== list)
        }
    }
}
