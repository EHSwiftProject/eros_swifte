import EHModels
import Foundation
import GRDB

extension TagTranslationStore {
    /// The longest query `search` accepts, in Unicode scalars; no key or name is longer.
    private static let maxQueryLength = 256

    /// Tags whose key or name contains `text`, most recently used first, following Flutter's
    /// `IsarHelper.searchTags`.
    ///
    /// `text` is trimmed and matched literally: no `ns:` prefix is parsed and FTS5 or `LIKE` syntax has no effect.
    /// Keys and names are searched, introductions are not, and the "rows" namespace is never offered. The match
    /// ignores case (ASCII only on the `LIKE` path). Order is last use time descending, then import order.
    /// - Returns: At most `limit` translations; empty for blank text, a `limit` of 0 or less, or text longer than
    ///   256 Unicode scalars.
    /// - Throws: `TagDatabaseError.damaged` (see `TagTranslationStore`); other database errors.
    public func search(_ text: String, limit: Int) throws -> [TagTranslation] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = query.unicodeScalars.count
        guard length > 0, length <= Self.maxQueryLength, limit > 0 else { return [] }
        // The trigram tokenizer cannot index fewer than three characters, so shorter queries use LIKE.
        let usesIndex = usesFullTextSearch && length >= 3
        return try checkingForDamage { try dbQueue.read { db in
            let rows: [Row]
            if usesIndex {
                // One quoted phrase, with embedded quotes doubled, so that FTS5 query syntax is literal.
                let phrase = "\"" + query.replacing("\"", with: "\"\"") + "\""
                rows = try Row.fetchAll(db, sql: """
                    SELECT tag.namespace, tag.key, tag.name, tag.intro, tag.links
                    FROM tag_fts JOIN tag ON tag.id = tag_fts.rowid
                    WHERE tag_fts MATCH ? AND tag.namespace <> 'rows'
                    ORDER BY tag.lastUseTime DESC, tag.id ASC LIMIT ?
                    """, arguments: [phrase, limit])
            } else {
                // "\" is the ESCAPE character, so it and the two wildcards are escaped.
                let escaped = query.replacing("\\", with: "\\\\").replacing("%", with: "\\%")
                    .replacing("_", with: "\\_")
                rows = try Row.fetchAll(db, sql: """
                    SELECT namespace, key, name, intro, links FROM tag
                    WHERE namespace <> 'rows' AND (key LIKE ?1 ESCAPE '\\' OR name LIKE ?1 ESCAPE '\\')
                    ORDER BY lastUseTime DESC, id ASC LIMIT ?2
                    """, arguments: ["%" + escaped + "%", limit])
            }
            return rows.map(Self.translation(from:))
        } }
    }

    /// Moves `tag` to the front of `search` results, for when the user picks it from the suggestions.
    ///
    /// The use time is the current time in milliseconds, raised above every other use time, so that the tag marked
    /// last always comes first, even within one millisecond or after the clock went back. A tag that is not in the
    /// store is ignored.
    /// - Throws: `TagDatabaseError.damaged` (see `TagTranslationStore`); other database errors.
    public func markUsed(_ tag: TagRef) throws {
        guard let tag = Self.normalized(tag) else { return }
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        try checkingForDamage {
            try dbQueue.write { db in
                guard let id = try Self.rowID(forNormalized: tag, in: db) else { return }
                try db.execute(sql: """
                    UPDATE tag SET lastUseTime = max(?, (SELECT ifnull(max(lastUseTime), 0) FROM tag) + 1) WHERE id = ?
                    """, arguments: [now, id])
            }
        }
    }

    /// `` `ns:key` `` fragments: words of ASCII letters, digits, `_` and `:` separated by whitespace. Dart's `\w` is
    /// ASCII only, so this matches what Flutter's `` `(([\w:]+\s+?)*[\w:]+)` `` does, without nested quantifiers.
    private static let backtickTags = try! NSRegularExpression(
        pattern: #"`([A-Za-z0-9_:]+(?:\s+[A-Za-z0-9_:]+)*)`"#
    )

    /// `intro` with each known `` `tag` `` replaced by `` `name (tag)` `` in the language of the translations,
    /// following Flutter's `TagTransController.getTranslatedIntro`.
    ///
    /// Each fragment between backticks is looked up with `translation(for:)`, so abbreviated namespaces work. It is
    /// replaced when found with a `plainName` that is not empty and differs from the fragment, with a space on both
    /// sides as in Flutter; any other fragment stays as it is.
    public func translatedIntro(_ intro: String) throws -> String {
        let source = intro as NSString
        let matches = Self.backtickTags.matches(in: intro, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return intro }
        var result = ""
        var position = 0
        for match in matches {
            result += source.substring(with: NSRange(location: position, length: match.range.location - position))
            let whole = source.substring(with: match.range)
            let fragment = source.substring(with: match.range(at: 1))
            if let name = try translation(for: TagRef(raw: fragment))?.plainName, !name.isEmpty, name != fragment {
                result += " `\(name) (\(fragment))` "
            } else {
                result += whole
            }
            position = match.range.location + match.range.length
        }
        result += source.substring(from: position)
        return result
    }
}
