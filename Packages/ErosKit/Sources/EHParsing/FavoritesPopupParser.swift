import EHModels
import Foundation
import SwiftSoup

/// Reads the add-to-favorites popup (`gallerypopups.php?gid=<gid>&t=<token>&act=addfav`).
public enum FavoritesPopupParser {
    /// Parses a favorites popup.
    ///
    /// - Folders: each `#galpop input[name=favcat]` whose value is a digit 0…9, in page order; the name is the text
    ///   of the last div of its row (the div holding the input's own div) that has any (the site ends each row with
    ///   an empty clearing `div.c`). The checked one is `selectedIndex`.
    /// - `isFavorited`: an `input[value=favdel]` (the "remove from favorites" choice) is offered.
    /// - The note: `textarea[name=favnote]`'s text, line breaks kept, trimmed.
    /// - The slots: "<used> / <total> favorite note slots" in an element after the note field (thousands separators
    ///   allowed); nil when none has it.
    /// - Throws: `ParseError.missing("favcat")` without a folder; `.missing("folderName")` when a folder's row has no
    ///   name; `.missing("favnote")` without the note field (saving the popup sends the note back, so an unknown note
    ///   must not read as ""); whatever SwiftSoup throws, unchanged.
    public static func parse(_ html: String) throws -> FavoritesPopup {
        let document = try SwiftSoup.parse(html)
        var folders: [FavoriteFolder] = []
        var selectedIndex: Int?
        for input in try document.select("#galpop input[name=favcat]") {
            let value = try input.attr("value").trimmingCharacters(in: .whitespaces)
            guard value.count == 1, let index = ImagePageParser.number(value) else { continue }
            folders.append(FavoriteFolder(index: index, name: try folderName(of: input)))
            if selectedIndex == nil, input.hasAttr("checked") { selectedIndex = index }
        }
        if folders.isEmpty { throw ParseError.missing("favcat") }
        guard let noteField = try document.select("#galpop textarea[name=favnote]").first() else {
            throw ParseError.missing("favnote")
        }
        let slots = try noteSlots(after: noteField)
        return FavoritesPopup(
            folders: folders,
            selectedIndex: selectedIndex,
            note: noteField.textNodes().map { $0.getWholeText() }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines),
            noteSlotsUsed: slots.flatMap { ImagePageParser.number($0.used) },
            noteSlotsTotal: slots.flatMap { ImagePageParser.number($0.total) },
            isFavorited: try !document.select("#galpop input[value=favdel]").isEmpty()
        )
    }

    /// "<used> / <total> favorite note slots" in the first element after the note field that has it. The folder
    /// names and the note itself, which the account writes, come before and are not searched.
    private static func noteSlots(after noteField: Element) throws -> (used: String, total: String)? {
        var next = try noteField.nextElementSibling()
        while let element = next {
            if let match = try element.text()
                .firstMatch(of: /([0-9][0-9,]*)\s*\/\s*([0-9][0-9,]*)\s+favorite note slots/.ignoresCase()) {
                return (String(match.1), String(match.2))
            }
            next = try element.nextElementSibling()
        }
        return nil
    }

    /// The text of the last div with any in the row of `input`: the parent of the div that holds the input.
    /// - Throws: `ParseError.missing("folderName")` without one.
    private static func folderName(of input: Element) throws -> String {
        guard let row = input.parent()?.parent() else { throw ParseError.missing("folderName") }
        for div in row.children().reversed() where div.tagName() == "div" {
            if let name = try GalleryListParser.nonEmpty(div.text()) { return name }
        }
        throw ParseError.missing("folderName")
    }
}
