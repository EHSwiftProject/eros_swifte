import EHFixtures
import EHModels
import EHParsing
import Foundation
import Testing

// Captured pages are checked by structure only (counts, formats, presence); a check that would print their values on
// failure (a collection's `isEmpty`, `==` on titles or ids) is bound to a Boolean before `#expect`. Hand-written rows
// and the constructed fixtures carry made-up values (gid 900001…, token 0f0f0f0f0f, "Fake Gallery 1"), which may be
// compared exactly.

/// One Compact list row, hand-written after the captured pages' markup. The rating div in the hover thumbnail
/// (`.glthumb`) always reads 2.5 and never has a user-rating class, so a test that sees anything else read the right
/// one: the sibling of `posted_<gid>`.
private func row(
    gid: Int = 900001,
    token: String = "0f0f0f0f0f",
    link: Bool = true,
    title: String = "Fake Gallery 1",
    ratingClass: String = "ir",
    ratingPosition: String = "0px -1px",
    postedAttributes: String = "",
    posted: String = "2011-11-11 11:11",
    tags: String = "",
    uploaderCell: String = #"<div><a href="https://e-hentai.org/uploader/Fake%20Uploader%201">Fake Uploader 1</a></div>"#
) -> String {
    let href = link ? "https://e-hentai.org/g/\(gid)/\(token)/" : "https://e-hentai.org/uploader/Fake%20Uploader%201"
    return """
    <tr><td class="gl1c glcat"><div class="cn ct2">Doujinshi</div></td>\
    <td class="gl2c"><div class="glcut" id="ic\(gid)"></div>\
    <div class="glthumb" id="it\(gid)" style="top:-11px;height:111px"><div>\
    <img style="height:111px;width:11px" alt="x" title="x" src="https://ehgt.org/a/11/111/11111-aaaaaaaa.webp"></div>\
    <div><div><div class="cn ct2">Doujinshi</div><div id="postedpop_\(gid)">2011-11-11 11:11</div></div>\
    <div><div class="ir" style="background-position:-32px -21px;opacity:1"></div><div>11 pages</div></div></div></div>\
    <div><div id="posted_\(gid)"\(postedAttributes)>\(posted)</div>\
    <div class="\(ratingClass)" style="background-position:\(ratingPosition);opacity:1"></div>\
    <div class="gldown"></div></div></td>\
    <td class="gl3c glname"><a href="\(href)"><div class="glink">\(title)</div><div>\(tags)</div></a></td>\
    <td class="gl4c glhide">\(uploaderCell)<div>11 pages</div></td></tr>
    """
}

/// A list page with only a results table (no display mode selector, so it is read as Compact).
private func page(_ rows: [String]) -> String {
    #"<html><body><div class="ido"><table class="itg gltc"><tr><th></th><th>Published</th></tr>"#
        + rows.joined() + "</table></div></body></html>"
}

private func isDigits(_ text: String?) -> Bool {
    guard let text, !text.isEmpty else { return false }
    return text.allSatisfy { $0.isASCII && $0.isNumber }
}

private func isToken(_ text: String) -> Bool {
    text.count == 10 && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
}

private func parse(fixture path: String) throws -> GalleryListPage {
    try GalleryListParser.parse(Fixtures.string(path))
}

@Suite struct GalleryListParserTests {
    // MARK: Captured and constructed fixtures, one test per row of the plan's table

    @Test(arguments: ["eh/list/front.html", "ex/list/front.html"])
    func frontPagesParse(path: String) throws {
        let list = try parse(fixture: path)
        #expect(list.items.count == 25)
        #expect(list.skippedRowCount == 0)
        for item in list.items {
            #expect(item.id.gid > 0)
            #expect(isToken(item.id.token))
            #expect(!item.title.isEmpty)
            #expect(item.category != nil)
            #expect(item.postedAt != nil)
            #expect((0...5).contains(item.rating))
            #expect(item.uploader != nil)
            #expect((item.pageCount ?? 0) > 0)
            #expect(item.coverURL?.scheme == "https")
        }
        #expect(list.displayMode == .compact)
        #expect(list.previousCursor == nil)
        #expect(isDigits(list.nextCursor))
        // Not a favorites page: no folders and no order control.
        let hasNoFolders = list.favoriteFolders.isEmpty
        #expect(hasNoFolders)
        #expect(list.favoritesOrder == nil)
    }

