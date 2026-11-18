import EHFixtures
import EHModels
import EHParsing
import Foundation
import Testing

private func items(_ pairs: KeyValuePairs<String, String>) -> [URLQueryItem] {
    pairs.map { URLQueryItem(name: $0.key, value: $0.value) }
}

private func search(_ configure: (inout AdvancedSearch) -> Void) -> AdvancedSearch {
    var search = AdvancedSearch()
    configure(&search)
    return search
}

@Suite struct AdvancedSearchParserTests {
    @Test func advancedSearchRoundTrips() {
        let searches = [
            AdvancedSearch(),
            search { $0.requireTorrent = true },
            search { $0.showExpunged = true; $0.minimumRating = 2 },
            search { $0.minimumRating = 5; $0.pageRange = PageRange(from: 20, to: 200) },
            search { $0.pageRange = PageRange(from: 20, to: nil) },
            search { $0.pageRange = PageRange(from: nil, to: 200) },
            search { $0.pageRange = PageRange(from: nil, to: nil) },
            search { $0.disableLanguageFilter = true },
            search { $0.disableUploaderFilter = true },
            search { $0.disableTagFilter = true },
            search {
                $0.requireTorrent = true; $0.showExpunged = true; $0.minimumRating = 4
                $0.pageRange = PageRange(from: 1, to: 2); $0.disableLanguageFilter = true
                $0.disableUploaderFilter = true; $0.disableTagFilter = true
            },
        ]
        for search in searches {
            #expect(AdvancedSearchParser.parse(queryItems: AdvancedSearchParser.queryItems(for: search)) == search)
        }
        #expect(AdvancedSearchParser.queryItems(for: AdvancedSearch()).isEmpty)
    }

    @Test func queryItemsFollowFlutterOrder() {
        let all = search {
            $0.requireTorrent = true; $0.showExpunged = true; $0.minimumRating = 3
            $0.pageRange = PageRange(from: 10, to: 100); $0.disableLanguageFilter = true
            $0.disableUploaderFilter = true; $0.disableTagFilter = true
        }
        let query = AdvancedSearchParser.queryItems(for: all)
        #expect(query.map(\.name) == ["f_sto", "f_sh", "f_sr", "f_srdd", "f_sp", "f_spf", "f_spt", "f_sfl", "f_sfu", "f_sft"])
        #expect(query.map(\.value) == ["on", "on", "on", "3", "on", "10", "100", "on", "on", "on"])
        let open = AdvancedSearchParser.queryItems(for: search { $0.pageRange = PageRange(from: nil, to: 100) })
        #expect(open.map(\.name) == ["f_sp", "f_spt"])
    }

    @Test func uploaderAndTagFiltersAreNotSwapped() {
        let uploader = AdvancedSearchParser.parse(queryItems: items(["f_sfu": "on"]))
        #expect(uploader == search { $0.disableUploaderFilter = true })
        let tags = AdvancedSearchParser.parse(queryItems: items(["f_sft": "on"]))
        #expect(tags == search { $0.disableTagFilter = true })
        let written = AdvancedSearchParser.queryItems(for: search { $0.disableUploaderFilter = true })
        #expect(written.map(\.name) == ["f_sfu"])
    }

    @Test func capturedAdvancedSearchURLParses() throws {
        let entry = try #require(Fixtures.manifest().entries.first { $0.path == "eh/list/search-advanced.html" })
        let url = try #require(entry.url.flatMap { URLComponents(string: $0) })
        let parsed = AdvancedSearchParser.parse(queryItems: url.queryItems ?? [])
        #expect(parsed == search {
            $0.requireTorrent = true; $0.showExpunged = true; $0.minimumRating = 4
            $0.pageRange = PageRange(from: 20, to: 200); $0.disableLanguageFilter = true
            $0.disableUploaderFilter = true; $0.disableTagFilter = true
        })
    }

    @Test func ratingOutsideTwoToFiveIsDropped() {
        for value in ["9", "1", "6", "0", "-3", "x", ""] {
            let parsed = AdvancedSearchParser.parse(queryItems: items(["f_sr": "on", "f_srdd": value]))
            #expect(parsed.minimumRating == nil, "f_srdd=\(value)")
        }
        #expect(AdvancedSearchParser.parse(queryItems: items(["f_sr": "on"])).minimumRating == nil)
        #expect(AdvancedSearchParser.parse(queryItems: items(["f_srdd": "4"])).minimumRating == nil)
        #expect(AdvancedSearchParser.queryItems(for: search { $0.minimumRating = 9 }).isEmpty)
    }

    @Test func unreadableOptionsAreIgnored() {
        let parsed = AdvancedSearchParser.parse(queryItems: items([
            "f_sp": "on", "f_spf": "abc", "f_spt": "-5", "f_sto": "off", "f_sh": "", "f_search": "fake", "advsearch": "1",
        ]))
        #expect(parsed == search { $0.pageRange = PageRange(from: nil, to: nil) })
        #expect(AdvancedSearchParser.parse(queryItems: items(["f_spf": "20", "f_spt": "200"])) == AdvancedSearch())
        #expect(AdvancedSearchParser.parse(queryItems: []) == AdvancedSearch())
    }

    @Test func lastRepeatedItemWins() {
        let parsed = AdvancedSearchParser.parse(queryItems: items(["f_sto": "on", "f_sto": "off"]))
        #expect(!parsed.requireTorrent)
    }
}
