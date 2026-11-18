import EHFixtures
import EHParsing
import Foundation

/// Who the account is, as far as the capture tool knows: its names and member id. Printing, debug-printing or
/// dumping it shows counts only, never a value.
public struct OwnIdentity: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The account's names (username, the `#profilename` nickname, names from the secrets file).
    public let words: [String]
    /// The account's member id.
    public let memberIDs: [String]

    public init(words: [String], memberIDs: [String]) {
        self.words = words
        self.memberIDs = memberIDs
    }

    /// The identity `capture` and `resanitize` judge by: every word among `secrets` (the username, the nickname
    /// `home.php` shows, the names in the secrets file) and `memberIDs`.
    init(secrets: SecretSet, memberIDs: [String]) {
        self.init(words: secrets.all.filter { $0.kind == .word }.map(\.value), memberIDs: memberIDs)
    }

    public var description: String { "OwnIdentity(\(words.count) names, \(memberIDs.count) member ids)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["names": words.count, "memberIDs": memberIDs.count], displayStyle: .struct)
    }
}

/// Finds public pages that show the account as the uploader of a gallery or of a torrent, or as a commenter. The
/// masked name would still lead back to the account through the public gallery id, so such a run is refused before
/// anything is masked. A page this check cannot read is refused as well (`owncheck`): it fails closed.
///
/// Two layers look at each page. The text layer matches the unmasked names and member id in the raw text: uploader
/// links, gdata's `"uploader"`, the PM links (`showuser=`), names without a link in `#gdn` and comment headers
/// (`div.c3`, after its `by:`), and the `Uploader:` of the torrent popup's `#torrentinfo`. A name without a link counts
/// only as the whole of a piece of text between tags (and `&nbsp;`), never inside an attribute or as the start of a
/// longer name. The parser layer reads list pages, gallery pages and the torrent popup with the app's parsers, which
/// also see names the text layer's patterns miss (a name broken over lines, a torrent uploader in an element of its
/// own).
public enum OwnContentCheck {
    /// The account uploaded a gallery the page shows (`#gdn`, a list row, gdata).
    public static let uploadRule = "ownupload"
    /// The account uploaded one of the torrents of the popup (`Uploader:` in `#torrentinfo`).
    public static let torrentRule = "owntorrent"
    /// The account commented on the gallery (a comment header, `div.c3`).
    public static let commentRule = "owncomment"
    /// The page could not be checked: its body is not UTF-8, the patterns for the identity could not be built, or a
    /// parser threw on a page that has the markup it reads (`#gdn` or `.c3` on a gallery page; `table.itg` or a
    /// gallery link on a list page; `#torrentinfo` on the torrent popup), on any element.
    public static let uncheckedRule = "owncheck"

    /// Unmasked pages only (before `Sanitizer`); private pages pass, and so does every page when the identity is
    /// empty. At most one finding per file and rule: at the line of the text layer's first match, else line 1.
    public static func findings(in raws: [RawCapture], identity: OwnIdentity) -> [HygieneViolation] {
        findings(in: raws.map { (path: $0.fixturePath, body: $0.body) }, identity: identity)
    }

    /// As `findings(in:identity:)`, for fixture paths (as in the capture plan) and bodies.
    static func findings(in pages: [(path: String, body: Data)], identity: OwnIdentity) -> [HygieneViolation] {
        let names = identity.words.filter { !$0.isEmpty }
        let ids = identity.memberIDs.filter { !$0.isEmpty }
        guard !names.isEmpty || !ids.isEmpty else { return [] }
        let matchers = try? Matchers(names: names, ids: ids)
        var result: [HygieneViolation] = []
        for page in pages where !PrivateFixtures.isPrivate(page.path) {
            var lines: [String: Int] = [:]
            if let matchers, let body = String(validating: page.body, as: UTF8.self) {
                let scan = TextScan(body, matchers: matchers)
                for (rule, line) in scan.findings {
                    lines[rule] = min(lines[rule] ?? line, line)
                }
                for rule in parsedFindings(path: page.path, body: body, names: names, ids: ids, scan: scan)
                where lines[rule] == nil {
                    lines[rule] = 1
                }
            } else {
                lines[uncheckedRule] = 1
            }
            for rule in lines.keys.sorted() {
                result.append(HygieneViolation(file: page.path, rule: rule, line: lines[rule]!))
            }
        }
        return result
    }

