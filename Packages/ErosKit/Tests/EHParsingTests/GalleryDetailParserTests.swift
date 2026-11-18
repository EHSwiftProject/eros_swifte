import EHFixtures
import EHModels
import EHParsing
import Foundation
import Testing

// Captured pages are checked by structure only (counts, formats, presence, agreement with the page's own script).
// Their ids, tags, titles, names and comments are compared as Booleans bound before `#expect`, and a whole parsed page
// with `Issue.record` naming only the fields that differ (`differingFields`), so that a failure prints no value.
// Hand-written pages and the constructed fixtures' made-up values (gid 900001, token 0f0f0f0f0f, "Fake Gallery 1") may
// be compared exactly.

// MARK: Hand-written gallery page, after the captured pages' markup

private let fakeID = GalleryID(gid: 900001, token: "0f0f0f0f0f")
private let sheetURL = "https://ehgt.org/a1/a1/900001-0.webp"

private let defaultScript = """
var base_url = "https://e-hentai.org/";
var gid = 900001;
var token = "0f0f0f0f0f";
var apiuid = 1111111;
var apikey = "aaaaaaaaaaaaaaaaaaaa";
var average_rating = 4.11;
var display_rating = 4.5;
"""

private let defaultDetails: [(key: String, value: String)] = [
    ("Posted:", "2011-11-11 11:11"),
    ("Parent:", "None"),
    ("Visible:", "Yes"),
    ("Language:", #"Fake Language &nbsp;<span class="halp" title="Fake help">TR</span>"#),
    ("File Size:", "11.11 MiB"),
    ("Length:", "21 pages"),
    ("Favorited:", "11 times"),
]

/// A tag cell: `strength` is the div's class, `vote` the link's.
private func tag(_ namespace: String, _ name: String, strength: String = "gt", vote: String = "", text: String? = nil) -> String {
    let raw = "\(namespace):\(name)"
    let id = raw.replacingOccurrences(of: " ", with: "_")
    return #"<div id="td_\#(id)" class="\#(strength)"><a id="ta_\#(id)" href="https://e-hentai.org/tag/\#(raw)" "#
        + #"class="\#(vote)" onclick="return toggle_tagmenu(1,'\#(raw)',this)">\#(text ?? name)</a></div>"#
}

private let defaultTagRows = """
<tr><td class="tc">other:</td><td>\(tag("other", "fake tag 1"))\(tag("other", "fake tag 2", strength: "gtl", vote: "tup"))</td></tr>\
<tr><td class="tc">misc:</td><td>\(tag("misc", "fake tag 3", strength: "gtw", vote: "tdn", text: "fake tag 3 | Fake Tag 3"))</td></tr>
"""

private func taglist(_ rows: String) -> String {
    #"<div id="taglist"><table>\#(rows)</table></div>"#
}

/// The uploader's comment.
private func uploaderComment(body: String = "Fake uploader comment") -> String {
    """
    <a name="c0"></a><div class="c1"><div class="c2"><div class="c3">Posted on 11 November 2011, 11:11 by: &nbsp; \
    <a href="https://e-hentai.org/uploader/Fake%20Uploader%201">Fake Uploader 1</a>&nbsp; &nbsp; \
    <a href="https://forums.e-hentai.org/index.php?showuser=1111111"><img class="ygm" src="https://ehgt.org/g/ygm.png" \
    alt="PM" title="Contact Poster" /></a></div><div class="c4 nosel"><a name="ulcomment"></a>Uploader Comment</div>\
    <div class="c"></div></div><div class="c6" id="comment_0">\(body)</div>\
    <div class="c7" id="cvotes_0" style="display:none"></div></div>
    """
}

/// Another account's comment; `upStyle` and `downStyle` mark the account's vote, `extraControls` go after the vote
/// links (an Edit link, say).
private func comment(
    id: Int,
    poster: String = "Fake Poster 1",
    memberID: Int? = 2222222,
    posted: String = "12 December 2012, 12:12",
    score: String = "+11",
    upStyle: String = "",
    downStyle: String = "",
    voteLinks: Bool = true,
    extraControls: String = "",
    body: String = "Fake comment",
    details: String = "Base +1, <span>Fake Voter 1 +1</span>, <span>Fake Voter 2 +1</span>"
) -> String {
    let profile = memberID.map {
        #"&nbsp; &nbsp; <a href="https://forums.e-hentai.org/index.php?showuser=\#($0)"><img class="ygm" src="https://ehgt.org/g/ygm.png" alt="PM" title="Contact Poster" /></a>"#
    } ?? ""
    let votes = voteLinks
        ? ##"[<a id="comment_vote_up_\##(id)" style="\##(upStyle)" href="#" onclick="vote_comment_up(\##(id)); this.blur(); return false">Vote+</a>] &nbsp; "##
            + ##"[<a id="comment_vote_down_\##(id)" style="\##(downStyle)" href="#" onclick="vote_comment_down(\##(id)); this.blur(); return false">Vote-</a>]"##
        : ""
    return """
    <a name="c\(id)"></a><div class="c1"><div class="c2"><div class="c3">Posted on \(posted) by: &nbsp; \
    <a href="https://e-hentai.org/uploader/\(poster.replacingOccurrences(of: " ", with: "%20"))">\(poster)</a>\(profile)</div>\
    <div class="c4 nosel">\(votes)\(extraControls)</div>\
    <div class="c5 nosel" onmouseover="document.getElementById('cvotes_\(id)').style.display=''">Score \
    <span id="comment_score_\(id)" style="opacity:1.0">\(score)</span></div><div class="c"></div></div>\
    <div class="c6" id="comment_\(id)">\(body)</div>\
    <div class="c7" id="cvotes_\(id)" style="display:none">\(details)</div></div>
    """
}

/// A current-style thumbnail (`#gdt > a > div`); with `label`, the div holds the cell and a label after it.
private func thumbnail(page: Int, offset: Int, height: Int = 141, label: Bool = false) -> String {
    let style = "width:100px;height:\(height)px;background:transparent url(\(sheetURL)) -\(offset)px 0 no-repeat"
    let cell = #"<div title="Page \#(page): \#(page).jpg" style="\#(style)"></div>"#
    let content = label ? #"<div>\#(cell)<div>Fake label</div></div>"# : cell
    return #"<a href="https://e-hentai.org/s/0f0f0f0f0f/900001-\#(page)">\#(content)</a>"#
}

private let defaultThumbnails = (1...2).map { thumbnail(page: $0, offset: ($0 - 1) * 100) }.joined()

/// Numbered thumbnail pages: `current` is 0-based.
private func pager(current: Int, count: Int) -> String {
    let cells = (0..<count).map { index in
        let href = "https://e-hentai.org/g/900001/0f0f0f0f0f/" + (index == 0 ? "" : "?p=\(index)")
        let attributes = index == current ? #" class="ptds""# : ""
        return #"<td\#(attributes)><a href="\#(href)" onclick="return false">\#(index + 1)</a></td>"#
    }
    return #"<table class="ptt"><tr><td class="ptdd">&lt;</td>\#(cells.joined())<td class="ptdd">&gt;</td></tr></table>"#
}

private func detailPage(
    script: String = defaultScript,
    gj: String = "Fake Gallery 1 (ja)",
    details: [(key: String, value: String)] = defaultDetails,
    ratingImage: String = #"<div id="rating_image" class="ir" style="background-position:-16px -1px">"#,
    ratingLabel: String = "Average: 3.11",
    fav: String = "",
    favoriteLink: String = #"<img src="https://ehgt.org/g/mr.gif" /> Add to Favorites"#,
    tags: String = taglist(defaultTagRows),
    torrents: Int = 1,
    comments: String = uploaderComment() + comment(id: 1111111),
    commentFooter: String = "",
    thumbnails: String = defaultThumbnails,
    pages: String = pager(current: 0, count: 2)
) -> String {
    let rows = details.map { #"<tr><td class="gdt1">\#($0.key)</td><td class="gdt2">\#($0.value)</td></tr>"# }.joined()
    return """
    <html><head><title>Fake Gallery 1 - E-Hentai Galleries</title></head><body>
    <script type="text/javascript">
    \(script)
    </script>
    <div class="gm"><div id="gleft"><div id="gd1"><div style="width:250px; height:354px; background:transparent \
    url(https://ehgt.org/a1/a1/900001-cover.webp) 0 0 no-repeat"></div></div></div>\
    <div id="gd2"><h1 id="gn">Fake Gallery 1 &amp; &#039;2&#039;</h1><h1 id="gj">\(gj)</h1></div>\
    <div id="gmid"><div id="gd3"><div id="gdc"><div class="cs ct2" onclick="document.location='https://e-hentai.org/doujinshi'">Doujinshi</div></div>\
    <div id="gdn"><a href="https://e-hentai.org/uploader/Fake%20Uploader%201">Fake Uploader 1</a></div>\
    <div id="gdd"><table>\(rows)</table></div>\
    <div id="gdr"><table><tr><td id="grt1">Rating:</td><td id="grt2">\(ratingImage)<img src="https://ehgt.org/g/blank.gif" usemap="#rating" /></div></td>\
    <td id="grt3"><span id="rating_count">1,111</span></td></tr><tr><td id="rating_label" colspan="3">\(ratingLabel)</td></tr></table></div>\
    <div id="gdf"><div style="float:left; cursor:pointer" id="fav">\(fav)</div><div style="float:left">&nbsp; \
    <a id="favoritelink" href="#" onclick="return false">\(favoriteLink)</a></div><div class="c"></div></div></div>\
    <div id="gd4">\(tags)</div>\
    <div id="gd5"><p class="g2 gsp"><img src="https://ehgt.org/g/mr.gif" /> <a href="#" \
    onclick="return popUp('https://e-hentai.org/archiver.php?gid=900001&amp;token=0f0f0f0f0f',480,320)">Archive Download</a></p>\
    <p class="g2"><img src="https://ehgt.org/g/mr.gif" /> <a href="#" \
    onclick="return popUp('https://e-hentai.org/gallerytorrents.php?gid=900001&amp;t=0f0f0f0f0f',610,590)">Torrent Download (\(torrents))</a></p></div>\
    <div class="c"></div></div><div class="c"></div></div>
    <div class="gtb"><p class="gpc">Showing 1 - 2 of 21 images</p>\(pages)</div>\
    <div id="gdt" class="gt200">\(thumbnails)</div>\
    <div class="gtb"><table class="ptb"><tr><td>1</td></tr></table></div>
    <div id="cdiv" class="gm">\(comments)<div id="chd">\(commentFooter)<p id="postnewcomment">[<a href="#" \
    onclick="display_comment_field(); return false">Post New Comment</a>]</p></div></div>
    </body></html>
    """
}

// MARK: Helpers for captured pages

private func parse(fixture path: String) throws -> GalleryDetail {
    try GalleryDetailParser.parse(Fixtures.string(path))
}

/// The gallery id the page's own script states, read independently of the parser.
private func scriptID(of html: String) throws -> GalleryID {
    let gid = try #require(html.firstMatch(of: /var gid = ([0-9]+);/).flatMap { Int($0.1) })
    let token = try #require(html.firstMatch(of: /var token = "([0-9a-f]{10})";/).map { String($0.1) })
    return GalleryID(gid: gid, token: token)
}

private func isHexKey(_ text: Substring) -> Bool {
    text.count == 10 && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
}

private func queryNames(of url: URL?) -> [String] {
    url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) } ?? []
}

