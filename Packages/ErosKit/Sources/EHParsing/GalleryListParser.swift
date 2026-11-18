import EHModels
import Foundation
import SwiftSoup

/// Why a gallery list page was not read.
public enum ListParseError: Error, Equatable {
    /// The page is in a display mode other than Compact, the only one `GalleryListParser` reads; carries the mode.
    case notCompact(ListDisplayMode)
}

/// Reads gallery list pages in the Compact display mode (`table.itg`): the front page and searches, popular,
/// toplists, image lookup results, favorites.php and the watched list.
public enum GalleryListParser {
    /// Parses a list page.
    ///
    /// A page without a display-mode selector (empty results, toplists) is read as Compact, as the Flutter app did.
    /// A row is a `table.itg` `tr` with a `td.gl1c.glcat`; one without a `/g/<gid>/<token>/` link or a title in its
    /// `td.gl3c` is skipped and counted in `skippedRowCount`. Every other field is optional and left nil (or 0, false,
    /// empty) when the row does not show it. A page without rows is an empty result only when it links no gallery
    /// either (the site's empty result pages link none), is not the site's "log on" notice, and shows the site's
    /// "No hits found" notice in `div.ido`.
    /// - Throws: `ListParseError.notCompact` for another display mode; `ParseError.loginRequired` for a page without
    ///   rows whose text says it "requires you to log on" (any case); `ParseError.missing("gallery rows")` when the
    ///   table has rows but none can be read, or when no row is found but the page links a gallery (either way the
    ///   markup may have changed); `ParseError.missing("list page")` for a page without rows that is not the site's
    ///   no-hits page (plain text, undecodable bytes, a truncated page); whatever SwiftSoup throws, unchanged.
    public static func parse(_ html: String) throws -> GalleryListPage {
        let document = try SwiftSoup.parse(html)
        let displayMode = try ListDisplayMode.detect(in: document)
        if let displayMode, !displayMode.isCompact { throw ListParseError.notCompact(displayMode) }

        var items: [GallerySummary] = []
        var rowCount = 0
        for row in try document.select("table.itg tr") where cell(of: row, classes: ["gl1c", "glcat"]) != nil {
            rowCount += 1
            if let item = try summary(of: row) { items.append(item) }
        }
        if rowCount == 0 {
            if try requiresLogin(document) { throw ParseError.loginRequired }
            // Rows the selectors no longer find (renamed classes, another layout): the galleries are still linked.
            if try linksAGallery(document) { throw ParseError.missing("gallery rows") }
            // Plain text, bytes decoded as text or a cut-off page have no rows either: only the site's own notice
            // makes this an empty result.
            if try !showsNoHits(document) { throw ParseError.missing("list page") }
        }
        if rowCount > 0 && items.isEmpty { throw ParseError.missing("gallery rows") }

        let pager = try numberedPages(in: document)
        return GalleryListPage(
            items: items,
            skippedRowCount: rowCount - items.count,
            displayMode: displayMode,
            previousCursor: try cursor(in: document, linkID: "uprev", query: "prev"),
            nextCursor: try cursor(in: document, linkID: "unext", query: "next"),
            pageIndex: pager.index,
            pageCount: pager.count,
            resultSummary: try nonEmpty(document.select(".searchtext p").first()?.text()),
            filteredCount: try filteredCount(in: document),
            similarityScanDisabled: html.contains("Similarity Scan was disabled"),
            favoriteFolders: try favoriteFolders(in: document),
            favoritesOrder: try favoritesOrder(in: document)
        )
    }

    // MARK: Rows

    private static func summary(of row: Element) throws -> GallerySummary? {
        guard let id = try galleryID(in: row),
              let title = try nonEmpty(row.select("td.gl3c .glink").first()?.text()) else { return nil }
        let posted = try row.select("div[id^=posted_]").first()
        let stars = posted?.siblingElements().first { $0.hasClass("ir") }
        let rating = try stars.flatMap { try rating(fromStyle: $0.attr("style")) } ?? 0
        let isRatedByUser = isUserRating(stars)
        let postedStyle = try posted?.attr("style") ?? ""
        let uploaderCell = cell(of: row, classes: ["gl4c"])?.children()
        let uploader = uploaderCell?.first()
        let cover = try row.select(".glthumb img").first()
        return GallerySummary(
            id: id,
            title: title,
            category: try row.select("td.gl1c.glcat > div").first().flatMap { GalleryCategory(siteLabel: try $0.text()) },
            coverURL: try cover.flatMap(coverURL(of:)),
            coverSize: try cover.flatMap { imageSize(fromStyle: try $0.attr("style")) },
            tags: try tags(in: row),
            postedAt: try posted.flatMap { EHDate.listTimestamp(try $0.text()) },
            rating: rating,
            isRatedByUser: isRatedByUser,
            favoriteSlot: favoriteSlot(fromStyle: postedStyle),
            favoriteName: try nonEmpty(posted?.attr("title")),
            favoriteNote: try row.select("div.glfnote").first().flatMap { try favoriteNote(from: $0.text()) },
            uploader: try nonEmpty(uploader?.text()),
            isUploaderDimmed: try uploader?.attr("style").localizedCaseInsensitiveContains("opacity") ?? false,
            pageCount: try pageCount(uploaderCell: uploaderCell, row: row),
            isExpunged: posted.map { !$0.children().isEmpty() } ?? false
        )
    }

