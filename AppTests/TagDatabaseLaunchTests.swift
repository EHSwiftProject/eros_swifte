import EHModels
import EHNetwork
@_spi(Testing) import EHStore
import Foundation
import Synchronization
import Testing

@testable import Eros

/// The tag database in `AppEnvironment`: the update at launch and the mirror, against a stub of GitHub.
///
/// Each test has a minute (`.timeLimit`): some hold the release request's answer (`ResponderGate`) until they let it
/// go, and one that never does must fail at the limit, not hang the run.
@MainActor @Suite(.timeLimit(.minutes(1))) struct TagDatabaseLaunchTests {
    private static let expectedVersion = "v9.9999.0 2026-10-01T00:00:00Z"

    /// An older database holding the same tag under another name.
    private static let oldDatabase = Data(
        #"{"data":[{"namespace":"female","data":{"fake tag":{"name":"旧译名"}}}]}"#.utf8
    )

    /// A stub answering `releases/latest` with a made-up release and its asset with a one-entry db.raw.json (the
    /// store reads a file gzipped or not). With `gate`, the first release request's answer waits for it (the stub's
    /// loading thread waits in the responder).
    private static func installStub(holdingFirstRelease gate: ResponderGate? = nil) -> StubSession {
        let releases = Mutex(0)
        return StubURLProtocol.install { request in
            let path = request.url?.path(percentEncoded: false) ?? ""
            if path.hasSuffix("releases/latest") {
                let isFirst = releases.withLock { count in
                    count += 1
                    return count == 1
                }
                if isFirst { gate?.wait() }
                let body = #"{"tag_name":"v9.9999.0","published_at":"2026-10-01T00:00:00Z","assets":[{"name":"db.raw.json.gz","browser_download_url":"https://example.invalid/download/db.raw.json.gz"}]}"#
                return StubResponse(body: Data(body.utf8))
            }
            if path.hasSuffix("db.raw.json.gz") { return StubResponse(body: TagNameCacheTests.smallDatabase) }
            return StubResponse(status: 404)
        }
    }

    /// As `installStub()`, the asset claiming to be larger than any tag database download may be.
    private static func installOversizedStub() -> StubSession {
        StubURLProtocol.install { request in
            let path = request.url?.path(percentEncoded: false) ?? ""
            if path.hasSuffix("releases/latest") {
                let body = #"{"tag_name":"v9.9999.0","published_at":"2026-10-01T00:00:00Z","assets":[{"name":"db.raw.json.gz","browser_download_url":"https://example.invalid/download/db.raw.json.gz"}]}"#
                return StubResponse(body: Data(body.utf8))
            }
            if path.hasSuffix("db.raw.json.gz") {
                return StubResponse(headers: ["Content-Length": String(64 << 20)], body: TagNameCacheTests.smallDatabase)
            }
            return StubResponse(status: 404)
        }
    }

    /// An environment whose tag database downloads through `stub`, with `store` when given (else its own in memory).
    private static func makeEnvironment(
        _ stub: StubSession, updatesOnLaunch: Bool = false, mirror: Bool = false, store: TagTranslationStore? = nil
    ) -> AppEnvironment {
        let configuration = URLSessionConfiguration.ephemeral
        stub.configurator.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        let environment = AppEnvironment(
            uiTesting: true, tagDatabaseSession: session, tagDatabaseLaunchDelay: .zero, tagTranslationStore: store
        )
        environment.settings.settings.updatesTagDatabaseOnLaunch = updatesOnLaunch
        environment.settings.settings.usesTagDatabaseMirror = mirror
        return environment
    }

    @Test func launchUpdatesWhenEnabled() async throws {
        let stub = Self.installStub()
        defer { stub.remove() }
        let environment = Self.makeEnvironment(stub, updatesOnLaunch: true)
        // The store holds an older translation of the tag, and the cache has read it.
        let store = try #require(environment.tagTranslations)
        _ = try await store.replaceAll(with: Self.oldDatabase, version: "v0 old")
        await environment.tagNames.prefetch([TagNameCacheTests.fakeTag])
        #expect(environment.tagNames.name(for: TagNameCacheTests.fakeTag) == "旧译名")
        await environment.start()
        // The update imports the new translation and clears the cache; a prefetch after that reads the new one.
        #expect(await eventually { (try? await store.version()) == Self.expectedVersion })
        #expect(await eventually {
            await environment.tagNames.prefetch([TagNameCacheTests.fakeTag])
            return environment.tagNames.name(for: TagNameCacheTests.fakeTag) == "示例标签"
        })
    }

    @Test func upToDateKeepsTheCachedNames() async throws {
        let stub = Self.installStub()
        defer { stub.remove() }
        let environment = Self.makeEnvironment(stub)
        #expect(try await environment.updateTagDatabase(force: false) == .updated(version: Self.expectedVersion, count: 1))
        await environment.tagNames.prefetch([TagNameCacheTests.fakeTag])
        let generation = environment.tagNames.generation
        #expect(try await environment.updateTagDatabase(force: false) == .upToDate(version: Self.expectedVersion))
        #expect(environment.tagNames.name(for: TagNameCacheTests.fakeTag) == "示例标签")
        #expect(environment.tagNames.generation == generation)
        // A real update (forced) clears the cache and bumps the counter.
        _ = try await environment.updateTagDatabase(force: true)
        #expect(environment.tagNames.name(for: TagNameCacheTests.fakeTag) == nil)
        #expect(environment.tagNames.generation == generation + 1)
    }

    @Test func launchDoesNothingWhenDisabled() async throws {
        let stub = Self.installStub()
        defer { stub.remove() }
        let environment = Self.makeEnvironment(stub, updatesOnLaunch: false)
        await environment.start()
        #expect(environment.tagDatabaseLaunchUpdate == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(stub.requests().isEmpty)
    }

    /// A store that found its file marked as damaged and rebuilt it (U5) is downloaded again at launch, once, the
    /// update at launch switched off or on: the footer that reported the damage said "It will be downloaded again the
    /// next time Eros-SE starts" (U5 option A; M2 re-review F5 N-3).
    @Test(arguments: [false, true])
    func aRebuiltDatabaseIsDownloadedAgainAtLaunch(updatesOnLaunch: Bool) async throws {
        try await Self.withFileStore(markedAsDamaged: true) { store in
            #expect(await store.wasRebuiltFromDamage)
            #expect(try await store.version() == nil)
            let stub = Self.installStub()
            defer { stub.remove() }
            let environment = Self.makeEnvironment(stub, updatesOnLaunch: updatesOnLaunch, store: store)
            await environment.start()
            let update = try #require(environment.tagDatabaseLaunchUpdate)
            await update.value
            #expect(try await store.version() == Self.expectedVersion)
            // One release request and one download: one update.
            #expect(stub.requests().count == 2)
        }
    }

    /// A store on a file opened without the mark keeps to the setting, as before (M2 re-review F5 N-3): off, no
    /// update at launch.
    @Test func aStoreOpenedWithoutTheMarkKeepsToTheSetting() async throws {
        try await Self.withFileStore(markedAsDamaged: false) { store in
            #expect(await !store.wasRebuiltFromDamage)
            let stub = Self.installStub()
            defer { stub.remove() }
            let environment = Self.makeEnvironment(stub, updatesOnLaunch: false, store: store)
            await environment.start()
            #expect(environment.tagDatabaseLaunchUpdate == nil)
            try await Task.sleep(for: .milliseconds(300))
            #expect(stub.requests().isEmpty)
            #expect(try await store.version() == "v0 old")
        }
    }

    /// Runs `body` with a store on a file in a fresh temporary directory, removed afterwards. The file holds
    /// `oldDatabase`; when `markedAsDamaged`, an earlier store marked it (`<name>.rebuild`, as `TagTranslationStore`
    /// does when SQLite finds the file damaged), so the store gets it rebuilt.
    private static func withFileStore(
        markedAsDamaged: Bool, _ body: (TagTranslationStore) async throws -> Void
    ) async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appending(path: "eros-tags-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let url = directory.appending(path: "TagTranslations.sqlite")
        do {
            let earlier = try TagTranslationStore(databaseURL: url)
            _ = try await earlier.replaceAll(with: oldDatabase, version: "v0 old")
        }
        if markedAsDamaged {
            try #require(manager.createFile(atPath: url.path(percentEncoded: false) + ".rebuild", contents: Data()))
        }
        try await body(TagTranslationStore(databaseURL: url))
    }

    @Test func mirrorTogglePrefixesRequests() async throws {
        let stub = Self.installStub()
        defer { stub.remove() }
        let environment = Self.makeEnvironment(stub, mirror: true)
        _ = try await environment.updateTagDatabase(force: false)
        let prefix = TagDatabaseUpdater.defaultMirrorPrefix.absoluteString
        let urls = stub.requests().compactMap { $0.url?.absoluteString }
        #expect(urls.count == 2)
        #expect(urls.allSatisfy { $0.hasPrefix(prefix) })
    }

    @Test func withoutTheMirrorRequestsGoToGitHub() async throws {
        let stub = Self.installStub()
        defer { stub.remove() }
        let environment = Self.makeEnvironment(stub, mirror: false)
        let result = try await environment.updateTagDatabase(force: false)
        #expect(result == .updated(version: Self.expectedVersion, count: 1))
        #expect(stub.requests().first?.url?.host() == "api.github.com")
        let again = try await environment.updateTagDatabase(force: false)
        #expect(again == .upToDate(version: Self.expectedVersion))
    }

    /// The update at launch and Update Now at once (L068a): the updater takes them as one, so there is one release
    /// request and one download, both callers get the update's result, and the new names are read. The first call's
    /// release request is held until the second has joined it (the updater's `waitingCallers`), so the two overlap
    /// however slowly the host runs (M2 re-review F3 M-9b).
    @Test func concurrentUpdatesDownloadOnce() async throws {
        let gate = ResponderGate()
        let stub = Self.installStub(holdingFirstRelease: gate)
        defer {
            gate.open()
            stub.remove()
        }
        let environment = Self.makeEnvironment(stub)
        let updater = try #require(environment.tagDatabase)
        let launch = Task { try await environment.updateTagDatabase(force: false) }
        #expect(await eventually { stub.requests().count == 1 })
        let manual = Task { try await environment.updateTagDatabase(force: false) }
        #expect(await eventually { await updater.waitingCallers == 2 })
        gate.open()
        let expected = TagDatabaseUpdateResult.updated(version: Self.expectedVersion, count: 1)
        #expect(try await launch.value == expected)
        #expect(try await manual.value == expected)
        #expect(stub.requests().count == 2)
        await environment.tagNames.prefetch([TagNameCacheTests.fakeTag])
        #expect(environment.tagNames.name(for: TagNameCacheTests.fakeTag) == "示例标签")
    }

    /// The mirror switched on while the update at launch hangs on GitHub (M2 re-review F3 M-2, F5 N-2): Update Now
    /// does not take that update's result, it waits for it to end and then goes through the mirror. The database is
    /// downloaded once all the same: the second update asks for the release only, and finds it imported. The
    /// environment keeps one updater.
    @Test func updateNowAfterSwitchingTheMirrorGoesThroughIt() async throws {
        let gate = ResponderGate()
        let stub = Self.installStub(holdingFirstRelease: gate)
        defer {
            gate.open()
            stub.remove()
        }
        let environment = Self.makeEnvironment(stub, mirror: false)
        let updater = try #require(environment.tagDatabase)
        let launch = Task { try await environment.updateTagDatabase(force: false) }
        #expect(await eventually { stub.requests().count == 1 })
        environment.settings.settings.usesTagDatabaseMirror = true
        #expect(environment.tagDatabaseMirror == TagDatabaseUpdater.defaultMirrorPrefix)
        let manual = Task { try await environment.updateTagDatabase(force: false) }
        #expect(await eventually { await updater.queuedCallers == 1 })
        #expect(await updater.waitingCallers == 1)
        gate.open()
        #expect(try await launch.value == .updated(version: Self.expectedVersion, count: 1))
        #expect(try await manual.value == .upToDate(version: Self.expectedVersion))
        let prefix = TagDatabaseUpdater.defaultMirrorPrefix.absoluteString
        let urls = stub.requests().compactMap { $0.url?.absoluteString }
        // GitHub's release and asset for the launch, then the mirror's release for Update Now.
        #expect(urls.count == 3)
        #expect(urls.prefix(2).allSatisfy { !$0.hasPrefix(prefix) })
        #expect(urls.last.map { $0.hasPrefix(prefix) && $0.hasSuffix("releases/latest") } == true)
        #expect(urls.filter { $0.hasSuffix("db.raw.json.gz") }.count == 1)
        #expect(environment.tagDatabase === updater)
    }

    /// A download larger than a tag database can be is refused, and the settings' footer says so rather than
    /// blaming the connection (L068a; the other failures keep their text until M8).
    @Test func anOversizedDownloadSaysSo() async throws {
        let stub = Self.installOversizedStub()
        defer { stub.remove() }
        let environment = Self.makeEnvironment(stub)
        do {
            _ = try await environment.updateTagDatabase(force: false)
            Issue.record("an oversized download was imported")
        } catch {
            #expect(error as? TagDatabaseUpdateError == .tooLarge)
            #expect(TagDatabaseSettings.failureText(for: error) == TagDatabaseSettings.tooLargeText)
        }
        #expect(TagDatabaseSettings.failureText(for: TagDatabaseError.tooLarge) == TagDatabaseSettings.tooLargeText)
        #expect(TagDatabaseSettings.tooLargeText == "Update failed. The download is larger than a tag database can be.")
        #expect(TagDatabaseSettings.failureText(for: URLError(.notConnectedToInternet))
            == "Update failed. Check your connection.")
        #expect(TagDatabaseSettings.failureText(for: TagDatabaseError.corruptArchive)
            == "Update failed. Check your connection.")
    }

    /// A database file found damaged (U5): the footer says it is downloaded again at the next launch, rather than
    /// blaming the connection (the store has marked the file; the next store opened on it starts empty, and the app
    /// downloads it then: `aRebuiltDatabaseIsDownloadedAgainAtLaunch`).
    @Test func aDamagedDatabaseSaysItIsDownloadedAgain() {
        #expect(TagDatabaseSettings.failureText(for: TagDatabaseError.damaged) == TagDatabaseSettings.damagedText)
        #expect(TagDatabaseSettings.damagedText
            == "The tag database is damaged. It will be downloaded again the next time Eros-SE starts.")
        // Logging it names the kind only (no path, no SQL); it must not trap either way.
        AppEnvironment.logTagDatabaseFailure("Updating the tag database", TagDatabaseError.damaged)
        AppEnvironment.logTagDatabaseFailure("Updating the tag database", URLError(.notConnectedToInternet))
    }
}