/// The names of `lhs`'s stored properties whose values differ from `rhs`'s (told apart by their reflected text), for a
/// failure message that must not show the values. "(unnamed)" when the values differ but no property's text does.
private func differingFields(_ lhs: GalleryDetail, _ rhs: GalleryDetail) -> [String] {
    let names = zip(Mirror(reflecting: lhs).children, Mirror(reflecting: rhs).children).compactMap { left, right in
        String(reflecting: left.value) == String(reflecting: right.value) ? nil : left.label ?? "?"
    }
    return names.isEmpty && lhs != rhs ? ["(unnamed)"] : names
}

@Suite struct GalleryDetailParserTests {
    // MARK: Captured and constructed fixtures, one test per row of the plan's table

    @Test(arguments: EHSite.allCases)
    func detailPagesParse(site: EHSite) throws {
        let path = "\(site.rawValue)/gallery/detail.html"
        let html = try Fixtures.string(path)
        let detail = try GalleryDetailParser.parse(html)
        let idIsTheScripts = detail.id == (try scriptID(of: html))
        #expect(idIsTheScripts)
        #expect(!detail.title.isEmpty)
        #expect(detail.japaneseTitle?.isEmpty == false)
        #expect(detail.category != nil)
        #expect(detail.uploader?.isEmpty == false)
        #expect(detail.coverURL?.scheme == "https")
        #expect(detail.postedAt != nil)
        let pageCount = try #require(detail.pageCount)

        #expect(detail.thumbnails.count == 20)
        #expect(detail.thumbnails.map(\.pageIndex) == Array(1...20))
        for thumbnail in detail.thumbnails {
            guard case let .sprite(url, size, offsetX) = thumbnail.image else {
                Issue.record("page \(thumbnail.pageIndex) is not a sprite")
                continue
            }
            #expect(url.scheme == "https")
            #expect(size.width > 0 && size.height > 0)
            #expect(offsetX >= 0)
            // /s/<key>/<gid>-<page>
            let parts = thumbnail.pageURL.path().split(separator: "/")
            let pathHasAKey = parts.count == 3 && parts[0] == "s" && isHexKey(parts[1])
            #expect(pathHasAKey, "page \(thumbnail.pageIndex)")
            let pathNamesThePage = parts.last.map(String.init) == "\(detail.id.gid)-\(thumbnail.pageIndex)"
            #expect(pathNamesThePage, "page \(thumbnail.pageIndex)")
        }
        #expect(detail.thumbnailPageIndex == 0)
        #expect(detail.thumbnailPageCount == (pageCount + 19) / 20)

        #expect(detail.tagGroups.count >= 3)
        for group in detail.tagGroups {
            #expect(!group.namespace.isEmpty && !group.namespace.hasSuffix(":"))
            #expect(!group.tags.isEmpty)
            for tag in group.tags {
                let namespaceIsTheGroups = tag.tag.namespace == group.namespace
                #expect(namespaceIsTheGroups)
                let nameIsPlain = !tag.tag.name.isEmpty && !tag.tag.name.contains("|")
                #expect(nameIsPlain)
                #expect(tag.vote == .none)
            }
        }

        #expect(detail.comments.count == 6)
        #expect(detail.comments.filter(\.isUploaderComment).count == 1)
        #expect(detail.comments.filter(\.canVote).count == 5)
        for comment in detail.comments {
            #expect(!comment.posterName.isEmpty)
            #expect(comment.postedAt != nil)
            #expect(!comment.bodyHTML.isEmpty)
            #expect(!comment.canEdit && comment.userVote == 0)
            // EH links each poster's forum profile; EX does not.
            #expect((comment.posterMemberID != nil) == (site == .eh))
            if comment.isUploaderComment {
                #expect(comment.id == 0 && comment.score == nil && comment.scoreDetails.isEmpty)
            } else {
                #expect(comment.id > 0 && comment.score != nil)
                #expect(comment.scoreDetails.first?.hasPrefix("Base ") == true)
            }
        }
        #expect(detail.comments.first?.isUploaderComment == true)
        #expect(!detail.hasMoreComments)

        #expect(detail.apiUID != nil)
        #expect(detail.apiKey?.isEmpty == false)
        #expect(detail.torrentCount >= 1)
        let archiver = try #require(detail.archiverURL)
        #expect(archiver.path() == "/archiver.php")
        #expect(archiver.host() == site.host)
        #expect(Set(queryNames(of: archiver)) == ["gid", "token"])
        #expect(!queryNames(of: archiver).contains("or"))
        #expect(detail.favoriteSlot == nil && detail.favoriteName == nil)
        #expect((0...5).contains(detail.displayedRating))
        #expect(detail.ratingAverage != nil && detail.ratingCount != nil)
        #expect(detail.favoritedCount != nil)
        #expect(detail.fileSizeText?.isEmpty == false)
        #expect(detail.language?.isEmpty == false)
        #expect(detail.visibility?.isEmpty == false)
    }

