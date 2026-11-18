import CryptoKit
import Foundation

/// What a cached response is stored under: the URL as requested and the account/profile scope
/// (`CookieStore.cacheScope(for:)`), so one account's page is never served to another account or profile.
public struct CacheKey: Sendable, Hashable {
    public let url: URL
    public let scope: String

    public init(url: URL, scope: String) {
        self.url = url
        self.scope = scope
    }
}

/// A response as the cache keeps it on disk.
///
/// Page bodies can hold account content; `set-cookie` is never kept (see `ResponseCache.store(_:for:)`).
public struct CachedResponse: Sendable, Equatable, Codable {
    public let status: Int
    /// The URL of the response, after any redirects.
    public let url: URL
    public let headers: [String: String]
    public let body: Data
    public let storedAt: Date

    public init(status: Int, url: URL, headers: [String: String], body: Data, storedAt: Date) {
        self.status = status
        self.url = url
        self.headers = headers
        self.body = body
        self.storedAt = storedAt
    }
}

/// Successful GET pages on disk, one file per `CacheKey`, for at most `maximumAge`.
///
/// The file name is the lowercase hex SHA-256 of `scope + "\n" + url`. Failures to read or write a file are not
/// reported: a cache that cannot be read is a miss, one that cannot be written is skipped. `EHClient` decides what
/// may be stored (GET, 2xx, no site notice); the cache only refuses to keep `set-cookie`, because cookies live in the
/// Keychain alone.
public actor ResponseCache {
    /// Three days.
    public static let maximumAge: Duration = .seconds(259_200)

    private let directory: URL
    private let now: @Sendable () -> Date
    /// One more on every `removeAll()`: `store(_:for:ifGeneration:)` keeps out a response asked for before it.
    private(set) var generation: UInt64 = 0

    public init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    /// The cache's clock, for stamping `storedAt` with the time `lookup` measures age against.
    public nonisolated func currentDate() -> Date {
        now()
    }

    /// `<cachesDirectory>/HTTPCache`, created when missing; `cachesDirectory` nil (the app): the user's Caches
    /// directory. Tests pass a temporary directory, so nothing is left in the Mac's `~/Library/Caches`.
    public static func standard(cachesDirectory: URL? = nil) throws -> ResponseCache {
        let caches = try cachesDirectory ?? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = caches.appending(path: "HTTPCache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ResponseCache(directory: directory)
    }

    /// The stored response, or nil when there is none. One older than `maximumAge` (or stored in the future, after
    /// the clock moved back), or one that does not decode, is deleted and counts as a miss.
    public func lookup(_ key: CacheKey) -> CachedResponse? {
        let file = fileURL(for: key)
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let cached = try? JSONDecoder().decode(CachedResponse.self, from: data) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        let age = now().timeIntervalSince(cached.storedAt)
        guard age >= 0, age <= Self.maximumAgeInSeconds else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return cached
    }

    /// Writes `response` under `key`, replacing an older one, without its `set-cookie` header (any case).
    public func store(_ response: CachedResponse, for key: CacheKey) {
        store(response, for: key, ifGeneration: nil)
    }

    /// `store(_:for:)` unless `removeAll()` ran after `generation` was read (nil: no check). `EHClient` reads the
    /// generation before a request goes out, so a page that comes back after a logout cleared the cache stays out.
    func store(_ response: CachedResponse, for key: CacheKey, ifGeneration generation: UInt64?) {
        if let generation, generation != self.generation { return }
        let kept = response.headers.filter { $0.key.lowercased() != "set-cookie" }
        let stored = CachedResponse(
            status: response.status, url: response.url, headers: kept, body: response.body,
            storedAt: response.storedAt
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: key), options: .atomic)
        } catch {
            // Skipped: the next request simply goes to the network.
        }
    }

    public func remove(_ key: CacheKey) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// Deletes every file in the directory (the directory stays). A response `EHClient` asked for before is not
    /// stored afterwards.
    public func removeAll() {
        generation += 1
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static var maximumAgeInSeconds: TimeInterval {
        TimeInterval(maximumAge.components.seconds)
    }

    private func fileURL(for key: CacheKey) -> URL {
        let digest = SHA256.hash(data: Data((key.scope + "\n" + key.url.absoluteString).utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name, directoryHint: .notDirectory)
    }
}
