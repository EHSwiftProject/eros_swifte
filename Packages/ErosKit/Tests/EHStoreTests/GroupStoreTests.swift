import EHModels
import EHStore
import Foundation
import Testing

@Suite struct GroupStoreTests {
    /// Popular g1, Gallery g2, Watched g3, Anthology g4.
    static func makeSeed() -> [CustomGroup] {
        var n = 0
        return CustomGroup.defaults(languageCode: "en", makeID: { n += 1; return "g\(n)" })
    }

    static let seed = makeSeed()

    static func seededStore() async throws -> UserDataStore {
        let store = try UserDataStore(inMemory: true)
        _ = try await store.groups(seed: { seed })
        return store
    }

    static func uuids(_ store: UserDataStore) async throws -> [String] {
        try await store.groups(seed: { [] }).map(\.uuid)
    }

    static func nowMilliseconds() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    @Test func firstReadSeedsAndPersists() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "UserData.store")
            do {
                let first = try UserDataStore(storeURL: url)
                #expect(try await first.groups(seed: { Self.seed }) == Self.seed)
                _ = try await first.groups(seed: { Self.seed })
            }
            let second = try UserDataStore(storeURL: url)
            #expect(try await second.groups(seed: { [CustomGroup(uuid: "x", name: "X")] }) == Self.seed)
        }
    }

    @Test func seedIsUsedOnlyOnce() async throws {
        let store = try UserDataStore(inMemory: true)
        _ = try await store.groups(seed: { Self.seed })
        for id in ["g1", "g2", "g3", "g4"] { try await store.deleteGroup(uuid: id) }
        #expect(try await store.groups(seed: { Self.seed }) == [])
    }

    @Test func saveReplacesSameUUIDInPlace() async throws {
        let store = try await Self.seededStore()
        let before = Self.nowMilliseconds()
        try await store.saveGroup(CustomGroup(uuid: "g2", name: "Renamed"))
        let after = Self.nowMilliseconds()
        let groups = try await store.groups(seed: { [] })
        #expect(groups.map(\.uuid) == ["g1", "g2", "g3", "g4"])
        #expect(groups[1].name == "Renamed")
        let edited = try #require(groups[1].lastEditTime)
        #expect(edited >= before && edited <= after)
    }

    @Test func saveReplacesSameNameInPlace() async throws {
        let store = try await Self.seededStore()
        let saved = CustomGroup(uuid: "n1", name: "Gallery", searchText: ["x"])
        try await store.saveGroup(saved)
        let groups = try await store.groups(seed: { [] })
        #expect(groups.map(\.uuid) == ["g1", "n1", "g3", "g4"])
        // The whole entry is the new group: nothing of the seeded "Gallery" is kept but its place.
        var replaced = groups[1]
        #expect(replaced.searchText == ["x"])
        #expect(replaced.lastEditTime != nil)
        replaced.lastEditTime = nil
        #expect(replaced == saved)
        #expect(try await store.deletedGroups().isEmpty)
    }

    @Test func saveTrimsTheName() async throws {
        let store = try await Self.seededStore()
        try await store.saveGroup(CustomGroup(uuid: "n2", name: "  Gallery  "))
        let groups = try await store.groups(seed: { [] })
        #expect(groups.map(\.uuid) == ["g1", "n2", "g3", "g4"])
        #expect(groups[1].name == "Gallery")
    }

    @Test func saveAppendsNewGroups() async throws {
        let store = try await Self.seededStore()
        try await store.saveGroup(CustomGroup(uuid: "n3", name: "New"))
        #expect(try await Self.uuids(store) == ["g1", "g2", "g3", "g4", "n3"])
    }

    @Test(arguments: ["", "   ", "\n\t"]) func blankNameIsRejected(_ name: String) async throws {
        let store = try await Self.seededStore()
        await #expect(throws: UserDataError.emptyGroupName) {
            try await store.saveGroup(CustomGroup(uuid: "n4", name: name))
        }
        #expect(try await store.groups(seed: { [] }) == Self.seed)
    }

    @Test func deleteRecordsATombstone() async throws {
        let store = try await Self.seededStore()
        try await store.saveGroup(Self.seed[2])
        let saved = try #require(try await store.groups(seed: { [] }).first { $0.uuid == "g3" })
        let time = try #require(saved.lastEditTime)
        try await store.deleteGroup(uuid: "g3")
        #expect(try await Self.uuids(store) == ["g1", "g2", "g4"])
        let deleted = try await store.deletedGroups()
        #expect(deleted == [saved])
        #expect(deleted.first?.lastEditTime == time)
    }

    @Test func deletingAnUnknownUUIDDoesNothing() async throws {
        let store = try await Self.seededStore()
        try await store.deleteGroup(uuid: "nope")
        #expect(try await store.groups(seed: { [] }) == Self.seed)
        #expect(try await store.deletedGroups().isEmpty)
    }

    @Test func tombstonesKeepOnePerUUID() async throws {
        let store = try await Self.seededStore()
        try await store.deleteGroup(uuid: "g1")
        try await store.deleteGroup(uuid: "g2")
        try await store.saveGroup(Self.seed[0])
        try await store.deleteGroup(uuid: "g1")
        #expect(try await store.deletedGroups().map(\.uuid) == ["g2", "g1"])
    }

    @Test(arguments: [
        ([0], 3, ["g2", "g3", "g1", "g4"]), ([3], 0, ["g4", "g1", "g2", "g3"]), ([1, 3], 0, ["g2", "g4", "g1", "g3"]),
        ([0], 4, ["g2", "g3", "g4", "g1"]), ([0], 99, ["g2", "g3", "g4", "g1"]), ([9], 0, ["g1", "g2", "g3", "g4"]),
    ])
    func moveFollowsListSemantics(_ from: [Int], _ to: Int, _ expected: [String]) async throws {
        let store = try await Self.seededStore()
        try await store.moveGroups(fromOffsets: IndexSet(from), toOffset: to)
        let groups = try await store.groups(seed: { [] })
        #expect(groups.map(\.uuid) == expected)
        let byID = Dictionary(uniqueKeysWithValues: Self.seed.map { ($0.uuid, $0.lastEditTime) })
        #expect(groups.allSatisfy { $0.lastEditTime == byID[$0.uuid] })
    }

    @Test func orderPersists() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "UserData.store")
            do {
                let first = try UserDataStore(storeURL: url)
                _ = try await first.groups(seed: { Self.seed })
                try await first.moveGroups(fromOffsets: IndexSet([3]), toOffset: 0)
                _ = try await first.groups(seed: { [] })
            }
            let second = try UserDataStore(storeURL: url)
            #expect(try await Self.uuids(second) == ["g4", "g1", "g2", "g3"])
        }
    }

    @Test func inMemoryStoresAreSeparate() async throws {
        _ = try await Self.seededStore()
        let second = try UserDataStore(inMemory: true)
        #expect(try await second.groups(seed: { [] }) == [])
    }

    @MainActor @Test func storeCreatedOnTheMainActorWorks() async throws {
        let store = try UserDataStore(inMemory: true)
        try await store.saveGroup(CustomGroup(uuid: "m1", name: "fake main"))
        let groups = try await store.groups(seed: { [] })
        #expect(groups.map(\.uuid) == ["m1"])
        #expect(groups.first?.name == "fake main")
    }
}
