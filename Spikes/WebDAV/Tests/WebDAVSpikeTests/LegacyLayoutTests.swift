import Foundation
import Testing
import WebDAVSpike

@Suite("LegacyLayout")
struct LegacyLayoutTests {
    static let separator = LegacyLayout.groupSeparator

    static let entries: [LegacyLayout.Entry] = [
        .history(gid: "1000001", lastViewTime: 1_762_000_000_000),
        .historyDeletion(gid: "1000003"),
        .readProgress(gid: "1000001"),
        .group(name: "汉语", uuid: "00000000-0000-4000-8000-000000000001", lastEditTime: 1_762_000_200_000),
        .group(name: "Fake Artist [Test] & 同人+", uuid: "00000000-0000-4000-8000-000000000002", lastEditTime: 0),
        .group(name: "v1.2 🍣", uuid: "", lastEditTime: 7),
        .quickSearch(time: 1_762_000_300_000),
        .quickSearch(time: 0),
    ]

    @Test func directoriesMatchTheLegacyConstants() {
        #expect(LegacyLayout.rootDirectory == "/fehviewer")
        #expect(LegacyLayout.startupDirectories == [
            "/fehviewer/history/s", "/fehviewer/history/del", "/fehviewer/read",
            "/fehviewer/group", "/fehviewer/search",
        ])
        #expect(Array(LegacyLayout.groupSeparator.utf8) == [0xE2, 0x80, 0x96, 0x40, 0xE2, 0x80, 0x96])
    }

    @Test func pathsFollowTheLegacyNaming() {
        #expect(LegacyLayout.path(for: .history(gid: "1000001", lastViewTime: 1_762_000_000_000))
            == "/fehviewer/history/s/1000001_1762000000000.json")
        #expect(LegacyLayout.path(for: .historyDeletion(gid: "1000003")) == "/fehviewer/history/del/1000003")
        #expect(LegacyLayout.path(for: .readProgress(gid: "1000001")) == "/fehviewer/read/1000001.json")
        #expect(LegacyLayout.path(for: .group(name: "汉语", uuid: "u-1", lastEditTime: 1_762_000_200_000))
            == "/fehviewer/group/汉语\(Self.separator)u-1\(Self.separator)1762000200000.json")
        #expect(LegacyLayout.path(for: .quickSearch(time: 1_762_000_300_000))
            == "/fehviewer/search/quickSearch_1762000300000.txt")
    }

    @Test(arguments: entries)
    func pathRoundTrips(_ entry: LegacyLayout.Entry) {
        #expect(LegacyLayout.entry(path: LegacyLayout.path(for: entry)) == entry)
    }

    @Test func parsesEveryFileOfTheGoldenSampleTree() throws {
        let paths = try Fixtures.sampleTreeRemotePaths()
        #expect(paths == Fixtures.manifest.files.map(\.remotePath).sorted())
        for file in Fixtures.manifest.files {
            let expected = try #require(SampleManifest.expectedEntry(file), "manifest entry \(file.remotePath)")
            #expect(LegacyLayout.entry(path: file.remotePath) == expected)
            #expect(LegacyLayout.path(for: expected) == file.remotePath)
        }
        let kinds = Set(Fixtures.manifest.files.map(\.kind))
        #expect(kinds == ["history", "historyDeletion", "readProgress", "group", "quickSearch"])
    }

    /// Names Swift ignores, grouped by what the legacy app does with them
    /// (webdav_controller.dart:256-271, 414-426, 493-516, 585-596). Only the last group is
    /// a deliberate difference: the legacy app handles those names, Swift skips them.
    @Test(arguments: [
        // The legacy listing throws (RangeError or FormatException), failing the whole sync.
        ("/fehviewer/history/s", "1000001.json", "crash: no time part"),
        ("/fehviewer/history/s", "1000001_1762000000000", "crash: no '.'"),
        ("/fehviewer/history/s", ".DS_Store", "crash: no time part"),
        ("/fehviewer/history/s", "1000001_x.json", "crash: time not an int"),
        ("/fehviewer/read", "1000001", "crash: no '.'"),
        ("/fehviewer/group", "汉语\(separator)uuid.json", "crash: only two parts"),
        ("/fehviewer/group", "汉语\(separator)uuid\(separator)x.json", "crash: time not an int"),
        ("/fehviewer/search", "quickSearchFoo.txt", "crash: time not an int"),
        // Parsed, then fetched under a rebuilt name that does not exist (download returns null).
        ("/fehviewer/history/s", "1000001_0005.json", "404: fetched as 1000001_5.json"),
        ("/fehviewer/history/s", "1000001_1_2.json", "404: fetched as 1000001_1.json"),
        ("/fehviewer/search", "quickSearch_1.json", "404: fetched as quickSearch_1.txt"),
        // Filtered out by the legacy app as well.
        ("/fehviewer/history/s", "1000001_-5.json", "filtered: time <= 0"),
        ("/fehviewer/history/s", "1000001_0.json", "filtered: time <= 0"),
        ("/fehviewer/group", "\(separator)uuid\(separator)1.json", "filtered: empty name"),
        ("/fehviewer/other", "1000001_1.json", "not a sync directory"),
        // The legacy app parses these as gid "" and downloads them fine; Swift ignores them
        // because a record without a gid cannot be merged.
        ("/fehviewer/history/s", "_1762000000000.json", "legacy ok: gid \"\""),
        ("/fehviewer/read", ".json", "legacy ok: gid \"\""),
        ("/fehviewer/history/del", "", "legacy ok: gid \"\" (cannot occur in a listing)"),
    ])
    func ignoresNamesSwiftCannotMerge(directory: String, fileName: String, legacy: String) {
        #expect(LegacyLayout.entry(directory: directory, fileName: fileName) == nil, "\(legacy)")
    }
}
