import EHModels
import Foundation
import SwiftSoup

/// Reads gallery pages (`/g/<gid>/<token>/`, and `?p=<n>` for the later thumbnail pages): the gallery's details,
/// rating, favorite mark, tag list, comments and thumbnails.
public enum GalleryDetailParser {
    /// The whole body of the site's answer for a gallery that does not exist or a wrong token.
    private static let keyMissing = "Key missing, or incorrect key provided."

    /// Parses a gallery page.
    ///
    /// The id comes from the page script (`var gid`, `var token`), the title from `#gn`; every other field is
    /// optional and left nil (or 0, false, empty) when the page does not show it. Thumbnails that cannot be read
    /// leave `thumbnails` empty and the rest of the page is still read (`thumbnails(in:)` throws instead).
    /// - Throws: `ParseError.unavailable` with the site's sentence when the page says the key is missing or wrong;
    ///   `ParseError.missing("gid")`, `("token")` or `("title")` when the page lacks one; whatever SwiftSoup throws,
    ///   unchanged.
    public static func parse(_ html: String) throws -> GalleryDetail {
        let document = try SwiftSoup.parse(html)
        // The comment bodies are kept as the page has them: no indentation or line breaks added.
        document.outputSettings().prettyPrint(pretty: false)
        if try document.body()?.text() == keyMissing { throw ParseError.unavailable(keyMissing) }

        let script = try scriptText(of: document)
        guard let gid = script.firstMatch(of: /var\s+gid\s*=\s*([0-9]+)\s*;/).flatMap({ Int($0.1) }), gid > 0 else {
            throw ParseError.missing("gid")
        }
        guard let token = script.firstMatch(of: /var\s+token\s*=\s*"([0-9a-f]{10})"\s*;/).map({ String($0.1) }) else {
            throw ParseError.missing("token")
        }
        guard let title = try nonEmpty(document.select("#gn").first()?.text()) else { throw ParseError.missing("title") }

        let details = try detailCells(in: document)
        let ratingImage = try document.select("#rating_image").first()
        let favorite = try favorite(in: document)
        let thumbnailPages = try GalleryListParser.numberedPages(in: document, selector: ".gtb table.ptt")
        let thumbnailPageIndex = thumbnailPages.index ?? 0
        let download = try downloads(in: document)
        return GalleryDetail(
            id: GalleryID(gid: gid, token: token),
            title: title,
            japaneseTitle: try nonEmpty(document.select("#gj").first()?.text()),
            category: try document.select("#gdc > div").first().flatMap { GalleryCategory(siteLabel: try $0.text()) },
            uploader: try uploader(in: document),
            coverURL: try document.select("#gd1 > div").first().flatMap { imageURL(fromStyle: try $0.attr("style")) },
            postedAt: try details["Posted:"].flatMap(valueText(of:)).flatMap(EHDate.listTimestamp),
            parent: try details["Parent:"].flatMap(parent(in:)),
            visibility: try details["Visible:"].flatMap(valueText(of:)),
            language: try details["Language:"].flatMap(valueText(of:)),
            fileSizeText: try details["File Size:"].flatMap(valueText(of:)),
            pageCount: try details["Length:"].flatMap(valueText(of:)).flatMap(pageCount(from:)),
            favoritedCount: try details["Favorited:"].flatMap(valueText(of:)).flatMap(favoritedCount(from:)),
            ratingAverage: try ratingAverage(script: script, document: document),
            ratingCount: try document.select("#rating_count").first().flatMap { integer(try $0.text()) },
            displayedRating: try displayedRating(script: script, ratingImage: ratingImage),
            isRatedByUser: GalleryListParser.isUserRating(ratingImage),
            favoriteSlot: favorite.slot,
            favoriteName: favorite.name,
            tagGroups: try document.select("#taglist").first().map(tagGroups(in:)) ?? [],
            comments: try comments(in: document),
            hasMoreComments: try !document.select("#chd a[href*=hc=1]").isEmpty(),
            thumbnails: try readThumbnails(in: document),
            thumbnailPageIndex: thumbnailPageIndex,
            thumbnailPageCount: thumbnailPages.count ?? thumbnailPageIndex + 1,
            apiUID: PageScript.apiUID(in: script),
            apiKey: PageScript.apiKey(in: script),
            torrentCount: download.torrentCount,
            archiverURL: download.archiverURL
        )
    }