    @Test(arguments: ["eh/list/front-next.html", "ex/list/front-next.html"])
    func nextPagesHaveBothCursors(path: String) throws {
        let list = try parse(fixture: path)
        #expect(list.items.count == 25)
        #expect(isDigits(list.previousCursor))
        #expect(isDigits(list.nextCursor))
    }

    @Test(arguments: EHSite.allCases.flatMap { site in
        ["front-seek", "category", "search", "search-advanced", "tag", "uploader"].map { "\(site.rawValue)/list/\($0).html" }
    })
    func searchPagesHaveResultSummaries(path: String) throws {
        let list = try parse(fixture: path)
        #expect(list.items.count == 25)
        #expect(list.resultSummary?.isEmpty == false)
    }

    @Test(arguments: ["eh/list/popular.html", "ex/list/popular.html"])
    func popularPagesHaveNoCursors(path: String) throws {
        let list = try parse(fixture: path)
        #expect(list.items.count == 70)
        #expect(list.previousCursor == nil)
        #expect(list.nextCursor == nil)
    }

    @Test(arguments: ["yesterday", "month", "year", "all"].map { "eh/list/toplist-\($0).html" })
    func toplistsStartAtPageZero(path: String) throws {
        let list = try parse(fixture: path)
        #expect(list.items.count == 50)
        #expect(list.pageIndex == 0)
        #expect((list.pageCount ?? 0) >= 2)
    }

    @Test(arguments: ["eh/list/toplist-yesterday-p1.html"])
    func toplistSecondPageIsIndexOne(path: String) throws {
        let list = try parse(fixture: path)
        #expect(list.items.count == 50)
        #expect(list.pageIndex == 1)
    }

    @Test(arguments: ["eh/list/search-empty.html", "ex/list/search-empty.html"])
    func emptySearchPagesAreEmpty(path: String) throws {
        let list = try parse(fixture: path)
        let isEmpty = list.items.isEmpty
        #expect(isEmpty)
        #expect(list.displayMode == nil)
    }

    @Test(arguments: ["eh/list/image-lookup.html", "ex/list/image-lookup.html"])
    func imageLookupResultsSaySimilarityScanWasDisabled(path: String) throws {
        let list = try parse(fixture: path)
        let isEmpty = list.items.isEmpty
        #expect(isEmpty)
        #expect(list.similarityScanDisabled)
    }

    /// `constructed/eh/list-login-required.html`: the site's "log on" notice is an error, not an empty result.
    @Test(arguments: ["constructed/eh/list-login-required.html"])
    func loginRequiredPageThrows(path: String) throws {
        let html = try Fixtures.string(path)
        #expect(throws: ParseError.loginRequired) { try GalleryListParser.parse(html) }
        // Any case, in any element of the page.
        let shouting = "<html><body><div><span>THIS PAGE REQUIRES YOU TO LOG ON.</span></div></body></html>"
        #expect(throws: ParseError.loginRequired) { try GalleryListParser.parse(shouting) }
    }

    @Test(arguments: ["constructed/eh/list-filtered.html"])
    func filteredListCountsFilteredGalleries(path: String) throws {
        let list = try parse(fixture: path)
        #expect(list.items.count == 25)
        #expect(list.filteredCount == 1)
        // The unfiltered source page has no such line.
        #expect(try parse(fixture: "eh/list/front.html").filteredCount == nil)
    }

