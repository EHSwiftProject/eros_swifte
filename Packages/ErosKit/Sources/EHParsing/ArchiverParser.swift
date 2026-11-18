import EHModels
import Foundation
import SwiftSoup

/// Reads the archiver popup (`archiver.php?gid=<gid>&token=<token>`).
///
/// Elements are found by their form fields and label text, not by position (the Flutter app used
/// `#db > p:nth-child(4)` and the indices of `#db > div`).
public enum ArchiverParser {
    /// Parses an archiver popup.
    ///
    /// - Downloads: each `form` with an `input[name=dltype]`, in page order; the cost and the size are the `strong`s
    ///   of the form's siblings labeled "Cost" ("Download Cost:") and "Size" ("Estimated Size:").
    /// - Funds: the two amounts after "Current Funds" ("<n> GP", "<n> Credits", thousands separators dropped), in
    ///   the element whose own text starts with the label or, when that holds the label only, the next one; nil
    ///   without the label (exhentai.org), and nil when the label is there but its amounts cannot be read (the
    ///   downloads and H@H options are still read: the funds are only shown).
    /// - H@H: each link whose `onclick` calls `do_hathdl('…')`: its argument is `xres`, its text the resolution; the
    ///   other two parts of its table cell are the size and the cost. A size of "N/A" (the site cannot make it), a
    ///   cell without a link and a cell without both parts are skipped.
    /// - Throws: `ParseError.missing("downloads")` without a `dltype` form; `.malformed("dltype")` when its value is
    ///   empty; `.missing("costText")` or `("sizeText")` when a form has no sibling with that label, `.malformed(…)`
    ///   when that sibling's `strong` is absent or empty; whatever SwiftSoup throws, unchanged.
    public static func parse(_ html: String) throws -> ArchiveOptions {
        let document = try SwiftSoup.parse(html)
        let forms = try document.select("form:has(input[name=dltype])")
        if forms.isEmpty() { throw ParseError.missing("downloads") }
        return ArchiveOptions(
            funds: try funds(in: document),
            downloads: try forms.map(download(of:)),
            hathOptions: try document.select("[onclick*=do_hathdl]").compactMap(hathOption(of:))
        )
    }

    // MARK: Downloads

    private static func download(of form: Element) throws -> ArchiveDownload {
        guard let type = try GalleryListParser.nonEmpty(form.select("input[name=dltype]").first()?.attr("value")) else {
            throw ParseError.malformed("dltype")
        }
        return ArchiveDownload(
            type: type,
            costText: try strongText(near: form, label: "Cost", field: "costText"),
            sizeText: try strongText(near: form, label: "Size", field: "sizeText")
        )
    }

    /// The `strong` of the first sibling of `form` whose text holds `label`.
    /// - Throws: `ParseError.missing(field)` without such a sibling; `.malformed(field)` when it has no `strong`, or
    ///   an empty one.
    private static func strongText(near form: Element, label: String, field: String) throws -> String {
        let siblings = form.siblingElements()
        guard let labeled = try siblings.first(where: { try $0.text().contains(label) }) else {
            throw ParseError.missing(field)
        }
        guard let text = try GalleryListParser.nonEmpty(labeled.select("strong").first()?.text()) else {
            throw ParseError.malformed(field)
        }
        return text
    }

    // MARK: Funds

    /// The amounts of the first element whose own text starts with "Current Funds" and that has them (itself, or
    /// itself and its next sibling), titles left out; nil without such an element, or when none has both amounts.
    private static func funds(in document: Document) throws -> ArchiveFunds? {
        let labels = try document.select(":containsOwn(Current Funds)").filter {
            !titleTags.contains($0.tagName())
                && $0.ownText().trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Current Funds")
        }
        for label in labels {
            var amounts = fundsAmounts(in: try label.text())
            if amounts == nil, let next = try label.nextElementSibling() {
                amounts = fundsAmounts(in: try label.text() + " " + next.text())
            }
            if let amounts, let gp = ImagePageParser.number(amounts.gp),
               let credits = ImagePageParser.number(amounts.credits) {
                return ArchiveFunds(gp: gp, credits: credits)
            }
        }
        return nil
    }

    /// The page title and the gallery title (`#db > h1`) are the uploader's words, never the label.
    private static let titleTags: Set<String> = ["title", "h1", "h2", "h3", "h4", "h5", "h6"]

    /// "<n> GP", then "<n> Credits" further on (the site puts a link and spaces between them).
    private static func fundsAmounts(in text: String) -> (gp: String, credits: String)? {
        guard let match = text.firstMatch(of: /([0-9][0-9,]*)\s*GP\b.*?([0-9][0-9,]*)\s*Credits/) else { return nil }
        return (String(match.1), String(match.2))
    }

    // MARK: H@H

    /// The option of a `do_hathdl('…')` link; nil when its cell does not offer one.
    private static func hathOption(of link: Element) throws -> HathDownloadOption? {
        guard let match = try link.attr("onclick").firstMatch(of: /do_hathdl\('([0-9A-Za-z_]+)'\)/),
              let place = enclosingCell(of: link) else { return nil }
        let xres = String(match.1)
        let others = place.cell.children().filter { $0 !== place.part }
        guard others.count >= 2,
              let size = try GalleryListParser.nonEmpty(others[0].text()),
              let cost = try GalleryListParser.nonEmpty(others[1].text()),
              size.uppercased() != "N/A" else { return nil }
        return HathDownloadOption(
            resolution: try GalleryListParser.nonEmpty(link.text()) ?? xres,
            xres: xres,
            sizeText: size,
            costText: cost
        )
    }

    /// The table cell around `link`, and its child that holds the link (the link itself when it is a child).
    private static func enclosingCell(of link: Element) -> (cell: Element, part: Element)? {
        var part = link
        while let parent = part.parent() {
            if parent.tagName() == "td" { return (parent, part) }
            part = parent
        }
        return nil
    }
}
