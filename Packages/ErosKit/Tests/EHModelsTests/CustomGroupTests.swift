import EHModels
import Foundation
import Testing

@Suite struct CustomGroupTests {
    private func golden(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Golden"))
        return try Data(contentsOf: url)
    }

    private func decode(_ json: String) throws -> CustomGroup {
        try JSONDecoder().decode(CustomGroup.self, from: Data(json.utf8))
    }

    @Test(arguments: ["webdav-group-plain", "webdav-group-advanced"])
    func goldenGroupsRoundTrip(_ name: String) throws {
        let data = try golden(name)
        let group = try JSONDecoder().decode(CustomGroup.self, from: data)
        let again = try JSONEncoder().encode(group)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == JSONDecoder().decode(JSONValue.self, from: again))
    }

    @Test func plainGoldenReadsEveryField() throws {
        let group = try JSONDecoder().decode(CustomGroup.self, from: golden("webdav-group-plain"))
        #expect(group == CustomGroup(
            uuid: "00000000-0000-4000-8000-000000000001", name: "汉语", searchText: ["l:chinese"],
            listTypeValue: "gallery", cats: 0, enableAdvance: false, listModeValue: "global", hideTab: false,
            lastEditTime: 1762000200000))
        #expect(group.listType == .gallery && group.listStyle == nil && group.categories == [] && group.advancedSearch == nil)
    }

    @Test func advancedGoldenMapsToAdvancedSearch() throws {
        let group = try JSONDecoder().decode(CustomGroup.self, from: golden("webdav-group-advanced"))
        #expect(group.enableAdvance == true)
        #expect(group.searchText == ["artist:\"fake artist$\"", "other:\"fake tag$\""])
        var expected = AdvancedSearch()
        expected.minimumRating = 3
        #expect(group.advancedSearch == expected)
    }

    @Test func nilFieldsAreWrittenAsNull() throws {
        let data = try JSONEncoder().encode(CustomGroup(uuid: "u", name: "n"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "uuid", "name", "searchText", "listTypeValue", "catsTypeValue", "cats", "enableAdvance", "advSearchTypeValue",
            "advSearch", "listModeValue", "hideTab", "aggregateGroups", "lastEditTime",
        ])
        #expect(object["cats"] is NSNull && object["advSearch"] is NSNull && object["lastEditTime"] is NSNull)
    }

    @Test func lenientDecodingFollowsFlutter() throws {
        let json = #"{"name":"n","searchText":"l:fake language","listTypeValue":5,"cats":"0x10","enableAdvance":"TRUE","advSearch":[1],"hideTab":1,"aggregateGroups":[1,"a",null,true],"lastEditTime":5.5,"extra":1}"#
        let group = try decode(json)
        #expect(group.uuid == "null" && group.searchText == [] && group.listTypeValue == "5" && group.cats == 16)
        #expect(group.enableAdvance == true && group.advSearch == nil && group.hideTab == false && group.lastEditTime == 0)
        #expect(group.aggregateGroups == ["1", "a", "null", "true"])
    }

    @Test func missingKeysStayNil() throws {
        let group = try decode(#"{"uuid":"u","name":"n"}"#)
        #expect(group == CustomGroup(uuid: "u", name: "n"))
        #expect(group.searchText == nil && group.listTypeValue == nil && group.catsTypeValue == nil && group.cats == nil)
        #expect(group.enableAdvance == nil && group.advSearchTypeValue == nil && group.advSearch == nil)
        #expect(group.listModeValue == nil && group.hideTab == nil && group.aggregateGroups == nil && group.lastEditTime == nil)
    }

    @Test func nullValuesReadAsNil() throws {
        let group = try decode(#"{"uuid":null,"name":null,"cats":null,"searchText":null}"#)
        #expect(group.uuid == "null" && group.name == "null" && group.cats == nil && group.searchText == nil)
    }

    @Test(arguments: [
        (#""12""#, 12), ("1.5", 0), ("true", 0), (#""abc""#, 0), ("5.0", 5), (#""-3""#, -3), (#""0x10""#, 16),
    ])
    func intFieldsParseLikeDart(_ json: String, _ expected: Int) throws {
        #expect(try decode(#"{"uuid":"u","name":"n","cats":\#(json)}"#).cats == expected)
    }

    @Test(arguments: [(#""TRUE""#, true), (#""false""#, false), ("1", false), (#""yes""#, false)])
    func boolFieldsParseLikeDart(_ json: String, _ expected: Bool) throws {
        #expect(try decode(#"{"uuid":"u","name":"n","hideTab":\#(json)}"#).hideTab == expected)
    }

    @Test func computedPropertiesReadAndWriteTheRawKeys() {
        var group = CustomGroup(uuid: "u", name: "n")
        #expect(group.listType == .gallery && group.listStyle == nil && group.categories == nil)
        group.listTypeValue = "toplist"
        #expect(group.listType == .gallery)
        group.listType = .popular
        #expect(group.listTypeValue == "popular")
        group.listModeValue = "debugSimple"
        #expect(group.listStyle == nil)
        group.listStyle = .waterfallLarge
        #expect(group.listModeValue == "waterfallLarge")
        group.listStyle = nil
        #expect(group.listModeValue == "global")
        group.categories = .only(.manga)
        #expect(group.cats == 1019)
        group.categories = nil
        #expect(group.cats == nil)
    }

    @Test func advancedSearchWritesFlutterKeys() {
        var group = CustomGroup(uuid: "u", name: "n")
        var search = AdvancedSearch()
        search.minimumRating = 4
        search.pageRange = PageRange(from: 10, to: nil)
        search.disableTagFilter = true
        group.advancedSearch = search
        #expect(group.advSearch == .object([
            "requireGalleryTorrent": .bool(false), "browseExpungedGalleries": .bool(false),
            "searchWithMinRating": .bool(true), "minRating": .number(4), "searchBetweenPage": .bool(true),
            "startPage": .string("10"), "endPage": .string(""), "disableCustomFilterLanguage": .bool(false),
            "disableCustomFilterUploader": .bool(false), "disableCustomFilterTags": .bool(true),
        ]))
        #expect(group.advancedSearch == search)
        group.advancedSearch = AdvancedSearch()
        // Switches off, values kept.
        #expect(group.advSearch == .object([
            "requireGalleryTorrent": .bool(false), "browseExpungedGalleries": .bool(false),
            "searchWithMinRating": .bool(false), "minRating": .number(4), "searchBetweenPage": .bool(false),
            "startPage": .string("10"), "endPage": .string(""), "disableCustomFilterLanguage": .bool(false),
            "disableCustomFilterUploader": .bool(false), "disableCustomFilterTags": .bool(false),
        ]))
        group.advancedSearch = nil
        #expect(group.advSearch == nil)
    }

    @Test func unknownAdvancedKeysSurvive() throws {
        var group = CustomGroup(uuid: "u", name: "n")
        group.advSearch = .object(["futureKey": .string("x"), "searchWithMinRating": .bool(true), "minRating": .number(5)])
        var search = try #require(group.advancedSearch)
        #expect(search.minimumRating == 5)
        search.requireTorrent = true
        group.advancedSearch = search
        guard case .object(let object) = group.advSearch else { Issue.record("not an object"); return }
        #expect(object["futureKey"] == .string("x"))
        #expect(object.count == 11)
        #expect(object["requireGalleryTorrent"] == .bool(true))
    }

    @Test(arguments: [JSONValue.null, .number(0), .number(7), .string("x")])
    func minimumRatingDefaultsToTwo(_ rating: JSONValue) {
        var group = CustomGroup(uuid: "u", name: "n")
        group.advSearch = .object(["searchWithMinRating": .bool(true), "minRating": rating])
        #expect(group.advancedSearch?.minimumRating == 2)
        group.advSearch = .object(["searchWithMinRating": .bool(true)])
        #expect(group.advancedSearch?.minimumRating == 2)
    }

    @Test func pageBoundsMustBeDigits() {
        var group = CustomGroup(uuid: "u", name: "n")
        group.advSearch = .object(["searchBetweenPage": .bool(true), "startPage": .string("20"), "endPage": .string("abc")])
        #expect(group.advancedSearch?.pageRange == PageRange(from: 20, to: nil))
    }

    @Test(arguments: [
        ("en", ["Popular", "Gallery", "Watched", "Anthology"]), ("fr-FR", ["Popular", "Gallery", "Watched", "Anthology"]),
        ("zh", ["热门", "画廊", "订阅", "汉语", "Anthology"]), ("zh-Hans-JP", ["热门", "画廊", "订阅", "汉语", "Anthology"]),
        ("zh-Hant", ["熱門", "畫廊", "關注", "汉语", "Anthology"]), ("zh_TW", ["熱門", "畫廊", "關注", "汉语", "Anthology"]),
        ("zh-HK", ["熱門", "畫廊", "關注", "汉语", "Anthology"]),
        ("zh-Hans-HK", ["热门", "画廊", "订阅", "汉语", "Anthology"]),
        ("zh-Hant-CN", ["熱門", "畫廊", "關注", "汉语", "Anthology"]),
        ("ja-JP", ["人気", "ギャラリー", "登録", "Anthology"]), ("ko-KR", ["인기", "갤러리", "Watched", "Anthology"]),
        ("ru", ["Популярное", "Галерея", "Отслеживаемое", "Anthology"]),
    ])
    func defaultsFollowFlutter(_ languageCode: String, _ names: [String]) {
        var counter = 0
        let groups = CustomGroup.defaults(languageCode: languageCode) { counter += 1; return "g\(counter)" }
        #expect(groups.map(\.name) == names)
        #expect(groups.map(\.uuid) == (1...names.count).map { "g\($0)" })
        #expect(groups.map(\.listTypeValue) == ["popular", "gallery", "watched"] + [String?](repeating: nil, count: names.count - 3))
        for group in groups {
            switch group.name {
            case "汉语": #expect(group.searchText == ["l:chinese"])
            case "Anthology": #expect(group.searchText == ["o:anthology"])
            default: #expect(group.searchText == nil)
            }
            #expect(group.catsTypeValue == nil && group.cats == nil && group.enableAdvance == nil)
            #expect(group.advSearchTypeValue == nil && group.advSearch == nil && group.listModeValue == nil)
            #expect(group.hideTab == nil && group.aggregateGroups == nil && group.lastEditTime == nil)
        }
    }

    @Test func defaultIDsAreLowercaseUUIDs() {
        let groups = CustomGroup.defaults(languageCode: "en")
        #expect(Set(groups.map(\.uuid)).count == groups.count)
        for group in groups {
            #expect(group.uuid.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil)
        }
    }
}
