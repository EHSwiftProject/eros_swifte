import EHModels
import Foundation
import GRDB

/// Why a `TagTranslationStore` searches with `LIKE` instead of its full-text index, for the app's log: a system
/// without FTS5 (expected, and lasting) is told from a failure (a full disk, a damaged file). It holds no path and no
/// SQL.
public enum FullTextSearchProblem: Sendable, Equatable {
    /// The system SQLite has no FTS5 module or no `trigram` tokenizer.
    case unsupported
    /// Setting up the index failed with this SQLite result code (the extended one where SQLite gives it), such as
    /// `SQLITE_FULL` (13) or `SQLITE_CORRUPT` (11). The next open tries again.
    case failed(resultCode: Int32)
}

/// EhTagTranslation's tag translations in one SQLite database, imported from `db.raw.json(.gz)`.
///
/// The `tag` table holds one row per namespace and key. When the system SQLite has FTS5 with the `trigram` tokenizer,
/// an external-content FTS5 table `tag_fts` indexes `key` and `name` for substring search (the counterpart of
/// Flutter's Isar `contains`); otherwise every search uses `LIKE`. By default the database is the file
/// Application Support/TagTranslations.sqlite, excluded from backups because it can be downloaded again.
///
/// A file that SQLite finds damaged while it is in use (an import or a read meets `SQLITE_CORRUPT` or
/// `SQLITE_NOTADB`) is marked with an empty file beside it, `<name>.rebuild`, and the call throws
/// `TagDatabaseError.damaged`; so is one whose full-text index is damaged beyond dropping it at the open. The next
/// store opened on the file deletes it, starts empty and says so (`wasRebuiltFromDamage`), so that the app downloads
/// the database again (user decision U5, 2026-11-17: rebuild and download at the next launch). A file SQLite cannot
/// open at all (not a database, or corrupt as soon as the schema is read) is rebuilt at that open, and said so too.
public actor TagTranslationStore {
    /// The database. Internal for the query extension in TagTranslationStore+Queries.swift.
    let dbQueue: DatabaseQueue

    /// Where `markDamaged()` puts the mark for the next open (`damageMarkerURL(for:)`); nil in memory.
    private let damageMarker: URL?

    /// Whether this store has left the mark (`markDamaged()`, or the full-text set-up at the open): once is enough, as
    /// only the next open reads it (M2 re-review F5 N-4).
    private var isMarkedDamaged: Bool

    /// Whether `tag_fts` passed its self-check when the store opened; fixed for the life of the store.
    public let usesFullTextSearch: Bool

    /// Why `usesFullTextSearch` is false; nil when it is true, and when full-text search was not allowed (tests).
    public let fullTextSearchProblem: FullTextSearchProblem?

    /// Whether the open deleted a damaged file and started empty: the file was marked as damaged by an earlier store
    /// (see the type), or SQLite found it was not a database or corrupt. The app then downloads the database again,
    /// whatever its update-at-launch setting (U5 promised it; M2 re-review F5 N-3). For that open only: the next one
    /// finds the rebuilt file. False in memory, and for a file that is not there yet, is empty or opens whole.
    public let wasRebuiltFromDamage: Bool

    /// Opens the database file at `databaseURL`, creating it and the directories above it when missing.
    ///
    /// A file that SQLite reports as not a database or corrupt, and one an earlier store marked as damaged (see the
    /// type), is deleted, with its `-journal`, `-wal` and `-shm` companions, and created again empty
    /// (`wasRebuiltFromDamage`). The file is excluded from backups.
    /// - Throws: When a directory cannot be created, a damaged file cannot be deleted, or the database cannot be
    ///   opened even after a rebuild.
    public init(databaseURL: URL) throws {
        let file = try Self.openFile(at: databaseURL)
        self.init(
            databaseQueue: file.databaseQueue, allowsFullTextSearch: true,
            damageMarker: Self.damageMarkerURL(for: databaseURL), wasRebuiltFromDamage: file.wasRebuiltFromDamage
        )
    }

    /// Opens a database of its own in memory, or the default file Application Support/TagTranslations.sqlite.
    ///
    /// - Throws: As `init(databaseURL:)`.
    public init(inMemory: Bool) throws {
        try self.init(inMemory: inMemory, allowsFullTextSearch: true)
    }

    /// Sets up full-text search on `databaseQueue`, which `openFile(at:)` or `openInMemory()` has opened and
    /// migrated; every other initializer delegates here. `damageMarker` is where the file's damage is marked
    /// (`damageMarkerURL(for:)` of its URL); nil in memory. `wasRebuiltFromDamage` is whether `openFile(at:)` rebuilt
    /// the file.
    init(
        databaseQueue: DatabaseQueue, allowsFullTextSearch: Bool, damageMarker: URL? = nil,
        wasRebuiltFromDamage: Bool = false
    ) {
        let setUp = Self.setUpFullTextSearch(
            in: databaseQueue, allowed: allowsFullTextSearch, damageMarker: damageMarker
        )
        usesFullTextSearch = setUp.isUsable
        fullTextSearchProblem = setUp.problem
        isMarkedDamaged = setUp.markedDamage
        dbQueue = databaseQueue
        self.damageMarker = damageMarker
        self.wasRebuiltFromDamage = wasRebuiltFromDamage
    }

    /// The version of the imported database, or nil before the first import.
    ///
    /// - Throws: `TagDatabaseError.damaged` (see the type); other database errors.
    public func version() throws -> String? {
        try checkingForDamage {
            try dbQueue.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM meta WHERE name = 'version'")
            }
        }
    }

    /// Replaces every translation with the content of `data`, then records `version`.
    ///
    /// `data` is `db.raw.json`, gzipped or not, at most 64 MiB (`Gzip.maximumSize`) once decompressed. It is
    /// decompressed and parsed first, so that a bad file leaves the store as it was. Then one transaction deletes the
    /// old rows, inserts the new ones, carries the use times of keys that are still there over to their new rows,
    /// rebuilds the full-text index (recording the version it was built for) and writes the version last. When the
    /// task is cancelled during the inserts, the transaction rolls back.
    /// - Returns: The number of rows now in the store.
    /// - Throws: `TagDatabaseError` for a file that is not a complete database (`.tooLarge` for plain JSON over the
    ///   limit, `.corruptArchive` for an archive whose content is), and `.damaged` for a database file SQLite finds
    ///   damaged (see the type); `CancellationError`; other database errors. The previous translations and version
    ///   stay in every case.
    public func replaceAll(with data: Data, version: String) throws -> Int {
        guard Gzip.isArchive(data) || data.count <= Gzip.maximumSize else { throw TagDatabaseError.tooLarge }
        let json = Gzip.isArchive(data) ? try Gzip.decompress(data) : data
        let entries = try TagDatabaseFile.entries(from: json)
        let rebuildsFullTextIndex = usesFullTextSearch
        return try checkingForDamage { try dbQueue.write { db in
            // A failed import rolls `kept` back with everything else: temp schema changes are transactional too.
            try db.execute(sql: """
                CREATE TEMP TABLE kept AS SELECT namespace, key, lastUseTime FROM tag WHERE lastUseTime > 0
                """)
            try db.execute(sql: "DELETE FROM tag")
            let insert = try db.makeStatement(sql: """
                INSERT OR REPLACE INTO tag(namespace, key, name, intro, links) VALUES (?, ?, ?, ?, ?)
                """)
            for (offset, entry) in entries.enumerated() {
                try insert.execute(arguments: [entry.namespace, entry.key, entry.name, entry.intro, entry.links])
                if (offset + 1).isMultiple(of: 1000) {
                    // Thrown inside the transaction, so the whole import rolls back. This closure runs on GRDB's
                    // queue: the synchronous `write` ends in `SerializedDatabase`'s `queue.sync`, and libdispatch
                    // runs a sync block on the calling thread where it can, so the current task (and whether it is
                    // cancelled) is still visible here. Should that change, cancellation would silently stop
                    // working, and `cancellationMidImportRollsBack` would fail.
                    try Task.checkCancellation()
                }
            }
            try db.execute(sql: """
                UPDATE tag SET lastUseTime = kept.lastUseTime FROM kept
                WHERE tag.namespace = kept.namespace AND tag.key = kept.key
                """)
            try db.execute(sql: "DROP TABLE kept")
            if rebuildsFullTextIndex {
                try db.execute(sql: "INSERT INTO tag_fts(tag_fts) VALUES('rebuild')")
            }
            // Without a rebuild, an index left behind no longer matches: the next open with FTS5 rebuilds it.
            try Self.recordFullTextIndex(builtFor: rebuildsFullTextIndex ? version : nil, in: db)
            try db.execute(sql: "INSERT OR REPLACE INTO meta(name, value) VALUES ('version', ?)", arguments: [version])
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM tag") ?? 0
        } }
    }

    /// The translation of `tag`, following Flutter's `IsarHelper.findTagTranslate`.
    ///
    /// The namespace and the name are trimmed and lowercased; an empty name finds nothing and an empty namespace
    /// counts as none. An abbreviated namespace is expanded with `TagNamespace`; any other namespace, such as
    /// "rows", is looked up as is. Without a namespace, the last imported row with that key outside "rows" wins.
    /// - Throws: `TagDatabaseError.damaged` (see the type); other database errors.
    public func translation(for tag: TagRef) throws -> TagTranslation? {
        guard let tag = Self.normalized(tag) else { return nil }
        return try checkingForDamage {
            try dbQueue.read { db in
                guard let id = try Self.rowID(forNormalized: tag, in: db) else { return nil }
                return try Row.fetchOne(
                    db, sql: "SELECT namespace, key, name, intro, links FROM tag WHERE id = ?", arguments: [id]
                ).map(Self.translation(from:))
            }
        }
    }

    // MARK: - Internal, shared with TagTranslationStore+Queries.swift

    /// The id of the row `translation(for:)` reads for `tag`, or nil when there is none.
    func rowID(for tag: TagRef) throws -> Int64? {
        guard let tag = Self.normalized(tag) else { return nil }
        return try checkingForDamage {
            try dbQueue.read { db in
                try Self.rowID(forNormalized: tag, in: db)
            }
        }
    }

    /// `body`'s result; an error by which SQLite says the file is damaged (`SQLITE_CORRUPT` with any of its extended
    /// codes, `SQLITE_NOTADB`) marks the file (`markDamaged()`) and becomes `TagDatabaseError.damaged`. Every query
    /// of the store runs in it.
    func checkingForDamage<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as DatabaseError where Self.meansDamage(error) {
            markDamaged()
            throw TagDatabaseError.damaged
        }
    }

    /// Whether `error` is SQLite's word for a damaged file. `resultCode` is the primary code, so
    /// `SQLITE_CORRUPT_VTAB`, `_SEQUENCE` and `_INDEX` count as `SQLITE_CORRUPT`.
    static func meansDamage(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
    }

    /// Leaves the empty file `damageMarker` for the next open (`openFile(at:)`), which then rebuilds the database;
    /// once (`isMarkedDamaged`). A mark that cannot be written is let go: the damage is met again, and marked again,
    /// on the next query.
    private func markDamaged() {
        guard let damageMarker, !isMarkedDamaged else { return }
        isMarkedDamaged = Self.leaveDamageMark(at: damageMarker)
    }

    /// Writes the empty file `marker`; whether it was written.
    private static func leaveDamageMark(at marker: URL) -> Bool {
        FileManager.default.createFile(atPath: marker.path(percentEncoded: false), contents: Data())
    }

    /// The id of the row for `tag`, already passed through `normalized(_:)`.
    ///
    /// With a namespace: that namespace and key. Without: the key in any namespace but "rows" (which holds the
    /// translations of namespace names), the highest id first, like Flutter's `lastOrNull`.
    static func rowID(forNormalized tag: TagRef, in db: Database) throws -> Int64? {
        if let namespace = tag.namespace {
            return try Int64.fetchOne(
                db, sql: "SELECT id FROM tag WHERE namespace = ? AND key = ?", arguments: [namespace, tag.name]
            )
        }
        return try Int64.fetchOne(
            db, sql: "SELECT id FROM tag WHERE key = ? AND namespace <> 'rows' ORDER BY id DESC LIMIT 1",
            arguments: [tag.name]
        )
    }

    /// `tag` as the database stores it: the name and namespace trimmed and lowercased, an empty namespace dropped and
    /// an abbreviated one expanded; nil when the name is empty.
    static func normalized(_ tag: TagRef) -> TagRef? {
        let name = normalizedText(tag.name)
        guard !name.isEmpty else { return nil }
        let namespace = tag.namespace.map(normalizedText).flatMap { namespace in
            namespace.isEmpty ? nil : TagNamespace.fullName(for: namespace) ?? namespace
        }
        return TagRef(namespace: namespace, name: name)
    }

    /// `text` trimmed and lowercased, the way keys are stored in `db.raw`.
    static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A row with the columns namespace, key, name, intro and links, as a value.
    static func translation(from row: Row) -> TagTranslation {
        TagTranslation(
            namespace: row["namespace"], key: row["key"], name: row["name"], intro: row["intro"], links: row["links"]
        )
    }

    // MARK: - Opening

    /// Application Support/TagTranslations.sqlite.
    static var defaultDatabaseURL: URL {
        URL.applicationSupportDirectory.appending(path: "TagTranslations.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE tag (id INTEGER PRIMARY KEY, namespace TEXT NOT NULL, key TEXT NOT NULL,
                                  name TEXT NOT NULL, intro TEXT NOT NULL, links TEXT NOT NULL,
                                  lastUseTime INTEGER NOT NULL DEFAULT 0, UNIQUE (namespace, key));
                CREATE INDEX tag_on_key ON tag(key);
                CREATE INDEX tag_on_lastUseTime ON tag(lastUseTime);
                CREATE TABLE meta (name TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
        }
        return migrator
    }

    /// The file beside the database at `url` that marks it as damaged: its name with ".rebuild" added.
    static func damageMarkerURL(for url: URL) -> URL {
        URL(filePath: url.path(percentEncoded: false) + damageMarkerSuffix)
    }

    /// What `damageMarkerURL(for:)` adds to the database's name.
    private static let damageMarkerSuffix = ".rebuild"

    /// Opens and migrates a database of its own in memory.
    static func openInMemory() throws -> DatabaseQueue {
        let databaseQueue = try DatabaseQueue()
        try migrator.migrate(databaseQueue)
        return databaseQueue
    }

    /// The database `openFile(at:)` opened, and whether it rebuilt the file: deleted it first for the mark of an
    /// earlier store, or after SQLite found it was not a database or corrupt.
    struct OpenedFile {
        let databaseQueue: DatabaseQueue
        let wasRebuiltFromDamage: Bool
    }

    /// Opens and migrates the file at `url`, and excludes it from backups. A file an earlier store marked as damaged
    /// (`damageMarkerURL(for:)`) is deleted first, with the mark; one SQLite then finds is not a database or corrupt
    /// (`meansDamage(_:)`) is deleted and opened again, once. Either is a rebuild (`OpenedFile.wasRebuiltFromDamage`);
    /// a file that is not there yet, or is empty, is not.
    static func openFile(at url: URL) throws -> OpenedFile {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let isMarked = FileManager.default.fileExists(atPath: damageMarkerURL(for: url).path(percentEncoded: false))
        if isMarked {
            try removeDatabaseFiles(at: url)
        }
        var isRebuilt = isMarked
        let databaseQueue: DatabaseQueue
        do {
            databaseQueue = try openAndMigrate(url)
        } catch let error as DatabaseError where meansDamage(error) {
            try removeDatabaseFiles(at: url)
            databaseQueue = try openAndMigrate(url)
            isRebuilt = true
        }
        // A failure is ignored: the database can be downloaded again, and losing every translation over a backup
        // flag would cost far more than a few megabytes in the user's backup.
        var fileURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? fileURL.setResourceValues(values)
        return OpenedFile(databaseQueue: databaseQueue, wasRebuiltFromDamage: isRebuilt)
    }

    /// Opens the file at `url` and runs the migrations; closes the connection again when they fail.
    private static func openAndMigrate(_ url: URL) throws -> DatabaseQueue {
        let databaseQueue = try DatabaseQueue(path: url.path(percentEncoded: false))
        do {
            try migrator.migrate(databaseQueue)
        } catch {
            try? databaseQueue.close()
            throw error
        }
        return databaseQueue
    }

    /// Deletes the database file at `url` and its `-journal`, `-wal` and `-shm` companions, then the damage mark,
    /// where they exist: the mark last, so that a deletion cut short is tried again at the next open.
    private static func removeDatabaseFiles(at url: URL) throws {
        let manager = FileManager.default
        for suffix in ["", "-journal", "-wal", "-shm", damageMarkerSuffix] {
            let path = url.path(percentEncoded: false) + suffix
            if manager.fileExists(atPath: path) {
                try manager.removeItem(atPath: path)
            }
        }
    }

    /// What `setUpFullTextSearch(in:allowed:damageMarker:)` found.
    private struct FullTextSetUp {
        /// Whether searches can use `tag_fts`.
        var isUsable: Bool
        /// Why not, when the check failed.
        var problem: FullTextSearchProblem?
        /// Whether it marked the file as damaged: the index could not even be dropped.
        var markedDamage = false
    }

    /// Creates `tag_fts` when allowed, checks that FTS5 with `trigram` answers a query, and rebuilds the index when it
    /// may not match the rows; drops the table otherwise.
    ///
    /// The index is rebuilt when the table is new over rows that are already there, and when it was not built for the
    /// version the database holds (`meta` row `fts_built`, which `replaceAll` writes): an import made while the store
    /// searched with `LIKE` left the old index behind, and its row ids now name other tags. When the check fails, or
    /// full-text search is not allowed, the table is dropped (with `fts_built`), so that a later open with FTS5 never
    /// reads a stale index. A damaged index that drops is built again at the next open, and nothing else is lost; one
    /// whose DROP meets the damage as well stays in the file, which nothing reads again, so it marks the file at
    /// `damageMarker` (M2 re-review F5 N-6).
    private static func setUpFullTextSearch(
        in databaseQueue: DatabaseQueue, allowed: Bool, damageMarker: URL?
    ) -> FullTextSetUp {
        var problem: FullTextSearchProblem?
        if allowed {
            do {
                try databaseQueue.write { db in
                    let isNew = try !db.tableExists("tag_fts")
                    try db.execute(sql: """
                        CREATE VIRTUAL TABLE IF NOT EXISTS tag_fts
                        USING fts5(key, name, content='tag', content_rowid='id', tokenize='trigram')
                        """)
                    _ = try Row.fetchOne(db, sql: #"SELECT rowid FROM tag_fts WHERE tag_fts MATCH '"abc"' LIMIT 1"#)
                    let version = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE name = 'version'")
                    let builtFor = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE name = 'fts_built'")
                    let hasRows = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM tag)") == true
                    if hasRows, isNew || builtFor != version {
                        try db.execute(sql: "INSERT INTO tag_fts(tag_fts) VALUES('rebuild')")
                        try recordFullTextIndex(builtFor: version, in: db)
                    }
                }
                return FullTextSetUp(isUsable: true)
            } catch let error as DatabaseError {
                problem = classifyFullTextSearchFailure(
                    resultCode: error.extendedResultCode.rawValue, message: error.message
                )
            } catch {
                problem = .failed(resultCode: ResultCode.SQLITE_ERROR.rawValue)
            }
        }
        do {
            try databaseQueue.write { db in
                try db.execute(sql: "DROP TABLE IF EXISTS tag_fts")
                try recordFullTextIndex(builtFor: nil, in: db)
            }
        } catch let error as DatabaseError where meansDamage(error) {
            return FullTextSetUp(
                isUsable: false, problem: problem, markedDamage: damageMarker.map(leaveDamageMark(at:)) ?? false
            )
        } catch {
            // Any other failure is let go: the next open drops it again.
        }
        return FullTextSetUp(isUsable: false, problem: problem)
    }

    /// Records the version `tag_fts` was last rebuilt for (`meta` row `fts_built`); nil removes the record, so that the
    /// next open with full-text search rebuilds the index.
    private static func recordFullTextIndex(builtFor version: String?, in db: Database) throws {
        if let version {
            try db.execute(sql: "INSERT OR REPLACE INTO meta(name, value) VALUES ('fts_built', ?)", arguments: [version])
        } else {
            try db.execute(sql: "DELETE FROM meta WHERE name = 'fts_built'")
        }
    }

    /// What a failed set-up of `tag_fts` means: `.unsupported` for SQLite's own words for a missing FTS5 module or
    /// `trigram` tokenizer (always a plain `SQLITE_ERROR`), `.failed` with `resultCode` for anything else.
    static func classifyFullTextSearchFailure(resultCode: Int32, message: String?) -> FullTextSearchProblem {
        let missing = ["no such module: fts5", "no such tokenizer: trigram"]
        if resultCode == ResultCode.SQLITE_ERROR.rawValue, let message, missing.contains(where: message.contains) {
            return .unsupported
        }
        return .failed(resultCode: resultCode)
    }
}

extension TagTranslationStore {
    /// Tests only: `allowsFullTextSearch: false` skips the FTS5 self-check and always uses LIKE.
    public init(inMemory: Bool, allowsFullTextSearch: Bool) throws {
        if inMemory {
            try self.init(databaseQueue: Self.openInMemory(), allowsFullTextSearch: allowsFullTextSearch)
        } else {
            let url = Self.defaultDatabaseURL
            let file = try Self.openFile(at: url)
            self.init(
                databaseQueue: file.databaseQueue, allowsFullTextSearch: allowsFullTextSearch,
                damageMarker: Self.damageMarkerURL(for: url), wasRebuiltFromDamage: file.wasRebuiltFromDamage
            )
        }
    }
}