    @Test(arguments: ["constructed/eh/list-non-compact.html"])
    func nonCompactListThrows(path: String) throws {
        #expect(throws: ListParseError.notCompact(.thumbnail)) { try parse(fixture: path) }
    }

    /// `constructed/eh/list-favorites.html`: made-up values, written after the structure of the local favorites page.
    @Test(arguments: ["constructed/eh/list-favorites.html"])
    func constructedFavoritesParse(path: String) throws {
        let list = try parse(fixture: path)
        #expect(list.favoriteFolders.count == 10)
        #expect(list.favoriteFolders.map(\.index) == Array(0...9))
        #expect(list.favoriteFolders.allSatisfy { !$0.name.isEmpty })
        #expect(!list.items.isEmpty)
        for item in list.items {
            #expect(item.favoriteSlot != nil)
            #expect(item.favoriteName?.isEmpty == false)
        }
        #expect(list.items.contains { $0.isRatedByUser })
        #expect(list.items.contains { $0.favoriteNote == "[favnote]" })
        #expect(list.favoritesOrder != nil)
        // The values written into the fixture.
        #expect(list.items.count == 5)
        #expect(list.items.map(\.id.gid) == [900005, 900004, 900003, 900002, 900001])
        #expect(list.items.map(\.favoriteSlot) == [0, 3, 3, 7, 9])
        #expect(list.items.map(\.favoriteName) == ["Fake Folder 0", "Fake Folder 3", "Fake Folder 3", "Fake Folder 7", "Fake Folder 9"])
        #expect(list.items.filter(\.isRatedByUser).map(\.id.gid) == [900004])
        #expect(list.items.compactMap(\.favoriteNote) == ["[favnote]"])
        #expect(list.items.filter(\.isExpunged).map(\.id.gid) == [900002])
        #expect(list.favoriteFolders.map(\.count) == [1, 11, 1, 111, 1, 1, 1, 11, 1, 1])
        #expect(list.favoriteFolders.map(\.name) == (0...9).map { "Fake Folder \($0)" })
        #expect(list.favoritesOrder == .favoritedTime)
        #expect(list.displayMode == .compact)
        #expect(list.previousCursor == nil)
        #expect(list.nextCursor == "900001-1111111111")
        // favorites.php has no uploader column; the page count comes from the hover thumbnail instead.
        #expect(list.items.allSatisfy { $0.uploader == nil && $0.pageCount == 11 })
    }

    /// `constructed/eh/list-watched.html`: made-up values, written after the structure of the local watched page.
    @Test(arguments: ["constructed/eh/list-watched.html"])
    func constructedWatchedParse(path: String) throws {
        let list = try parse(fixture: path)
        #expect(list.items.count == 4)
        #expect(list.items.map(\.id.gid) == [900004, 900003, 900002, 900001])
        #expect(list.previousCursor == nil)
        #expect(list.nextCursor == "900001")
        #expect(list.skippedRowCount == 0)
        #expect(list.displayMode == .compact)
        #expect(list.resultSummary == nil)
        #expect(list.favoriteFolders.isEmpty)
        #expect(list.favoritesOrder == nil)
        #expect(list.items.allSatisfy { $0.uploader?.hasPrefix("Fake Uploader ") == true && $0.pageCount == 11 })
    }

    // MARK: Hand-written fragments

    @Test func ratingFromBackgroundPosition() throws {
        let cases: [(position: String, rating: Double)] = [
            ("-16px -1px", 4.0), ("0px -21px", 4.5), ("-64px -21px", 0.5), ("-80px -1px", 0),
        ]
        for (position, rating) in cases {
            let list = try GalleryListParser.parse(page([row(ratingPosition: position)]))
            #expect(list.items.first?.rating == rating, "\(position)")
            #expect(list.items.first?.isRatedByUser == false)
        }
        // Below zero is clamped to 0; the offsets' signs do not matter.
        #expect(try GalleryListParser.parse(page([row(ratingPosition: "-96px -1px")])).items.first?.rating == 0)
        #expect(try GalleryListParser.parse(page([row(ratingPosition: "-80px -21px")])).items.first?.rating == 0)
        #expect(try GalleryListParser.parse(page([row(ratingPosition: "16px 21px")])).items.first?.rating == 3.5)
        // The account's own rating colors the stars.
        for userClass in ["irr", "irg", "irb", "iry"] {
            let list = try GalleryListParser.parse(page([row(ratingClass: "ir \(userClass)")]))
            #expect(list.items.first?.isRatedByUser == true, "\(userClass)")
        }
    }

