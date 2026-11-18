import Foundation

/// The one table of tag namespace abbreviations and full names, shared by tag translation, search and browsing.
///
/// Abbreviations follow Flutter's `EHConst.prefixToNameSpaceMap`; the full names are the 14 keys of its
/// `EHConst.translateTagType`. Input is trimmed and lowercased; results are always the lowercase canonical names.
public enum TagNamespace {
    /// Abbreviation → full name, as the site writes them in searches ("f:fake tag").
    private static let fullNamesByAbbreviation: [String: String] = [
        "a": "artist", "c": "character", "f": "female", "g": "group", "l": "language", "m": "male",
        "p": "parody", "r": "reclass", "o": "other", "x": "mixed", "cos": "cosplayer", "misc": "misc",
    ]

    /// Full name → abbreviation; "uploader" and "temp" have none.
    private static let abbreviationsByFullName: [String: String] = Dictionary(
        uniqueKeysWithValues: fullNamesByAbbreviation.map { ($0.value, $0.key) }
    )

    /// Every namespace the site uses for tags.
    private static let fullNames: Set<String> = [
        "artist", "female", "male", "parody", "character", "group", "language",
        "reclass", "misc", "uploader", "other", "mixed", "cosplayer", "temp",
    ]

    /// The full namespace name for an abbreviation ("f" → "female"); a full name comes back as is.
    ///
    /// Unlike Flutter, which only expands one-letter abbreviations, "cos" is expanded too.
    /// - Returns: The lowercase full name, or nil for anything else (an empty string, "rows", an unknown name).
    public static func fullName(for nameOrAbbreviation: String) -> String? {
        let name = normalized(nameOrAbbreviation)
        if let fullName = fullNamesByAbbreviation[name] {
            return fullName
        }
        return fullNames.contains(name) ? name : nil
    }

    /// The abbreviation of a full namespace name ("female" → "f", "misc" → "misc").
    ///
    /// Flutter's `shortName` falls back to the input; this returns nil instead, and callers fall back to the full name.
    /// - Returns: The abbreviation, or nil for "uploader", "temp" and names that are not full namespace names.
    public static func abbreviation(for fullName: String) -> String? {
        abbreviationsByFullName[normalized(fullName)]
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