    /// What the tool prints when it refuses over `findings`: what happened, each finding (file, line and rule, never
    /// a value), then what to do about each rule found.
    public static func explanation(of findings: [HygieneViolation]) -> String {
        let rules = Set(findings.map(\.rule))
        let advice = [
            (uploadRule, "pick a gallery in targets.json the account did not upload, and an uploader other than the account."),
            (torrentRule, "pick a gallery in targets.json the account has not uploaded a torrent for."),
            (commentRule, "pick a gallery in targets.json the account has not commented on."),
            (uncheckedRule, "these pages could not be checked (not UTF-8, or their layout is not what the parsers "
                + "read); capture again after updating the parsers."),
        ]
        return (["Refused to write: these public pages show the account as uploader, torrent uploader or commenter (the "
            + "masked name still leads back to it through the public gallery id), or could not be checked for it. No "
            + "fixtures were written."]
            + findings.map { "  \($0)" }
            + advice.filter { rules.contains($0.0) }.map { "  \($0.0): \($0.1)" }).joined(separator: "\n")
    }

    // MARK: Text layer

    /// The patterns for one identity, matched against unescaped, lowercased text.
    private struct Matchers {
        /// `/uploader/<name>`.
        let uploaderLink: NSRegularExpression?
        /// gdata's `"uploader": "<name>"`.
        let jsonUploader: NSRegularExpression?
        /// The names a piece of text without a link must equal, whole (`#gdn` and comment headers).
        let wholeNames: Set<String>
        /// A torrent's `Uploader:</span> <name>`, the name all of the text up to the next tag.
        let torrentUploader: NSRegularExpression?
        /// `showuser=<member id>`.
        let showUser: NSRegularExpression?

        /// Names in every encoded form (`FixtureHygiene.encodedForms(of:)`), lowercased.
        /// - Throws: When a pattern does not compile; the caller then refuses every page.
        init(names: [String], ids: [String]) throws {
            let forms = Set(names.flatMap { FixtureHygiene.encodedForms(of: $0) }.map { $0.lowercased() })
            wholeNames = forms
            if names.isEmpty {
                uploaderLink = nil
                jsonUploader = nil
                torrentUploader = nil
            } else {
                let alternatives = forms.sorted { $0.count > $1.count }
                    .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
                uploaderLink = try NSRegularExpression(pattern: "/uploader/(?:\(alternatives))(?=[\"'/?#&<\\s]|$)")
                jsonUploader = try NSRegularExpression(pattern: "\"uploader\"\\s*:\\s*\"(?:\(alternatives))\"")
                torrentUploader = try NSRegularExpression(
                    pattern: "uploader:\\s*</span>(?:\\s|&nbsp;)*(?:\(alternatives))(?:\\s|&nbsp;)*(?=<|$)"
                )
            }
            let idAlternatives = Set(ids.map { $0.lowercased() }).map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            showUser = ids.isEmpty ? nil : try NSRegularExpression(pattern: "showuser=(?:\(idAlternatives))(?![0-9])")
        }
    }

    private static let divTag = try! NSRegularExpression(pattern: "<(/?)div\\b[^>]*>")
    private static let gdnID = try! NSRegularExpression(pattern: "(?<![\\w-])id\\s*=\\s*[\"']gdn[\"']")
    private static let torrentInfoID = try! NSRegularExpression(pattern: "(?<![\\w-])id\\s*=\\s*[\"']torrentinfo[\"']")
    private static let c3Class = try! NSRegularExpression(
        pattern: "(?<![\\w-])class\\s*=\\s*[\"'][^\"']*(?<![\\w-])c3(?![\\w-])[^\"']*[\"']"
    )
    private static let itgClass = try! NSRegularExpression(
        pattern: "(?<![\\w-])class\\s*=\\s*[\"'][^\"']*(?<![\\w-])itg(?![\\w-])[^\"']*[\"']"
    )
    private static let galleryLink = try! NSRegularExpression(pattern: "/g/[0-9]+/[0-9a-f]{10}/")
    /// A tag, `&nbsp;` or a no-break space: what `TextScan` blanks out, so that what is left is the text between them.
    private static let textBreak = try! NSRegularExpression(pattern: "<[^>]*>|&nbsp;|\\u00A0")
    /// A piece of text between blanks (`textBreak`).
    private static let textPiece = try! NSRegularExpression(pattern: "[^\\u0000]+")
    /// Where a comment header names its poster: what follows it.
    private static let posterLead = try! NSRegularExpression(pattern: "\\bby:")

