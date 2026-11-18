import EHModels
import Foundation

/// What an image search found: the site's result address (the `Location` of its answer to the upload) and the first
/// page there, read in the Compact view (`EHService.imageLookup(image:format:options:site:)`).
public struct ImageLookupResult: Sendable, Equatable {
    /// The result list's address on the site, as the site gave it.
    public let resultURL: URL
    /// The first page of the results.
    public let page: GalleryListPage

    public init(resultURL: URL, page: GalleryListPage) {
        self.resultURL = resultURL
        self.page = page
    }

    /// The address of the results at `position`: `resultURL` without its `next` and `prev` for `.first`, with
    /// `next=<cursor>` or `prev=<cursor>` in their place for `.next` and `.previous`; nil for any other position (the
    /// results are paged by cursor only).
    public func url(for position: ListPosition) -> URL? {
        let cursor: (name: String, value: String)?
        switch position {
        case .first: cursor = nil
        case .next(let value): cursor = ("next", value)
        case .previous(let value): cursor = ("prev", value)
        case .page, .jump, .seek, .offset: return nil
        }
        guard var components = URLComponents(url: resultURL, resolvingAgainstBaseURL: true) else { return nil }
        var pairs = (components.percentEncodedQuery ?? "").split(separator: "&").map(String.init).filter { pair in
            let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let decoded = name.removingPercentEncoding ?? String(name)
            return decoded != "next" && decoded != "prev"
        }
        if let cursor { pairs.append("\(cursor.name)=\(URLEncoding.component(cursor.value))") }
        components.percentEncodedQuery = pairs.isEmpty ? nil : pairs.joined(separator: "&")
        return components.url
    }
}

/// Why an image search's upload led to no result page. None of these sends a second request.
public enum ImageLookupError: Error, Equatable {
    /// The site answered the upload with this status, not a redirect.
    case noRedirect(status: Int)
    /// The redirect has no `Location`, or one that is no URL.
    case missingLocation
    /// The `Location` is not an https address on the site the upload went to, on its default port, without a user,
    /// password or fragment.
    case unexpectedLocation
}
