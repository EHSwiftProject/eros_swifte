import EHModels
import Foundation
import SwiftSoup

/// Reads the account overview (`home.php`).
public enum HomePageParser {
    /// The Image Limits section: the first `div.homebox` after the `h2` "Image Limits", before the next `h2`.
    ///
    /// The first three numbers in its `p > strong` (thousands separators dropped) are the current count, the limit
    /// and the reset cost. Fewer than three (the Flutter app's rule) means the section only offers to unlock the
    /// limits: the first is that cost, and the count and the limit are 0. `highResolutionLimited` is true when the
    /// section says "high-resolution images can be limited".
    /// - Throws: `ParseError.missing("Image Limits")` without the heading; `.missing("div.homebox")` without the box
    ///   after it; `.missing("p > strong")` without a number in the box; `.malformed("current")` or `("limit")`
    ///   when one of those cannot be read (an unreadable cost is nil); whatever SwiftSoup throws, unchanged.
    public static func imageLimits(in html: String) throws -> ImageLimits {
        let document = try SwiftSoup.parse(html)
        guard let heading = try document.select("h2").first(where: { try $0.text() == "Image Limits" }) else {
            throw ParseError.missing("Image Limits")
        }
        guard let box = try section(after: heading) else { throw ParseError.missing("div.homebox") }
        let numbers = try box.select("p > strong").prefix(3).map { ImagePageParser.number(try $0.text()) }
        if numbers.isEmpty { throw ParseError.missing("p > strong") }
        let isLimited = try box.text().contains("high-resolution images can be limited")
        guard numbers.count == 3 else {
            return ImageLimits(current: 0, limit: 0, resetCost: numbers[0], highResolutionLimited: isLimited)
        }
        guard let current = numbers[0] else { throw ParseError.malformed("current") }
        guard let limit = numbers[1] else { throw ParseError.malformed("limit") }
        return ImageLimits(current: current, limit: limit, resetCost: numbers[2], highResolutionLimited: isLimited)
    }

    /// The first `div.homebox` among the siblings after `heading`, before the next `h2`.
    private static func section(after heading: Element) throws -> Element? {
        var next = try heading.nextElementSibling()
        while let element = next, element.tagName() != "h2" {
            if element.tagName() == "div", element.hasClass("homebox") { return element }
            next = try element.nextElementSibling()
        }
        return nil
    }
}
