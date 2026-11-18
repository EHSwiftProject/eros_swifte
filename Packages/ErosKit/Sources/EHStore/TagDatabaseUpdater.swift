import Foundation
import Synchronization

/// The latest release of EhTagTranslation's database, as GitHub's `releases/latest` describes it.
public struct TagDatabaseRelease: Sendable, Equatable {
    /// `tag_name + " " + published_at`, the version string the Flutter app compares and stores.
    public let version: String
    /// The `browser_download_url` of the `db.raw.json.gz` asset, without a mirror prefix.
    public let assetURL: URL

    public init(version: String, assetURL: URL) {
        self.version = version
        self.assetURL = assetURL
    }
}

/// What `TagDatabaseUpdater.update(force:mirrorPrefix:)` did.
public enum TagDatabaseUpdateResult: Sendable, Equatable {
    /// The store already had this version; nothing was downloaded.
    case upToDate(version: String)
    /// This version was downloaded and imported; the store now holds `count` rows.
    case updated(version: String, count: Int)
}

/// Why `TagDatabaseUpdater` could not read a release or download its asset. The store keeps its previous data.
public enum TagDatabaseUpdateError: Error, Equatable {
    /// GitHub (or the mirror) answered with this status instead of 200.
    case httpStatus(Int)
    /// The release body is not a JSON object with string `tag_name` and `published_at` (an HTML error page, …).
    case malformedRelease
    /// The release has no `db.raw.json.gz` asset with a usable `browser_download_url`.
    case missingAsset
    /// The answer is larger than `TagDatabaseUpdater.maximumDownloadSize` (32 MiB), by its `Content-Length` or as
    /// it arrived; the rest of it is not read.
    case tooLarge
}

