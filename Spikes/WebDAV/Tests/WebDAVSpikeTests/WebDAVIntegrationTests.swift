import Foundation
import Testing
import WebDAVSpike

/// Live-server settings. Start a server with `scripts/serve-local-webdav.sh start` and export
/// what it prints. Without `WEBDAV_SPIKE_URL` the whole suite is skipped.
///
/// The tests delete and recreate sub-directories of the base URL (``freshClient(root:_:)``), so
/// they only run against a loopback host unless `WEBDAV_SPIKE_ALLOW_DESTRUCTIVE=1` is set.
enum Live {
    static let environment = ProcessInfo.processInfo.environment
    static let baseURL: URL? = environment["WEBDAV_SPIKE_URL"].flatMap { URL(string: $0) }
    static let digestURL: URL? = environment["WEBDAV_SPIKE_DIGEST_URL"].flatMap { URL(string: $0) }
    static let allowsDestructive = environment["WEBDAV_SPIKE_ALLOW_DESTRUCTIVE"] == "1"

    /// True for `127.0.0.1`, `localhost` and `::1`, or for any host when destructive runs are allowed.
    static func isDisposable(_ url: URL?) -> Bool {
        guard let host = url?.host(percentEncoded: false)?.lowercased() else { return false }
        return allowsDestructive || ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }
    /// Defaults are the fake account hard-coded in scripts/serve-local-webdav.sh.
    static let username = environment["WEBDAV_SPIKE_USER"] ?? "eros-spike"
    static let password = environment["WEBDAV_SPIKE_PASSWORD"] ?? "not-a-real-password"
    /// Where `writesRecordsTheLegacyClientCanRead` stores the values it uploaded, for the Dart check.
    static let expectedOutput: URL? = environment["WEBDAV_SPIKE_EXPECT_OUT"].map { URL(filePath: $0) }
    /// Sub-directory written by `golden/bin/legacy_client.dart write`, if that ran first.
    static let legacyBase: String? = environment["WEBDAV_SPIKE_LEGACY_BASE"]

    static func client(
        root: URL? = baseURL,
        _ subdirectory: String,
        password: String = password,
        authentication: WebDAVConfiguration.Authentication = .challenge
    ) -> WebDAVClient {
        WebDAVClient(configuration: WebDAVConfiguration(
            baseURL: root!.appending(path: subdirectory, directoryHint: .isDirectory),
            username: username,
            password: password,
            authentication: authentication
        ))
    }

    /// An empty sub-directory of the server root, used as a stand-in for a user's base URL.
    static func freshClient(root: URL? = baseURL, _ subdirectory: String) async throws -> WebDAVClient {
        let rootClient = client(root: root, "")
        _ = try await rootClient.delete("/\(subdirectory)/")
        #expect(try await rootClient.makeCollection("/\(subdirectory)/") == .created)
        return client(root: root, subdirectory)
    }
}

@Suite(
    "WebDAV against a live server",
    .serialized,
    .enabled(if: Live.baseURL != nil, "set WEBDAV_SPIKE_URL (see scripts/serve-local-webdav.sh)"),
    .enabled(
        if: Live.baseURL == nil || Live.isDisposable(Live.baseURL),
        "WEBDAV_SPIKE_URL is not a loopback host; these tests delete directories, set WEBDAV_SPIKE_ALLOW_DESTRUCTIVE=1 to run them anyway"
    )
)
struct WebDAVIntegrationTests {
    /// Step 5.1: the directory tree the legacy app creates at start-up.
    @Test func buildsTheLegacyDirectoryTree() async throws {
        let client = try await Live.freshClient("tree")
        try await client.ensureLegacyDirectories()
        for directory in LegacyLayout.startupDirectories {
            #expect(try await client.list(directory).isEmpty, "\(directory)")
        }
        #expect(Set(try await client.list(LegacyLayout.rootDirectory).map(\.name)) == ["history", "read", "group", "search"])
        #expect(Set(try await client.list(LegacyLayout.historyDirectory).map(\.name)) == ["s", "del"])
        try await client.ensureLegacyDirectories()
    }

