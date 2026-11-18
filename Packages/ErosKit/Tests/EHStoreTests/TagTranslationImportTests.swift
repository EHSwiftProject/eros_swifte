import EHModels
import EHStore
import Foundation
import SQLite3
import Testing

@Suite struct TagTranslationImportTests {
    private static let fakeTag = TagRef(namespace: "female", name: "fake tag")

    /// An in-memory store with the gzip sample imported as version "v1".
    private func sampleStore() async throws -> TagTranslationStore {
        let store = try TagTranslationStore(inMemory: true)
        #expect(try await store.replaceAll(with: TagSamples.gzip(), version: "v1") == 8)
        return store
    }

    /// The sample imported by `sampleStore()` is still there, under version "v1".
    private func expectSampleKept(in store: TagTranslationStore) async throws {
        #expect(try await store.version() == "v1")
        #expect(try await store.translation(for: Self.fakeTag)?.name == "示例标签")
    }

    @Test func importsTheGzipSample() async throws {
        let store = try TagTranslationStore(inMemory: true)
        #expect(try await store.version() == nil)
        #expect(try await store.replaceAll(with: TagSamples.gzip(), version: "v1") == 8)
        #expect(try await store.version() == "v1")
        #expect(try await store.translation(for: TagRef(namespace: "female", name: "fake tag")) == TagTranslation(
            namespace: "female", key: "fake tag", name: "示例标签",
            intro: "示例介绍，参见 `other:fake other` 与 `missing tag`。", links: ""
        ))
        let cosplayer = try await store.translation(for: TagRef(namespace: "cosplayer", name: "fake cosplayer"))
        #expect(cosplayer == TagTranslation(
            namespace: "cosplayer", key: "fake cosplayer", name: "示例扮演者", intro: "", links: ""
        ))
    }

    @Test func plainJSONImportsTheSame() async throws {
        let store = try TagTranslationStore(inMemory: true)
        #expect(try await store.replaceAll(with: TagSamples.json(), version: "v1") == 8)
        let long = try await store.translation(for: TagRef(namespace: "female", name: "fake long"))
        #expect(long?.name == "![图](https://example.invalid/a.png) 长示例")
        #expect(long?.links == "[链接](https://example.invalid/)")
    }

    @Test(arguments: [
        ("female", "fake tag", "示例标签"), ("f", "fake tag", "示例标签"), (" Female ", "Fake Tag ", "示例标签"),
        ("cos", "fake cosplayer", "示例扮演者"), (nil, "shared", "共享（其他）"), ("", "fake tag", "示例标签"),
        (nil, "female", nil), ("rows", "female", "女性"), ("x", "fake tag", nil), ("female", "", nil),
    ] as [(String?, String, String?)])
    func exactLookupRules(_ example: (namespace: String?, name: String, expected: String?)) async throws {
        let store = try await sampleStore()
        let tag = TagRef(namespace: example.namespace, name: example.name)
        #expect(try await store.translation(for: tag)?.name == example.expected)
    }

    @Test func reimportReplacesEverything() async throws {
        let store = try await sampleStore()
        let update = Data(#"{"data":[{"namespace":"female","data":{"new tag":{"name":"新"}}}]}"#.utf8)
        #expect(try await store.replaceAll(with: update, version: "v2") == 1)
        #expect(try await store.translation(for: Self.fakeTag) == nil)
        #expect(try await store.translation(for: TagRef(namespace: "female", name: "new tag"))?.name == "新")
        #expect(try await store.version() == "v2")
    }

    @Test func repeatedNamespaceLastWins() async throws {
        let store = try TagTranslationStore(inMemory: true)
        let file = Data(#"""
            {"data":[{"namespace":"female","data":{"a":{"name":"一"}}},{"namespace":"female","data":{"a":{"name":"二"}}}]}
            """#.utf8)
        #expect(try await store.replaceAll(with: file, version: "v1") == 1)
        #expect(try await store.translation(for: TagRef(namespace: "female", name: "a"))?.name == "二")
    }

    @Test func gzipHeaderFieldsAreSkipped() async throws {
        let store = try TagTranslationStore(inMemory: true)
        #expect(try await store.replaceAll(with: TagSamples.withHeaderFields(TagSamples.gzip()), version: "v1") == 8)
        #expect(try await store.translation(for: Self.fakeTag)?.name == "示例标签")
    }

    @Test func truncatedArchiveKeepsOldData() async throws {
        let store = try await sampleStore()
        let gzip = try TagSamples.gzip()
        await #expect(throws: TagDatabaseError.corruptArchive) {
            try await store.replaceAll(with: gzip.prefix(gzip.count - 20), version: "v2")
        }
        try await expectSampleKept(in: store)
    }

    @Test func flippedByteIsRejected() async throws {
        let store = try await sampleStore()
        var gzip = try TagSamples.gzip()
        gzip[gzip.count / 2] ^= 0xFF
        await #expect(throws: TagDatabaseError.corruptArchive) {
            try await store.replaceAll(with: gzip, version: "v2")
        }
        try await expectSampleKept(in: store)
    }

    @Test func extraFieldBeyondTheEndIsRejected() async throws {
        let store = try await sampleStore()
        let archive = try TagSamples.withExtraFieldBeyondTheEnd(TagSamples.gzip())
        await #expect(throws: TagDatabaseError.corruptArchive) {
            try await store.replaceAll(with: archive, version: "v2")
        }
        try await expectSampleKept(in: store)
    }

    @Test func unterminatedFileNameIsRejected() async throws {
        let store = try await sampleStore()
        await #expect(throws: TagDatabaseError.corruptArchive) {
            try await store.replaceAll(with: TagSamples.unterminatedFileName(), version: "v2")
        }
        try await expectSampleKept(in: store)
    }

    @Test(arguments: [
        Data([0x1F, 0x8B]),
        Data([0x1F, 0x8B, 0x08, 0x00, 0x01, 0x02, 0x03, 0x04, 0x02, 0x03]),
        TagSamples.archive(method: 0x07, flags: 0x00, fields: [0x01]),
        TagSamples.archive(flags: 0x20, fields: [0x01]),
        TagSamples.archive(flags: 0x04, fields: [0x01]),
        TagSamples.archive(flags: 0x10, fields: Array("fake comment".utf8)),
        TagSamples.archive(flags: 0x02, fields: [0x01]),
        TagSamples.archive(flags: 0x00, fields: []),
    ])
    func damagedHeaderIsRejected(_ archive: Data) async throws {
        let store = try await sampleStore()
        await #expect(throws: TagDatabaseError.corruptArchive) {
            try await store.replaceAll(with: archive, version: "v2")
        }
        try await expectSampleKept(in: store)
    }

    @Test func htmlBodyIsRejected() async throws {
        let store = try await sampleStore()
        let page = Data("<!DOCTYPE html><html><body>502 Bad Gateway</body></html>".utf8)
        await #expect(throws: TagDatabaseError.malformedJSON) {
            try await store.replaceAll(with: page, version: "v2")
        }
        try await expectSampleKept(in: store)
    }

    @Test(arguments: [#"{"message":"API rate limit exceeded"}"#, #"{"data":{}}"#, #"[{"data":[]}]"#, "null"])
    func wrongShapeIsRejected(_ body: String) async throws {
        let store = try await sampleStore()
        await #expect(throws: TagDatabaseError.malformedJSON) {
            try await store.replaceAll(with: Data(body.utf8), version: "v2")
        }
        try await expectSampleKept(in: store)
    }

    @Test(arguments: [#"{"data":[]}"#, #"{"data":[{"namespace":"","data":{}}]}"#])
    func emptyDataIsRejected(_ body: String) async throws {
        let store = try await sampleStore()
        await #expect(throws: TagDatabaseError.empty) {
            try await store.replaceAll(with: Data(body.utf8), version: "v2")
        }
        try await expectSampleKept(in: store)
    }

    @Test func malformedEntriesAreSkipped() async throws {
        let store = try TagTranslationStore(inMemory: true)
        let file = Data(#"""
            {"data":[
              {"data":{"fake missing":{"name":"示例缺命名空间"}}},
              {"namespace":"","data":{"fake empty":{"name":"示例空命名空间"}}},
              {"namespace":7,"data":{"fake number":{"name":"示例数字命名空间"}}},
              {"namespace":"female","data":["fake array"]},
              {"namespace":"female","data":"fake string"},
              "fake element",
              {"namespace":"male","data":{"fake string":"示例","fake number":5,"fake null":null,"fake array":[]}},
              {"namespace":"other","data":{
                "fake valid":{"name":"示例有效","intro":5,"links":null},
                "fake bare":{"name":["x"]}}}
            ]}
            """#.utf8)
        #expect(try await store.replaceAll(with: file, version: "v1") == 2)
        #expect(try await store.translation(for: TagRef(namespace: "other", name: "fake valid")) == TagTranslation(
            namespace: "other", key: "fake valid", name: "示例有效", intro: "", links: ""
        ))
        #expect(try await store.translation(for: TagRef(namespace: "other", name: "fake bare")) == TagTranslation(
            namespace: "other", key: "fake bare", name: "", intro: "", links: ""
        ))
        for name in ["fake missing", "fake empty", "fake number", "fake string", "fake null", "fake array"] {
            #expect(try await store.translation(for: TagRef(namespace: nil, name: name)) == nil)
        }
    }

    @Test func cancellationMidImportRollsBack() async throws {
        let store = try TagTranslationStore(inMemory: true)
        _ = try await store.replaceAll(with: TagSamples.gzip(), version: "v1")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.replaceAll(with: TagSamples.synthetic(count: 5_000), version: "v2")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.version() == "v1")
        #expect(try await store.translation(for: Self.fakeTag) != nil)
        #expect(try await store.translation(for: TagRef(namespace: "female", name: "fake 00000")) == nil)
        // The connection holds no open transaction and no leftover `kept` table: the next import goes through.
        #expect(try await store.replaceAll(with: TagSamples.synthetic(count: 5_000), version: "v3") == 5_000)
        #expect(try await store.version() == "v3")
        #expect(try await store.translation(for: TagRef(namespace: "female", name: "fake 04999"))?.name == "示例 04999")
        #expect(try await store.translation(for: Self.fakeTag) == nil)
    }

    @Test func largeImportFinishes() async throws {
        let store = try TagTranslationStore(inMemory: true)
        let file = TagSamples.synthetic(count: 50_000)
        let clock = ContinuousClock()
        let start = clock.now
        #expect(try await store.replaceAll(with: file, version: "v1") == 50_000)
        #expect(clock.now - start < .seconds(30))
        #expect(try await store.translation(for: TagRef(namespace: "female", name: "fake 49999"))?.name == "示例 49999")
    }

    @Test func fullTextSearchIsAvailable() async throws {
        #expect(try await TagTranslationStore(inMemory: true).usesFullTextSearch == true)
    }

    @Test func fullTextProblemIsNilWhenAvailable() async throws {
        let store = try TagTranslationStore(inMemory: true)
        #expect(await store.usesFullTextSearch)
        #expect(await store.fullTextSearchProblem == nil)
        // Turned off on purpose (tests only) is no problem either.
        let withoutFullText = try TagTranslationStore(inMemory: true, allowsFullTextSearch: false)
        #expect(await withoutFullText.fullTextSearchProblem == nil)
    }

    /// An index left from an earlier import (its rebuild skipped: the store opened without full-text search, and the
    /// index could not be dropped) is rebuilt when the store opens with full-text search again, because the version it
    /// was built for is not the database's.
    @Test func staleIndexIsRebuiltOnOpen() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            do {
                let store = try TagTranslationStore(databaseURL: url)
                try #require(await store.usesFullTextSearch)
                #expect(try await store.replaceAll(with: TagSamples.json(), version: "v1") == 8)
            }
            // v2 imported without touching `tag_fts`: its rows are not in the index.
            try Self.execute("""
                DELETE FROM tag;
                INSERT INTO tag(namespace, key, name, intro, links) VALUES ('female', 'fake stale', '示例过期', '', '');
                UPDATE meta SET value = 'v2' WHERE name = 'version';
                """, on: url)
            #expect(try Self.rows(of: url, sql: Self.matchingKeys("示例过")) == [])
            let store = try TagTranslationStore(databaseURL: url)
            try #require(await store.usesFullTextSearch)
            #expect(try Self.rows(of: url, sql: Self.matchingKeys("示例过")) == ["fake stale"])
            #expect(try Self.rows(of: url, sql: Self.matchingKeys("示例标")) == [])
            #expect(try await store.search("示例过", limit: 10).map(\.key) == ["fake stale"])
        }
    }

    /// Plain JSON is held to the same 64 MiB as a decompressed archive: a body past it is not parsed.
    @Test func oversizedPlainJSONIsRejected() async throws {
        let store = try await sampleStore()
        let body = Data(repeating: UInt8(ascii: " "), count: 64 << 20) + Data("{}".utf8)
        await #expect(throws: TagDatabaseError.tooLarge) {
            try await store.replaceAll(with: body, version: "v2")
        }
        try await expectSampleKept(in: store)
    }

    /// An archive whose trailer claims more than 64 MiB is refused before anything is decompressed.
    @Test func archiveClaimingMoreThanTheLimitIsRejected() async throws {
        let store = try await sampleStore()
        let size = UInt32((64 << 20) + 1)
        let trailer = [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: size >> $0) }
        let archive = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03] + [0, 0, 0, 0] + trailer)
        #expect(archive.count == 18)
        await #expect(throws: TagDatabaseError.corruptArchive) {
            try await store.replaceAll(with: archive, version: "v2")
        }
        try await expectSampleKept(in: store)
    }

    @Test func fullTextSearchCanBeTurnedOff() async throws {
        let store = try TagTranslationStore(inMemory: true, allowsFullTextSearch: false)
        #expect(await store.usesFullTextSearch == false)
        #expect(try await store.replaceAll(with: TagSamples.gzip(), version: "v1") == 8)
        #expect(try await store.translation(for: Self.fakeTag)?.name == "示例标签")
        #expect(try await store.translation(for: TagRef(namespace: nil, name: "shared"))?.name == "共享（其他）")
    }

    @Test func fileDatabasePersists() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "a/TagTranslations.sqlite")
            do {
                let store = try TagTranslationStore(databaseURL: url)
                #expect(try await store.replaceAll(with: TagSamples.gzip(), version: "v1") == 8)
            }
            let reopened = try TagTranslationStore(databaseURL: url)
            try await expectSampleKept(in: reopened)
        }
    }

    @Test func importOrderIsFileOrderThenKey() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            do {
                let store = try TagTranslationStore(databaseURL: url)
                #expect(try await store.replaceAll(with: TagSamples.json(), version: "v1") == 8)
            }
            #expect(try Self.rows(of: url, sql: "SELECT id, namespace, key FROM tag ORDER BY id") == [
                "1 rows female", "2 rows other", "3 female fake long", "4 female fake tag", "5 female shared",
                "6 other fake other", "7 other shared", "8 cosplayer fake cosplayer",
            ])
        }
    }

    @Test func reimportKeepsUseTimesOfKeptKeys() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            do {
                let store = try TagTranslationStore(databaseURL: url)
                #expect(try await store.replaceAll(with: TagSamples.json(), version: "v1") == 8)
            }
            try Self.execute("UPDATE tag SET lastUseTime = 900001 WHERE key IN ('fake tag', 'fake long')", on: url)
            let store = try TagTranslationStore(databaseURL: url)
            let update = Data(#"""
                {"data":[{"namespace":"female","data":{"fake tag":{"name":"示例新"},"fake new":{"name":"示例"}}}]}
                """#.utf8)
            #expect(try await store.replaceAll(with: update, version: "v2") == 2)
            #expect(try Self.rows(of: url, sql: "SELECT key, name, lastUseTime FROM tag ORDER BY id") == [
                "fake new 示例 0", "fake tag 示例新 900001",
            ])
        }
    }

    @Test func fullTextIndexFollowsEachImport() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            let store = try TagTranslationStore(databaseURL: url)
            try #require(await store.usesFullTextSearch)
            #expect(try await store.replaceAll(with: TagSamples.json(), version: "v1") == 8)
            #expect(try Self.rows(of: url, sql: Self.matchingKeys("示例标")) == ["fake tag"])
            let update = Data(#"{"data":[{"namespace":"female","data":{"fake new":{"name":"新示例标签"}}}]}"#.utf8)
            #expect(try await store.replaceAll(with: update, version: "v2") == 1)
            #expect(try Self.rows(of: url, sql: Self.matchingKeys("示例标")) == ["fake new"])
        }
    }

    @Test func fullTextIndexIsRebuiltWhenCreatedOverOldRows() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            do {
                let store = try TagTranslationStore(databaseURL: url)
                #expect(try await store.replaceAll(with: TagSamples.json(), version: "v1") == 8)
            }
            try Self.execute("DROP TABLE tag_fts", on: url)
            let store = try TagTranslationStore(databaseURL: url)
            try #require(await store.usesFullTextSearch)
            #expect(try Self.rows(of: url, sql: Self.matchingKeys("示例标")) == ["fake tag"])
        }
    }

    /// A file SQLite cannot open (not a database) is deleted with its companions and created again empty at the
    /// open, and the store says so (`wasRebuiltFromDamage`, for that open only), as for a file an earlier store
    /// marked: the app downloads the database then (M2 re-review F5 N-3, ruled 2026-11-18).
    @Test func corruptDatabaseFileIsRebuilt() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            let wal = dir.appending(path: "TagTranslations.sqlite-wal")
            try Data(repeating: UInt8(ascii: "x"), count: 4096).write(to: url)
            try Data(repeating: UInt8(ascii: "x"), count: 4096).write(to: wal)
            do {
                let store = try TagTranslationStore(databaseURL: url)
                #expect(await store.wasRebuiltFromDamage)
                #expect(try await store.version() == nil)
                #expect(!FileManager.default.fileExists(atPath: wal.path(percentEncoded: false)))
                #expect(try await store.replaceAll(with: TagSamples.gzip(), version: "v1") == 8)
                try await expectSampleKept(in: store)
            }
            let later = try TagTranslationStore(databaseURL: url)
            #expect(await !later.wasRebuiltFromDamage)
            try await expectSampleKept(in: later)
        }
    }

    /// A file whose header is whole but whose schema page is damaged: SQLite reports it corrupt as soon as the store
    /// reads the schema at the open, which rebuilds it as it does a file that is not a database, and says so, for
    /// that open only.
    @Test func damagedSchemaIsRebuiltAtTheOpen() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            do {
                let store = try TagTranslationStore(databaseURL: url)
                #expect(try await store.replaceAll(with: TagSamples.json(), version: "v0") == 8)
            }
            try Self.damageSchema(in: url)
            do {
                let store = try TagTranslationStore(databaseURL: url)
                #expect(await store.wasRebuiltFromDamage)
                #expect(try await store.version() == nil)
                #expect(try await store.replaceAll(with: TagSamples.gzip(), version: "v1") == 8)
            }
            let later = try TagTranslationStore(databaseURL: url)
            #expect(await !later.wasRebuiltFromDamage)
            try await expectSampleKept(in: later)
        }
    }

    /// A file that is not there yet (a first install), or that is there but empty, opens as a new database: it was
    /// not rebuilt, so the app keeps to "Update on Launch".
    @Test(arguments: [false, true])
    func aNewFileIsNotARebuild(isThereEmpty: Bool) async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "a/TagTranslations.sqlite")
            if isThereEmpty {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data().write(to: url)
            }
            let store = try TagTranslationStore(databaseURL: url)
            #expect(await !store.wasRebuiltFromDamage)
            #expect(try await store.version() == nil)
            #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        }
    }

    /// U5 (L048b, option A): a file whose header and schema are whole but whose `tag` pages are damaged still opens.
    /// The first import that meets the damage throws `.damaged` and marks the file; the next store opened on it
    /// deletes it and starts empty, ready for the database to be downloaded again, and says so
    /// (`wasRebuiltFromDamage`, for that open only: the app downloads the database then, M2 re-review F5 N-3).
    @Test func damagedDataPageIsRebuiltOnNextOpen() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            let marker = dir.appending(path: "TagTranslations.sqlite.rebuild").path(percentEncoded: false)
            do {
                let store = try TagTranslationStore(databaseURL: url)
                #expect(try await store.replaceAll(with: TagSamples.json(), version: "v1") == 8)
            }
            try Self.damagePages(of: "tag", in: url)
            do {
                let store = try TagTranslationStore(databaseURL: url)
                #expect(!FileManager.default.fileExists(atPath: marker))
                #expect(await !store.wasRebuiltFromDamage)
                await #expect(throws: TagDatabaseError.damaged) {
                    try await store.replaceAll(with: TagSamples.gzip(), version: "v2")
                }
                #expect(FileManager.default.fileExists(atPath: marker))
            }
            do {
                let reopened = try TagTranslationStore(databaseURL: url)
                #expect(await reopened.wasRebuiltFromDamage)
                #expect(try await reopened.version() == nil)
                #expect(!FileManager.default.fileExists(atPath: marker))
                #expect(try await reopened.replaceAll(with: TagSamples.gzip(), version: "v2") == 8)
                #expect(try await reopened.translation(for: Self.fakeTag)?.name == "示例标签")
            }
            let later = try TagTranslationStore(databaseURL: url)
            #expect(await !later.wasRebuiltFromDamage)
            #expect(try await later.version() == "v2")
        }
    }

    /// A read that meets a damaged page throws `.damaged` and marks the file as well, as an import does. The mark is
    /// written once (M2 re-review F5 N-4): the lists ask for a page of names at a time, and every read meets the
    /// damage again.
    @Test func aReadThatMeetsDamageMarksTheFile() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            let marker = dir.appending(path: "TagTranslations.sqlite.rebuild").path(percentEncoded: false)
            do {
                let store = try TagTranslationStore(databaseURL: url)
                #expect(try await store.replaceAll(with: TagSamples.json(), version: "v1") == 8)
            }
            try Self.damagePages(of: "tag", in: url)
            let store = try TagTranslationStore(databaseURL: url)
            await #expect(throws: TagDatabaseError.damaged) { try await store.translation(for: Self.fakeTag) }
            #expect(FileManager.default.fileExists(atPath: marker))
            // Taken away (by the test), it is not written again.
            try FileManager.default.removeItem(atPath: marker)
            await #expect(throws: TagDatabaseError.damaged) { try await store.search("示例", limit: 10) }
            await #expect(throws: TagDatabaseError.damaged) { try await store.translation(for: Self.fakeTag) }
            #expect(!FileManager.default.fileExists(atPath: marker), "The mark was written again")
            // What the damage did not reach still reads.
            #expect(try await store.version() == "v1")
        }
    }

    /// The full-text index's own pages damaged beyond dropping it (M2 re-review F5 N-6): the self-check at the open
    /// meets the damage, and so does the DROP that should clear the index away. Nothing would read those pages again
    /// (the store searches with `LIKE`), so the open marks the file, and the next open rebuilds it.
    @Test func anIndexThatCannotBeDroppedMarksTheFile() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            let marker = dir.appending(path: "TagTranslations.sqlite.rebuild").path(percentEncoded: false)
            do {
                let store = try TagTranslationStore(databaseURL: url)
                try #require(await store.usesFullTextSearch)
                #expect(try await store.replaceAll(with: TagSamples.json(), version: "v1") == 8)
            }
            try Self.damagePages(of: "tag_fts_data", in: url)
            do {
                let store = try TagTranslationStore(databaseURL: url)
                #expect(await !store.usesFullTextSearch)
                let problem = await store.fullTextSearchProblem
                guard case .failed(let code)? = problem else {
                    Issue.record("No failure for a damaged index: \(String(describing: problem))")
                    return
                }
                #expect(code & 0xFF == 11, "SQLite result \(code)")
                // The DROP failed: the index is still there.
                #expect(try Self.rows(of: url, sql: Self.fullTextTable) == ["tag_fts"])
                #expect(FileManager.default.fileExists(atPath: marker))
                // What the damage did not reach still reads, until the next open.
                #expect(try await store.version() == "v1")
            }
            let reopened = try TagTranslationStore(databaseURL: url)
            #expect(await reopened.wasRebuiltFromDamage)
            #expect(try await reopened.version() == nil)
            #expect(!FileManager.default.fileExists(atPath: marker))
            #expect(await reopened.usesFullTextSearch)
        }
    }

    /// The full-text index damaged where the DROP can still clear it away (its structure record overwritten, its pages
    /// whole): the open drops it and searches with `LIKE`, without a mark, and the next open builds it again from the
    /// rows. Nothing of the user's is lost (the use times stay), as the self-check's failure alone never marks the
    /// file (M2 re-review F5 N-6).
    @Test func anIndexThatCanBeDroppedIsRebuiltWithoutAMark() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            let marker = dir.appending(path: "TagTranslations.sqlite.rebuild").path(percentEncoded: false)
            do {
                let store = try TagTranslationStore(databaseURL: url)
                try #require(await store.usesFullTextSearch)
                #expect(try await store.replaceAll(with: TagSamples.json(), version: "v1") == 8)
                try await store.markUsed(Self.fakeTag)
            }
            try Self.damageFullTextStructure(in: url)
            do {
                let store = try TagTranslationStore(databaseURL: url)
                #expect(await !store.usesFullTextSearch)
                let problem = await store.fullTextSearchProblem
                guard case .failed(let code)? = problem else {
                    Issue.record("No failure for a damaged index: \(String(describing: problem))")
                    return
                }
                #expect(code & 0xFF == 11, "SQLite result \(code)")
                // The DROP worked: the index is gone.
                #expect(try Self.rows(of: url, sql: Self.fullTextTable).isEmpty)
                #expect(!FileManager.default.fileExists(atPath: marker))
            }
            let reopened = try TagTranslationStore(databaseURL: url)
            #expect(await !reopened.wasRebuiltFromDamage)
            #expect(await reopened.usesFullTextSearch)
            #expect(try await reopened.version() == "v1")
            #expect(try await reopened.search("示例标", limit: 10).first?.key == "fake tag")
            #expect(try Self.rows(of: url, sql: "SELECT key FROM tag WHERE lastUseTime > 0") == ["fake tag"])
        }
    }

    @Test func databaseFileIsExcludedFromBackup() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "TagTranslations.sqlite")
            _ = try TagTranslationStore(databaseURL: url)
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true)
        }
    }

    /// SQL for the name of the full-text table, when it is there.
    private static let fullTextTable = "SELECT name FROM sqlite_schema WHERE name = 'tag_fts'"

    /// SQL for the keys whose key or name holds `text`, through the FTS5 index, in id order.
    private static func matchingKeys(_ text: String) -> String {
        #"SELECT tag.key FROM tag_fts JOIN tag ON tag.id = tag_fts.rowid "#
            + #"WHERE tag_fts MATCH '"\#(text)"' ORDER BY tag.id"#
    }

    /// Overwrites every page that holds `table` or one of its indexes (their root pages: the sample's rows fit in one)
    /// with 0xFF bytes, leaving the file's header and the schema on page 1 whole, so the file still opens.
    private static func damagePages(of table: String, in url: URL) throws {
        let pageSize = try #require(Int(try rows(of: url, sql: "PRAGMA page_size").first ?? ""))
        let pages = try rows(of: url, sql: "SELECT rootpage FROM sqlite_schema WHERE tbl_name = '\(table)'")
            .compactMap(Int.init)
        try #require(!pages.isEmpty)
        try #require(pages.allSatisfy { $0 > 1 })
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for page in pages {
            try handle.seek(toOffset: UInt64((page - 1) * pageSize))
            try handle.write(contentsOf: Data(repeating: 0xFF, count: pageSize))
        }
    }

    /// Overwrites the schema's page (page 1 after the 100-byte file header) of the database file at `url` with 0xFF
    /// bytes: the header still says it is a database, but reading the schema then fails with `SQLITE_CORRUPT`.
    private static func damageSchema(in url: URL) throws {
        let pageSize = try #require(Int(try rows(of: url, sql: "PRAGMA page_size").first ?? ""))
        let header = 100
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64(header))
        try handle.write(contentsOf: Data(repeating: 0xFF, count: pageSize - header))
        try handle.close()
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        let opened = sqlite3_open_v2(url.path(percentEncoded: false), &connection, SQLITE_OPEN_READONLY, nil)
        try #require(opened == SQLITE_OK)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepared = sqlite3_prepare_v2(connection, "SELECT count(*) FROM sqlite_schema", -1, &statement, nil)
        try #require(prepared & 0xFF == SQLITE_CORRUPT, "Reading the damaged schema gave SQLite result \(prepared)")
    }

    /// Overwrites FTS5's structure record of `tag_fts` (the blob of `tag_fts_data` row 10) with 0xFF bytes where it
    /// stands in the file at `url`: the record no longer decodes, but every page stays whole. (SQL cannot write it:
    /// the system SQLite keeps shadow tables read-only.)
    private static func damageFullTextStructure(in url: URL) throws {
        let structure = try #require(try blob(of: url, sql: "SELECT block FROM tag_fts_data WHERE id = 10"))
        var file = try Data(contentsOf: url)
        let ranges = file.ranges(of: structure)
        try #require(ranges.count == 1, "The structure record stands \(ranges.count) times in the file")
        file.replaceSubrange(ranges[0], with: Data(repeating: 0xFF, count: structure.count))
        try file.write(to: url)
    }

    /// The first column of the first row `sql` reads from the database file at `url`, as bytes; nil without a row.
    private static func blob(of url: URL, sql: String) throws -> Data? {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        let opened = sqlite3_open_v2(url.path(percentEncoded: false), &connection, SQLITE_OPEN_READONLY, nil)
        try #require(opened == SQLITE_OK)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        return sqlite3_column_blob(statement, 0).map { Data(bytes: $0, count: count) }
    }

    /// Runs `sql` on the database file at `url` with plain SQLite.
    private static func execute(_ sql: String, on url: URL) throws {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        let opened = sqlite3_open_v2(url.path(percentEncoded: false), &connection, SQLITE_OPEN_READWRITE, nil)
        try #require(opened == SQLITE_OK)
        try #require(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
    }

    /// Reads `sql` from the database file at `url` with plain SQLite, one space-separated line per row.
    private static func rows(of url: URL, sql: String) throws -> [String] {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        let opened = sqlite3_open_v2(url.path(percentEncoded: false), &connection, SQLITE_OPEN_READONLY, nil)
        try #require(opened == SQLITE_OK)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK)
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columns = (0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            rows.append(columns.joined(separator: " "))
        }
        return rows
    }
}
