import EHModels
import Foundation
import SwiftSoup

/// Reads the torrent popup (`gallerytorrents.php?gid=<gid>&t=<token>`).
public enum TorrentListParser {
    /// Parses a torrent popup.
    ///
    /// Each `#torrentinfo form` with an `a[href$=".torrent"]` is a torrent, in page order; the others (the upload
    /// form) are not. The link gives the name (its text), `downloadURL` (its href, not the `document.location` of its
    /// onclick) and the info hash (the 40 hexadecimal digits in the href). The figures are read by their labels: a
    /// table cell whose first `span` reads "Posted:", "Size:", "Seeds:", "Peers:", "Downloads:" or "Uploader:"
    /// holds the value after it (thousands separators allowed in the counts); a label the form lacks leaves the field
    /// nil.
    /// - Throws: `ParseError.missing("torrentinfo")` without `#torrentinfo`; for a torrent link, `.missing("name")`
    ///   without text, `.malformed("downloadURL")` when the href is not an absolute http(s) address and
    ///   `.malformed("infoHash")` without a hash; whatever SwiftSoup throws, unchanged.
    public static func parse(_ html: String) throws -> [TorrentInfo] {
        let document = try SwiftSoup.parse(html)
        guard let info = try document.select("#torrentinfo").first() else { throw ParseError.missing("torrentinfo") }
        var torrents: [TorrentInfo] = []
        for form in try info.select("form") {
            guard let link = try form.select("a[href$=.torrent]").first() else { continue }
            torrents.append(try torrent(link: link, values: labeledValues(in: form)))
        }
        return torrents
    }

    private static func torrent(link: Element, values: [String: String]) throws -> TorrentInfo {
        guard let name = try GalleryListParser.nonEmpty(link.text()) else { throw ParseError.missing("name") }
        let href = try link.attr("href")
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host()?.isEmpty == false else { throw ParseError.malformed("downloadURL") }
        guard let hash = href.firstMatch(of: /(?:^|[^0-9a-f])([0-9a-f]{40})(?![0-9a-f])/).map({ String($0.1) }) else {
            throw ParseError.malformed("infoHash")
        }
        return TorrentInfo(
            name: name,
            infoHash: hash,
            downloadURL: url,
            postedText: values["Posted:"],
            sizeText: values["Size:"],
            seeds: values["Seeds:"].flatMap(ImagePageParser.number),
            peers: values["Peers:"].flatMap(ImagePageParser.number),
            downloads: values["Downloads:"].flatMap(ImagePageParser.number),
            uploader: values["Uploader:"]
        )
    }

    /// The form's labeled cells: a `td` whose first `span` ends with ":" maps that label to the cell's text after
    /// it; the first cell of a label wins, and a cell with nothing after its label is left out.
    private static func labeledValues(in form: Element) throws -> [String: String] {
        var values: [String: String] = [:]
        for cell in try form.select("td") {
            guard let label = try GalleryListParser.nonEmpty(cell.select("span").first()?.text()),
                  label.hasSuffix(":"), values[label] == nil else { continue }
            let text = try cell.text()
            guard let range = text.range(of: label) else { continue }
            values[label] = GalleryListParser.nonEmpty(String(text[range.upperBound...]))
        }
        return values
    }
}
