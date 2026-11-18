import Foundation

/// Why a quick search file could not be read.
public enum QuickSearchFileError: Error, Equatable {
    /// The text does not contain the `#FEhViewer` header.
    case missingHeader
}

/// The text file the Flutter app exports its quick searches to: a `#FEhViewer` header line, then one search a line.
public enum QuickSearchFile {
    private static let header = "#FEhViewer"

    /// The file text: the header, then each search after a "\n"; no newline at the end.
    public static func export(_ texts: [String]) -> String {
        texts.reduce(header) { $0 + "\n" + $1 }
    }

    /// The searches in a file, in order and not de-duplicated.
    ///
    /// A leading byte order mark is dropped (the Flutter app would import it as a search). Lines that start with `#`
    /// (checked before trimming) are skipped, the others are trimmed and kept when not empty.
    ///
    /// - Throws: `QuickSearchFileError.missingHeader` when the text has no `#FEhViewer`.
    public static func parse(_ text: String) throws -> [String] {
        var text = text
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        guard text.contains(header) else { throw QuickSearchFileError.missingHeader }
        // `components` splits on the UTF-16 "\n", also inside a "\r\n", which Swift treats as one Character.
        return text.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// "QSearch_yyyyMMdd_HHmmss.txt" in local time.
    public static func fileName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "QSearch_\(formatter.string(from: date)).txt"
    }
}
