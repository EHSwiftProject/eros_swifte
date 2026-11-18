import CoreFoundation
import EHModels
import Foundation
import SwiftSoup

/// Reads the JSON answers of `api.php` (gallery data, tag suggestions and the write methods).
///
/// Every method reads the answer as a JSON object whatever its `Content-Type` (the site sends `text/html`).
/// - Throws (every method): `APIError.notJSON` when the answer is not a JSON object (also JSON of another kind);
///   `APIError.server(message)` for `{"error": message}`.
public enum APIResponseParser {
    /// The galleries of a `gdata` answer, in the answer's order.
    ///
    /// - Entries with an `error` (an unknown gid or token) are dropped.
    /// - An entry that is not an object, or lacks a readable `gid`, `token` or `title`, is skipped on its own; the
    ///   others are still returned. The result may therefore be shorter than the request: callers must match
    ///   entries to galleries by `GalleryID`, never by index.
    /// - The rest of an entry degrades: an unreadable optional field is nil (`isExpunged` false, `tags` empty).
    ///   Numbers may be JSON numbers or strings of digits; `posted` is Unix seconds; `title` and `title_jpn` are
    ///   HTML-unescaped once.
    /// - Answers whose entries all have an `error` give `[]`.
    /// - Throws: `ParseError.missing("gmetadata")` without the list (`.malformed` when it is not an array); when
    ///   the list has entries without an `error` but none can be read, the first such entry's error:
    ///   `ParseError.missing(name)` or `.malformed(name)` for its field (`.malformed("gmetadata")` for a non-object).
    public static func galleryMetadata(_ json: Data) throws -> [GalleryMetadata] {
        let answer = try ShowPageParser.object(from: json)
        guard let list = answer["gmetadata"], !(list is NSNull) else { throw ParseError.missing("gmetadata") }
        guard let entries = list as? [Any] else { throw ParseError.malformed("gmetadata") }
        var result: [GalleryMetadata] = []
        var firstFailure: (any Error)?
        for entry in entries {
            guard let entry = entry as? [String: Any] else {
                firstFailure = firstFailure ?? ParseError.malformed("gmetadata")
                continue
            }
            if let error = entry["error"], !(error is NSNull) { continue }
            do {
                result.append(try metadata(from: entry))
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if result.isEmpty, let firstFailure { throw firstFailure }
        return result
    }

    /// The suggestions of a `tagsuggest` answer: `tags`' values `{"ns": …, "tn": …}`, in the order they appear in
    /// the text (the keys are ids, and a JSON object has no order of its own).
    ///
    /// When the answer has `tags` more than once, the last one decides, alone: Dart's `jsonDecode` and JavaScript's
    /// `JSON.parse` let a later member override an earlier one, so Flutter reads the last (`JSONSerialization` would
    /// keep the first). Its members are read one by one, a repeated key included, and a tag that appears again is kept
    /// once, where it first appears. Only when the text cannot be followed, or a value found in it does not decode on
    /// its own (it was valid JSON all the same), are the values of `JSONSerialization`'s `tags` read, ordered by key.
    ///
    /// A value without a readable name (`tn`) is skipped; an empty or absent namespace gives a tag without one.
    /// - Throws: `ParseError.missing("tags")` without `tags` (`.malformed` when it is neither an object nor an
    ///   array); `ParseError.malformed("tags")` when it has values but none can be read.
    public static func tagSuggestions(_ json: Data) throws -> [TagRef] {
        let answer = try ShowPageParser.object(from: json)
        var scanner = KeyScanner(json)
        var tags = answer["tags"]
        // The values of the last `tags` object in text order; nil means JSONSerialization's, ordered by key.
        var members: [Any]?
        switch scanner.lastMember(named: "tags") {
        case .unreadable:
            break
        case .absent:
            tags = nil
        case .found(let value, let inner):
            // A value that does not decode on its own means the scan went astray: keep JSONSerialization's, as when
            // the text cannot be followed.
            guard let decoded = scanner.value(in: value) else { break }
            if let inner {
                guard let values = scanner.values(of: inner) else { break }
                members = values
            }
            tags = decoded
        }
        guard let tags, !(tags is NSNull) else { throw ParseError.missing("tags") }
        if let list = tags as? [Any] {
            // PHP writes an empty object as [].
            if list.isEmpty { return [] }
            throw ParseError.malformed("tags")
        }
        guard let object = tags as? [String: Any] else { throw ParseError.malformed("tags") }
        let values = members ?? object.keys.sorted().compactMap { object[$0] }
        var suggestions: [TagRef] = []
        var seen = Set<TagRef>()
        for value in values {
            guard let value = value as? [String: Any], let name = string(value["tn"]) else { continue }
            let tag = TagRef(namespace: string(value["ns"]), name: name)
            if seen.insert(tag).inserted { suggestions.append(tag) }
        }
        if suggestions.isEmpty && !values.isEmpty { throw ParseError.malformed("tags") }
        return suggestions
    }

    /// The answer to `rategallery`: `rating_avg`, `rating_usr`, `rating_cnt`.
    /// - Throws: `ParseError.missing(name)` for a field the answer lacks, `.malformed(name)` when it is not a number.
    public static func rating(_ json: Data) throws -> RatingResult {
        let answer = try ShowPageParser.object(from: json)
        return RatingResult(
            average: try requiredDouble(answer, "rating_avg"),
            userRating: try requiredDouble(answer, "rating_usr"),
            count: try requiredInteger(answer, "rating_cnt")
        )
    }

    /// The answer to `votecomment`: `comment_id`, `comment_score`, `comment_vote` (the score may be negative).
    /// - Throws: `ParseError.missing(name)` for a field the answer lacks, `.malformed(name)` when it is not an
    ///   integer.
    public static func commentVote(_ json: Data) throws -> CommentVoteResult {
        let answer = try ShowPageParser.object(from: json)
        return CommentVoteResult(
            commentID: try requiredInteger(answer, "comment_id"),
            score: try requiredInteger(answer, "comment_score"),
            vote: try requiredInteger(answer, "comment_vote")
        )
    }

    /// The answer to `taggallery`: `tagpane`, the gallery's tag list as HTML, read by
    /// `GalleryDetailParser.tagGroups(inFragment:)`. A tag list without rows gives no groups.
    /// - Throws: `ParseError.missing("tagpane")` without it, `.malformed("tagpane")` when it is not a string;
    ///   whatever SwiftSoup throws, unchanged.
    public static func tagVote(_ json: Data) throws -> TagVoteResult {
        let answer = try ShowPageParser.object(from: json)
        guard let pane = answer["tagpane"], !(pane is NSNull) else { throw ParseError.missing("tagpane") }
        guard let html = pane as? String else { throw ParseError.malformed("tagpane") }
        return TagVoteResult(tagGroups: try GalleryDetailParser.tagGroups(inFragment: html))
    }

    /// The answer to `setusertag`: success unless it is `{"error": …}`; nothing else is read.
    public static func userTag(_ json: Data) throws {
        _ = try ShowPageParser.object(from: json)
    }

    // MARK: Gallery data

    private static func metadata(from entry: [String: Any]) throws -> GalleryMetadata {
        let gid = try requiredInteger(entry, "gid")
        guard let rawToken = entry["token"], !(rawToken is NSNull) else { throw ParseError.missing("token") }
        guard let token = string(rawToken) else { throw ParseError.malformed("token") }
        guard let rawTitle = entry["title"], !(rawTitle is NSNull) else { throw ParseError.missing("title") }
        guard let title = (rawTitle as? String).flatMap(unescaped) else { throw ParseError.malformed("title") }
        return GalleryMetadata(
            id: GalleryID(gid: gid, token: token),
            title: title,
            japaneseTitle: (entry["title_jpn"] as? String).flatMap(unescaped),
            category: string(entry["category"]).flatMap { GalleryCategory(siteLabel: $0) },
            thumbnailURL: string(entry["thumb"]).flatMap(webURL),
            uploader: string(entry["uploader"]),
            postedAt: integer(entry["posted"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            fileCount: integer(entry["filecount"]),
            fileSize: integer(entry["filesize"]),
            isExpunged: boolean(entry["expunged"]),
            rating: double(entry["rating"]),
            torrentCount: integer(entry["torrentcount"]),
            tags: (entry["tags"] as? [Any] ?? []).compactMap { value in
                string(value).map(TagRef.init(raw:)).flatMap { $0.name.isEmpty ? nil : $0 }
            }
        )
    }

    /// `text` with its HTML entities decoded once and trimmed; nil when nothing is left.
    private static func unescaped(_ text: String) -> String? {
        let decoded = (try? Parser.unescapeEntities(text, false)) ?? text
        return GalleryListParser.nonEmpty(decoded)
    }

    private static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    // MARK: Fields

    /// A non-empty string (trimmed); nil for anything else, numbers included.
    private static func string(_ value: Any?) -> String? {
        (value as? String).flatMap(GalleryListParser.nonEmpty)
    }

    /// A JSON integer or a string of digits (a leading "-" allowed); not a Boolean.
    private static func integer(_ value: Any?) -> Int? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("-") else { return ShowPageParser.integer(trimmed) }
            return ShowPageParser.integer(String(trimmed.dropFirst())).map { -$0 }
        }
        return ShowPageParser.integer(value)
    }

    /// A finite JSON number or a string holding one; not a Boolean.
    private static func double(_ value: Any?) -> Double? {
        if let text = value as? String {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isFinite ? $0 : nil }
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    /// A JSON Boolean, or the strings "true"/"1"; false for anything else.
    private static func boolean(_ value: Any?) -> Bool {
        if let text = value as? String { return ["true", "1"].contains(text.lowercased()) }
        guard let number = value as? NSNumber else { return false }
        return number.boolValue
    }

    private static func requiredInteger(_ object: [String: Any], _ name: String) throws -> Int {
        guard let value = object[name], !(value is NSNull) else { throw ParseError.missing(name) }
        guard let number = integer(value) else { throw ParseError.malformed(name) }
        return number
    }

    private static func requiredDouble(_ object: [String: Any], _ name: String) throws -> Double {
        guard let value = object[name], !(value is NSNull) else { throw ParseError.missing(name) }
        guard let number = double(value) else { throw ParseError.malformed(name) }
        return number
    }
}

/// Finds the members of a JSON object in the order the text writes them, repeated keys included (`JSONSerialization`
/// keeps no order and only one member per key). The text has already been parsed as JSON, so it only has to skip
/// values, not validate them.
private struct KeyScanner {
    /// A member of an object: its decoded key and the byte range of its value in the text.
    struct Member {
        let key: String
        let value: Range<Int>
    }

    /// What `lastMember(named:)` found.
    enum Lookup {
        /// The text could not be followed.
        case unreadable
        /// The top-level object has no member of that name.
        case absent
        /// The last member of that name: the byte range of its value and, when the value is an object, that object's
        /// members in text order (nil for a value of any other kind).
        case found(value: Range<Int>, members: [Member]?)
    }

    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = Array(data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    }

    /// The last top-level member `name`, read once from the start of the text.
    mutating func lastMember(named name: String) -> Lookup {
        guard let members = objectMembers() else { return .unreadable }
        guard let member = members.last(where: { $0.key == name }) else { return .absent }
        index = member.value.lowerBound
        guard current == UInt8(ascii: "{") else { return .found(value: member.value, members: nil) }
        guard let inner = objectMembers() else { return .unreadable }
        return .found(value: member.value, members: inner)
    }

    /// The JSON value at `range` of the text, decoded on its own; nil when it cannot be.
    func value(in range: Range<Int>) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(bytes[range]), options: [.fragmentsAllowed])
    }

    /// The values of `members`, each decoded on its own, in their order; nil when one cannot be.
    func values(of members: [Member]) -> [Any]? {
        var values: [Any] = []
        for member in members {
            guard let value = value(in: member.value) else { return nil }
            values.append(value)
        }
        return values
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipSpace() {
        while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
    }

    /// At "{": the members, in text order; leaves the index after the "}".
    private mutating func objectMembers() -> [Member]? {
        skipSpace()
        guard current == UInt8(ascii: "{") else { return nil }
        index += 1
        var members: [Member] = []
        skipSpace()
        if current == UInt8(ascii: "}") { index += 1; return members }
        while true {
            skipSpace()
            guard let key = readString() else { return nil }
            skipSpace()
            guard current == UInt8(ascii: ":") else { return nil }
            index += 1
            skipSpace()
            let start = index
            guard skipValue() else { return nil }
            members.append(Member(key: key, value: start..<index))
            skipSpace()
            if current == UInt8(ascii: ",") { index += 1; continue }
            if current == UInt8(ascii: "}") { index += 1; return members }
            return nil
        }
    }

    /// At a quote: the string's decoded text; leaves the index after the closing quote.
    private mutating func readString() -> String? {
        let start = index
        guard skipString() else { return nil }
        let literal = Data(bytes[start..<index])
        return (try? JSONSerialization.jsonObject(with: literal, options: [.fragmentsAllowed])) as? String
    }

    private mutating func skipString() -> Bool {
        guard current == UInt8(ascii: "\"") else { return false }
        index += 1
        while let byte = current {
            if byte == UInt8(ascii: "\\") {
                index += 2
            } else {
                index += 1
                if byte == UInt8(ascii: "\"") { return true }
            }
        }
        return false
    }

    private mutating func skipValue() -> Bool {
        guard let first = current else { return false }
        if first == UInt8(ascii: "\"") { return skipString() }
        guard first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else {
            while let byte = current, byte != UInt8(ascii: ","), byte != UInt8(ascii: "}"), byte != UInt8(ascii: "]"),
                  byte != 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D { index += 1 }
            return true
        }
        var depth = 0
        while let byte = current {
            switch byte {
            case UInt8(ascii: "\""):
                guard skipString() else { return false }
                continue
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default:
                break
            }
            index += 1
            if depth == 0 { return true }
        }
        return false
    }
}