    /// The row's direct `td` child that has every one of `classes`.
    private static func cell(of row: Element, classes: [String]) -> Element? {
        row.children().first { cell in cell.tagName() == "td" && classes.allSatisfy { cell.hasClass($0) } }
    }

    /// The first `/g/<gid>/<token>/` link in the row's title cell.
    private static func galleryID(in row: Element) throws -> GalleryID? {
        for link in try row.select("td.gl3c a[href]") {
            if let id = galleryID(fromHref: try link.attr("href")) { return id }
        }
        return nil
    }

    /// The gallery a `/g/<gid>/<token>/` href names (gid above 0); nil for any other href.
    private static func galleryID(fromHref href: String) -> GalleryID? {
        guard let match = href.firstMatch(of: /\/g\/([0-9]+)\/([0-9a-f]{10})\//), let gid = Int(match.1), gid > 0 else {
            return nil
        }
        return GalleryID(gid: gid, token: String(match.2))
    }

    /// Whether any link of the page names a gallery (`galleryID(fromHref:)`).
    private static func linksAGallery(_ document: Document) throws -> Bool {
        try document.select("a[href]").contains { galleryID(fromHref: try $0.attr("href")) != nil }
    }

    /// Whether the page's text says it "requires you to log on" (any case): the site's notice to a visitor without a
    /// session, in place of favorites, the watched list and other account pages. There is no real sample yet; the
    /// wording is that of `constructed/eh/list-login-required.html`.
    private static func requiresLogin(_ document: Document) throws -> Bool {
        try document.body()?.text().range(of: "requires you to log on", options: .caseInsensitive) != nil
    }

    /// Whether the index (`div.ido`) carries the site's "No hits found" notice (any case), the mark of an empty result.
    /// Checked against the real empty search and image lookup pages; an empty favorites folder is not yet checked
    /// against a real page (entry task E4), so it may need a second marker.
    private static func showsNoHits(_ document: Document) throws -> Bool {
        try document.select("div.ido").contains { try $0.text().range(of: "No hits found", options: .caseInsensitive) != nil }
    }

    /// `data-src` (thumbnails loaded lazily), else `src`.
    private static func coverURL(of image: Element) throws -> URL? {
        let source = try nonEmpty(image.attr("data-src")) ?? nonEmpty(image.attr("src"))
        return source.flatMap { URL(string: $0) }
    }

    private static func imageSize(fromStyle style: String) -> ImageSize? {
        guard let match = style.firstMatch(of: /height:\s*([0-9]+)px;\s*width:\s*([0-9]+)px/),
              let height = Int(match.1), let width = Int(match.2) else { return nil }
        return ImageSize(width: width, height: height)
    }

    /// `div.gt[title]` and `div.gtl[title]`, in page order.
    private static func tags(in row: Element) throws -> [ListTag] {
        try row.select("div.gt[title], div.gtl[title]").map { element in
            ListTag(tag: TagRef(raw: try element.attr("title")), colors: tagColors(fromStyle: try element.attr("style")))
        }
    }

