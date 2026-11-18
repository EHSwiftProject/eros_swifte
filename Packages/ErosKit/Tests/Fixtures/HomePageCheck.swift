import Foundation

/// A check of `home.php` that shares nothing with `FixtureHygiene`'s patterns: element text, with scripts, styles,
/// comments, tags and character references removed, must not hold a digit other than "1" anywhere outside the
/// Image Limits section (its heading up to the next heading); `203.0.113.x` stand-ins are allowed. A second
/// opinion on the `homestats` and `torrentkey` rules: the capture tool runs it before writing (and refuses on a
/// finding), and `EHFixturesTests` on the checked-in fixtures.
public enum HomePageCheck {
    /// The rule name its violations report.
    public static let rule = "homepage-number"

    /// Whether `path` (relative to a fixture root, `local/` or not) is a `home.php` capture this check applies to.
    public static func applies(to path: String) -> Bool {
        path.hasSuffix("/account/home.html")
    }

    /// One `rule` violation per line of `unmaskedNumberLines(in:)`; never the text.
    public static func violations(in html: String, file: String) -> [HygieneViolation] {
        unmaskedNumberLines(in: html).map { HygieneViolation(file: file, rule: rule, line: $0) }
    }

    /// Line numbers, ascending and without repeats, of element text holding a digit other than "1".
    public static func unmaskedNumberLines(in html: String) -> [Int] {
        var text = html
        if let section = imageLimitsSection(in: text) { text = blanking(text, ranges: [section]) }
        // The 203.0.113.0/24 stand-ins the capture tool puts in place of addresses are sanitized text, not numbers.
        for pattern in [
            #"<(script|style)\b[\s\S]*?</\1\s*>"#, #"<!--[\s\S]*?-->"#, #"<[^>]*>"#, #"&#?[A-Za-z0-9]+;"#,
            #"(?<![0-9.])203\.0\.113\.[0-9]{1,3}(?![0-9])"#,
        ] {
            text = blanking(text, ranges: ranges(of: pattern, in: text))
        }
        var lines: [Int] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where line.contains(where: { $0.isNumber && $0 != "1" }) {
            lines.append(index + 1)
        }
        return lines
    }

    /// From the `<h2>` whose text, without tags, is "Image Limits" to the next `<h2` or the end.
    private static func imageLimitsSection(in html: String) -> Range<String.Index>? {
        for heading in ranges(of: #"<h2\b[^>]*>[\s\S]*?</h2\s*>"#, in: html) {
            let words = blanking(String(html[heading]), ranges: ranges(of: #"<[^>]*>|&nbsp;"#, in: String(html[heading])))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard words.caseInsensitiveCompare("Image Limits") == .orderedSame else { continue }
            let end = html.range(of: "<h2", options: .caseInsensitive, range: heading.upperBound..<html.endIndex)?.lowerBound
            return heading.lowerBound..<(end ?? html.endIndex)
        }
        return nil
    }

    private static func ranges(of pattern: String, in text: String) -> [Range<String.Index>] {
        // Constant patterns, exercised by the tests.
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    /// `text` with every character of `ranges` but line breaks turned into a space, so line numbers stay.
    private static func blanking(_ text: String, ranges: [Range<String.Index>]) -> String {
        var result = ""
        var position = text.startIndex
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= position {
            result += text[position..<range.lowerBound]
            result += String(text[range].map { $0.isNewline ? $0 : " " })
            position = range.upperBound
        }
        result += text[position...]
        return result
    }
}
