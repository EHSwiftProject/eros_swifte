import Compression
import EHNetworkTesting
@testable import EHStore
import Foundation
import GRDB
import SQLite3
import Testing

/// The size limits and the full-text problem classes, below what the public API can reach without hundreds of MiB.
@Suite struct TagDatabaseInternalsTests {
    /// A gzip archive (one member, no header fields) of `content`, compressed with the system's raw DEFLATE.
    private static func gzip(_ content: Data) throws -> Data {
        var deflated = Data(count: max(content.count / 100, 1 << 16))
        let written = deflated.withUnsafeMutableBytes { destination in
            content.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.baseAddress!.assumingMemoryBound(to: UInt8.self), destination.count,
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self), source.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        try #require(written > 0)
        deflated.count = written
        func littleEndian(_ value: UInt32) -> [UInt8] { [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: value >> $0) } }
        let header: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]
        return Data(header) + deflated + Data(littleEndian(Gzip.crc32(content)) + littleEndian(UInt32(content.count)))
    }

    /// A well-formed archive whose content is one byte more than 64 MiB: refused, not inflated.
    @Test func archiveInflatingPastTheLimitIsRejected() throws {
        #expect(Gzip.maximumSize == 64 << 20)
        let archive = try Self.gzip(Data(count: (64 << 20) + 1))
        #expect(archive.count < 1 << 20)
        #expect(throws: TagDatabaseError.corruptArchive) { try Gzip.decompress(archive) }
        // One that fits the limit is read.
        #expect(try Gzip.decompress(Self.gzip(Data(count: 1 << 20))).count == 1 << 20)
    }

    /// Without a `Content-Length` the download is counted as it arrives, and refused once past the limit.
    @Test func downloadIsCountedAsItArrives() async throws {
        #expect(TagDatabaseUpdater.maximumDownloadSize == 32 << 20)
        let release = Data(#"""
            {"tag_name":"v9","published_at":"2026-10-01T00:00:00Z",
             "assets":[{"name":"db.raw.json.gz","browser_download_url":"https://example.invalid/db.raw.json.gz"}]}
            """#.utf8)
        let mock = MockURLProtocol.install { request in
            let path = request.url?.path(percentEncoded: false) ?? ""
            return MockResponse(body: path.hasSuffix("db.raw.json.gz") ? Data(count: 2048) : release)
        }
        defer { mock.remove() }
        let configuration = URLSessionConfiguration.ephemeral
        mock.configurator.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let store = try TagTranslationStore(inMemory: true)
        let updater = TagDatabaseUpdater(store: store, session: session, mirrorPrefix: nil, maximumDownloadSize: 1024)
        await #expect(throws: TagDatabaseUpdateError.tooLarge) { try await updater.update(force: false) }
        #expect(try await store.version() == nil)
        #expect(mock.requests().count == 2)
    }

    @Test(arguments: [
        (1, "no such module: fts5", nil),
        (1, "no such tokenizer: trigram", nil),
        (1, "near \"x\": syntax error", 1),
        (13, "database or disk is full", 13),
        (11, "database disk image is malformed", 11),
        (267, "no such module: fts5", 267),
        (1, nil, 1),
    ] as [(Int32, String?, Int32?)])
    func fullTextProblemsAreClassified(code: Int32, message: String?, failed: Int32?) {
        let problem = TagTranslationStore.classifyFullTextSearchFailure(resultCode: code, message: message)
        #expect(problem == (failed.map { .failed(resultCode: $0) } ?? .unsupported))
    }

    /// Only SQLite's words for a damaged file mark it for a rebuild (U5): `SQLITE_CORRUPT` with any of its extended
    /// codes, and `SQLITE_NOTADB`. A full disk, a read-only, busy or locked file, an I/O error, an interrupt, a file
    /// that cannot be opened, a denied permission or authorization (`SQLITE_AUTH`: a protected file read while the
    /// device is locked, as GRDB documents) never delete the user's database (M2 re-review F5 N-5, m-3).
    @Test(arguments: [
        (ResultCode.SQLITE_CORRUPT, true), (.SQLITE_CORRUPT_VTAB, true), (.SQLITE_CORRUPT_SEQUENCE, true),
        (.SQLITE_CORRUPT_INDEX, true), (.SQLITE_NOTADB, true),
        (.SQLITE_FULL, false), (.SQLITE_READONLY, false), (.SQLITE_READONLY_DBMOVED, false), (.SQLITE_BUSY, false),
        (.SQLITE_BUSY_SNAPSHOT, false), (.SQLITE_LOCKED, false), (.SQLITE_LOCKED_SHAREDCACHE, false),
        (.SQLITE_IOERR, false), (.SQLITE_IOERR_SHORT_READ, false), (.SQLITE_INTERRUPT, false),
        (.SQLITE_CANTOPEN, false), (.SQLITE_PERM, false), (.SQLITE_AUTH, false),
    ] as [(ResultCode, Bool)])
    func onlyDamageMeansARebuild(code: ResultCode, isDamage: Bool) {
        #expect(TagTranslationStore.meansDamage(DatabaseError(resultCode: code)) == isDamage)
    }

    /// An error that is not damage leaves the store's damage check as it came: no mark, and the next open keeps the
    /// database (M2 re-review F5 N-5). nil stands for a cancelled import (`CancellationError`).
    @Test(arguments: [
        ResultCode.SQLITE_FULL, .SQLITE_READONLY, .SQLITE_READONLY_DBMOVED, .SQLITE_BUSY, .SQLITE_LOCKED,
        .SQLITE_IOERR, .SQLITE_IOERR_SHORT_READ, .SQLITE_INTERRUPT, .SQLITE_AUTH, nil,
    ] as [ResultCode?])
    func anErrorThatIsNotDamageLeavesTheFile(code: ResultCode?) async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            let marker = dir.appending(path: "TagTranslations.sqlite.rebuild").path(percentEncoded: false)
            do {
                let store = try TagTranslationStore(databaseURL: url)
                #expect(try await store.replaceAll(with: TagSamples.json(), version: "v1") == 8)
                let thrown: any Error = code.map { DatabaseError(resultCode: $0) } ?? CancellationError()
                let caught = await #expect(throws: (any Error).self) { try await Self.check(thrown, on: store) }
                if let code {
                    #expect((caught as? DatabaseError)?.extendedResultCode == code)
                } else {
                    #expect(caught is CancellationError)
                }
                #expect(!FileManager.default.fileExists(atPath: marker))
            }
            let reopened = try TagTranslationStore(databaseURL: url)
            #expect(await !reopened.wasRebuiltFromDamage)
            #expect(try await reopened.version() == "v1")
        }
    }

    /// Throws `error` from inside the store's damage check (`checkingForDamage`), as a query of the store would.
    private static func check(_ error: any Error, on store: isolated TagTranslationStore) throws {
        try store.checkingForDamage { () throws -> Void in throw error }
    }

    /// An import made while the store searches with `LIKE` drops `fts_built`, even when it imports the version the
    /// index was built for (Update Now, forced): an index left behind (its DROP failed) then names other tags by the
    /// same row ids, and the next open with full-text search must rebuild it rather than trust the version.
    @Test func forcedReimportWithoutFullTextRebuildsOnOpen() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            do {
                let store = try TagTranslationStore(databaseURL: url)
                try #require(await store.usesFullTextSearch)
                #expect(try await store.replaceAll(with: TagSamples.json(), version: "v1") == 8)
            }
            do {
                let store = try TagTranslationStore(
                    databaseQueue: TagTranslationStore.openFile(at: url).databaseQueue, allowsFullTextSearch: false
                )
                // The index is back after the store dropped it (as if the DROP had failed), still built for v1.
                try Self.execute("""
                    CREATE VIRTUAL TABLE tag_fts
                    USING fts5(key, name, content='tag', content_rowid='id', tokenize='trigram');
                    INSERT INTO tag_fts(tag_fts) VALUES('rebuild');
                    INSERT OR REPLACE INTO meta(name, value) VALUES ('fts_built', 'v1');
                    """, on: url)
                let update = Data(#"{"data":[{"namespace":"female","data":{"fake fresh":{"name":"新鲜示例"}}}]}"#.utf8)
                #expect(try await store.replaceAll(with: update, version: "v1") == 1)
            }
            let store = try TagTranslationStore(databaseURL: url)
            try #require(await store.usesFullTextSearch)
            #expect(try await store.search("新鲜示", limit: 10).map(\.key) == ["fake fresh"])
        }
    }

    /// Runs `sql` on the database file at `url` with plain SQLite.
    private static func execute(_ sql: String, on url: URL) throws {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        let opened = sqlite3_open_v2(url.path(percentEncoded: false), &connection, SQLITE_OPEN_READWRITE, nil)
        try #require(opened == SQLITE_OK)
        try #require(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
    }
}
