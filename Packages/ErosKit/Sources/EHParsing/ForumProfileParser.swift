import EHModels
import Foundation
import SwiftSoup

/// Reads a member's profile page on the forums (`forums.e-hentai.org/index.php?showuser=<id>`).
public enum ForumProfileParser {
    /// Where the forum's relative image paths ("uploads/av-<n>.jpg") are.
    private static let forumBase = URL(string: "https://forums.e-hentai.org/")!

    /// Parses a forum profile page, with the Flutter app's selectors (`user_profile_parser.dart`).
    ///
    /// - The name: the text of `#profilename`, trimmed.
    /// - The avatar: the `src` of the first `img` in the second element after `#profilename`, resolved against
    ///   `https://forums.e-hentai.org/` when relative; nil without one, or when it is not an http(s) address.
    /// - Throws: `ParseError.missing("#profilename")` without the name element; `.malformed("#profilename")` when it
    ///   is empty; whatever SwiftSoup throws, unchanged.
    public static func parse(_ html: String) throws -> ForumProfile {
        let document = try SwiftSoup.parse(html)
        guard let nameElement = try document.select("#profilename").first() else {
            throw ParseError.missing("#profilename")
        }
        guard let name = try GalleryListParser.nonEmpty(nameElement.text()) else {
            throw ParseError.malformed("#profilename")
        }
        let avatarCell = try nameElement.nextElementSibling()?.nextElementSibling()
        let source = try GalleryListParser.nonEmpty(avatarCell?.select("img").first()?.attr("src"))
        return ForumProfile(displayName: name, avatarURL: source.flatMap(avatarURL(from:)))
    }

    private static func avatarURL(from source: String) -> URL? {
        guard let url = URL(string: source, relativeTo: forumBase)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil
        else { return nil }
        return url
    }
}
