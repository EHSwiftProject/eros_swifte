import EHModels
import EHNetworkTesting
@_spi(Testing) @testable import EHStore
import Foundation
import Synchronization
import Testing

/// Each test has a minute (`.timeLimit`): some hold the release request's answer (`MockGate`) until they let it go,
/// and one that never does must fail at the limit, not hang the run.
@Suite(.timeLimit(.minutes(1))) struct TagDatabaseUpdaterTests {
    private static let api = "https://api.github.com/repos/EhTagTranslation/Database/releases/latest"
    private static let asset = "https://example.invalid/download/v9.9999.0/db.raw.json.gz"
    private static let expectedVersion = "v9.9999.0 2026-10-01T00:00:00Z"
    private static let fakeTag = TagRef(namespace: "female", name: "fake tag")

    private static let textAsset =
        #"{"name":"db.text.json","browser_download_url":"https://example.invalid/download/v9.9999.0/db.text.json"}"#
    private static let rawAsset = #"{"name":"db.raw.json.gz","browser_download_url":"\#(asset)"}"#

    /// A made-up `releases/latest` body for v9.9999.0 with the given asset objects.
    private static func releaseJSON(assets: [String] = [textAsset, rawAsset]) -> Data {
        let assets = assets.joined(separator: ",")
        return Data(
            #"{"tag_name":"v9.9999.0","published_at":"2026-10-01T00:00:00Z","assets":[\#(assets)]}"#.utf8
        )
    }

    /// An updater on an in-memory store, talking to a mock that answers a path ending in `releases/latest` with
    /// `release` (the first of them held by `gate`, the second by `secondGate`, when there are), one ending in
    /// `db.raw.json.gz` with `asset`, and anything else with 404. `onAbandon` is the updater's hook for the moment the
    /// last caller of an update has left and its task is not cancelled yet; `onQueuedWaitEnd` its hook for the end of
    /// a call's wait for an update in flight.
    private struct Harness {
        let store: TagTranslationStore
        let updater: TagDatabaseUpdater
        let mock: MockSession
        let session: URLSession

        /// The absolute URL of every request so far, oldest first.
        var urls: [String] { mock.requests().map { $0.url?.absoluteString ?? "" } }

        init(
            importedVersion: String? = nil, mirrorPrefix: URL? = nil,
            release: MockResponse = MockResponse(body: TagDatabaseUpdaterTests.releaseJSON()),
            asset: MockResponse? = nil, gate: MockGate? = nil, secondGate: MockGate? = nil,
            onAbandon: (@Sendable () -> Void)? = nil, onQueuedWaitEnd: (@Sendable (String?) async -> Void)? = nil
        ) async throws {
            store = try TagTranslationStore(inMemory: true)
            if let importedVersion {
                #expect(try await store.replaceAll(with: TagSamples.gzip(), version: importedVersion) == 8)
            }
            let asset = try asset ?? MockResponse(body: TagSamples.gzip())
            let releases = Mutex(0)
            mock = MockURLProtocol.install { request in
                let path = request.url?.path(percentEncoded: false) ?? ""
                if path.hasSuffix("releases/latest") {
                    let number = releases.withLock { count in
                        count += 1
                        return count
                    }
                    guard let held = number == 1 ? gate : number == 2 ? secondGate : nil else { return release }
                    return MockResponse(
                        status: release.status, headers: release.headers, body: release.body, heldBy: held
                    )
                }
                if path.hasSuffix("db.raw.json.gz") { return asset }
                return MockResponse(status: 404)
            }
            let configuration = URLSessionConfiguration.ephemeral
            mock.configurator.apply(to: configuration)
            session = URLSession(configuration: configuration)
            updater = TagDatabaseUpdater(
                store: store, session: session, mirrorPrefix: mirrorPrefix,
                maximumDownloadSize: TagDatabaseUpdater.maximumDownloadSize, onAbandon: onAbandon,
                onQueuedWaitEnd: onQueuedWaitEnd
            )
        }

        func close() {
            mock.remove()
            session.finishTasksAndInvalidate()
        }

        /// The sample imported as `version` is still there.
        func expectSampleKept(version: String) async throws {
            #expect(try await store.version() == version)
            #expect(try await store.translation(for: TagDatabaseUpdaterTests.fakeTag)?.name == "示例标签")
        }
    }

    // MARK: - Releases

    @Test func latestReleaseReadsVersionAndAsset() async throws {
        let h = try await Harness()
        defer { h.close() }
        let release = try await h.updater.latestRelease()
        #expect(release == TagDatabaseRelease(version: Self.expectedVersion, assetURL: try #require(URL(string: Self.asset))))
        let requests = h.mock.requests()
        #expect(requests.map { $0.url?.absoluteString } == [Self.api])
        let request = try #require(requests.first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.httpMethod == "GET")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == 30)
    }

    @Test func missingAssetThrows() async throws {
        let h = try await Harness(release: MockResponse(body: Self.releaseJSON(assets: [Self.textAsset])))
        defer { h.close() }
        await #expect(throws: TagDatabaseUpdateError.missingAsset) { try await h.updater.update(force: false) }
        #expect(h.urls == [Self.api])
    }

    @Test func htmlReleaseIsMalformed() async throws {
        let h = try await Harness(release: MockResponse(body: Data("<!DOCTYPE html><html></html>".utf8)))
        defer { h.close() }
        await #expect(throws: TagDatabaseUpdateError.malformedRelease) { try await h.updater.latestRelease() }
    }

    @Test(arguments: [
        "[]", #"{"message":"API rate limit exceeded"}"#, #"{"tag_name":1,"published_at":"x","assets":[]}"#,
        #"{"tag_name":"v1","assets":[]}"#, #"{"tag_name":"v1","published_at":null,"assets":[]}"#, "",
    ])
    func wrongShapeIsMalformed(_ body: String) async throws {
        let h = try await Harness(release: MockResponse(body: Data(body.utf8)))
        defer { h.close() }
        await #expect(throws: TagDatabaseUpdateError.malformedRelease) { try await h.updater.latestRelease() }
    }

    // MARK: - Updates

    @Test func newVersionIsImported() async throws {
        let h = try await Harness()
        defer { h.close() }
        #expect(try await h.updater.update(force: false) == .updated(version: Self.expectedVersion, count: 8))
        #expect(try await h.store.version() == Self.expectedVersion)
        #expect(try await h.store.translation(for: Self.fakeTag)?.name == "示例标签")
        let requests = h.mock.requests()
        #expect(requests.map { $0.url?.absoluteString } == [Self.api, Self.asset])
        let download = try #require(requests.last)
        #expect(download.value(forHTTPHeaderField: "Accept") != "application/vnd.github+json")
        #expect(download.httpMethod == "GET")
        #expect(download.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(download.timeoutInterval == 30)
    }

    @Test func sameVersionIsUpToDate() async throws {
        let h = try await Harness(importedVersion: Self.expectedVersion)
        defer { h.close() }
        #expect(try await h.updater.update(force: false) == .upToDate(version: Self.expectedVersion))
        #expect(h.urls == [Self.api])
    }

    @Test func forceImportsAgain() async throws {
        let h = try await Harness(importedVersion: Self.expectedVersion)
        defer { h.close() }
        #expect(try await h.updater.update(force: true) == .updated(version: Self.expectedVersion, count: 8))
        #expect(h.urls == [Self.api, Self.asset])
    }

    @Test func mirrorPrefixesBothRequests() async throws {
        let h = try await Harness(mirrorPrefix: URL(string: "https://mirror.invalid")!)
        defer { h.close() }
        #expect(try await h.updater.update(force: false) == .updated(version: Self.expectedVersion, count: 8))
        #expect(h.urls == [
            "https://mirror.invalid/https://api.github.com/repos/EhTagTranslation/Database/releases/latest",
            "https://mirror.invalid/https://example.invalid/download/v9.9999.0/db.raw.json.gz",
        ])
        // The release keeps the asset's own address; only the request goes through the mirror.
        #expect(try await h.updater.latestRelease().assetURL.absoluteString == Self.asset)
    }

    @Test func defaultMirrorIsFlutters() {
        #expect(TagDatabaseUpdater.defaultMirrorPrefix.absoluteString == "https://ghproxy.homeboyc.cn/")
    }

    @Test func mirrorPrefixEndingInSlashIsNotDoubled() async throws {
        let h = try await Harness(mirrorPrefix: TagDatabaseUpdater.defaultMirrorPrefix)
        defer { h.close() }
        _ = try await h.updater.latestRelease()
        // Flutter's kCDNApiUrl.
        #expect(h.urls == [
            "https://ghproxy.homeboyc.cn/https://api.github.com/repos/EhTagTranslation/Database/releases/latest",
        ])
    }

    // MARK: - Failures keep the old database

    @Test(arguments: [403, 404, 500])
    func httpErrorKeepsOldData(_ status: Int) async throws {
        let h = try await Harness(importedVersion: "v1", release: MockResponse(status: status, body: Self.releaseJSON()))
        defer { h.close() }
        await #expect(throws: TagDatabaseUpdateError.httpStatus(status)) { try await h.updater.update(force: false) }
        try await h.expectSampleKept(version: "v1")
        #expect(h.urls == [Self.api])
    }

    @Test func assetHTTPErrorKeepsOldData() async throws {
        let h = try await Harness(importedVersion: "v1", asset: MockResponse(status: 404))
        defer { h.close() }
        await #expect(throws: TagDatabaseUpdateError.httpStatus(404)) { try await h.updater.update(force: false) }
        try await h.expectSampleKept(version: "v1")
        #expect(h.urls == [Self.api, Self.asset])
    }

    @Test func corruptDownloadKeepsOldData() async throws {
        let truncated = try TagSamples.gzip().dropLast(20)
        let h = try await Harness(importedVersion: "v1", asset: MockResponse(body: Data(truncated)))
        defer { h.close() }
        await #expect(throws: TagDatabaseError.corruptArchive) { try await h.updater.update(force: false) }
        try await h.expectSampleKept(version: "v1")
    }

    /// A download that says it is larger than 32 MiB is refused before its body is read; the store keeps its data.
    @Test func oversizedAssetIsRejected() async throws {
        let h = try await Harness(
            importedVersion: "v1",
            asset: MockResponse(headers: ["Content-Length": "\((32 << 20) + 1)"], body: TagSamples.gzip())
        )
        defer { h.close() }
        await #expect(throws: TagDatabaseUpdateError.tooLarge) { try await h.updater.update(force: false) }
        try await h.expectSampleKept(version: "v1")
    }

    // MARK: - Concurrent updates

    /// One step of `run(_:on:)`.
    private enum Step {
        /// An update, forced or not, through the given mirror (the updater's own when `.updatersOwn`).
        case update(force: Bool, mirror: Mirror = .updatersOwn)
        /// Cancels the update the step at this index started.
        case cancel(Int)
    }

    /// The mirror one update goes through.
    private enum Mirror {
        case updatersOwn
        case given(URL?)
    }

    /// Runs `steps` in order on the updater's own executor: each update runs until it waits, so every call has met
    /// the others (and every cancellation has reached its caller) before anything has been downloaded, and before
    /// the updater can start an update's work. The tasks of the updates, in the order of their steps.
    private static func run(
        _ steps: [Step], on updater: isolated TagDatabaseUpdater
    ) -> [Task<TagDatabaseUpdateResult, any Error>] {
        var tasks: [Task<TagDatabaseUpdateResult, any Error>] = []
        var started: [Int: Task<TagDatabaseUpdateResult, any Error>] = [:]
        for (index, step) in steps.enumerated() {
            switch step {
            case .update(let force, .updatersOwn):
                let task = Task.immediate { try await updater.update(force: force) }
                started[index] = task
                tasks.append(task)
            case .update(let force, .given(let prefix)):
                let task = Task.immediate { try await updater.update(force: force, mirrorPrefix: prefix) }
                started[index] = task
                tasks.append(task)
            case .cancel(let target):
                started[target]?.cancel()
            }
        }
        return tasks
    }

    /// `run(_:on:)` with one plain or forced update per element of `forces`.
    private static func start(
        _ forces: [Bool], on updater: isolated TagDatabaseUpdater
    ) -> [Task<TagDatabaseUpdateResult, any Error>] {
        run(forces.map { .update(force: $0) }, on: updater)
    }

    /// The launch update and Update Now at once: one download and one import, and both callers get its result.
    @Test func concurrentUpdatesDownloadOnce() async throws {
        let h = try await Harness(importedVersion: "v1")
        defer { h.close() }
        let tasks = await Self.start([false, false], on: h.updater)
        let expected = TagDatabaseUpdateResult.updated(version: Self.expectedVersion, count: 8)
        for task in tasks {
            #expect(try await task.value == expected)
        }
        #expect(h.urls == [Self.api, Self.asset])
        // Once it is over, the next update runs on its own.
        #expect(try await h.updater.update(force: false) == .upToDate(version: Self.expectedVersion))
        #expect(h.urls == [Self.api, Self.asset, Self.api])
    }

    /// A forced update does not take the answer of a plain one in flight (it may have found the version stored): it
    /// waits for it to end, then runs. While the plain one's release request is held, the forced one has sent
    /// nothing.
    @Test func forcedUpdateRunsAfterAPlainOneInFlight() async throws {
        let gate = MockGate()
        let h = try await Harness(importedVersion: Self.expectedVersion, gate: gate)
        defer {
            gate.open()
            h.close()
        }
        let tasks = await Self.start([false, true], on: h.updater)
        #expect(await waitUntil { gate.heldCount == 1 })
        // Room for a forced update that did not wait to ask as well (the held answer does not hold the session's
        // other requests); one that waits never does.
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.urls == [Self.api])
        #expect(await h.updater.waitingCallers == 1)
        gate.open()
        #expect(try await tasks[0].value == .upToDate(version: Self.expectedVersion))
        #expect(try await tasks[1].value == .updated(version: Self.expectedVersion, count: 8))
        #expect(h.urls == [Self.api, Self.api, Self.asset])
    }

    /// Cancelling the only caller cancels the update, which then imports nothing: the caller is cancelled on the
    /// updater's executor, before the update can start its work.
    @Test func cancellingTheOnlyCallerStopsTheUpdate() async throws {
        let h = try await Harness(importedVersion: "v1")
        defer { h.close() }
        let tasks = await Self.run([.update(force: false), .cancel(0)], on: h.updater)
        await #expect(throws: CancellationError.self) { try await tasks[0].value }
        try await h.expectSampleKept(version: "v1")
        #expect(h.urls.isEmpty)
    }

    /// One caller of two going away leaves the update to the other; the one that went still gets its result.
    @Test func cancellingOneOfTwoCallersKeepsTheUpdate() async throws {
        let h = try await Harness(importedVersion: "v1")
        defer { h.close() }
        let tasks = await Self.run([.update(force: false), .update(force: false), .cancel(0)], on: h.updater)
        let expected = TagDatabaseUpdateResult.updated(version: Self.expectedVersion, count: 8)
        #expect(try await tasks[1].value == expected)
        #expect(try await tasks[0].value == expected)
        #expect(try await h.store.version() == Self.expectedVersion)
        #expect(h.urls == [Self.api, Self.asset])
    }

    /// A call that comes after the only caller of the update in flight was cancelled (Update Now tapped again) does
    /// not take that cancelled update: it waits for it to end and runs one of its own.
    @Test func aCallAfterTheOnlyCallerWasCancelledRunsAnew() async throws {
        let h = try await Harness(importedVersion: "v1")
        defer { h.close() }
        let tasks = await Self.run([.update(force: false), .cancel(0), .update(force: false)], on: h.updater)
        await #expect(throws: CancellationError.self) { try await tasks[0].value }
        #expect(try await tasks[1].value == .updated(version: Self.expectedVersion, count: 8))
        #expect(h.urls == [Self.api, Self.asset])
        #expect(try await h.store.version() == Self.expectedVersion)
    }

    /// Each update goes through the mirror its call gives (the app passes its setting with every call): with one,
    /// without one, and the updater's own when a call gives none.
    @Test func eachCallGoesThroughTheMirrorItGives() async throws {
        let mirror = try #require(URL(string: "https://mirror.invalid"))
        let h = try await Harness(importedVersion: Self.expectedVersion)
        defer { h.close() }
        let upToDate = TagDatabaseUpdateResult.upToDate(version: Self.expectedVersion)
        #expect(try await h.updater.update(force: false, mirrorPrefix: mirror) == upToDate)
        #expect(try await h.updater.update(force: false, mirrorPrefix: nil) == upToDate)
        #expect(h.urls == ["https://mirror.invalid/\(Self.api)", Self.api])
        let mirrored = try await Harness(importedVersion: Self.expectedVersion, mirrorPrefix: mirror)
        defer { mirrored.close() }
        _ = try await mirrored.updater.update(force: false)
        _ = try await mirrored.updater.update(force: false, mirrorPrefix: nil)
        #expect(mirrored.urls == ["https://mirror.invalid/\(Self.api)", Self.api])
    }

    /// A call that gives another mirror than the update in flight (the user switched the mirror meanwhile, perhaps
    /// because the first route hangs) does not take that update's result: it waits for the update to end, then runs
    /// through its own mirror. Both are plain, so the second asks for the release only, finds it imported and
    /// downloads nothing again (M2 re-review F5 N-2, option B).
    @Test func aCallThroughAnotherMirrorRunsAfterTheUpdateInFlight() async throws {
        let mirror = try #require(URL(string: "https://mirror.invalid"))
        let h = try await Harness(importedVersion: "v1")
        defer { h.close() }
        let tasks = await Self.run(
            [.update(force: false, mirror: .given(nil)), .update(force: false, mirror: .given(mirror))], on: h.updater
        )
        #expect(try await tasks[0].value == .updated(version: Self.expectedVersion, count: 8))
        #expect(try await tasks[1].value == .upToDate(version: Self.expectedVersion))
        #expect(h.urls == [Self.api, Self.asset, "https://mirror.invalid/\(Self.api)"])
    }

    /// Calls through the same mirror share the update in flight, however each writes it (the updater's own, or given
    /// with or without the final "/"): one download, one import.
    @Test func callsThroughTheSameMirrorShareTheUpdateInFlight() async throws {
        let mirror = try #require(URL(string: "https://mirror.invalid"))
        let slashed = try #require(URL(string: "https://mirror.invalid/"))
        let h = try await Harness(importedVersion: "v1", mirrorPrefix: mirror)
        defer { h.close() }
        let tasks = await Self.run(
            [
                .update(force: false), .update(force: false, mirror: .given(slashed)),
                .update(force: false, mirror: .given(mirror)),
            ],
            on: h.updater
        )
        let expected = TagDatabaseUpdateResult.updated(version: Self.expectedVersion, count: 8)
        for task in tasks {
            #expect(try await task.value == expected)
        }
        #expect(h.urls == ["https://mirror.invalid/\(Self.api)", "https://mirror.invalid/\(Self.asset)"])
    }

    /// The last caller of an update leaving (cancelled, on its own thread) makes the update abandoned at once, under
    /// the lock that counts its callers; its task is cancelled a moment later. A call in that moment does not join
    /// the update about to be cancelled (it would get its cancellation): it waits for the update to end and runs one
    /// of its own (M2 re-review F5 N-1). The leaving thread is held in that moment, so the call always falls into it.
    @Test func aCallAsTheLastCallerLeavesRunsAnew() async throws {
        let gate = MockGate()
        let abandon = AbandonGate()
        let h = try await Harness(importedVersion: "v1", gate: gate, onAbandon: abandon.hold)
        defer {
            abandon.open()
            gate.open()
            h.close()
        }
        let first = Task { try await h.updater.update(force: false) }
        #expect(await waitUntil { gate.heldCount == 1 })
        // Cancelled on a thread of its own, which the abandon hook holds.
        Thread { first.cancel() }.start()
        #expect(await waitUntil { abandon.isHolding })
        let second = Task { try await h.updater.update(force: false) }
        #expect(await waitUntil { await h.updater.queuedCallers == 1 })
        #expect(await h.updater.waitingCallers == 0)
        abandon.open()
        await #expect(throws: (any Error).self) { try await first.value }
        #expect(try await second.value == .updated(version: Self.expectedVersion, count: 8))
        #expect(h.urls == [Self.api, Self.api, Self.asset])
    }

    /// A call cancelled while it waits for an update in flight to end goes as soon as that update ends, even when
    /// another one it could not join has started meanwhile: it does not wait for that one as well (M2 re-review F5
    /// m-2). A plain update runs straight to GitHub (its release answer held); a call through a mirror and a forced
    /// one queue behind it, and the mirror call is cancelled. When the plain update ends, the mirror call is held
    /// where its wait ended (`onQueuedWaitEnd`) until the forced call has started its own update (its release answer
    /// held as well), so it always meets that update when it looks again.
    @Test func aCallCancelledInTheQueueGoesWhenItsWaitEnds() async throws {
        let mirror = try #require(URL(string: "https://mirror.invalid"))
        let first = MockGate()
        let second = MockGate()
        let waitEnd = QueueGate(holding: "https://mirror.invalid/")
        let h = try await Harness(
            importedVersion: "v1", gate: first, secondGate: second, onQueuedWaitEnd: { await waitEnd.pass($0) }
        )
        defer {
            waitEnd.open()
            first.open()
            second.open()
            h.close()
        }
        let tasks = await Self.run(
            [
                .update(force: false, mirror: .given(nil)), .update(force: false, mirror: .given(mirror)),
                .update(force: true, mirror: .given(nil)), .cancel(1),
            ],
            on: h.updater
        )
        #expect(await waitUntil { first.heldCount == 1 })
        #expect(await h.updater.queuedCallers == 2)
        first.open()
        #expect(await waitUntil { second.heldCount == 1 && waitEnd.isHolding })
        let ended = Mutex(false)
        let watcher = Task {
            _ = await tasks[1].result
            ended.withLock { $0 = true }
        }
        waitEnd.open()
        // Either it ends, or it waits again (queued behind the forced update, whose answer is still held).
        #expect(await waitUntil { await h.updater.queuedCallers == 1 || ended.withLock { $0 } })
        #expect(ended.withLock { $0 }, "The cancelled call waits for the forced update as well")
        #expect(await h.updater.queuedCallers == 0)
        second.open()
        await watcher.value
        await #expect(throws: CancellationError.self) { try await tasks[1].value }
        let expected = TagDatabaseUpdateResult.updated(version: Self.expectedVersion, count: 8)
        #expect(try await tasks[0].value == expected)
        #expect(try await tasks[2].value == expected)
        #expect(h.urls == [Self.api, Self.asset, Self.api, Self.asset])
    }

    /// Holds the calls through `prefix` where their wait for an update in flight ends (the updater's
    /// `onQueuedWaitEnd`) until `open()`, and lets every other call through.
    private final class QueueGate: Sendable {
        private struct State {
            var isOpen = false
            var held: [CheckedContinuation<Void, Never>] = []
        }

        private let prefix: String
        private let state = Mutex(State())

        init(holding prefix: String) {
            self.prefix = prefix
        }

        /// Whether a call is held.
        var isHolding: Bool { state.withLock { !$0.held.isEmpty } }

        func pass(_ prefix: String?) async {
            guard prefix == self.prefix else { return }
            await withCheckedContinuation { continuation in
                let isOpen = state.withLock { state in
                    if !state.isOpen { state.held.append(continuation) }
                    return state.isOpen
                }
                if isOpen { continuation.resume() }
            }
        }

        func open() {
            let held = state.withLock { state in
                state.isOpen = true
                defer { state.held = [] }
                return state.held
            }
            for continuation in held { continuation.resume() }
        }
    }

    /// Holds the thread that calls `hold()` (the updater's abandon hook) until `open()`; for at most 10 s, so a
    /// broken test does not hang the run.
    private final class AbandonGate: Sendable {
        private let holding = Mutex(false)
        private let semaphore = DispatchSemaphore(value: 0)

        /// Whether a thread has come to `hold()`.
        var isHolding: Bool { holding.withLock { $0 } }

        func hold() {
            holding.withLock { $0 = true }
            _ = semaphore.wait(timeout: .now() + 10)
        }

        func open() {
            semaphore.signal()
        }
    }

    @Test func transportErrorIsRethrown() async throws {
        let mock = MockURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        defer { mock.remove() }
        let configuration = URLSessionConfiguration.ephemeral
        mock.configurator.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let store = try TagTranslationStore(inMemory: true)
        let updater = TagDatabaseUpdater(store: store, session: session)
        let error = await #expect(throws: URLError.self) { try await updater.update(force: false) }
        #expect(error?.code == .notConnectedToInternet)
        #expect(try await store.version() == nil)
    }
}
