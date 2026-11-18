import EHModels
import Foundation
import SwiftSoup

/// Reads the mytags page (`mytags`, `mytags?tagset=<n>`).
///
/// The fields are the Flutter app's (`mytags_parser.dart`); the tag set chooser is found anywhere in
/// `#tagset_outer`, since the page moved it from that app's `div:nth-child(3)` to the second div.
public enum MyTagsParser {
    /// Parses a mytags page.
    ///
    /// - Tag sets: each option with a `value` of the first `select` in `#tagset_outer`, in page order; the text is
    ///   "<name> (<tag count>)", the one with `selected` is shown. No chooser gives no tag sets.
    /// - Tags: each child `div#usertag_<id>` of `#usertags_outer` but `usertag_0` (the row that adds a new tag). The
    ///   tag is the `title` of its `#tagpreview_<id>`; whether it is watched or hidden, its color and its weight are
    ///   the inputs `#tagwatch_<id>` and `#taghide_<id>` (checked) and `#tagcolor_<id>` and `#tagweight_<id>` (value).
    ///   A row is skipped when its tag cannot be read, when it lacks the watch, hide or color input, or when its color
    ///   is neither empty nor six hex digits: saving a tag (`setusertag`) sends all three back, so an unknown one must
    ///   never read as unchecked or as the tag set's color. A weight that is not a whole number is nil.
    /// - `apiUID` and `apiKey`: the page script's `var apiuid = <n>;` and `var apikey = "<key>";`, read as on the
    ///   gallery page (`PageScript`); nil without them.
    /// - `canDeleteTagSet`: an element whose `onclick` calls `do_tagset_delete()` (the Delete button; the function's
    ///   name elsewhere, as in a script, does not count).
    /// - Throws: `ParseError.missing("usertags_outer")` without the tag list (it is no mytags page);
    ///   `.missing("usertag")` when it has tag rows but none can be read; `.malformed("tagset")` when a tag set's value
    ///   is not a number; whatever SwiftSoup throws, unchanged.
    public static func parse(_ html: String) throws -> MyTagsPage {
        let document = try SwiftSoup.parse(html)
        guard let list = try document.select("#usertags_outer").first() else {
            throw ParseError.missing("usertags_outer")
        }
        var rowCount = 0
        var userTags: [UserTag] = []
        for row in list.children() {
            guard row.tagName() == "div", let id = rowID(of: row) else { continue }
            rowCount += 1
            if let tag = try userTag(id: id, in: row) { userTags.append(tag) }
        }
        if rowCount > 0 && userTags.isEmpty { throw ParseError.missing("usertag") }
        return MyTagsPage(
            tagSets: try tagSets(in: document),
            userTags: userTags,
            apiUID: PageScript.apiUID(in: html),
            apiKey: PageScript.apiKey(in: html),
            canDeleteTagSet: try !document.select("[onclick*=do_tagset_delete]").isEmpty()
        )
    }

    // MARK: Tag sets

    private static func tagSets(in document: Document) throws -> [TagSet] {
        guard let chooser = try document.select("#tagset_outer select").first() else { return [] }
        return try chooser.select("option[value]").map { option in
            guard let id = ImagePageParser.number(try option.attr("value")) else {
                throw ParseError.malformed("tagset")
            }
            let text = try option.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let count = text.firstMatch(of: /\s*\(([0-9][0-9,]*)\)\z/)
            return TagSet(
                id: id,
                name: count.map { String(text[..<$0.range.lowerBound]) } ?? text,
                tagCount: count.flatMap { ImagePageParser.number(String($0.1)) },
                isSelected: option.hasAttr("selected")
            )
        }
    }

    // MARK: Tags

    /// The `<id>` of `usertag_<id>`; nil for another id and for the new-tag row, `usertag_0`.
    private static func rowID(of row: Element) -> Int? {
        let id = row.id()
        guard id.hasPrefix("usertag_"), let number = ImagePageParser.number(String(id.dropFirst("usertag_".count))),
              number > 0 else { return nil }
        return number
    }

    /// The tag of row `id`; nil when its preview has no tag in its title, when the row lacks its watch, hide or color
    /// input, or when its color cannot be read.
    private static func userTag(id: Int, in row: Element) throws -> UserTag? {
        let element = { (prefix: String) throws in try row.select("[id=\(prefix)\(id)]").first() }
        guard let title = try GalleryListParser.nonEmpty(element("tagpreview_")?.attr("title")),
              let watch = try element("tagwatch_"), let hide = try element("taghide_"),
              let colorInput = try element("tagcolor_"), let color = tagColor(try colorInput.attr("value"))
        else { return nil }
        let tag = TagRef(raw: title)
        if tag.name.isEmpty { return nil }
        return UserTag(
            id: id,
            tag: tag,
            isWatched: watch.hasAttr("checked"),
            isHidden: hide.hasAttr("checked"),
            colorHex: color.hex,
            weight: try element("tagweight_").flatMap { Int(try $0.attr("value").trimmingCharacters(in: .whitespaces)) }
        )
    }

    /// What a tag's color input says.
    private enum TagColor {
        /// Empty: the tag takes the tag set's color.
        case tagSet
        /// "#RRGGBB".
        case custom(String)

        var hex: String? {
            if case .custom(let hex) = self { hex } else { nil }
        }
    }

    /// The color of a color input: empty is the tag set's, six hex digits (with or without their "#") a custom one as
    /// "#RRGGBB"; nil (unreadable) for anything else.
    private static func tagColor(_ text: String) -> TagColor? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .tagSet }
        guard let match = text.wholeMatch(of: /#?([0-9A-Fa-f]{6})/) else { return nil }
        return .custom("#" + match.1)
    }
}
