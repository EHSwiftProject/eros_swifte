import EHModels
import Foundation

/// The text of a search field, as tag suggestions read and change it (Flutter `search_page_controller.dart`), and as
/// the search page cleans, extends and reads it (search Q2).
nonisolated enum SearchText {
    /// The characters that end a word: Flutter splits at `[ ;"]`.
    private static let separators: Set<Character> = [" ", ";", "\""]

    /// The word being typed: what follows the last space, semicolon or quote of `text` ("" when `text` ends with one).
    /// Flutter: `text.split(RegExp(r'[ ;"]')).last`.
    static func currentToken(in text: String) -> String {
        String(text[tokenStart(in: text)...])
    }

    /// What the local tag table is searched for when `token` is typed: `token` without a leading "-" (an exclusion),
    /// then without a leading "<letters>:" and a trailing "$" ("-f:fake$" → "fake"), as the table searches literally.
    static func localQuery(for token: String) -> String {
        var query = Substring(token)
        if query.hasPrefix("-") { query = query.dropFirst() }
        if let colon = query.firstIndex(of: ":"), colon > query.startIndex,
           query[..<colon].allSatisfy({ $0.isASCII && $0.isLetter }) {
            query = query[query.index(after: colon)...]
        }
        if query.hasSuffix("$") { query = query.dropLast() }
        return String(query)
    }

    /// `text` with `suggestion.searchTerm` and a space in place of what is being typed.
    ///
    /// With a quote left open, everything from that quote on is replaced, together with a "<letters>:" right before
    /// it; otherwise `currentToken(in:)`. So `female:"example ta` becomes `f:"example tag$" `, where Flutter,
    /// replacing only the last word, would leave `female:"example f:"example tag$"`. An exclusion stays one in both
    /// cases: the "-" that starts the replaced word is kept (`-fak` → `-a:fakeartist$ `, `-female:"example ta` →
    /// `-f:"example tag$" `), and so is everything before it.
    static func applying(_ suggestion: TagSuggestion, to text: String) -> String {
        var start = openQuote(in: text).map { namespaceStart(before: $0, in: text) } ?? tokenStart(in: text)
        if start < text.endIndex, text[start] == "-" { start = text.index(after: start) }
        return String(text[..<start]) + suggestion.searchTerm + " "
    }

    /// Where `currentToken(in:)` begins: after the last separator, or at the start.
    private static func tokenStart(in text: String) -> String.Index {
        text.lastIndex(where: separators.contains).map(text.index(after:)) ?? text.startIndex
    }

    /// The last quote of `text` when it has an odd number of them; nil when every quote is closed.
    private static func openQuote(in text: String) -> String.Index? {
        let quotes = text.indices.filter { text[$0] == "\"" }
        return quotes.count.isMultiple(of: 2) ? nil : quotes.last
    }

    /// The start of the "<letters>:" that ends right before `quote`, or `quote` itself without one.
    private static func namespaceStart(before quote: String.Index, in text: String) -> String.Index {
        guard quote > text.startIndex else { return quote }
        let colon = text.index(before: quote)
        guard text[colon] == ":" else { return quote }
        var start = colon
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard text[previous].isASCII, text[previous].isLetter else { break }
            start = previous
        }
        return start == colon ? quote : start
    }
}

// MARK: - The search page (search Q2)

nonisolated extension SearchText {
    /// `text` on one line: every line break (`CharacterSet.newlines`: CR, LF, U+2028, U+2029, NEL and the others)
    /// and tab becomes a space, then the whitespace at both ends goes. Everything else,
    /// quotes included (the site's syntax), stays as it is.
    static func normalized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(scalar == "\t" || CharacterSet.newlines.contains(scalar) ? " " : scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a search writes for exactly `tag` (Flutter `navigator_util.dart`, without its `split(':')[1]`, which cuts
    /// a name at its first colon): `<namespace>:"<name>$"`, an uploader `uploader:"<name>"`, a tag without a namespace
    /// `"<name>$"`. Quotes in the name are dropped, as they would end the term.
    static func tagTerm(for tag: TagRef) -> String {
        let name = tag.name.replacing("\"", with: "")
        switch tag.namespace {
        case "uploader"?: return "uploader:\"\(name)\""
        case let namespace?: return "\(namespace):\"\(name)$\""
        case nil: return "\"\(name)$\""
        }
    }

    /// `term` added to `text` (Flutter `appendTextToSearch`): `text` without its trailing whitespace, a space, `term`
    /// and a space; `term` and a space when that leaves nothing.
    static func appending(_ term: String, to text: String) -> String {
        var kept = Substring(text)
        while let last = kept.last, last.isWhitespace { kept.removeLast() }
        return kept.isEmpty ? term + " " : "\(kept) \(term) "
    }

    /// The site page `text` links to: a text without whitespace that `URL(string:)` reads as an http or https URL with
    /// a host, given as that URL to `EHLink(url:)` (entry E1; the text is not encoded again here). nil for anything
    /// else, a link to another site among them.
    static func link(in text: String) -> EHLink? {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return EHLink(url: url)
    }
}
