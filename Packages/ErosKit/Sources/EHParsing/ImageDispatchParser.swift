import EHModels
import Foundation

/// Reads `imagedispatch` answers of `api.php`: a page of the multi-page viewer.
public enum ImageDispatchParser {
    /// Parses an `imagedispatch` answer. The answer is read as the method's JSON whatever its `Content-Type` (the
    /// site sends `text/html`).
    ///
    /// - The image: `i`; the 509 placeholder sets `isBandwidthExceeded`.
    /// - The size: `xres` and `yres`, else the dimensions of `d` ("<width> x <height> :: <size>"), whose last part is
    ///   the file size.
    /// - The gallery and the page number: `lo`, `s/<key>/<gid>-<page>` (with a leading slash, or a whole address,
    ///   too). The Flutter parser read `lo` from `yres`, so every page came out as page 1; that is not carried over.
    /// - The original: `lf`, `fullimg/…`.
    /// - The reload token: `s`, the next request's `nl`.
    ///
    /// Numbers may be JSON numbers or strings of digits. Relative addresses are resolved against `site.baseURL`.
    /// The answer has no gallery token, file name, page count, showkey or image key: they stay nil.
    /// - Throws: `APIError.notJSON` when the answer is not a JSON object; `APIError.server(message)` for
    ///   `{"error": message}`; `ParseError.missing("imageURL")` without `i` (`.malformed` when it is not an address);
    ///   `ParseError.missing("pageIndex")` without `lo` (`.malformed` when it is not of that shape).
    public static func parse(_ json: Data, site: EHSite) throws -> ImagePageInfo {
        let answer = try ShowPageParser.object(from: json)
        guard let source = ShowPageParser.text(answer["i"]) else { throw ParseError.missing("imageURL") }
        guard let imageURL = URL(string: source, relativeTo: site.baseURL)?.absoluteURL else {
            throw ParseError.malformed("imageURL")
        }
        let page = try self.page(answer["lo"], site: site)
        let sizeLine = ShowPageParser.text(answer["d"])?
            .wholeMatch(of: /([0-9]+)\s+x\s+([0-9]+)\s+::\s+(.+)/)
        let lineSize = sizeLine.flatMap { match in
            Int(match.1).flatMap { width in Int(match.2).map { ImageSize(width: width, height: $0) } }
        }
        let size = ShowPageParser.integer(answer["xres"]).flatMap { width in
            ShowPageParser.integer(answer["yres"]).map { ImageSize(width: width, height: $0) }
        }
        return ImagePageInfo(
            gid: page.gid,
            token: nil,
            pageIndex: page.index,
            pageCount: nil,
            imageURL: imageURL,
            imageSize: size ?? lineSize,
            fileName: nil,
            fileSizeText: sizeLine.flatMap { GalleryListParser.nonEmpty(String($0.3)) },
            originalImageURL: ShowPageParser.text(answer["lf"]).flatMap {
                URL(string: $0, relativeTo: site.baseURL)?.absoluteURL
            },
            reloadToken: ShowPageParser.text(answer["s"]),
            showKey: nil,
            imageKey: nil,
            isBandwidthExceeded: ImagePageParser.isBandwidthPlaceholder(imageURL)
        )
    }

    /// The gallery and the page number of `lo`.
    /// - Throws: `ParseError.missing("pageIndex")` without it; `.malformed("pageIndex")` when its path is not
    ///   `/s/<key>/<gid>-<page>`.
    private static func page(_ value: Any?, site: EHSite) throws -> (gid: Int, index: Int) {
        guard let lo = ShowPageParser.text(value) else { throw ParseError.missing("pageIndex") }
        guard let path = URL(string: lo, relativeTo: site.baseURL)?.absoluteURL.path(),
              let match = path.wholeMatch(of: /\/s\/([0-9a-z]+)\/([0-9]+)-([0-9]+)\/?/),
              let gid = Int(match.2), let index = Int(match.3) else { throw ParseError.malformed("pageIndex") }
        return (gid, index)
    }
}