    /// The thumbnails of a gallery page, in page order. Three markups are tried in turn: the legacy small
    /// thumbnails (`#gdt > div.gdtm`), the legacy large ones (`#gdt > div.gdtl`) and the current ones (`#gdt > a`).
    /// A cell without a page number, a link or an image is skipped.
    /// - Throws: `ParseError.missing("thumbnails")` when no cell of any of them can be read; whatever SwiftSoup
    ///   throws, unchanged.
    public static func thumbnails(in html: String) throws -> [GalleryThumbnail] {
        let thumbnails = try readThumbnails(in: SwiftSoup.parse(html))
        if thumbnails.isEmpty { throw ParseError.missing("thumbnails") }
        return thumbnails
    }

    /// Tag groups from a #taglist table or a fragment holding one (also the "tagpane" of the taggallery API).
    ///
    /// The rows are those of `#taglist` when the fragment has one, else every row of the fragment; a row is a group
    /// when it has a `td.tc` (its namespace, the trailing ":" dropped). An empty fragment has none.
    /// - Throws: whatever SwiftSoup throws, unchanged.
    public static func tagGroups(inFragment html: String) throws -> [TagGroup] {
        let document = try SwiftSoup.parseBodyFragment(html)
        let scope: Element = try document.select("#taglist").first() ?? document.body() ?? document
        return try tagGroups(in: scope)
    }

    // MARK: Details

    /// Every script's text, in page order (the gallery's variables are set in an inline script).
    private static func scriptText(of document: Document) throws -> String {
        try document.select("script").array().map { $0.data() }.joined(separator: "\n")
    }

    /// `#gdd`'s rows: the label cell's text (`td.gdt1`, "Posted:") to the value cell (`td.gdt2`); the first row of a
    /// label wins.
    private static func detailCells(in document: Document) throws -> [String: Element] {
        var cells: [String: Element] = [:]
        for row in try document.select("#gdd tr") {
            guard let label = try nonEmpty(row.select("td.gdt1").first()?.text()),
                  let value = try row.select("td.gdt2").first(), cells[label] == nil else { continue }
            cells[label] = value
        }
        return cells
    }

    /// A value cell's own text (so the language's "TR" mark, a child span, is left out), else all of its text.
    private static func valueText(of cell: Element) throws -> String? {
        try nonEmpty(cell.ownText()) ?? nonEmpty(cell.text())
    }

    /// The `/g/<gid>/<token>/` link of the Parent row; nil for "None".
    private static func parent(in cell: Element) throws -> GalleryID? {
        for link in try cell.select("a[href]") {
            let href = try link.attr("href")
            if let match = href.firstMatch(of: /\/g\/([0-9]+)\/([0-9a-f]{10})\//), let gid = Int(match.1), gid > 0 {
                return GalleryID(gid: gid, token: String(match.2))
            }
        }
        return nil
    }

    /// "Never" → 0, "Once" → 1, "N times" → N (thousands separators allowed); nil for anything else.
    private static func favoritedCount(from text: String) -> Int? {
        switch text {
        case "Never": 0
        case "Once": 1
        default: text.firstMatch(of: /([0-9][0-9,]*)\s+times/).flatMap { integer(String($0.1)) }
        }
    }

    /// "N pages" (or "1 page") → N, thousands separators allowed.
    private static func pageCount(from text: String) -> Int? {
        text.firstMatch(of: /([0-9][0-9,]*)\s+pages?/).flatMap { integer(String($0.1)) }
    }