    @Test func favoriteColorsMapToSlots() throws {
        let colors = ["#000", "#f00", "#fa0", "#dd0", "#080", "#9f4", "#4bf", "#00f", "#508", "#e8e"]
        let rows = colors.enumerated().map { slot, color in
            row(
                gid: 900001 + slot,
                postedAttributes: #" style="border-color:\#(color);background-color:rgba(1,1,1,.1)" title="Fake Folder \#(slot)""#
            )
        }
        let unknown = row(
            gid: 900011, postedAttributes: #" style="border-color:#123;background-color:rgba(1,1,1,.1)" title="Fake Folder 1""#
        )
        let list = try GalleryListParser.parse(page(rows + [unknown, row(gid: 900012)]))
        #expect(list.items.map(\.favoriteSlot) == Array(0...9).map(Optional.some) + [nil, nil])
        #expect(list.items.prefix(10).map(\.favoriteName) == (0...9).map { "Fake Folder \($0)" })
        #expect(list.items.last?.favoriteName == nil)
    }

    @Test func tagColorsAreRead() throws {
        let style = "color:#111111;border-color:#222222;background:radial-gradient(#333333,#444444)"
        let tags = #"<div class="gt" style="\#(style)" title="other:fake tag 1">fake tag 1</div>"#
            + #"<div class="gtl" title="fake tag 2">fake tag 2</div>"#
        let list = try GalleryListParser.parse(page([row(tags: tags)]))
        let parsed = try #require(list.items.first?.tags)
        #expect(parsed.count == 2)
        #expect(parsed.first?.tag == TagRef(namespace: "other", name: "fake tag 1"))
        #expect(parsed.first?.colors == TagColors(text: "#111111", border: "#222222", background: "#444444"))
        #expect(parsed.last?.tag == TagRef(namespace: nil, name: "fake tag 2"))
        #expect(parsed.last?.colors == nil)
    }

    @Test func entitiesAreDecoded() throws {
        let list = try GalleryListParser.parse(page([row(title: "A &amp; B &#039;C&#039;")]))
        #expect(list.items.first?.title == "A & B 'C'")
    }