    /// The `#rrggbb` values of a tag's style in order: the first is the text color, the second the border, the last
    /// (of three or more) the background. nil without any.
    private static func tagColors(fromStyle style: String) -> TagColors? {
        let colors = style.matches(of: /#([0-9A-Fa-f]{6})(?![0-9A-Fa-f])/).map { "#" + $0.1.lowercased() }
        guard let text = colors.first else { return nil }
        return TagColors(
            text: text,
            border: colors.count >= 2 ? colors[1] : nil,
            background: colors.count >= 3 ? colors.last : nil
        )
    }

    /// The Flutter formula on the star sprite's offset: `(80 - |x|) / 16`, half a star less on the lower row
    /// (`|y| == 21`), clamped to 0…5. Shared with `GalleryDetailParser` (`#rating_image`).
    static func rating(fromStyle style: String) -> Double? {
        guard let match = style.firstMatch(of: /background-position:\s*(-?[0-9]+)px\s+(-?[0-9]+)px/),
              let x = Int(match.1).map(abs), let y = Int(match.2).map(abs) else { return nil }
        let rating = Double(80 - x) / 16 - (y == 21 ? 0.5 : 0)
        return min(max(rating, 0), 5)
    }

    /// Whether the stars show the account's own rating: one of the colored classes `irr`, `irg`, `irb`, `iry`.
    /// Shared with `GalleryDetailParser` (`#rating_image`).
    static func isUserRating(_ stars: Element?) -> Bool {
        ["irr", "irg", "irb", "iry"].contains { stars?.hasClass($0) == true }
    }

    /// The favorites category of a posted date's `border-color`, as the Flutter `EHConst.favCat`.
    private static func favoriteSlot(fromStyle style: String) -> Int? {
        guard let match = style.firstMatch(of: /border-color:\s*(#[0-9A-Fa-f]{3})(?![0-9A-Fa-f])/) else { return nil }
        return favoriteColors[match.1.lowercased()]
    }

    private static let favoriteColors: [String: Int] = [
        "#000": 0, "#f00": 1, "#fa0": 2, "#dd0": 3, "#080": 4, "#9f4": 5, "#4bf": 6, "#00f": 7, "#508": 8, "#e8e": 9,
    ]

    private static func favoriteNote(from text: String) -> String? {
        guard let match = text.firstMatch(of: /Note:\s(.+)/) else { return nil }
        return nonEmpty(String(match.1))
    }

    /// The uploader column's second div ("N pages"); favorites.php has no such column, so there the hover
    /// thumbnail's line of the same shape.
    private static func pageCount(uploaderCell: Elements?, row: Element) throws -> Int? {
        if let cells = uploaderCell {
            return try cells.array().dropFirst().first.flatMap { pages(in: try $0.text()) }
        }
        for line in try row.select(".glthumb div") {
            if let count = pages(in: line.ownText()), line.ownText().wholeMatch(of: /\s*[0-9]+ pages?\s*/) != nil {
                return count
            }
        }
        return nil
    }

    private static func pages(in text: String) -> Int? {
        text.firstMatch(of: /([0-9]+) pages?/).flatMap { Int($0.1) }
    }

    // MARK: Page

    /// The value of `query` in the href of the `a` with id `linkID` (SwiftSoup has already decoded `&amp;`); nil
    /// when the element is a `span` (no page that way) or missing.
    private static func cursor(in document: Document, linkID: String, query: String) throws -> String? {
        guard let link = try document.select("#\(linkID)").first(), link.tagName() == "a" else { return nil }
        let href = try link.attr("href")
        guard let questionMark = href.firstIndex(of: "?") else { return nil }
        let queryString = href[href.index(after: questionMark)...].prefix { $0 != "#" }
        for item in queryString.split(separator: "&") {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == query else { continue }
            let value = String(parts[1])
            return nonEmpty(value.removingPercentEncoding ?? value)
        }
        return nil
    }

    /// `table.ptt` (toplists; `selector` picks another): the current page's number (`td.ptds`) less one, and the
    /// number in the second-to-last cell (the last is the "next" arrow). Shared with `GalleryDetailParser` (the
    /// thumbnail pages, `.gtb table.ptt`).
    static func numberedPages(in document: Document, selector: String = "table.ptt") throws -> (index: Int?, count: Int?) {
        guard let table = try document.select(selector).first() else { return (nil, nil) }
        let cells = try table.select("td").array()
        func number(_ cell: Element?) throws -> Int? {
            try cell.flatMap { Int(try $0.text().replacingOccurrences(of: ",", with: "")) }
        }
        let current = try number(cells.first { $0.hasClass("ptds") })
        let count = try cells.count > 2 ? number(cells[cells.count - 2]) : nil
        return (current.map { $0 - 1 }, count)
    }

    /// "Filtered N galleries" in the text above the results.
    private static func filteredCount(in document: Document) throws -> Int? {
        for element in try document.select(".searchtext, p.ip") {
            if let match = try element.text().firstMatch(of: /Filtered ([0-9]+) galler(?:y|ies)/) {
                return Int(match.1)
            }
        }
        return nil
    }

    /// favorites.php's category bar (`body > div.ido > div.nosel > div`): each cell holds the count, the icon and the
    /// name in its first three divs; cells without them (the "show all" cell, a clearing div) are not categories.
    private static func favoriteFolders(in document: Document) throws -> [FavoriteFolderSummary] {
        var folders: [FavoriteFolderSummary] = []
        var index = 0
        for cell in try document.select("body > div.ido > div.nosel > div") where index < 10 {
            let parts = cell.children().array()
            guard parts.count >= 3 else { continue }
            defer { index += 1 }
            let digits = try parts[0].text().filter { $0.isASCII && $0.isNumber }
            guard let count = Int(digits) else { continue }
            folders.append(FavoriteFolderSummary(index: index, name: try parts[2].text(), count: count))
        }
        return folders
    }

    /// The order control in the first part of favorites.php's `.searchnav` (other lists leave that part empty): its
    /// selected option, or the first one when none is marked, names `Favorited` or not.
    private static func favoritesOrder(in document: Document) throws -> FavoritesOrder? {
        guard let control = try document.select(".searchnav").first()?.children().first()?.select("select").first()
        else { return nil }
        let options = try control.select("option")
        guard let option = options.first(where: { $0.hasAttr("selected") }) ?? options.first() else { return nil }
        return try option.text().contains("Favorited") ? .favoritedTime : .postedTime
    }

    /// `text` trimmed, or nil when nothing is left. Shared with `GalleryDetailParser`.
    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