/// Downloads EhTagTranslation's `db.raw.json.gz` from its latest GitHub release into a `TagTranslationStore`,
/// following Flutter's `TagTransController` (common/controller/tag_trans_controller.dart).
///
/// With a mirror prefix both requests go through the mirror, written as the prefix followed by the original URL
/// (Flutter's `kCDNApiUrl` and `'$kCDNPrefix$_dbUrl'`): the updater's own (`init`), or the one a call gives
/// (`update(force:mirrorPrefix:)`), so that one updater serves a setting that changes. Concurrent updates through one
/// mirror are merged (`update(force:mirrorPrefix:)`): the launch update and Update Now at once download and import
/// once. One through another mirror runs after the one in flight: it asks for the release again, and downloads
/// nothing when that one imported it.
public actor TagDatabaseUpdater {
    /// GitHub's API for the latest release of EhTagTranslation/Database.
    static let releaseAPIURL = URL(string: "https://api.github.com/repos/EhTagTranslation/Database/releases/latest")!
    /// The asset `update(force:)` downloads.
    static let assetName = "db.raw.json.gz"
    /// Flutter waits up to 30 s to receive data (kReceiveTimeout).
    static let timeout: TimeInterval = 30
    /// The most either request may bring: 32 MiB. The compressed database is a few MiB (about 12 MB once imported), so
    /// an answer from a mirror past this is refused rather than read into memory.
    static let maximumDownloadSize = 32 << 20

    private let store: TagTranslationStore
    private let session: URLSession
    /// The updater's own prefix as a string ending in "/" (`normalized(_:)`), or nil without a mirror.
    private let mirrorPrefix: String?
    /// `maximumDownloadSize`, smaller in tests.
    private let downloadLimit: Int
    /// The update in flight, which later calls join.
    private var current: Run?
    /// How many calls wait for the update in flight to end before they start (or join) one of their own.
    private var queued = 0
    /// Tests only: runs on the thread where the last caller of an update left, once the update counts as abandoned
    /// and before its task is cancelled.
    private let onAbandon: (@Sendable () -> Void)?
    /// Tests only: awaited, with the call's mirror prefix, when a call has waited for an update in flight to end and
    /// before it looks again.
    private let onQueuedWaitEnd: (@Sendable (String?) async -> Void)?

    /// - Parameters:
    ///   - store: The store the downloaded database is imported into.
    ///   - session: The session both requests are made with.
    ///   - mirrorPrefix: A proxy written in front of every request URL, such as `defaultMirrorPrefix`; a "/" is
    ///     added when it does not end in one. A call may give another (`update(force:mirrorPrefix:)`).
    public init(store: TagTranslationStore, session: URLSession = .shared, mirrorPrefix: URL? = nil) {
        self.init(store: store, session: session, mirrorPrefix: mirrorPrefix, maximumDownloadSize: Self.maximumDownloadSize)
    }

    /// As `init(store:session:mirrorPrefix:)`, with another download limit, an abandon hook and a hook for the end of
    /// a wait in the queue (tests).
    init(
        store: TagTranslationStore, session: URLSession, mirrorPrefix: URL?, maximumDownloadSize: Int,
        onAbandon: (@Sendable () -> Void)? = nil, onQueuedWaitEnd: (@Sendable (String?) async -> Void)? = nil
    ) {
        self.store = store
        self.session = session
        self.mirrorPrefix = Self.normalized(mirrorPrefix)
        downloadLimit = maximumDownloadSize
        self.onAbandon = onAbandon
        self.onQueuedWaitEnd = onQueuedWaitEnd
    }

    /// Reads the latest release from GitHub (through the updater's own mirror, when it has one).
    ///
    /// - Throws: `TagDatabaseUpdateError.httpStatus` for any status but 200, `.malformedRelease` or `.missingAsset`
    ///   for a body that does not describe a release with the asset; transport errors as they are.
    public func latestRelease() async throws -> TagDatabaseRelease {
        try await latestRelease(through: mirrorPrefix)
    }

    /// `update(force:mirrorPrefix:)` through the updater's own mirror (`init`).
    public func update(force: Bool) async throws -> TagDatabaseUpdateResult {
        try await update(force: force, through: mirrorPrefix)
    }

    /// Imports the latest release unless the store already has its version; `force` imports it anyway. Both requests
    /// go through `mirrorPrefix` (nil: straight to GitHub), instead of the updater's own; a "/" is added when it does
    /// not end in one.
    ///
    /// A call while an update is in flight through the same mirror waits for that update and returns its result (one
    /// download, one import), unless:
    /// - it is forced and the one in flight is not: it waits for that one to end and runs after it;
    /// - every caller of the one in flight was cancelled (it is being cancelled): it waits for that one to end and
    ///   runs one of its own, rather than getting its cancellation.
    ///
    /// A call through another mirror (the setting was switched meanwhile, perhaps because the first route hangs)
    /// waits for the one in flight to end too, then runs through its own mirror: a plain call asks for the release
    /// again and downloads nothing when that one imported it; after a failure, it tries its own route.
    ///
    /// A call cancelled while it waits for an update in flight to end (any of the three cases above) throws
    /// `CancellationError` as soon as that update ends, and starts or joins nothing, even when another update it may
    /// not join has started meanwhile. A caller cancelled once it has joined (or started) an update stops counting;
    /// the update is cancelled (and imports nothing) once no caller is left, but a caller still gets the update's
    /// own result or error.
    /// - Throws: As `latestRelease()`; `TagDatabaseUpdateError.httpStatus` or `.tooLarge` for the download;
    ///   `TagDatabaseError`, `CancellationError` or database errors from the import. The store keeps its previous data
    ///   and version on every error.
    public func update(force: Bool, mirrorPrefix: URL?) async throws -> TagDatabaseUpdateResult {
        try await update(force: force, through: Self.normalized(mirrorPrefix))
    }

    /// How many callers share the update in flight (the one that started it and those that joined, less those that
    /// were cancelled); 0 without one. Tests read it to know that a call has joined.
    @_spi(Testing) public var waitingCallers: Int {
        current?.callerCount ?? 0
    }

    /// How many calls wait for the update in flight to end before they start (or join) one of their own: through
    /// another mirror, forced after a plain one, or after its callers all left. Tests read it to know that a call
    /// waits.
    @_spi(Testing) public var queuedCallers: Int {
        queued
    }

    /// `update(force:mirrorPrefix:)` with the prefix already normalized.
    private func update(force: Bool, through prefix: String?) async throws -> TagDatabaseUpdateResult {
        let run = try await run(force: force, through: prefix)
        let result = await withTaskCancellationHandler {
            await run.task.result
        } onCancel: {
            run.leave()
        }
        if current === run { current = nil }
        return try result.get()
    }

    /// The update a call waits for: the one in flight when the call may join it (see `update(force:mirrorPrefix:)`),
    /// else a new one, once every update in flight it may not join has ended.
    /// - Throws: `CancellationError` when the call is cancelled by the time it would join or start one, or by the time
    ///   an update it waited for ends.
    private func run(force: Bool, through prefix: String?) async throws -> Run {
        while true {
            if let running = current, running.isAbandoned || running.prefix != prefix || (force && !running.force) {
                queued += 1
                _ = await running.task.result
                queued -= 1
                await onQueuedWaitEnd?(prefix)
                if current === running { current = nil }
                // Cancelled meanwhile: go now, rather than wait for an update started since (M2 re-review F5 m-2).
                try Task.checkCancellation()
                continue
            }
            try Task.checkCancellation()
            guard let running = current else {
                let run = Run(
                    force: force, prefix: prefix, task: Task { try await self.perform(force: force, through: prefix) },
                    onAbandon: onAbandon
                )
                current = run
                return run
            }
            if running.join() { return running }
            // Its last caller left (on another thread) since the check above: wait for it to end instead.
        }
    }

    /// One update as `update(force:mirrorPrefix:)` describes it, for every caller that waits for it.
    private func perform(force: Bool, through prefix: String?) async throws -> TagDatabaseUpdateResult {
        try Task.checkCancellation()
        let release = try await latestRelease(through: prefix)
        if !force, try await store.version() == release.version {
            return .upToDate(version: release.version)
        }
        let data = try await fetch(Self.request(for: Self.mirrored(release.assetURL, through: prefix)))
        let count = try await store.replaceAll(with: data, version: release.version)
        return .updated(version: release.version, count: count)
    }

    /// `latestRelease()` through `prefix`.
    private func latestRelease(through prefix: String?) async throws -> TagDatabaseRelease {
        var request = try Self.request(for: Self.mirrored(Self.releaseAPIURL, through: prefix))
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return try Self.release(from: await fetch(request))
    }

    /// An update in flight, the mirror it goes through, and how many callers wait for it; the last caller to go
    /// abandons it and cancels it.
    private final class Run: Sendable {
        let force: Bool
        /// The prefix its requests go through, normalized; nil straight to GitHub.
        let prefix: String?
        let task: Task<TagDatabaseUpdateResult, any Error>
        /// The callers that wait for it; nil once the last one has left (the run is abandoned: its task is cancelled,
        /// or about to be). Deciding that under the lock keeps a call from joining the run in between (M2 re-review
        /// F5 N-1).
        private let callers = Mutex<Int?>(1)
        private let onAbandon: (@Sendable () -> Void)?

        init(
            force: Bool, prefix: String?, task: Task<TagDatabaseUpdateResult, any Error>,
            onAbandon: (@Sendable () -> Void)?
        ) {
            self.force = force
            self.prefix = prefix
            self.task = task
            self.onAbandon = onAbandon
        }

        /// Whether its last caller has left: no call joins it any more.
        var isAbandoned: Bool { callers.withLock { $0 == nil } }

        /// The callers that wait for it now.
        var callerCount: Int { callers.withLock { $0 ?? 0 } }

        /// One more caller, unless the run was abandoned: false then (the call waits for it to end instead).
        func join() -> Bool {
            callers.withLock { count in
                guard let current = count else { return false }
                count = current + 1
                return true
            }
        }

        /// A caller was cancelled: called synchronously from its cancellation handler. The last one abandons the run,
        /// then cancels its task.
        func leave() {
            let isLast = callers.withLock { count -> Bool in
                guard let current = count else { return false }
                count = current > 1 ? current - 1 : nil
                return count == nil
            }
            if isLast {
                onAbandon?()
                task.cancel()
            }
        }
    }

    // MARK: - Requests

    /// `prefix` as a string ending in "/"; nil without one.
    private static func normalized(_ prefix: URL?) -> String? {
        prefix.map { prefix in
            let text = prefix.absoluteString
            return text.hasSuffix("/") ? text : text + "/"
        }
    }

    /// `url` behind `prefix` (normalized), or `url` itself without one.
    private static func mirrored(_ url: URL, through prefix: String?) throws -> URL {
        guard let prefix else { return url }
        guard let mirroredURL = URL(string: prefix + url.absoluteString) else { throw URLError(.badURL) }
        return mirroredURL
    }

    /// A GET for `url` that skips the local cache (Flutter's `refresh: true`) and times out after 30 s.
    private static func request(for url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    }

    /// The body of `request`'s response, counted as it arrives.
    ///
    /// - Throws: `TagDatabaseUpdateError.httpStatus` for any status but 200; `.tooLarge` once the body is past the
    ///   download limit, or at once when its `Content-Length` is; `URLError(.badServerResponse)` for a response that
    ///   is not HTTP; transport errors as they are.
    private func fetch(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        guard response.statusCode == 200 else {
            bytes.task.cancel()
            throw TagDatabaseUpdateError.httpStatus(response.statusCode)
        }
        guard response.expectedContentLength <= Int64(downloadLimit) else {
            bytes.task.cancel()
            throw TagDatabaseUpdateError.tooLarge
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < downloadLimit else {
                bytes.task.cancel()
                throw TagDatabaseUpdateError.tooLarge
            }
            data.append(byte)
        }
        return data
    }

    // MARK: - Parsing

    /// The release in a `releases/latest` body.
    ///
    /// The body must be a JSON object whose `tag_name` and `published_at` are strings (`.malformedRelease`
    /// otherwise). The asset is the last object in `assets` named `db.raw.json.gz` (Flutter maps names to URLs, so
    /// the last one wins); when there is none, or its `browser_download_url` is not a URL string, the release has no
    /// asset (`.missingAsset`).
    static func release(from data: Data) throws -> TagDatabaseRelease {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = object["tag_name"] as? String,
              let publishedAt = object["published_at"] as? String
        else {
            throw TagDatabaseUpdateError.malformedRelease
        }
        let assets = (object["assets"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        guard let asset = assets.last(where: { $0["name"] as? String == assetName }),
              let address = asset["browser_download_url"] as? String,
              let assetURL = URL(string: address)
        else {
            throw TagDatabaseUpdateError.missingAsset
        }
        return TagDatabaseRelease(version: tagName + " " + publishedAt, assetURL: assetURL)
    }
}

extension TagDatabaseUpdater {
    /// The CDN proxy the Flutter app offers (tag_trans_controller.dart:20); the app passes it when
    /// AppSettings.usesTagDatabaseMirror is on.
    public static let defaultMirrorPrefix = URL(string: "https://ghproxy.homeboyc.cn/")!
}