    /// Step 5.2: the Dart-generated sample tree, uploaded byte for byte, lists, downloads and decodes.
    @Test func readsTheGoldenTreeAfterUploadingIt() async throws {
        let client = try await Live.freshClient("golden")
        try await client.ensureLegacyDirectories()
        for file in Fixtures.manifest.files {
            try await client.put(file.remotePath, data: Fixtures.sampleTreeData(file.remotePath))
        }
        try await Self.verify(client, matches: Fixtures.manifest)
    }

    /// Step 5.2, live variant: files written by webdav_client 1.2.2 itself.
    @Test(.enabled(if: Live.legacyBase != nil, "set WEBDAV_SPIKE_LEGACY_BASE after legacy_client.dart write"))
    func readsWhatTheLegacyClientWrote() async throws {
        try await Self.verify(Live.client(Live.legacyBase!), matches: Fixtures.manifest)
    }

    /// Step 5.3: Swift writes one record of each kind; `legacy_client.dart read` and
    /// `decrypt.dart` check them against `WEBDAV_SPIKE_EXPECT_OUT`.
    @Test func writesRecordsTheLegacyClientCanRead() async throws {
        let client = try await Live.freshClient("swift-write")
        try await client.ensureLegacyDirectories()
        let written = try Self.swiftRecords()
        for (path, data, _) in written {
            try await client.put(path, data: data)
        }
        let manifest = SampleManifest(files: written.map(\.manifest))
        try await Self.verify(client, matches: manifest)

        if let output = Live.expectedOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(to: output)
        }
    }

    /// Step 5.4: replacing and deleting follow the legacy sync code.
    @Test func replaceAndDeleteFollowTheLegacySemantics() async throws {
        let client = try await Live.freshClient("delete")
        try await client.ensureLegacyDirectories()
        let history = LegacyHistoryRecord(json: try LegacyCodec.decodeJSONPayload(
            Fixtures.sampleTreeData("/fehviewer/history/s/1000001_1762000000000.json")
        ))

        // _uploadHistoriesWebDAV: upload the newer file, delete the older one.
        let old = LegacyLayout.Entry.history(gid: "1000001", lastViewTime: 1_762_000_000_000)
        let new = LegacyLayout.Entry.history(gid: "1000001", lastViewTime: 1_762_000_900_000)
        try await client.put(LegacyLayout.path(for: old), data: LegacyCodec.encodeHistory(history))
        var newer = history
        newer.fields["lastViewTime"] = .int(1_762_000_900_000)
        try await client.put(LegacyLayout.path(for: new), data: LegacyCodec.encodeHistory(newer))
        #expect(try await client.delete(LegacyLayout.path(for: old)) == .deleted)
        #expect(try await Self.entries(client, LegacyLayout.historyDetailDirectory) == [new])
        // Deleting again is not an error for the legacy client (404 counts as done).
        #expect(try await client.delete(LegacyLayout.path(for: old)) == .notFound)

        // syncQuickSearch: upload the newer list, delete every older version.
        for time in [1_762_000_300_000, 1_762_000_400_000, 1_762_000_500_000] {
            try await client.put(
                LegacyLayout.path(for: .quickSearch(time: time)),
                data: LegacyCodec.encodeQuickSearch(["v\(time)"])
            )
        }
        for time in [1_762_000_300_000, 1_762_000_400_000] {
            #expect(try await client.delete(LegacyLayout.path(for: .quickSearch(time: time))) == .deleted)
        }
        #expect(try await Self.entries(client, LegacyLayout.quickSearchDirectory) == [.quickSearch(time: 1_762_000_500_000)])

        // _uploadProfiles: same replace-then-delete pattern, keyed by name and uuid.
        let uuid = "00000000-0000-4000-8000-000000000301"
        let groupV1 = LegacyLayout.Entry.group(name: "替换 Demo", uuid: uuid, lastEditTime: 1)
        let groupV2 = LegacyLayout.Entry.group(name: "替换 Demo", uuid: uuid, lastEditTime: 2)
        for (entry, time) in [(groupV1, 1), (groupV2, 2)] {
            try await client.put(LegacyLayout.path(for: entry), data: LegacyCodec.encodeGroup(
                LegacyCustomProfile(uuid: uuid, name: "替换 Demo", lastEditTime: time)
            ))
        }
        #expect(try await client.delete(LegacyLayout.path(for: groupV1)) == .deleted)
        #expect(try await Self.entries(client, LegacyLayout.groupDirectory) == [groupV2])

        // A deletion flag is an empty file named by gid.
        try await client.put(LegacyLayout.path(for: .historyDeletion(gid: "1000203")), data: Data())
        #expect(try await Self.entries(client, LegacyLayout.historyDeletionDirectory) == [.historyDeletion(gid: "1000203")])
        #expect(try await client.get(LegacyLayout.path(for: .historyDeletion(gid: "1000203"))).isEmpty)
    }

    @Test func preemptiveBasicAuthenticationWorks() async throws {
        let client = Live.client("", authentication: .preemptiveBasic)
        _ = try await client.list("/")
    }

    @Test func wrongPasswordIsRejected() async throws {
        for authentication in [WebDAVConfiguration.Authentication.challenge, .preemptiveBasic] {
            let client = Live.client("", password: "wrong-password", authentication: authentication)
            let error = await #expect(throws: WebDAVError.self) { try await client.list("/") }
            #expect(error == .unauthorized, "\(authentication)")
        }
    }

    /// The legacy client also speaks Digest; URLSession answers Digest challenges itself.
    @Test(
        .enabled(if: Live.digestURL != nil, "set WEBDAV_SPIKE_DIGEST_URL"),
        .enabled(if: Live.digestURL == nil || Live.isDisposable(Live.digestURL), "WEBDAV_SPIKE_DIGEST_URL is not a loopback host")
    )
    func digestAuthenticationThroughURLSession() async throws {
        let client = try await Live.freshClient(root: Live.digestURL, "digest")
        try await client.ensureLegacyDirectories()
        let path = LegacyLayout.path(for: .readProgress(gid: "1000001"))
        let data = try LegacyCodec.encodeReadProgress(LegacyReadProgress(
            gid: "1000001", lastIndex: 3, lastOffset: nil, columnModeVal: "", time: 1
        ))
        try await client.put(path, data: data)
        #expect(try await client.get(path) == data)

        let basicOnly = Live.client(root: Live.digestURL, "digest", authentication: .preemptiveBasic)
        _ = await #expect(throws: WebDAVError.self) { try await basicOnly.get(path) }
    }

    // MARK: - Helpers

    static func entries(_ client: WebDAVClient, _ directory: String) async throws -> [LegacyLayout.Entry] {
        try await client.list(directory)
            .filter { !$0.isCollection }
            .compactMap { LegacyLayout.entry(directory: directory, fileName: $0.name) }
    }

    /// Lists every legacy directory, downloads every sync file and compares it with `manifest`.
    static func verify(_ client: WebDAVClient, matches manifest: SampleManifest) async throws {
        var found: [LegacyLayout.Entry] = []
        for directory in LegacyLayout.startupDirectories {
            found += try await entries(client, directory)
        }
        let expected = manifest.files.compactMap(SampleManifest.expectedEntry)
        #expect(Set(found) == Set(expected))
        #expect(found.count == expected.count)

        for file in manifest.files {
            let data = try await client.get(file.remotePath)
            switch try #require(LegacyLayout.entry(path: file.remotePath)) {
            case .history:
                let json = try LegacyCodec.decodeJSONPayload(data)
                #expect(json == file.json, "\(file.remotePath)")
                #expect(LegacyHistoryRecord(json: json).gid != nil)
            case .readProgress:
                let json = try LegacyCodec.decodeJSONPayload(data)
                #expect(json == file.json, "\(file.remotePath)")
                #expect(LegacyReadProgress(json: json).gid != nil)
            case let .group(name, uuid, _):
                #expect(try LegacyCodec.decodeJSONPayload(data) == file.json, "\(file.remotePath)")
                #expect(try LegacyCodec.decodeGroup(data: data, name: name, uuid: uuid).name == name)
            case .quickSearch:
                #expect(try LegacyCodec.decodeQuickSearch(data) == file.lines, "\(file.remotePath)")
            case .historyDeletion:
                #expect(data.isEmpty)
            }
        }
    }

    /// One record of every kind, written the way the Swift app would.
    static func swiftRecords() throws -> [(path: String, data: Data, manifest: SampleManifest.File)] {
        var history = LegacyHistoryRecord(json: try LegacyCodec.decodeJSONPayload(
            Fixtures.sampleTreeData("/fehviewer/history/s/1000001_1762000000000.json")
        ))
        history.fields["gid"] = .string("1000101")
        history.fields["token"] = .string("0000000101")
        history.fields["url"] = .string("https://e-hentai.org/g/1000101/0000000101/")
        history.fields["englishTitle"] = .string("Written by Swift 🍣 \"quoted\" / slash")
        history.fields["japaneseTitle"] = .string("スウィフトが書いた履歴")
        history.fields["rating"] = .double(3.5)
        history.fields["lastViewTime"] = .int(1_762_100_000_000)
        history = history.preparedForUpload()
        let historyEntry = LegacyLayout.Entry.history(gid: "1000101", lastViewTime: 1_762_100_000_000)

        let read = LegacyReadProgress(gid: "1000101", lastIndex: 7, lastOffset: 42.5, columnModeVal: "", time: 1_762_100_050_000)
        let group = LegacyCustomProfile(
            uuid: "00000000-0000-4000-8000-000000000101",
            name: "Swift 分组 [1] & more+",
            searchText: ["l:japanese$", "other:\"fake$\""],
            listTypeValue: "gallery",
            cats: 0,
            enableAdvance: false,
            listModeValue: "global",
            hideTab: false,
            lastEditTime: 1_762_100_200_000
        )
        let groupEntry = LegacyLayout.Entry.group(name: group.name, uuid: group.uuid, lastEditTime: 1_762_100_200_000)
        let searches = ["swift 1", "スウィフト 2 🔍", "f:\"x$\""]
        let deletion = LegacyLayout.Entry.historyDeletion(gid: "1000103")

        func file(_ entry: LegacyLayout.Entry, _ kind: String, json: JSONValue? = nil, lines: [String]? = nil) -> SampleManifest.File {
            SampleManifest.File(
                remotePath: LegacyLayout.path(for: entry), kind: kind,
                parsedName: SampleManifest.parsedName(for: entry), json: json, lines: lines
            )
        }
        return [
            (LegacyLayout.path(for: historyEntry), try LegacyCodec.encodeHistory(history),
             file(historyEntry, "history", json: history.json)),
            (LegacyLayout.path(for: .readProgress(gid: "1000101")), try LegacyCodec.encodeReadProgress(read),
             file(.readProgress(gid: "1000101"), "readProgress", json: read.json)),
            (LegacyLayout.path(for: groupEntry), try LegacyCodec.encodeGroup(group),
             file(groupEntry, "group", json: group.json)),
            (LegacyLayout.path(for: .quickSearch(time: 1_762_100_300_000)), LegacyCodec.encodeQuickSearch(searches),
             file(.quickSearch(time: 1_762_100_300_000), "quickSearch", lines: searches)),
            (LegacyLayout.path(for: deletion), Data(), file(deletion, "historyDeletion")),
        ]
    }
}
