import EHModels
import Foundation
import SwiftSoup

/// Reads the multi-page viewer page (`/mpv/<gid>/<token>/`).
public enum MPVPageParser {
    /// Parses a multi-page viewer page.
    ///
    /// Reads the inline variables of the page's scripts (not of its text): `var gid = <n>;`, `var mpvkey = "<key>";`,
    /// `var pagecount = <n>;` and `var imagelist = [ … ];`, a JSON array whose entries give `n` (name), `k` (key) and
    /// `t` (thumbnail). Spaces around `=` are optional: the site writes `var gid=<n>;` but `var mpvkey = "…";`. The
    /// list ends at the `]` that closes its `[` (brackets inside strings, such as a file name with `];`, do not count).
    /// - Throws: `ParseError.missing("gid")`, `("mpvKey")`, `("pageCount")` or `("imagelist")` when a variable is not
    ///   found; `ParseError.malformed("imagelist")` when the list does not close or is not an array of such entries;
    ///   whatever SwiftSoup throws, unchanged.
    public static func parse(_ html: String) throws -> MPVInfo {
        let script = try SwiftSoup.parse(html).select("script").array().map { $0.data() }.joined(separator: "\n")
        guard let gid = script.firstMatch(of: /var\s+gid\s*=\s*([0-9]+)\s*;/).flatMap({ Int($0.1) }), gid > 0 else {
            throw ParseError.missing("gid")
        }
        guard let mpvKey = script.firstMatch(of: /var\s+mpvkey\s*=\s*"([^"]+)"\s*;/).map({ String($0.1) }) else {
            throw ParseError.missing("mpvKey")
        }
        guard let pageCount = script.firstMatch(of: /var\s+pagecount\s*=\s*([0-9]+)\s*;/).flatMap({ Int($0.1) }) else {
            throw ParseError.missing("pageCount")
        }
        guard let start = script.firstMatch(of: /var\s+imagelist\s*=\s*\[/) else {
            throw ParseError.missing("imagelist")
        }
        let listStart = script.index(before: start.range.upperBound)
        guard let list = jsonArray(at: script[listStart...]),
              let entries = try? JSONDecoder().decode([Entry].self, from: Data(list.utf8)) else {
            throw ParseError.malformed("imagelist")
        }
        return MPVInfo(
            gid: gid,
            mpvKey: mpvKey,
            pageCount: pageCount,
            images: entries.map { MPVImage(name: $0.n, key: $0.k, thumbnail: $0.t) }
        )
    }

    /// An entry of `imagelist`, as the site writes it.
    private struct Entry: Decodable {
        let n: String
        let k: String
        let t: String
    }

    /// The JSON array that `text` starts with (its first character is `[`), up to the `]` that closes it; brackets
    /// and braces inside strings are skipped. nil when it does not close.
    private static func jsonArray(at text: Substring) -> Substring? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in text.utf8.indices {
            let byte = text.utf8[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return text[...index] }
            default:
                break
            }
        }
        return nil
    }
}
