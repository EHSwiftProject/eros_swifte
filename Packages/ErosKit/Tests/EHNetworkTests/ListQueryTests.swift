import EHModels
import EHNetwork
import Foundation
import Testing

struct ListQueryTests {
    @Test func frontWithSearchCategoriesAndCursor() {
        let query = ListQuery(source: .front, search: "fake tag", excludedCategories: 1021, position: .next("900001"))
        #expect(query.url(for: .eh).absoluteString == "https://e-hentai.org/?f_cats=1021&f_search=fake%20tag&next=900001")
    }

    @Test func advancedSearchAppendsAfterAdvsearch() {
        var advanced = AdvancedSearch()
        advanced.requireTorrent = true
        advanced.showExpunged = true
        advanced.minimumRating = 4
        advanced.pageRange = PageRange(from: 20, to: 200)
        advanced.disableLanguageFilter = true
        advanced.disableUploaderFilter = true
        advanced.disableTagFilter = true
        let query = ListQuery(source: .front, search: "x", excludedCategories: 1021, advanced: advanced, position: .page(1))
        #expect(query.url(for: .eh).absoluteString == "https://e-hentai.org/?f_cats=1021&f_search=x&page=1&advsearch=1&f_sto=on&f_sh=on&f_sr=on&f_srdd=4&f_sp=on&f_spf=20&f_spt=200&f_sfl=on&f_sfu=on&f_sft=on")
    }

    @Test func toplistIsAlwaysOnEHWithP() {
        let query = ListQuery(source: .toplist(.month), position: .page(2))
        #expect(query.url(for: .ex).absoluteString == "https://e-hentai.org/toplist.php?tl=13&p=2")
    }

    @Test func toplistIgnoresAdvancedSearchAndSearch() {
        var advanced = AdvancedSearch()
        advanced.requireTorrent = true
        let query = ListQuery(source: .toplist(.allTime), search: "x", advanced: advanced)
        let url = query.url(for: .eh).absoluteString
        #expect(url == "https://e-hentai.org/toplist.php?tl=11")
        #expect(!url.contains("advsearch"))
    }

    @Test func favoritesFolderAndSearch() {
        let query = ListQuery(source: .favorites(folder: 3), search: "x", excludedCategories: 7)
        #expect(query.url(for: .ex).absoluteString == "https://exhentai.org/favorites.php?f_search=x&favcat=3")
    }

    @Test func positionComesBeforeAdvancedSearch() {
        var advanced = AdvancedSearch()
        advanced.requireTorrent = true
        let query = ListQuery(source: .front, search: "x", advanced: advanced, position: .next("900001"))
        #expect(query.url(for: .eh).absoluteString == "https://e-hentai.org/?f_search=x&next=900001&advsearch=1&f_sto=on")
    }

    @Test func emptyAdvancedSearchAddsNothing() {
        let query = ListQuery(source: .watched, advanced: AdvancedSearch(), position: .previous("900001"))
        #expect(query.url(for: .eh).absoluteString == "https://e-hentai.org/watched?prev=900001")
    }

    @Test func jumpAndSeek() {
        #expect(ListQuery(source: .front, position: .jump("1w")).url(for: .eh).absoluteString == "https://e-hentai.org/?jump=1w")
        #expect(ListQuery(source: .front, position: .seek("2026-01-02")).url(for: .eh).absoluteString == "https://e-hentai.org/?seek=2026-01-02")
    }

    // MARK: - Offsets (jump and seek from a cursor)

    @Test func offsetCarriesItsCursor() {
        let query = ListQuery(source: .front, position: .offset(jump: "1w", seek: nil, from: .next("123")))
        #expect(query.url(for: .eh).absoluteString == "https://e-hentai.org/?jump=1w&next=123")
    }

    @Test func offsetWithSeekAndPrevious() {
        let query = ListQuery(source: .front, position: .offset(jump: nil, seek: "2024-01-01", from: .previous("9")))
        #expect(query.url(for: .eh).absoluteString == "https://e-hentai.org/?seek=2024-01-01&prev=9")
    }

    /// The address of the replayed `eh/list/front-seek.html`.
    @Test func offsetWithoutCursor() {
        let query = ListQuery(source: .front, position: .offset(jump: nil, seek: "2024-01-01", from: nil))
        #expect(query.url(for: .eh).absoluteString == "https://e-hentai.org/?seek=2024-01-01")
    }

    @Test func offsetComesBeforeAdvancedSearch() {
        var advanced = AdvancedSearch()
        advanced.requireTorrent = true
        let query = ListQuery(
            source: .front, search: "x", excludedCategories: 1021, advanced: advanced,
            position: .offset(jump: "3d", seek: "2024-01-01", from: .next("900001"))
        )
        #expect(query.url(for: .eh).absoluteString == "https://e-hentai.org/?f_cats=1021&f_search=x&jump=3d&seek=2024-01-01&next=900001&advsearch=1&f_sto=on")
    }

    @Test func popularIgnoresOffset() {
        let query = ListQuery(source: .popular, position: .offset(jump: "1y", seek: "2024-01-01", from: .previous("9")))
        #expect(query.url(for: .eh).absoluteString == "https://e-hentai.org/popular")
    }

    @Test func offsetPositionsRoundTripCodable() throws {
        let positions: [ListPosition] = [
            .offset(jump: "1w", seek: nil, from: .next("123")),
            .offset(jump: nil, seek: "2024-01-01", from: .previous("9")),
            .offset(jump: nil, seek: "24-01", from: nil),
            .offset(jump: nil, seek: nil, from: nil),
        ]
        for position in positions {
            let data = try JSONEncoder().encode(position)
            #expect(try JSONDecoder().decode(ListPosition.self, from: data) == position)
        }
        let cursors: [ListCursor] = [.next("123"), .previous("456")]
        for cursor in cursors {
            #expect(try JSONDecoder().decode(ListCursor.self, from: JSONEncoder().encode(cursor)) == cursor)
        }
    }

    @Test func tagPathUsesPlus() {
        let query = ListQuery(source: .tag(TagRef(raw: "female:fake tag")))
        #expect(query.url(for: .eh).absoluteString == "https://e-hentai.org/tag/female:fake+tag")
    }

    @Test func uploaderPathIsPercentEncoded() {
        #expect(ListQuery(source: .uploader("fake user/é")).url(for: .ex).absoluteString == "https://exhentai.org/uploader/fake%20user%2F%C3%A9")
    }

    @Test func popularIgnoresSearchAndPosition() {
        var advanced = AdvancedSearch()
        advanced.requireTorrent = true
        let query = ListQuery(source: .popular, search: "x", excludedCategories: 3, advanced: advanced, position: .page(2))
        #expect(query.url(for: .eh).absoluteString == "https://e-hentai.org/popular")
    }

    @Test func forceCompactAddsInlineSet() {
        let request = EHRequests.list(ListQuery(source: .front, search: "x"), site: .eh, forceCompact: true)
        #expect(request.url.absoluteString.hasSuffix("&inline_set=dm_l"))
        #expect(request.cachePolicy == .none)
        let bare = EHRequests.list(ListQuery(source: .popular), site: .eh, forceCompact: true)
        #expect(bare.url.absoluteString == "https://e-hentai.org/popular?inline_set=dm_l")
    }

    @Test func listCachePolicyFollowsRefresh() {
        let query = ListQuery(source: .front)
        #expect(EHRequests.list(query, site: .eh).cachePolicy == .preferCache)
        #expect(EHRequests.list(query, site: .eh, refresh: true).cachePolicy == .reload)
    }
}
