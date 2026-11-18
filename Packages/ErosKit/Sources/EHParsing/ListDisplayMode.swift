import EHModels
import SwiftSoup

extension ListDisplayMode {
    /// Reads the selected display mode from a gallery list page.
    ///
    /// Mirrors the Flutter `isGalleryListDmL`: with a `.searchnav`, the options live in the sibling after
    /// `#ulast`'s parent; otherwise in `#dms > div > select`. Returns the first `selected` option's mode.
    /// - Returns: nil when the page has no display-mode selector (an empty result page, a toplist). What nil means is
    ///   the caller's call: the app reads such a page as Compact (the Flutter behavior; network plan N6, and
    ///   `GalleryListParser` does so), while the capture tool stops on it as an unknown mode.
    /// - Throws: whatever SwiftSoup throws while parsing, unchanged.
    public static func detect(in html: String) throws -> ListDisplayMode? {
        try detect(in: SwiftSoup.parse(html))
    }

    /// `detect(in:)` on a page already parsed, so a parser that needs the document too reads the page once.
    static func detect(in document: Document) throws -> ListDisplayMode? {
        let options: Elements
        if let searchnav = try document.select(".searchnav").first() {
            guard let container = try searchnav.select("#ulast").first()?.parent()?.nextElementSibling() else {
                return nil
            }
            options = try container.select("option")
        } else {
            options = try document.select("#dms > div > select > option")
        }
        for option in options where option.hasAttr("selected") {
            return ListDisplayMode(code: try option.attr("value"))
        }
        return nil
    }
}
