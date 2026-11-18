import EHModels
import EHStore

/// Translates a whole search text for display, term by term (Flutter
/// `TagTransController.getTranTagWithNameSpaseAuto`).
@MainActor final class SearchTermTranslator {
    private let translations: TagTranslationStore?

    init(translations: TagTranslationStore?) {
        self.translations = translations
    }

    /// `text` with each term translated, the terms joined by three spaces; nil without a table, or when no term has a
    /// translation.
    ///
    /// Terms are split at whitespace, a term that opens a quote joined (by one space) to the next ones until the quote
    /// closes. A leading "-" (an exclusion) is kept in front of what the term becomes. The rest is read as
    /// `[<prefix>:]["]<name>[$]["]` and looked up as `TagRef(namespace: prefix, name: name)` (the table expands an
    /// abbreviated namespace). With a prefix the term becomes "<namespace>:<translation or name>", the namespace's
    /// Chinese name where `TagNamespaceNames` has one, else its full name (or the prefix as written when
    /// `TagNamespace` does not know it); without one, the translation or the term as written.
    func translation(of text: String) async -> String? {
        guard let translations else { return nil }
        var parts: [String] = []
        var translatedAny = false
        for term in Self.terms(in: text) {
            let exclusion = term.hasPrefix("-") ? "-" : ""
            let body = term.dropFirst(exclusion.count)
            guard let match = body.wholeMatch(of: /(?:([A-Za-z]+):)?"?([^"$]+)\$?"?/) else {
                parts.append(term)
                continue
            }
            let prefix = match.output.1.map(String.init)
            let name = String(match.output.2)
            let found = (try? await translations.translation(for: TagRef(namespace: prefix, name: name)))?.plainName
            let translated = found?.isEmpty == false ? found : nil
            if translated != nil { translatedAny = true }
            if let prefix {
                let fullName = TagNamespace.fullName(for: prefix) ?? prefix
                parts.append("\(exclusion)\(TagNamespaceNames.chinese(fullName) ?? fullName):\(translated ?? name)")
            } else {
                parts.append(exclusion + (translated ?? String(body)))
            }
        }
        return translatedAny ? parts.joined(separator: "   ") : nil
    }

    /// The terms of `text`: its words, a word that leaves a quote open joined with the next ones until it closes (or
    /// the text ends).
    private static func terms(in text: String) -> [String] {
        var terms: [String] = []
        var open: String?
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let term = open.map { "\($0) \(word)" } ?? word
            if term.count(where: { $0 == "\"" }).isMultiple(of: 2) {
                terms.append(term)
                open = nil
            } else {
                open = term
            }
        }
        if let open { terms.append(open) }
        return terms
    }
}
