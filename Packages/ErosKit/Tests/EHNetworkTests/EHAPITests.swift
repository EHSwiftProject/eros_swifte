import EHModels
import EHNetwork
import Foundation
import Testing

struct EHAPITests {
    let id = GalleryID(gid: 900001, token: "0f0f0f0f0f")

    private func body(_ request: EHRequest) throws -> NSDictionary {
        guard case .json(let data) = request.body else { throw CocoaError(.coderInvalidValue) }
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func check(_ request: EHRequest, equals expected: NSDictionary, site: EHSite = .eh) throws {
        #expect(request.method == .post)
        #expect(request.url == EHEndpoints.api(site: site))
        #expect(request.expectsJSON)
        #expect(request.cachePolicy == .none)
        #expect(try body(request) == expected)
    }

    @Test func apiBodiesMatchFlutter() throws {
        try check(EHAPI.gdata([id], site: .eh)[0], equals: ["method": "gdata", "gidlist": [[900001, "0f0f0f0f0f"]]])
        try check(EHAPI.showpage(gid: 900001, page: 2, imageKey: "abcdef0123", showKey: "fake-showkey", site: .ex),
                  equals: ["method": "showpage", "gid": 900001, "page": 2, "imgkey": "abcdef0123", "showkey": "fake-showkey"], site: .ex)
        try check(EHAPI.imagedispatch(gid: 900001, page: 2, imageKey: "abcdef0123", mpvKey: "fake-mpvkey", reloadToken: nil, site: .eh),
                  equals: ["method": "imagedispatch", "gid": 900001, "page": 2, "imgkey": "abcdef0123", "mpvkey": "fake-mpvkey"])
        try check(EHAPI.rategallery(id, rating: 9, apiUID: 1234567, apiKey: "fake-apikey", site: .eh),
                  equals: ["method": "rategallery", "apiuid": 1234567, "apikey": "fake-apikey", "gid": 900001, "token": "0f0f0f0f0f", "rating": 9])
        try check(EHAPI.votecomment(id, commentID: 55, vote: -1, apiUID: 1234567, apiKey: "fake-apikey", site: .eh),
                  equals: ["method": "votecomment", "apiuid": 1234567, "apikey": "fake-apikey", "gid": 900001, "token": "0f0f0f0f0f", "comment_id": 55, "comment_vote": -1])
        try check(EHAPI.taggallery(id, tags: "female:fake tag", vote: 1, apiUID: 1234567, apiKey: "fake-apikey", site: .eh),
                  equals: ["method": "taggallery", "apiuid": 1234567, "apikey": "fake-apikey", "gid": 900001, "token": "0f0f0f0f0f", "tags": "female:fake tag", "vote": 1])
        try check(EHAPI.tagsuggest("fake", site: .eh), equals: ["method": "tagsuggest", "text": "fake"])
        try check(EHAPI.setusertag(tagID: 77, watch: true, hide: false, color: nil, weight: 10, apiUID: 1234567, apiKey: "fake-apikey", site: .eh),
                  equals: ["method": "setusertag", "apiuid": 1234567, "apikey": "fake-apikey", "tagid": 77, "tagwatch": 1, "taghide": 0, "tagcolor": "", "tagweight": "10"])
    }

    @Test func gdataSplitsIntoBatchesOf25() throws {
        let ids = (0..<26).map { GalleryID(gid: 900001 + $0, token: "0f0f0f0f0f") }
        let requests = EHAPI.gdata(ids, site: .eh)
        #expect(requests.count == 2)
        let lists = try requests.map { try #require(try body($0)["gidlist"] as? [[Any]]) }
        #expect(lists.map(\.count) == [25, 1])
        #expect(lists[0].first?.first as? Int == 900001)
        #expect(lists[1].first?.first as? Int == 900026)
        #expect(EHAPI.gdata([], site: .eh).isEmpty)
    }

    @Test func imagedispatchAddsNLOnlyWhenGiven() throws {
        let without = EHAPI.imagedispatch(gid: 900001, page: 1, imageKey: "k", mpvKey: "m", reloadToken: nil, site: .eh)
        let with = EHAPI.imagedispatch(gid: 900001, page: 1, imageKey: "k", mpvKey: "m", reloadToken: "1234-fake", site: .eh)
        #expect(try body(without)["nl"] == nil)
        #expect(try body(with)["nl"] as? String == "1234-fake")
    }
}