    @Test(arguments: EHSite.allCases)
    func detailPageCountsMatchMPV(site: EHSite) throws {
        let detail = try parse(fixture: "\(site.rawValue)/gallery/detail.html")
        let viewer = try MPVPageParser.parse(Fixtures.string("\(site.rawValue)/mpv/mpv.html"))
        #expect(detail.pageCount == viewer.pageCount)
    }

    @Test(arguments: EHSite.allCases)
    func secondThumbnailPageStartsAtPage21(site: EHSite) throws {
        let detail = try parse(fixture: "\(site.rawValue)/gallery/detail-p1.html")
        let first = try parse(fixture: "\(site.rawValue)/gallery/detail.html")
        #expect(detail.thumbnailPageIndex == 1)
        #expect(detail.thumbnails.first?.pageIndex == 21)
        #expect(detail.thumbnails.map(\.pageIndex) == Array(21...40))
        #expect(detail.thumbnailPageCount == first.thumbnailPageCount)
        let sameGallery = detail.id == first.id
        #expect(sameGallery)
    }

    @Test(arguments: EHSite.allCases)
    func notFoundPageThrows(site: EHSite) {
        #expect(throws: ParseError.unavailable("Key missing, or incorrect key provided.")) {
            try parse(fixture: "\(site.rawValue)/gallery/not-found.html")
        }
    }

    /// `constructed/eh/detail-thumbs-normal.html`: four legacy small thumbnails (`div.gdtm`) of one sprite sheet.
    @Test func normalThumbnailsAreSprites() throws {
        let html = try Fixtures.string("constructed/eh/detail-thumbs-normal.html")
        let thumbnails = try GalleryDetailParser.thumbnails(in: html)
        let sheet = try #require(URL(string: "https://ehgt.org/m/111111/900001-00.jpg"))
        #expect(thumbnails == (1...4).map { page in
            GalleryThumbnail(
                pageIndex: page,
                pageURL: URL(string: "https://e-hentai.org/s/0f0f0f0f0f/900001-\(page)")!,
                image: .sprite(url: sheet, size: ImageSize(width: 100, height: 140 + page), offsetX: (page - 1) * 100)
            )
        })
    }

    /// `constructed/eh/detail-thumbs-large.html`: four legacy large thumbnails (`div.gdtl`), one image each.
    @Test func largeThumbnailsAreSingleImages() throws {
        let html = try Fixtures.string("constructed/eh/detail-thumbs-large.html")
        let thumbnails = try GalleryDetailParser.thumbnails(in: html)
        #expect(thumbnails.count == 4)
        for (offset, thumbnail) in thumbnails.enumerated() {
            let page = offset + 1
            #expect(thumbnail.pageIndex == page)
            #expect(thumbnail.pageURL == URL(string: "https://e-hentai.org/s/0f0f0f0f0f/900001-\(page)"))
            let size = ImageSize(width: 1000 + offset * 100, height: 1400 + offset * 100)
            let url = URL(string: "https://ehgt.org/0f/0f/0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0\(page)-111111-\(size.width)-\(size.height)-jpg_l.jpg")!
            #expect(thumbnail.image == .single(url: url, originalSize: size))
        }
    }

    /// `constructed/eh/detail-favorited.html`: `eh/gallery/detail.html` with only the listed marks changed, so the
    /// parse equals the source's with exactly those fields changed.
    @Test func favoritedDetailParses() throws {
        let source = try parse(fixture: "eh/gallery/detail.html")
        let favorited = try parse(fixture: "constructed/eh/detail-favorited.html")
        #expect(favorited.favoriteSlot == 3)
        #expect(favorited.favoriteName == "Fake Folder 3")
        #expect(favorited.isRatedByUser)
        let votes = favorited.tagGroups.flatMap(\.tags).map(\.vote)
        #expect(votes.prefix(2) == [.up, .down])
        #expect(votes.dropFirst(2).allSatisfy { $0 == .none })
        let edited = try #require(favorited.comments.dropFirst().first)
        #expect(edited.userVote == 1 && edited.canEdit && edited.canVote)
        #expect(favorited.comments.filter { $0.userVote != 0 || $0.canEdit }.count == 1)

        var expected = source
        expected.favoriteSlot = 3
        expected.favoriteName = "Fake Folder 3"
        expected.isRatedByUser = true
        var marked = 0
        expected.tagGroups = source.tagGroups.map { group in
            TagGroup(namespace: group.namespace, tags: group.tags.map { tag in
                defer { marked += 1 }
                let vote: TagVote = marked == 0 ? .up : marked == 1 ? .down : tag.vote
                return DetailTag(tag: tag.tag, strength: tag.strength, vote: vote)
            })
        }
        let original = source.comments[1]
        expected.comments[1] = GalleryComment(
            id: original.id, posterName: original.posterName, posterMemberID: original.posterMemberID,
            postedAt: original.postedAt, score: original.score, isUploaderComment: false, canVote: true, canEdit: true,
            userVote: 1, bodyHTML: original.bodyHTML, scoreDetails: original.scoreDetails
        )
        // Built from the captured page: only the names of differing fields may reach the report.
        if favorited != expected {
            Issue.record("the constructed page differs from its source in more than its marks: \(differingFields(favorited, expected))")
        }
    }

    // MARK: Listed in the plan

    @Test func detailWithoutGalleryIDThrows() throws {
        let withoutGID = detailPage(script: defaultScript.replacingOccurrences(of: "var gid = 900001;\n", with: ""))
        #expect(throws: ParseError.missing("gid")) { try GalleryDetailParser.parse(withoutGID) }
        let withoutToken = detailPage(script: defaultScript.replacingOccurrences(of: "var token = \"0f0f0f0f0f\";\n", with: ""))
        #expect(throws: ParseError.missing("token")) { try GalleryDetailParser.parse(withoutToken) }
        // The same on a captured page.
        let captured = try Fixtures.string("eh/gallery/detail.html")
            .replacing(/var gid = [0-9]+;/, with: "")
        #expect(throws: ParseError.missing("gid")) { try GalleryDetailParser.parse(captured) }
    }

    @Test func favoritedCountForms() throws {
        let cases: [(text: String, count: Int?)] = [
            ("Never", 0), ("Once", 1), ("1,234 times", 1234), ("11 times", 11), ("Fake count", nil),
        ]
        for (text, count) in cases {
            let details = defaultDetails.map { $0.key == "Favorited:" ? (key: $0.key, value: text) : $0 }
            #expect(try GalleryDetailParser.parse(detailPage(details: details)).favoritedCount == count, "\(text)")
        }
    }

    @Test func parentLinkParses() throws {
        let linked = defaultDetails.map {
            $0.key == "Parent:" ? (key: $0.key, value: #"<a href="https://e-hentai.org/g/900001/0f0f0f0f0f/">900001</a>"#) : $0
        }
        #expect(try GalleryDetailParser.parse(detailPage(details: linked)).parent == GalleryID(gid: 900001, token: "0f0f0f0f0f"))
        #expect(try GalleryDetailParser.parse(detailPage()).parent == nil)
    }

    @Test func commentBodyKeepsHTML() throws {
        let body = #"Fake line 1<br>Fake line 2 <a href="https://e-hentai.org/g/900002/0f0f0f0f0f/">Fake link</a><br><b>Fake bold</b>"#
        let detail = try GalleryDetailParser.parse(detailPage(comments: uploaderComment(body: body) + comment(id: 1111111, body: body)))
        #expect(detail.comments.map(\.bodyHTML) == [body, body])
    }

    @Test func tagFragmentParses() throws {
        // A hand-written tag list, alone in a fragment and inside the whole page.
        let fragment = taglist(defaultTagRows)
        let whole = try GalleryDetailParser.parse(detailPage(tags: fragment)).tagGroups
        #expect(try GalleryDetailParser.tagGroups(inFragment: fragment) == whole)
        #expect(whole == [
            TagGroup(namespace: "other", tags: [
                DetailTag(tag: TagRef(namespace: "other", name: "fake tag 1"), strength: .solid, vote: .none),
                DetailTag(tag: TagRef(namespace: "other", name: "fake tag 2"), strength: .dashed, vote: .up),
            ]),
            TagGroup(namespace: "misc", tags: [
                DetailTag(tag: TagRef(namespace: "misc", name: "fake tag 3"), strength: .weak, vote: .down),
            ]),
        ])
        // The taggallery API's "tagpane": the table without the #taglist div around it.
        #expect(try GalleryDetailParser.tagGroups(inFragment: "<table>\(defaultTagRows)</table>") == whole)
        // The tag list of a captured page, cut out of it as text, reads the same as the whole page.
        let html = try Fixtures.string("eh/gallery/detail.html")
        let start = try #require(html.range(of: #"<div id="taglist">"#))
        let end = try #require(html.range(of: #"<div id="tagmenu_act""#, range: start.upperBound..<html.endIndex))
        let captured = try GalleryDetailParser.tagGroups(inFragment: String(html[start.lowerBound..<end.lowerBound]))
        #expect(!captured.isEmpty)
        let fragmentReadsAsThePage = captured == (try GalleryDetailParser.parse(html).tagGroups)
        #expect(fragmentReadsAsThePage)
    }

    // MARK: Other fields

    @Test func detailFieldsAreRead() throws {
        let detail = try GalleryDetailParser.parse(detailPage())
        #expect(detail.id == fakeID)
        #expect(detail.title == "Fake Gallery 1 & '2'")
        #expect(detail.japaneseTitle == "Fake Gallery 1 (ja)")
        #expect(detail.category == .doujinshi)
        #expect(detail.uploader == "Fake Uploader 1")
        #expect(detail.coverURL == URL(string: "https://ehgt.org/a1/a1/900001-cover.webp"))
        #expect(detail.postedAt == EHDate.listTimestamp("2011-11-11 11:11"))
        #expect(detail.parent == nil)
        #expect(detail.visibility == "Yes")
        #expect(detail.language == "Fake Language")
        #expect(detail.fileSizeText == "11.11 MiB")
        #expect(detail.pageCount == 21)
        #expect(detail.favoritedCount == 11)
        // The page script's values (4.11, 4.5) win over the markup's (Average: 3.11; 4.0 from the star sprite).
        #expect(detail.ratingAverage == 4.11)
        #expect(detail.displayedRating == 4.5)
        #expect(detail.ratingCount == 1111)
        #expect(!detail.isRatedByUser)
        #expect(detail.favoriteSlot == nil && detail.favoriteName == nil)
        #expect(detail.tagGroups.map(\.namespace) == ["other", "misc"])
        #expect(detail.hasMoreComments == false)
        #expect(detail.thumbnailPageIndex == 0 && detail.thumbnailPageCount == 2)
        #expect(detail.thumbnails == (1...2).map { page in
            GalleryThumbnail(
                pageIndex: page, pageURL: URL(string: "https://e-hentai.org/s/0f0f0f0f0f/900001-\(page)")!,
                image: .sprite(url: URL(string: sheetURL)!, size: ImageSize(width: 100, height: 141), offsetX: (page - 1) * 100)
            )
        })
        #expect(detail.apiUID == 1111111)
        #expect(detail.apiKey == "aaaaaaaaaaaaaaaaaaaa")
        #expect(detail.torrentCount == 1)
        #expect(detail.archiverURL == URL(string: "https://e-hentai.org/archiver.php?gid=900001&token=0f0f0f0f0f"))

        #expect(detail.comments == [
            GalleryComment(
                id: 0, posterName: "Fake Uploader 1", posterMemberID: 1111111,
                postedAt: EHDate.commentTimestamp("11 November 2011, 11:11"), score: nil, isUploaderComment: true,
                canVote: false, canEdit: false, userVote: 0, bodyHTML: "Fake uploader comment", scoreDetails: []
            ),
            GalleryComment(
                id: 1111111, posterName: "Fake Poster 1", posterMemberID: 2222222,
                postedAt: EHDate.commentTimestamp("12 December 2012, 12:12"), score: 11, isUploaderComment: false,
                canVote: true, canEdit: false, userVote: 0, bodyHTML: "Fake comment",
                scoreDetails: ["Base +1", "Fake Voter 1 +1", "Fake Voter 2 +1"]
            ),
        ])
    }

    @Test func emptyJapaneseTitleIsNil() throws {
        #expect(try GalleryDetailParser.parse(detailPage(gj: "")).japaneseTitle == nil)
        #expect(try GalleryDetailParser.parse(detailPage(gj: " ")).japaneseTitle == nil)
    }

    @Test func ratingFallsBackToTheMarkup() throws {
        let script = defaultScript
            .replacingOccurrences(of: "var average_rating = 4.11;\n", with: "")
            .replacingOccurrences(of: "var display_rating = 4.5;", with: "")
        #expect(!script.contains("rating"))
        // "Average: 3.11"; -16px -1px on the star sprite: 4.0.
        let detail = try GalleryDetailParser.parse(detailPage(script: script))
        #expect(detail.ratingAverage == 3.11)
        #expect(detail.displayedRating == 4)
        let other = try GalleryDetailParser.parse(detailPage(
            script: script,
            ratingImage: #"<div id="rating_image" class="ir irb" style="background-position:-32px -1px">"#,
            ratingLabel: "Not Yet Rated"
        ))
        #expect(other.ratingAverage == nil)
        #expect(other.displayedRating == 3)
        #expect(other.isRatedByUser)
        // Each of the account's star colors counts as its own rating.
        for userClass in ["irr", "irg", "irb", "iry"] {
            let page = detailPage(ratingImage: #"<div id="rating_image" class="ir \#(userClass)" style="background-position:0px -1px">"#)
            #expect(try GalleryDetailParser.parse(page).isRatedByUser, "\(userClass)")
        }
    }

    @Test func favoriteSlotsFromTheIconOffset() throws {
        for slot in 0...9 {
            let detail = try GalleryDetailParser.parse(detailPage(
                fav: #"<div class="i" style="background-position:0px -\#(2 + 19 * slot)px; margin-left:10px"></div>"#,
                favoriteLink: "Fake Folder \(slot)"
            ))
            #expect(detail.favoriteSlot == slot)
            #expect(detail.favoriteName == "Fake Folder \(slot)")
        }
        // An offset past the ten categories is no slot.
        #expect(try GalleryDetailParser.parse(detailPage(fav: #"<div style="background-position:0px -192px"></div>"#)).favoriteSlot == nil)
    }

    @Test func commentVotesEditsAndMore() throws {
        let edit = ##" &nbsp; [<a href="#" onclick="edit_comment(1111113); return false">Edit</a>]"##
        let detail = try GalleryDetailParser.parse(detailPage(
            comments: uploaderComment()
                + comment(id: 1111111, upStyle: "color:blue")
                + comment(id: 1111112, memberID: nil, score: "-3", downStyle: "color:blue", details: "Base -3")
                + comment(id: 1111113, voteLinks: false, extraControls: edit, details: ""),
            commentFooter: #"<p>There are 1 more comments below the viewing threshold - <a href="https://e-hentai.org/g/900001/0f0f0f0f0f/?hc=1#comments" rel="nofollow">click to show all</a>.</p>"#
        ))
        #expect(detail.comments.map(\.id) == [0, 1111111, 1111112, 1111113])
        #expect(detail.comments.map(\.userVote) == [0, 1, -1, 0])
        #expect(detail.comments.map(\.canVote) == [false, true, true, false])
        #expect(detail.comments.map(\.canEdit) == [false, false, false, true])
        #expect(detail.comments.map(\.score) == [nil, 11, -3, 11])
        #expect(detail.comments.map(\.posterMemberID) == [1111111, 2222222, nil, 2222222])
        #expect(detail.comments.map(\.scoreDetails) == [[], ["Base +1", "Fake Voter 1 +1", "Fake Voter 2 +1"], ["Base -3"], []])
        #expect(detail.hasMoreComments)
    }

    @Test func currentThumbnailWithLabelReadsItsFirstChild() throws {
        let thumbnails = try GalleryDetailParser.thumbnails(in: detailPage(
            thumbnails: thumbnail(page: 1, offset: 0, label: true) + thumbnail(page: 2, offset: 100, height: 142)
        ))
        #expect(thumbnails.map(\.pageIndex) == [1, 2])
        #expect(thumbnails.map(\.image) == [
            .sprite(url: URL(string: sheetURL)!, size: ImageSize(width: 100, height: 141), offsetX: 0),
            .sprite(url: URL(string: sheetURL)!, size: ImageSize(width: 100, height: 142), offsetX: 100),
        ])
    }

    /// Unreadable thumbnails cost the page its thumbnails only: everything else is read as usual.
    @Test func detailWithoutReadableThumbnailsStillParses() throws {
        let unreadable = #"<a href="https://e-hentai.org/s/0f0f0f0f0f/900001-1"><div title="Fake title"></div></a>"#
        for thumbnails in ["", unreadable] {
            let detail = try GalleryDetailParser.parse(detailPage(thumbnails: thumbnails))
            var expected = try GalleryDetailParser.parse(detailPage())
            expected.thumbnails = []
            #expect(detail.thumbnails.isEmpty)
            #expect(detail.id == fakeID)
            #expect(detail.title == "Fake Gallery 1 & '2'")
            #expect(detail.pageCount == 21)
            #expect(detail == expected)
        }
    }

    /// `thumbnails(in:)` has nothing else to return, so unreadable thumbnails are an error there.
    @Test func thumbnailsWithoutReadableCellsThrow() {
        let unreadable = #"<a href="https://e-hentai.org/s/0f0f0f0f0f/900001-1"><div title="Fake title"></div></a>"#
        for html in [detailPage(thumbnails: ""), detailPage(thumbnails: unreadable), "<html><body></body></html>"] {
            #expect(throws: ParseError.missing("thumbnails")) { try GalleryDetailParser.thumbnails(in: html) }
        }
    }

    @Test func thumbnailPagesOfAPageWithoutAPager() throws {
        let detail = try GalleryDetailParser.parse(detailPage(pages: ""))
        #expect(detail.thumbnailPageIndex == 0)
        #expect(detail.thumbnailPageCount == 1)
        let third = try GalleryDetailParser.parse(detailPage(pages: pager(current: 2, count: 3)))
        #expect(third.thumbnailPageIndex == 2 && third.thumbnailPageCount == 3)
    }

    @Test func missingTitleThrows() {
        let page = detailPage().replacingOccurrences(of: #"<h1 id="gn">Fake Gallery 1 &amp; &#039;2&#039;</h1>"#, with: "")
        #expect(throws: ParseError.missing("title")) { try GalleryDetailParser.parse(page) }
    }

    /// The gallery page reads `apikey` by the mytags page's rule: letters of either case and
    /// digits, not only lowercase hex.
    @Test func apiKeyOfLettersAndDigitsIsRead() throws {
        let script = defaultScript.replacingOccurrences(
            of: #"var apikey = "aaaaaaaaaaaaaaaaaaaa";"#, with: #"var apikey = "AAAAaaaa1111AAAAzzzz";"#
        )
        let detail = try GalleryDetailParser.parse(detailPage(script: script))
        #expect(detail.apiKey == "AAAAaaaa1111AAAAzzzz")
        #expect(detail.apiUID == 1111111)
        // Neither page takes a key in another shape.
        let quoted = defaultScript.replacingOccurrences(of: #""aaaaaaaaaaaaaaaaaaaa""#, with: #""aaaa-aaaa""#)
        #expect(try GalleryDetailParser.parse(detailPage(script: quoted)).apiKey == nil)
    }

    @Test func detailRoundTripsThroughJSON() throws {
        for path in ["eh/gallery/detail.html", "constructed/eh/detail-favorited.html"] {
            let detail = try parse(fixture: path)
            let again = try JSONDecoder().decode(GalleryDetail.self, from: JSONEncoder().encode(detail))
            // A captured page among them: only the names of differing fields may reach the report.
            if again != detail { Issue.record("\(path) changed in a round trip: \(differingFields(again, detail))") }
        }
        let thumbnails = try GalleryDetailParser.thumbnails(in: Fixtures.string("constructed/eh/detail-thumbs-large.html"))
        #expect(try JSONDecoder().decode([GalleryThumbnail].self, from: JSONEncoder().encode(thumbnails)) == thumbnails)
    }
}
