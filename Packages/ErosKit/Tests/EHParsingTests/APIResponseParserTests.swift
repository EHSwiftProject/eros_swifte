import EHFixtures
import EHModels
import EHParsing
import Foundation
import Testing

// The captured answers (gdata, tagsuggest) are checked by structure only (counts, presence, equality with the list
// page); their ids and tags are compared as Booleans bound before `#expect`, so that a failure prints no value. The
// constructed answers and hand-written snippets carry made-up values and are compared exactly.

private func data(_ text: String) -> Data { Data(text.utf8) }

private func fixture(_ path: String) throws -> Data { try Fixtures.data(path) }

/// A gdata answer with one entry holding `fields` (JSON members, without braces) after a valid gid and token.
private func gdata(_ fields: String = #""title":"Fake Gallery 1""#) -> Data {
    data(#"{"gmetadata":[{"gid":900001,"token":"0f0f0f0f0f",\#(fields)}]}"#)
}

private func one(_ json: Data) throws -> GalleryMetadata {
    try #require(APIResponseParser.galleryMetadata(json).first)
}

@Suite struct APIResponseParserTests {
    // MARK: Captured and constructed fixtures, one test per row of the plan's table

    @Test(arguments: EHSite.allCases)
    func galleryDataParses(site: EHSite) throws {
        let json = try fixture("\(site.rawValue)/api/gdata.json")
        let galleries = try APIResponseParser.galleryMetadata(json)
        let list = try GalleryListParser.parse(Fixtures.string("\(site.rawValue)/list/front.html"))
        #expect(galleries.count == 3)
        let idsAreTheLists = galleries.map(\.id) == list.items.prefix(3).map(\.id)
        #expect(idsAreTheLists)

        // The same entries as raw JSON, to compare the tags with their source text.
        let raw = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let entries = try #require(raw["gmetadata"] as? [[String: Any]])
        #expect(entries.count == galleries.count)
        for (gallery, entry) in zip(galleries, entries) {
            #expect(!gallery.title.isEmpty)
            #expect(gallery.category != nil)
            #expect(!gallery.tags.isEmpty)
            #expect(gallery.postedAt != nil)
            #expect((gallery.fileCount ?? 0) > 0)
            let rawTags = try #require(entry["tags"] as? [String])
            let tagsAreTheSource = gallery.tags.map(\.raw) == rawTags.map { TagRef(raw: $0).raw }
            #expect(tagsAreTheSource)
            for (tag, text) in zip(gallery.tags, rawTags) where !text.contains(":") {
                let hasNoNamespace = tag.namespace == nil
                #expect(hasNoNamespace)
            }
        }
    }

    @Test(arguments: EHSite.allCases)
    func tagSuggestionsParse(site: EHSite) throws {
        let suggestions = try APIResponseParser.tagSuggestions(fixture("\(site.rawValue)/api/tagsuggest.json"))
        #expect(suggestions.count == 10)
        for tag in suggestions {
            #expect(!(tag.namespace ?? "").isEmpty)
            #expect(!tag.name.isEmpty)
        }
    }

    @Test func ratingFixture() throws {
        let result = try APIResponseParser.rating(fixture("constructed/eh/api-rategallery.json"))
        #expect(result == RatingResult(average: 3.5, userRating: 4, count: 12))
    }

    @Test func commentVoteFixture() throws {
        let result = try APIResponseParser.commentVote(fixture("constructed/eh/api-votecomment.json"))
        #expect(result == CommentVoteResult(commentID: 1, score: 5, vote: 1))
    }

    @Test func tagVoteFixture() throws {
        let result = try APIResponseParser.tagVote(fixture("constructed/eh/api-taggallery.json"))
        func group(_ namespace: String, _ name: String) -> TagGroup {
            TagGroup(
                namespace: namespace,
                tags: [DetailTag(tag: TagRef(namespace: namespace, name: name), strength: .solid, vote: .none)]
            )
        }
        #expect(result.tagGroups.count == 2)
        #expect(result == TagVoteResult(tagGroups: [group("fakeone", "fake tag 1"), group("faketwo", "fake tag 2")]))
    }

    @Test func userTagFixture() throws {
        try APIResponseParser.userTag(fixture("constructed/eh/api-setusertag.json"))
    }

    @Test func errorObjectsBecomeServerErrors() throws {
        let json = try fixture("constructed/eh/api-error.json")
        let failure = APIError.server("Fake error")
        #expect(throws: failure) { try APIResponseParser.galleryMetadata(json) }
        #expect(throws: failure) { try APIResponseParser.tagSuggestions(json) }
        #expect(throws: failure) { try APIResponseParser.rating(json) }
        #expect(throws: failure) { try APIResponseParser.commentVote(json) }
        #expect(throws: failure) { try APIResponseParser.tagVote(json) }
        #expect(throws: failure) { try APIResponseParser.userTag(json) }
    }

    @Test func answersThatAreNotObjectsAreNotJSON() throws {
        for text in ["", "<html></html>", "[]", "[1,2]", "\"text\"", "12", "null"] {
            let json = data(text)
            #expect(throws: APIError.notJSON) { try APIResponseParser.galleryMetadata(json) }
            #expect(throws: APIError.notJSON) { try APIResponseParser.tagSuggestions(json) }
            #expect(throws: APIError.notJSON) { try APIResponseParser.rating(json) }
            #expect(throws: APIError.notJSON) { try APIResponseParser.commentVote(json) }
            #expect(throws: APIError.notJSON) { try APIResponseParser.tagVote(json) }
            #expect(throws: APIError.notJSON) { try APIResponseParser.userTag(json) }
        }
    }

    // MARK: Numbers

    @Test func numbersMayBeStrings() throws {
        let rating = try APIResponseParser.rating(data(#"{"rating_avg":"3.5","rating_usr":"4","rating_cnt":"12"}"#))
        #expect(rating == RatingResult(average: 3.5, userRating: 4, count: 12))
        let vote = try APIResponseParser.commentVote(data(#"{"comment_id":"1","comment_score":"5","comment_vote":"1"}"#))
        #expect(vote == CommentVoteResult(commentID: 1, score: 5, vote: 1))
    }

    @Test func commentScoresMayBeNegative() throws {
        let numbers = try APIResponseParser.commentVote(data(#"{"comment_id":1,"comment_score":-3,"comment_vote":-1}"#))
        #expect(numbers == CommentVoteResult(commentID: 1, score: -3, vote: -1))
        let strings = try APIResponseParser.commentVote(data(#"{"comment_id":"1","comment_score":"-3","comment_vote":"0"}"#))
        #expect(strings == CommentVoteResult(commentID: 1, score: -3, vote: 0))
    }

    @Test func requiredFieldsAreMissingOrMalformed() {
        #expect(throws: ParseError.missing("rating_cnt")) {
            try APIResponseParser.rating(data(#"{"rating_avg":3.5,"rating_usr":4}"#))
        }
        #expect(throws: ParseError.malformed("rating_avg")) {
            try APIResponseParser.rating(data(#"{"rating_avg":"high","rating_usr":4,"rating_cnt":1}"#))
        }
        #expect(throws: ParseError.malformed("rating_usr")) {
            try APIResponseParser.rating(data(#"{"rating_avg":3,"rating_usr":true,"rating_cnt":1}"#))
        }
        #expect(throws: ParseError.malformed("rating_cnt")) {
            try APIResponseParser.rating(data(#"{"rating_avg":3,"rating_usr":4,"rating_cnt":1.5}"#))
        }
        #expect(throws: ParseError.missing("comment_score")) {
            try APIResponseParser.commentVote(data(#"{"comment_id":1,"comment_score":null,"comment_vote":1}"#))
        }
        #expect(throws: ParseError.malformed("comment_id")) {
            try APIResponseParser.commentVote(data(#"{"comment_id":"x","comment_score":1,"comment_vote":1}"#))
        }
        #expect(throws: ParseError.missing("tagpane")) { try APIResponseParser.tagVote(data("{}")) }
        #expect(throws: ParseError.malformed("tagpane")) { try APIResponseParser.tagVote(data(#"{"tagpane":5}"#)) }
    }

    @Test func tagVoteWithoutRowsHasNoGroups() throws {
        let result = try APIResponseParser.tagVote(data(#"{"tagpane":""}"#))
        #expect(result.tagGroups.isEmpty)
    }

    @Test func userTagIgnoresOtherFields() throws {
        try APIResponseParser.userTag(data("{}"))
        try APIResponseParser.userTag(data(#"{"error":null,"result":"ok"}"#))
        #expect(throws: APIError.server("Fake error")) {
            try APIResponseParser.userTag(data(#"{"result":"ok","error":"Fake error"}"#))
        }
    }

    // MARK: Tag suggestions

    @Test func tagSuggestionsKeepServerOrder() throws {
        let json = data(#"{"tags":{"9":{"ns":"a","tn":"x"},"2":{"ns":"b","tn":"y"}}}"#)
        #expect(try APIResponseParser.tagSuggestions(json) == [
            TagRef(namespace: "a", name: "x"), TagRef(namespace: "b", name: "y"),
        ])
    }

    @Test func tagSuggestionOrderSurvivesAwkwardText() throws {
        // Keys with escapes and brackets inside strings, nested values, a repeated key and a BOM.
        let text = "\u{FEFF} {\"other\" : {\"7\":{\"ns\":\"z\",\"tn\":\"z\"}},\n\"tags\" :\t{ \"30\" : {\"ns\":\"a\",\"tn\":\"x}\\\"{\",\"x\":[1,{\"a\":2}]},"
            + "\"1\":{\"ns\":\"b\",\"tn\":\"y\"},\"\\u0032\":{\"ns\":\"c\",\"tn\":\"w\"}} }"
        #expect(try APIResponseParser.tagSuggestions(data(text)) == [
            TagRef(namespace: "a", name: "x}\"{"), TagRef(namespace: "b", name: "y"), TagRef(namespace: "c", name: "w"),
        ])
    }

    @Test func tagSuggestionsDegrade() throws {
        let json = data(#"{"tags":{"1":{"ns":"a"},"2":{"ns":"","tn":"y"},"3":"text","4":{"ns":"c","tn":"w"}}}"#)
        #expect(try APIResponseParser.tagSuggestions(json) == [
            TagRef(namespace: nil, name: "y"), TagRef(namespace: "c", name: "w"),
        ])
        #expect(try APIResponseParser.tagSuggestions(data(#"{"tags":[]}"#)).isEmpty)
        #expect(try APIResponseParser.tagSuggestions(data(#"{"tags":{}}"#)).isEmpty)
        #expect(throws: ParseError.malformed("tags")) {
            try APIResponseParser.tagSuggestions(data(#"{"tags":{"1":{"ns":"a"}}}"#))
        }
        #expect(throws: ParseError.missing("tags")) { try APIResponseParser.tagSuggestions(data("{}")) }
        #expect(throws: ParseError.malformed("tags")) { try APIResponseParser.tagSuggestions(data(#"{"tags":"x"}"#)) }
    }

    /// Dart's `jsonDecode` and JavaScript's `JSON.parse` let a later member override an earlier one, so Flutter reads
    /// the last top-level `tags`; `JSONSerialization` keeps the first.
    @Test func duplicateTopLevelTagsUseTheLastOne() throws {
        let json = data(
            #"{"tags":{"1":{"ns":"female","tn":"fake first"}},"tags":{"2":{"ns":"male","tn":"fake second"}}}"#
        )
        #expect(try APIResponseParser.tagSuggestions(json) == [TagRef(namespace: "male", name: "fake second")])
    }

    @Test func theLastTagsAloneDecidesEmptyOrMissing() throws {
        let first = #"{"tags":{"1":{"ns":"female","tn":"fake first"}},"#
        #expect(try APIResponseParser.tagSuggestions(data(first + #""tags":[]}"#)).isEmpty)
        #expect(throws: ParseError.missing("tags")) {
            try APIResponseParser.tagSuggestions(data(first + #""tags":null}"#))
        }
        #expect(throws: ParseError.malformed("tags")) {
            try APIResponseParser.tagSuggestions(data(first + #""tags":"x"}"#))
        }
    }

    /// Every inner member counts, in text order, a repeated key included; a tag that appears again is kept once, where
    /// it first appears.
    @Test func innerMembersAreReadOneByOne() throws {
        let json = data(
            #"{"tags":{"2":{"ns":"x","tn":"b"},"1":{"ns":"x","tn":"a"},"#
                + #""2":{"ns":"x","tn":"c"},"3":{"ns":"x","tn":"a"}}}"#
        )
        #expect(try APIResponseParser.tagSuggestions(json) == [
            TagRef(namespace: "x", name: "b"), TagRef(namespace: "x", name: "a"), TagRef(namespace: "x", name: "c"),
        ])
    }

    // MARK: Gallery data

    @Test func galleryFieldsAreRead() throws {
        let json = data("""
        {"gmetadata":[{"gid":900001,"token":"0f0f0f0f0f","title":"Fake Gallery 1","title_jpn":"Fake JP 1",\
        "category":"Artist CG","thumb":"https://ehgt.org/0f/0f/fake.webp","uploader":"Fake Uploader 1",\
        "posted":"1320000000","filecount":"11","filesize":111,"expunged":true,"rating":"4.50","torrentcount":"2",\
        "torrents":[],"tags":["fake tag 1","female:fake tag 2"," other : fake tag 3 "]}]}
        """)
        let gallery = try one(json)
        #expect(gallery == GalleryMetadata(
            id: GalleryID(gid: 900001, token: "0f0f0f0f0f"),
            title: "Fake Gallery 1",
            japaneseTitle: "Fake JP 1",
            category: .artistCG,
            thumbnailURL: URL(string: "https://ehgt.org/0f/0f/fake.webp"),
            uploader: "Fake Uploader 1",
            postedAt: Date(timeIntervalSince1970: 1_320_000_000),
            fileCount: 11,
            fileSize: 111,
            isExpunged: true,
            rating: 4.5,
            torrentCount: 2,
            tags: [
                TagRef(namespace: nil, name: "fake tag 1"), TagRef(namespace: "female", name: "fake tag 2"),
                TagRef(namespace: "other", name: "fake tag 3"),
            ]
        ))
    }

    @Test func numbersInGalleryDataMayBeNumbers() throws {
        let gallery = try one(gdata(#""title":"Fake Gallery 1","posted":1320000000,"filecount":11,"filesize":"111","rating":4.5,"torrentcount":0"#))
        #expect(gallery.postedAt == Date(timeIntervalSince1970: 1_320_000_000))
        #expect(gallery.fileCount == 11)
        #expect(gallery.fileSize == 111)
        #expect(gallery.rating == 4.5)
        #expect(gallery.torrentCount == 0)
    }

    @Test func titlesAreUnescapedOnce() throws {
        let gallery = try one(gdata(#""title":"Fake &amp; Gallery &#39;1&#39; &amp;lt; &quot;x&quot;","title_jpn":"&lt;JP&gt; &amp;amp;""#))
        #expect(gallery.title == #"Fake & Gallery '1' &lt; "x""#)
        #expect(gallery.japaneseTitle == "<JP> &amp;")
    }

    @Test func emptyJapaneseTitleIsNil() throws {
        #expect(try one(gdata(#""title":"Fake Gallery 1","title_jpn":"""#)).japaneseTitle == nil)
    }

    @Test func entriesWithErrorsAreDropped() throws {
        let json = data("""
        {"gmetadata":[{"gid":900002,"error":"Key missing, or incorrect key provided."},\
        {"gid":900001,"token":"0f0f0f0f0f","title":"Fake Gallery 1"},{"error":"Fake error"}]}
        """)
        let galleries = try APIResponseParser.galleryMetadata(json)
        #expect(galleries.map(\.id.gid) == [900001])
        #expect(try APIResponseParser.galleryMetadata(data(#"{"gmetadata":[]}"#)).isEmpty)
    }

    @Test func badEntriesAreSkippedOnTheirOwn() throws {
        let json = data("""
        {"gmetadata":[{"gid":900001,"token":"0f0f0f0f0f","title":"Fake Gallery 1"},\
        {"gid":900002,"title":"Fake Gallery 2"},5,{"gid":"x","token":"0f0f0f0f0f","title":"Fake Gallery 3"},\
        {"gid":900004,"token":"0f0f0f0f0f","title":" "},{"gid":900005,"error":"Fake error"},\
        {"gid":900006,"token":"0f0f0f0f0f","title":"Fake Gallery 6"}]}
        """)
        #expect(try APIResponseParser.galleryMetadata(json).map(\.id.gid) == [900001, 900006])
    }

    @Test func allBadEntriesThrowTheFirstFailure() {
        #expect(throws: ParseError.missing("token")) {
            try APIResponseParser.galleryMetadata(data("""
            {"gmetadata":[{"gid":900005,"error":"Fake error"},{"gid":900002,"title":"Fake Gallery 2"},\
            {"gid":"x","token":"0f0f0f0f0f","title":"Fake Gallery 3"},5]}
            """))
        }
        #expect(throws: ParseError.malformed("gmetadata")) {
            try APIResponseParser.galleryMetadata(data(#"{"gmetadata":[5,{"gid":1}]}"#))
        }
    }

    @Test func onlyErrorEntriesGiveNoGalleries() throws {
        let json = data(#"{"gmetadata":[{"gid":900001,"error":"Fake error"},{"gid":900002,"error":"Fake error"}]}"#)
        #expect(try APIResponseParser.galleryMetadata(json).isEmpty)
    }

    @Test func optionalGalleryFieldsDegrade() throws {
        let json = gdata("""
        "title":"Fake Gallery 1","title_jpn":5,"category":"Nothing","thumb":"ftp://x/y","uploader":7,\
        "posted":"soon","filecount":"many","filesize":1.5,"expunged":"maybe","rating":"high","torrentcount":null,\
        "tags":"fake"
        """)
        let gallery = try one(json)
        #expect(gallery == GalleryMetadata(
            id: GalleryID(gid: 900001, token: "0f0f0f0f0f"), title: "Fake Gallery 1", japaneseTitle: nil, category: nil,
            thumbnailURL: nil, uploader: nil, postedAt: nil, fileCount: nil, fileSize: nil, isExpunged: false,
            rating: nil, torrentCount: nil, tags: []
        ))
        let sparse = try one(gdata(#""title":"Fake Gallery 1","tags":["",5,"female:","fake tag 1"]"#))
        #expect(sparse.tags == [TagRef(namespace: nil, name: "fake tag 1")])
    }

    @Test func requiredGalleryFieldsAreMissingOrMalformed() {
        #expect(throws: ParseError.missing("gmetadata")) { try APIResponseParser.galleryMetadata(data("{}")) }
        #expect(throws: ParseError.malformed("gmetadata")) { try APIResponseParser.galleryMetadata(data(#"{"gmetadata":{}}"#)) }
        #expect(throws: ParseError.malformed("gmetadata")) { try APIResponseParser.galleryMetadata(data(#"{"gmetadata":[1]}"#)) }
        #expect(throws: ParseError.missing("gid")) {
            try APIResponseParser.galleryMetadata(data(#"{"gmetadata":[{"token":"0f0f0f0f0f","title":"x"}]}"#))
        }
        #expect(throws: ParseError.malformed("gid")) {
            try APIResponseParser.galleryMetadata(data(#"{"gmetadata":[{"gid":"x","token":"0f0f0f0f0f","title":"x"}]}"#))
        }
        #expect(throws: ParseError.missing("token")) {
            try APIResponseParser.galleryMetadata(data(#"{"gmetadata":[{"gid":1,"title":"x"}]}"#))
        }
        #expect(throws: ParseError.malformed("token")) {
            try APIResponseParser.galleryMetadata(data(#"{"gmetadata":[{"gid":1,"token":5,"title":"x"}]}"#))
        }
        #expect(throws: ParseError.missing("title")) {
            try APIResponseParser.galleryMetadata(data(#"{"gmetadata":[{"gid":1,"token":"0f0f0f0f0f"}]}"#))
        }
        #expect(throws: ParseError.malformed("title")) {
            try APIResponseParser.galleryMetadata(data(#"{"gmetadata":[{"gid":1,"token":"0f0f0f0f0f","title":" "}]}"#))
        }
    }
}