    /// What the text layer finds on one page, and which markup the parsers read the page has.
    private struct TextScan {
        /// (rule, line) pairs, before deduplication.
        private(set) var findings: [(String, Int)] = []
        /// `#gdn` or a comment header (`.c3`), on any element: what `GalleryDetailParser` reads names from.
        private(set) var hasGalleryMarkup = false
        /// A `table.itg` or a gallery link: what `GalleryListParser` reads rows from.
        private(set) var hasListMarkup = false
        /// `#torrentinfo`, on any element: what `TorrentListParser` reads torrents from.
        private(set) var hasTorrentMarkup = false

        init(_ body: String, matchers: Matchers) {
            let text = htmlUnescaped(body).lowercased()
            let ns = text as NSString
            let whole = NSRange(location: 0, length: ns.length)

            // #gdn, div.c3 and #torrentinfo: from the start tag to the `</div>` that closes it (the end of the text
            // when none does).
            var gdnRanges: [NSRange] = []
            var c3Ranges: [NSRange] = []
            var torrentRanges: [NSRange] = []
            for match in divTag.matches(in: text, range: whole) where match.range(at: 1).length == 0 {
                let tag = ns.substring(with: match.range)
                let tagRange = NSRange(location: 0, length: (tag as NSString).length)
                let isGdn = gdnID.firstMatch(in: tag, range: tagRange) != nil
                let isC3 = c3Class.firstMatch(in: tag, range: tagRange) != nil
                let isTorrentInfo = torrentInfoID.firstMatch(in: tag, range: tagRange) != nil
                guard isGdn || isC3 || isTorrentInfo else { continue }
                let from = match.range.location
                let range = NSRange(location: from, length: Self.end(of: match.range, in: text) - from)
                if isGdn { gdnRanges.append(range) }
                if isC3 { c3Ranges.append(range) }
                if isTorrentInfo { torrentRanges.append(range) }
            }
            // The parsers read these on any element, so a page has them wherever they stand, not only on a `div` (the
            // ranges the text layer looks in).
            hasGalleryMarkup = gdnID.firstMatch(in: text, range: whole) != nil
                || c3Class.firstMatch(in: text, range: whole) != nil
            hasTorrentMarkup = torrentInfoID.firstMatch(in: text, range: whole) != nil
            hasListMarkup = itgClass.firstMatch(in: text, range: whole) != nil
                || galleryLink.firstMatch(in: text, range: whole) != nil

            func contains(_ ranges: [NSRange], _ location: Int) -> Bool {
                ranges.contains { NSLocationInRange(location, $0) }
            }
            func line(at location: Int) -> Int {
                var count = 1
                var index = 0
                while index < location {
                    if ns.character(at: index) == 0x0A { count += 1 }
                    index += 1
                }
                return count
            }
            func matches(_ pattern: NSRegularExpression?, in ranges: [NSRange]) -> [NSTextCheckingResult] {
                ranges.flatMap { pattern?.matches(in: text, range: $0) ?? [] }
            }

            for match in matchers.uploaderLink?.matches(in: text, range: whole) ?? [] {
                let rule = contains(c3Ranges, match.range.location) ? commentRule : uploadRule
                findings.append((rule, line(at: match.range.location)))
            }
            for match in matchers.jsonUploader?.matches(in: text, range: whole) ?? [] {
                findings.append((uploadRule, line(at: match.range.location)))
            }
            for match in matchers.showUser?.matches(in: text, range: whole) ?? [] {
                let location = match.range.location
                if contains(gdnRanges, location) {
                    findings.append((uploadRule, line(at: location)))
                } else if contains(c3Ranges, location) {
                    findings.append((commentRule, line(at: location)))
                }
            }
            // Names without a link, which otherwise only the parsers read: a page they cannot read is still refused
            // for what it shows, and the parser layer becomes a second line. Only the text between tags counts, a
            // piece at a time and whole, so that an attribute (`title="Contact Poster"`) or a longer name (`<name>-x`)
            // is no finding; in a comment header, only what follows its `by:` (not `Posted on …`).
            let blanked = gdnRanges.isEmpty && c3Ranges.isEmpty ? "" : Self.blanked(text, whole: whole)
            let pieces = blanked as NSString
            func wholeNames(in ranges: [NSRange], after lead: NSRegularExpression? = nil) -> [Int] {
                ranges.flatMap { range -> [Int] in
                    var start = range.location
                    if let lead, let found = lead.firstMatch(in: blanked, range: range) {
                        start = NSMaxRange(found.range)
                    }
                    let rest = NSRange(location: start, length: NSMaxRange(range) - start)
                    return textPiece.matches(in: blanked, range: rest).compactMap { piece in
                        let name = pieces.substring(with: piece.range).trimmingCharacters(in: .whitespacesAndNewlines)
                        return matchers.wholeNames.contains(name) ? piece.range.location : nil
                    }
                }
            }
            for location in wholeNames(in: gdnRanges) {
                findings.append((uploadRule, line(at: location)))
            }
            for location in wholeNames(in: c3Ranges, after: posterLead) {
                findings.append((commentRule, line(at: location)))
            }
            for match in matches(matchers.torrentUploader, in: torrentRanges) {
                findings.append((torrentRule, line(at: match.range.location)))
            }
        }

