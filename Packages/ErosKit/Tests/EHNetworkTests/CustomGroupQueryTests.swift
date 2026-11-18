import EHModels
import EHNetwork
import Foundation
import Testing

@Suite struct CustomGroupQueryTests {
    @Test func popularTakesNoParameters() {
        var group = CustomGroup(
            uuid: "u", name: "n", searchText: ["l:fake language"], listTypeValue: "popular", cats: 1021, enableAdvance: true)
        var search = AdvancedSearch()
        search.minimumRating = 4
        group.advancedSearch = search
        #expect(group.listQuery(position: .page(2)) == ListQuery(source: .popular))
        #expect(group.listQuery().url(for: .eh).absoluteString == "https://e-hentai.org/popular")
    }

    @Test func galleryCarriesEverything() {
        var group = CustomGroup(
            uuid: "u", name: "n", searchText: ["l:fake language", "o:fake other"], cats: 1021, enableAdvance: true)
        var search = AdvancedSearch()
        search.minimumRating = 3
        group.advancedSearch = search
        let query = group.listQuery(position: .next("900001"))
        #expect(query == ListQuery(
            source: .front, search: "l:fake language o:fake other", excludedCategories: 1021, advanced: search,
            position: .next("900001")))
        #expect(query.url(for: .eh).absoluteString
            == "https://e-hentai.org/?f_cats=1021&f_search=l%3Afake%20language%20o%3Afake%20other&next=900001&advsearch=1&f_sr=on&f_srdd=3")
    }

    @Test func advancedNeedsEnableAdvance() {
        var search = AdvancedSearch()
        search.minimumRating = 3
        for flag in [nil, false] as [Bool?] {
            var group = CustomGroup(uuid: "u", name: "n", enableAdvance: flag)
            group.advancedSearch = search
            #expect(group.listQuery().advanced == nil)
        }
    }

    @Test func watchedUsesWatched() {
        #expect(CustomGroup(uuid: "u", name: "n", listTypeValue: "watched").listQuery().url(for: .ex).absoluteString
            == "https://exhentai.org/watched")
    }

    @Test func searchTextFollowsFlutter() {
        #expect(CustomGroup(uuid: "u", name: "n").listQuery().search == nil)
        let empty = CustomGroup(uuid: "u", name: "n", searchText: [])
        #expect(empty.listQuery().search == "")
        #expect(empty.listQuery().url(for: .eh).absoluteString == "https://e-hentai.org/?f_search=")
    }
}