    /// `text` as an integer once thousands separators and surrounding whitespace are dropped.
    private static func integer(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ""))
    }

    /// `#gdn > a`, else `#gdn`'s text (a gallery without a linked uploader).
    private static func uploader(in document: Document) throws -> String? {
        try nonEmpty(document.select("#gdn > a").first()?.text()) ?? nonEmpty(document.select("#gdn").first()?.text())
    }

    /// The address in a style's `url(…)`, quoted or not.
    private static func imageURL(fromStyle style: String) -> URL? {
        guard let match = style.firstMatch(of: /url\(\s*['"]?([^'")\s]+)['"]?\s*\)/) else { return nil }
        return URL(string: String(match.1))
    }

    /// The page script's `average_rating`, else the `Average: x` of `#rating_label`.
    private static func ratingAverage(script: String, document: Document) throws -> Double? {
        if let match = script.firstMatch(of: /var\s+average_rating\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*;/) {
            return Double(match.1)
        }
        let label = try document.select("#rating_label").first()?.text() ?? ""
        return label.firstMatch(of: /Average:\s*([0-9]+(?:\.[0-9]+)?)/).flatMap { Double($0.1) }
    }

    /// The page script's `display_rating`, else the star sprite's offset (the list pages' formula), else 0.
    private static func displayedRating(script: String, ratingImage: Element?) throws -> Double {
        if let match = script.firstMatch(of: /var\s+display_rating\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*;/),
           let rating = Double(match.1) {
            return rating
        }
        return try ratingImage.flatMap { GalleryListParser.rating(fromStyle: try $0.attr("style")) } ?? 0
    }

    /// The favorites category from the offset of the icon in `#fav` (`background-position:0px -<n>px`, the
    /// category `(n - 2) / 19`, as the Flutter app), and the name `#favoritelink` shows instead of "Add to Favorites".
    private static func favorite(in document: Document) throws -> (slot: Int?, name: String?) {
        var slot: Int?
        if let icon = try document.select("#fav > div").first(),
           let match = try icon.attr("style").firstMatch(of: /background-position:\s*0(?:px)?\s+-([0-9]+)px/),
           let offset = Int(match.1), offset >= 2, (0...9).contains((offset - 2) / 19) {
            slot = (offset - 2) / 19
        }
        let name = try nonEmpty(document.select("#favoritelink").first()?.text())
        return (slot, name == "Add to Favorites" ? nil : name)
    }

    /// `#gd5`: the count in "Torrent Download (N)", and the archiver popup's address (the first argument of the
    /// `popUp('…')` of the link whose `onclick` opens `archiver.php`). The current site no longer adds an `or=` to it.
    private static func downloads(in document: Document) throws -> (torrentCount: Int, archiverURL: URL?) {
        var torrentCount = 0
        var archiverURL: URL?
        for link in try document.select("#gd5 a") {
            if let match = try link.text().firstMatch(of: /Torrent Download\s*\(([0-9][0-9,]*)\)/),
               let count = integer(String(match.1)) {
                torrentCount = count
            }
            let onclick = try link.attr("onclick")
            if archiverURL == nil, onclick.contains("archiver.php"), let match = onclick.firstMatch(of: /popUp\('([^']+)'/) {
                // SwiftSoup has decoded the attribute; a `&amp;` left over was written twice-escaped.
                archiverURL = URL(string: String(match.1).replacingOccurrences(of: "&amp;", with: "&"))
            }
        }
        return (torrentCount, archiverURL)
    }

    // MARK: Tags

    /// The tag rows under `scope`: each `tr` with a `td.tc`, its `div.gt`, `div.gtl` and `div.gtw` boxes in order.
    private static func tagGroups(in scope: Element) throws -> [TagGroup] {
        var groups: [TagGroup] = []
        for row in try scope.select("tr") {
            guard let label = try row.select("td.tc").first() else { continue }
            var namespace = try label.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if namespace.hasSuffix(":") { namespace = String(namespace.dropLast()) }
            var tags: [DetailTag] = []
            for box in try row.select("div.gt, div.gtl, div.gtw") {
                guard let link = box.children().first(where: { $0.tagName() == "a" }) else { continue }
                // A tag may show a second name after "|"; the tag is the part before it.
                let text = try link.text()
                guard let name = nonEmpty(String(text[..<(text.firstIndex(of: "|") ?? text.endIndex)])) else { continue }
                let strength: TagStrength = box.hasClass("gt") ? .solid : box.hasClass("gtl") ? .dashed : .weak
                let vote: TagVote = link.hasClass("tup") ? .up : link.hasClass("tdn") ? .down : .none
                tags.append(DetailTag(tag: TagRef(namespace: nonEmpty(namespace), name: name), strength: strength, vote: vote))
            }
            groups.append(TagGroup(namespace: namespace, tags: tags))
        }
        return groups
    }

    // MARK: Comments

    /// `#cdiv > div.c1`, in page order; a comment without its header (`div.c3`) or body (`div.c6` with an id
    /// `comment_<n>`) is skipped.
    private static func comments(in document: Document) throws -> [GalleryComment] {
        try document.select("#cdiv > div.c1").compactMap(comment(from:))
    }

    private static func comment(from element: Element) throws -> GalleryComment? {
        guard let header = try element.select("div.c3").first(),
              let body = try element.select("div.c6").first(),
              let id = try body.attr("id").wholeMatch(of: /comment_([0-9]+)/).flatMap({ Int($0.1) }) else { return nil }
        let headerText = try header.text()
        let poster = header.children().first { $0.tagName() == "a" }
        let posterName = try nonEmpty(poster?.text())
            ?? headerText.firstMatch(of: /by:(.*)$/).flatMap { nonEmpty(String($0.1)) }
            ?? ""
        var memberID: Int?
        for link in try header.select("a[href*=showuser=]") {
            if let match = try link.attr("href").firstMatch(of: /showuser=([0-9]+)/) { memberID = Int(match.1); break }
        }

        let controls = try element.select("div.c4").first()
        let isUploaderComment = try controls?.text().contains("Uploader Comment") ?? false
        let voteUp = try controls?.select("a[id^=comment_vote_up_]").first()
        let voteDown = try controls?.select("a[id^=comment_vote_down_]").first()
        var userVote = 0
        if try nonEmpty(voteUp?.attr("style")) != nil { userVote = 1 }
        if try nonEmpty(voteDown?.attr("style")) != nil { userVote = -1 }

        let scoreText = try element.select("div.c5 span").first()?.text() ?? ""
        return GalleryComment(
            id: id,
            posterName: posterName,
            posterMemberID: memberID,
            postedAt: headerText.firstMatch(of: /Posted on (.+?) by:/).flatMap { EHDate.commentTimestamp(String($0.1)) },
            score: scoreText.firstMatch(of: /[+-]?[0-9]+/).flatMap { Int($0.output) },
            isUploaderComment: isUploaderComment,
            canVote: voteUp != nil,
            canEdit: try controls.map { try !$0.select("a[onclick*=edit_comment]").isEmpty() } ?? false,
            userVote: userVote,
            bodyHTML: try body.html(),
            scoreDetails: try element.select("div.c7").first().map(scoreDetails(in:)) ?? []
        )
    }

    /// `div.c7`: the text before its first element ("Base +N", the trailing comma dropped), then each `span`'s text.
    private static func scoreDetails(in element: Element) throws -> [String] {
        var leading = ""
        for node in element.getChildNodes() {
            guard let text = node as? TextNode else { break }
            leading += text.text()
        }
        while let last = leading.last, last == "," || last.isWhitespace { leading.removeLast() }
        let spans = try element.select("span").compactMap { nonEmpty(try $0.text()) }
        return (nonEmpty(leading).map { [$0] } ?? []) + spans
    }

    // MARK: Thumbnails

    /// The readable cells of the first of the three markups the page uses; empty when it uses none, or none of its
    /// cells can be read.
    private static func readThumbnails(in document: Document) throws -> [GalleryThumbnail] {
        let small = try document.select("#gdt > div.gdtm")
        if !small.isEmpty() { return try small.compactMap(smallThumbnail(in:)) }
        let large = try document.select("#gdt > div.gdtl")
        if !large.isEmpty() { return try large.compactMap(largeThumbnail(in:)) }
        return try document.select("#gdt > a").compactMap(currentThumbnail(in:))
    }

    /// `div.gdtm`: the first div inside holds the sprite's style; the link holds an image whose `alt` is the page.
    private static func smallThumbnail(in cell: Element) throws -> GalleryThumbnail? {
        guard let link = try cell.select("a[href]").first(),
              let pageURL = URL(string: try link.attr("href")),
              let page = try pageIndex(ofImage: cell.select("img").first()),
              let styled = try cell.select("div").array().first(where: { $0 !== cell }),
              let image = sprite(fromStyle: try styled.attr("style")) else { return nil }
        return GalleryThumbnail(pageIndex: page, pageURL: pageURL, image: image)
    }

    /// `div.gdtl`: one image per page; its file name ends in `-<width>-<height>-<ext>`, the original image's size.
    private static func largeThumbnail(in cell: Element) throws -> GalleryThumbnail? {
        guard let link = try cell.select("a[href]").first(),
              let pageURL = URL(string: try link.attr("href")),
              let image = try cell.select("img").first(),
              let page = try pageIndex(ofImage: image),
              let url = try nonEmpty(image.attr("src")).flatMap({ URL(string: $0) }) else { return nil }
        let parts = url.lastPathComponent.split(separator: "-")
        var size: ImageSize?
        if parts.count >= 3, let width = Int(parts[parts.count - 3]), let height = Int(parts[parts.count - 2]) {
            size = ImageSize(width: width, height: height)
        }
        return GalleryThumbnail(pageIndex: page, pageURL: pageURL, image: .single(url: url, originalSize: size))
    }

    /// `#gdt > a`: the div inside (or its first child, when the div also holds a label) has the page in its title
    /// ("Page N: …") and the sprite in its style.
    private static func currentThumbnail(in link: Element) throws -> GalleryThumbnail? {
        guard let pageURL = URL(string: try link.attr("href")), let box = try link.select("div").first() else { return nil }
        let cell = box.children().first() ?? box
        guard let page = try pageNumber(inTitle: cell.attr("title")),
              let image = sprite(fromStyle: try cell.attr("style")) else { return nil }
        return GalleryThumbnail(pageIndex: page, pageURL: pageURL, image: image)
    }

    /// An image's `alt` (the page number, zero-padded), else the "Page N:" of its title.
    private static func pageIndex(ofImage image: Element?) throws -> Int? {
        guard let image else { return nil }
        if let page = Int(try image.attr("alt").trimmingCharacters(in: .whitespaces)), page > 0 { return page }
        return try pageNumber(inTitle: image.attr("title"))
    }

    private static func pageNumber(inTitle title: String) -> Int? {
        title.firstMatch(of: /Page ([0-9]+):/).flatMap { Int($0.1) }.flatMap { $0 > 0 ? $0 : nil }
    }

    /// A sprite cell's style: its `width` and `height`, the sheet in `url(…)`, and the horizontal offset right after
    /// it (`) -<n>px`; 0 when the style gives none).
    private static func sprite(fromStyle style: String) -> ThumbnailImage? {
        guard let url = imageURL(fromStyle: style),
              let width = style.firstMatch(of: /(?:^|[;\s])width:\s*([0-9]+)px/).flatMap({ Int($0.1) }),
              let height = style.firstMatch(of: /(?:^|[;\s])height:\s*([0-9]+)px/).flatMap({ Int($0.1) }) else { return nil }
        let offset = style.firstMatch(of: /\)\s*-?([0-9]+)px/).flatMap { Int($0.1) } ?? 0
        return .sprite(url: url, size: ImageSize(width: width, height: height), offsetX: offset)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        GalleryListParser.nonEmpty(text)
    }
}
