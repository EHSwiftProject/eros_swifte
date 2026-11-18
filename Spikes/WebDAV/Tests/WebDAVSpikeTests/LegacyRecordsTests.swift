import Foundation
import Testing
import WebDAVSpike

@Suite("Legacy records")
struct LegacyRecordsTests {
    @Test(arguments: Fixtures.manifest.files)
    func decodesTheGoldenSampleFile(_ file: SampleManifest.File) throws {
        let data = try Fixtures.sampleTreeData(file.remotePath)
        #expect(data.count == file.size)
        switch try #require(LegacyLayout.entry(path: file.remotePath)) {
        case .history:
            let json = try LegacyCodec.decodeJSONPayload(data)
            #expect(json == file.json)
            let record = LegacyHistoryRecord(json: json)
            #expect(record.json == json)
        case .readProgress:
            let json = try LegacyCodec.decodeJSONPayload(data)
            #expect(json == file.json)
            _ = LegacyReadProgress(json: json)
        case let .group(name, uuid, _):
            let json = try LegacyCodec.decodeJSONPayload(data)
            #expect(json == file.json)
            let profile = try LegacyCodec.decodeGroup(data: data, name: name, uuid: uuid)
            #expect(profile.name == name)
            #expect(profile.uuid == uuid)
        case .quickSearch:
            #expect(try LegacyCodec.decodeQuickSearch(data) == file.lines)
        case .historyDeletion:
            #expect(data.isEmpty)
        }
    }

    /// Before 690502e2 (2021-08-30) the app uploaded plain JSON, history in the old `GalleryItem`
    /// shape. The `{` rule added in that commit reads them, in the legacy app and here.
    @Test func readsPlainJSONFilesFromBeforeAES() throws {
        let historyData = try Fixtures.sampleTreeData("/fehviewer/history/s/1000004_1629000000000.json")
        #expect(historyData.first == UInt8(ascii: "{"))
        let history = LegacyHistoryRecord(json: try LegacyCodec.decodeJSONPayload(historyData))
        #expect(history.gid == "1000004")
        #expect(history.lastViewTime == 1_629_000_000_000)
        #expect(history.englishTitle == "[Fake] Pre-AES History Entry")
        #expect(history.rating == 3.5)
        #expect(history.fields["chapter"] == nil && history.fields["favNote"] == nil, "old GalleryItem keys")
        // The old model wrote imgHeight as a double ("300.0"). JSONDecoder reads it as 300; the
        // current legacy app's int.tryParse('300.0') reads 0.
        #expect(history.fields["imgHeight"] == .int(300))

        let readData = try Fixtures.sampleTreeData("/fehviewer/read/1000004.json")
        #expect(readData.first == UInt8(ascii: "{"))
        #expect(LegacyReadProgress(json: try LegacyCodec.decodeJSONPayload(readData)) == LegacyReadProgress(
            gid: "1000004", lastIndex: 5, lastOffset: nil, columnModeVal: "", time: 1_629_000_050_000
        ))
    }

    @Test func typedFieldsOfTheGoldenRecords() throws {
        let history = LegacyHistoryRecord(json: try LegacyCodec.decodeJSONPayload(
            Fixtures.sampleTreeData("/fehviewer/history/s/1000002_1762000100000.json")
        ))
        #expect(history.gid == "1000002")
        #expect(history.token == "0000000002")
        #expect(history.lastViewTime == 1_762_000_100_000)
        #expect(history.englishTitle == "Fake Anthology 🍣 Edition")
        #expect(history.japaneseTitle == "フェイク合同誌 🍣")
        #expect(history.rating == 4.0)

        let read = LegacyReadProgress(json: try LegacyCodec.decodeJSONPayload(
            Fixtures.sampleTreeData("/fehviewer/read/1000002.json")
        ))
        #expect(read == LegacyReadProgress(
            gid: "1000002", lastIndex: 0, lastOffset: 1536.5, columnModeVal: "", time: 1_762_000_150_000
        ))

        let groupFile = try #require(Fixtures.manifest.files.first { $0.remotePath.contains("Fake Artist") })
        guard case let .group(name, uuid, time) = LegacyLayout.entry(path: groupFile.remotePath) else {
            Issue.record("not a group path")
            return
        }
        let group = try LegacyCodec.decodeGroup(
            data: Fixtures.sampleTreeData(groupFile.remotePath), name: name, uuid: uuid
        )
        #expect(group.searchText == ["artist:\"fake artist$\"", "other:\"fake tag$\""])
        #expect(group.enableAdvance == true)
        #expect(group.lastEditTime == time)
        #expect(group.advSearch?["minRating"] == .int(3))
    }

    /// `X.fromJson` in the Flutter models: `?.toString()`, `int.tryParse('$v') ?? 0`,
    /// `double.tryParse('$v') ?? 0.0`, `bool.tryParse('$v', caseSensitive: false) ?? false`.
    @Test func lenientParsingMirrorsTheLegacyFromJSON() {
        let read = LegacyReadProgress(json: .object([
            "gid": .int(1_000_001),
            "lastIndex": .string("12"),
            "lastOffset": .int(3),
            "columnModeVal": .null,
            "time": .double(5.0),
        ]))
        #expect(read.gid == "1000001")
        #expect(read.lastIndex == 12)
        #expect(read.lastOffset == 3.0)
        #expect(read.columnModeVal == nil)
        #expect(read.time == 0, "int.tryParse('5.0') is null, so the app stores 0")

        let group = LegacyCustomProfile(json: .object([
            "name": .string("n"),
            "hideTab": .string("TRUE"),
            "enableAdvance": .int(1),
            "cats": .string("x"),
        ]))
        #expect(group.uuid == "null", "json['uuid'].toString() on a missing key")
        #expect(group.hideTab == true)
        #expect(group.enableAdvance == false)
        #expect(group.cats == 0)
        #expect(group.searchText == nil)
    }

    @Test func groupNameAndUUIDComeFromTheFileName() throws {
        let stored = LegacyCustomProfile(uuid: "json-uuid", name: "json-name", lastEditTime: 5)
        let data = try LegacyCodec.encodeGroup(stored)
        let decoded = try LegacyCodec.decodeGroup(data: data, name: "file-name", uuid: "file-uuid")
        #expect(decoded.name == "file-name")
        #expect(decoded.uuid == "file-uuid")
        #expect(decoded.lastEditTime == 5)
    }

    @Test func uploadFormsMatchTheLegacyApp() throws {
        var history = LegacyHistoryRecord(json: try LegacyCodec.decodeJSONPayload(
            Fixtures.sampleTreeData("/fehviewer/history/s/1000001_1762000000000.json")
        ))
        history.fields["galleryComment"] = .array([.object(["text": .string("c")])])
        history.fields["galleryImages"] = .array([.object(["ser": .int(1)])])
        let upload = history.preparedForUpload()
        #expect(upload.fields["galleryComment"] == .array([]))
        #expect(upload.fields["galleryImages"] == .array([]))
        #expect(upload.fields["tagGroup"] == .array([]))

        let historyData = try LegacyCodec.encodeHistory(upload)
        #expect(historyData.first != UInt8(ascii: "{"), "history files are encrypted")
        #expect(LegacyHistoryRecord(json: try LegacyCodec.decodeJSONPayload(historyData)) == upload)

        let read = LegacyReadProgress(gid: "1", lastIndex: 2, lastOffset: nil, columnModeVal: "single", time: 3)
        let readJSON = try LegacyCodec.decodeJSONPayload(try LegacyCodec.encodeReadProgress(read))
        #expect(LegacyReadProgress(json: readJSON).columnModeVal == "", "uploadRead clears columnModeVal")

        let groupData = try LegacyCodec.encodeGroup(LegacyCustomProfile(uuid: "u", name: "n"))
        #expect(groupData.first == UInt8(ascii: "{"), "uploadGroupProfile writes plain JSON by default")
    }

    @Test func quickSearchKeepsNonBlankLinesUntrimmed() throws {
        #expect(try LegacyCodec.decodeQuickSearch(Data("a\n\n   \n  b \nc".utf8)) == ["a", "  b ", "c"])
        #expect(LegacyCodec.encodeQuickSearch(["a", "b"]) == Data("a\nb".utf8))
        #expect(LegacyCodec.encodeQuickSearch([]) == Data())
    }
}