        /// `text` with every tag, `&nbsp;` and no-break space (`textBreak`) replaced by as many U+0000: the text
        /// between them stays where it was, so offsets (and lines) are the text's own.
        private static func blanked(_ text: String, whole: NSRange) -> String {
            var units = Array(text.utf16)
            for match in textBreak.matches(in: text, range: whole) {
                for index in match.range.location..<NSMaxRange(match.range) { units[index] = 0 }
            }
            return String(decoding: units, as: UTF16.self)
        }

        /// Where the `div` whose start tag is `start` ends: just past the `</div>` that closes it, counting the `div`s
        /// nested in it; the end of `text` when none does.
        private static func end(of start: NSRange, in text: String) -> Int {
            let length = (text as NSString).length
            var depth = 1
            var end = length
            divTag.enumerateMatches(in: text, range: NSRange(location: NSMaxRange(start), length: length - NSMaxRange(start))) {
                match, _, stop in
                guard let match else { return }
                depth += match.range(at: 1).length == 0 ? 1 : -1
                if depth == 0 {
                    end = NSMaxRange(match.range)
                    stop.pointee = true
                }
            }
            return end
        }
    }

    // MARK: Parser layer

    /// The rules the parsers find: names without a link the text layer's patterns may miss, and `owncheck` when a
    /// parser throws on a page that has the markup it reads (`scan`).
    private static func parsedFindings(
        path: String, body: String, names: [String], ids: [String], scan: TextScan
    ) -> Set<String> {
        let lowerNames = Set(names.map { $0.lowercased() })
        let lowerIDs = Set(ids)
        func isOwn(_ name: String?) -> Bool {
            name.map { lowerNames.contains($0.lowercased()) } ?? false
        }
        var rules: Set<String> = []
        if path.contains("/list/") {
            do {
                let page = try GalleryListParser.parse(body)
                if page.items.contains(where: { isOwn($0.uploader) }) { rules.insert(uploadRule) }
            } catch {
                if scan.hasListMarkup { rules.insert(uncheckedRule) }
            }
        }
        if path.contains("/gallery/") {
            do {
                let detail = try GalleryDetailParser.parse(body)
                if isOwn(detail.uploader) { rules.insert(uploadRule) }
                if detail.comments.contains(where: {
                    isOwn($0.posterName) || ($0.posterMemberID.map { lowerIDs.contains(String($0)) } ?? false)
                }) {
                    rules.insert(commentRule)
                }
            } catch {
                if scan.hasGalleryMarkup { rules.insert(uncheckedRule) }
            }
        }
        if path.contains("/popup/torrents") {
            do {
                if try TorrentListParser.parse(body).contains(where: { isOwn($0.uploader) }) { rules.insert(torrentRule) }
            } catch {
                if scan.hasTorrentMarkup { rules.insert(uncheckedRule) }
            }
        }
        return rules
    }
}