    @Test func rowWithoutGalleryLinkIsSkipped() throws {
        let list = try GalleryListParser.parse(page([row(gid: 900001), row(gid: 900002, link: false), row(gid: 900003)]))
        #expect(list.items.map(\.id) == [
            GalleryID(gid: 900001, token: "0f0f0f0f0f"), GalleryID(gid: 900003, token: "0f0f0f0f0f"),
        ])
        #expect(list.skippedRowCount == 1)
        // A row without a title is skipped too.
        let untitled = try GalleryListParser.parse(page([row(gid: 900001), row(gid: 900002, title: "")]))
        #expect(untitled.items.count == 1)
        #expect(untitled.skippedRowCount == 1)
    }

    @Test func pageWithRowsButNoneParsableThrows() {
        #expect(throws: ParseError.missing("gallery rows")) {
            try GalleryListParser.parse(page([row(gid: 900001, link: false), row(gid: 900002, link: false)]))
        }
    }

    /// The same as `emptySearchPagesAreEmpty`, on its own so the review can point at it.
    @Test func emptySearchIsAnEmptyPage() throws {
        for path in ["eh/list/search-empty.html", "ex/list/search-empty.html"] {
            let list = try GalleryListParser.parse(Fixtures.string(path))
            let isEmpty = list.items.isEmpty
            #expect(isEmpty, "\(path)")
            #expect(list.skippedRowCount == 0, "\(path)")
            #expect(list.displayMode == nil, "\(path)")
        }
    }

    /// Rows the selectors no longer find are a parse failure, not an empty result: the page still
    /// links its galleries. A renamed row class and a renamed table class.
    @Test func galleriesWithoutRowsThrow() {
        let renamedRows = page([row(gid: 900001), row(gid: 900002)])
            .replacingOccurrences(of: #"class="gl1c glcat""#, with: #"class="gl1x glcat""#)
        let renamedTable = page([row(gid: 900001)]).replacingOccurrences(of: #"class="itg gltc""#, with: #"class="itg2 gltc""#)
        for html in [renamedRows, renamedTable] {
            #expect(throws: ParseError.missing("gallery rows")) { try GalleryListParser.parse(html) }
        }
    }

    /// An Extended table (`table.itg.glte`) on a page without a display mode selector, which reads as Compact: no
    /// Compact row, but the galleries are linked.
    @Test func extendedTableWithoutSelectorThrows() {
        let extended = """
        <html><body><div class="ido"><table class="itg glte"><tr><td class="gl1e"><div>\
        <a href="https://e-hentai.org/g/900001/0f0f0f0f0f/"><img alt="Fake Gallery 1" src="https://ehgt.org/a/11/111/11111-aaaaaaaa.webp"></a>\
        </div></td><td class="gl2e"><div><div class="gl3e"><div class="cn ct2">Doujinshi</div></div>\
        <a href="https://e-hentai.org/g/900001/0f0f0f0f0f/"><div><div class="glink">Fake Gallery 1</div></div></a>\
        </div></td></tr></table></div></body></html>
        """
        #expect(throws: ParseError.missing("gallery rows")) { try GalleryListParser.parse(extended) }
    }

    /// A page without rows and without gallery links stays an empty result, whatever else it links.
    @Test func pageWithoutRowsOrGalleryLinksIsEmpty() throws {
        let html = """
        <html><body><div class="ido"><p>Fake: no hits found.</p>\
        <a href="https://e-hentai.org/uploader/Fake%20Uploader%201">Fake</a>\
        <a href="https://e-hentai.org/g/900001/">Fake link without a token</a>\
        <a href="https://e-hentai.org/s/0f0f0f0f0f/900001-1">Fake page link</a></div></body></html>
        """
        let list = try GalleryListParser.parse(html)
        #expect(list.items.isEmpty && list.skippedRowCount == 0)
    }

    /// A body without the page's structure is not an empty result: only the site's no-hits notice makes a page without
    /// rows an empty list.
    @Test func plainTextIsNotAnEmptyList() {
        #expect(throws: ParseError.missing("list page")) { try GalleryListParser.parse("Fake plain text without markup") }
    }

    /// Non-HTML bytes decoded as UTF-8 become U+FFFD text.
    @Test func binaryBodyIsNotAnEmptyList() {
        let body = String(decoding: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF]), as: UTF8.self)
        #expect(throws: ParseError.missing("list page")) { try GalleryListParser.parse(body) }
    }

    /// A real front page cut off before its table.
    @Test func truncatedPageIsNotAnEmptyList() throws {
        let html = try Fixtures.string("eh/list/front.html")
        let cut = try #require(html.range(of: #"<table class="itg"#))
        let truncated = String(html[..<cut.lowerBound])
        #expect(throws: ParseError.missing("list page")) { try GalleryListParser.parse(truncated) }
    }

    /// The marker counts only inside `div.ido`.
    @Test func noHitsOutsideTheIndexDoesNotCount() {
        let html = "<html><body><p>No hits found</p></body></html>"
        #expect(throws: ParseError.missing("list page")) { try GalleryListParser.parse(html) }
    }

    /// Read from the markup only: an uploader div with an `opacity` style is dimmed, with or without a link (the
    /// captured pages have both shapes); one without is not.
    @Test func dimmedUploaderIsReadFromStructure() throws {
        let list = try GalleryListParser.parse(page([
            row(gid: 900001, uploaderCell: #"<div style="opacity:0.5">Fake Uploader 2</div>"#),
            row(gid: 900002),
            row(
                gid: 900003,
                uploaderCell: #"<div style="opacity:0.5"><a href="https://e-hentai.org/uploader/Fake%20Uploader%203">Fake Uploader 3</a></div>"#
            ),
        ]))
        #expect(list.items.map(\.isUploaderDimmed) == [true, false, true])
        #expect(list.items.map(\.uploader) == ["Fake Uploader 2", "Fake Uploader 1", "Fake Uploader 3"])
        #expect(list.items.allSatisfy { $0.pageCount == 11 })
    }

    /// Guards against a quadratic slowdown only: the bound is loose so a loaded full test run cannot trip it.
    @Test func listParsingStaysFast() throws {
        let html = try Fixtures.string("eh/list/popular.html")
        let elapsed = try ContinuousClock().measure {
            for _ in 0..<10 { _ = try GalleryListParser.parse(html) }
        }
        #expect(elapsed < .seconds(30))
    }

    // MARK: Other fields

    @Test func cursorsComeFromTheLinksQueryValues() throws {
        let navigation = """
        <div class="searchnav"><div></div><div><a id="uprev" href="https://e-hentai.org/?f_search=a&amp;prev=900009">\
        Prev</a></div><div><a id="unext" href="https://e-hentai.org/?next=900001&amp;f_search=a">Next</a></div>\
        <div><a id="ulast" href="https://e-hentai.org/?prev=1">Last</a></div>\
        <div><select><option value="l" selected="selected">Compact</option></select></div></div>
        """
        let html = page([row()]).replacingOccurrences(of: "<div class=\"ido\">", with: "<div class=\"ido\">" + navigation)
        let list = try GalleryListParser.parse(html)
        #expect(list.previousCursor == "900009")
        #expect(list.nextCursor == "900001")
        #expect(list.displayMode == .compact)
        // A span (no page that way) has no cursor.
        let spans = html.replacingOccurrences(of: #"<a id="uprev""#, with: #"<span id="uprev""#)
        #expect(try GalleryListParser.parse(spans).previousCursor == nil)
    }

    @Test func rowFieldsAreRead() throws {
        let tags = #"<div class="gt" title="other:fake tag 1">fake tag 1</div>"#
        let list = try GalleryListParser.parse(page([row(ratingPosition: "-16px -21px", posted: "<s>2011-11-11 11:11</s>", tags: tags)]))
        let item = try #require(list.items.first)
        #expect(item.id == GalleryID(gid: 900001, token: "0f0f0f0f0f"))
        #expect(item.title == "Fake Gallery 1")
        #expect(item.category == .doujinshi)
        #expect(item.coverURL == URL(string: "https://ehgt.org/a/11/111/11111-aaaaaaaa.webp"))
        #expect(item.coverSize == ImageSize(width: 11, height: 111))
        #expect(item.tags == [ListTag(tag: TagRef(namespace: "other", name: "fake tag 1"), colors: nil)])
        #expect(item.postedAt == EHDate.listTimestamp("2011-11-11 11:11"))
        #expect(item.rating == 3.5)
        #expect(item.isExpunged)
        #expect(item.favoriteSlot == nil && item.favoriteName == nil && item.favoriteNote == nil)
        #expect(item.uploader == "Fake Uploader 1")
        #expect(!item.isUploaderDimmed)
        #expect(item.pageCount == 11)
    }

    @Test func pageTypesRoundTripThroughJSON() throws {
        let list = try GalleryListParser.parse(Fixtures.string("constructed/eh/list-favorites.html"))
        let again = try JSONDecoder().decode(GalleryListPage.self, from: JSONEncoder().encode(list))
        #expect(again == list)
    }
}
