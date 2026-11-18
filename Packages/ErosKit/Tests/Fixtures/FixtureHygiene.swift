import Foundation

/// How a known secret is delimited when searching for it.
public enum SecretKind: String, Sendable, Codable {
    /// Digits, e.g. a member id; an occurrence must not touch other digits.
    case numeric
    /// A name, e.g. the username; an occurrence must not touch ASCII letters, digits or `_`.
    case word
    /// An opaque token, e.g. a cookie value; any substring counts. Values shorter than 4 characters are skipped.
    case literal
}

/// A credential value that must never appear in a fixture.
public struct KnownSecret: Sendable, Hashable {
    public let kind: SecretKind
    public let value: String

    public init(kind: SecretKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

// Printing, debug-printing or dumping a secret never shows its value.
extension KnownSecret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "KnownSecret(\(kind.rawValue), <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["kind": kind], displayStyle: .struct) }
}

/// One hygiene finding. Stores only where and which rule, never the matched text, so it is always safe to print.
public struct HygieneViolation: Sendable, Equatable, CustomStringConvertible {
    public let file: String
    /// Structural rule name ("apikey", "ipv4", ...) or "secret:<kind>".
    public let rule: String
    /// 1-based line on which the match starts.
    public let line: Int

    public init(file: String, rule: String, line: Int) {
        self.file = file
        self.rule = rule
        self.line = line
    }

    public var description: String { "\(file):\(line): \(rule)" }
}

/// Checks that fixture text carries no personal data. Shared by the tests and the capture tool, which refuses to
/// write a fixture that fails either check.
public enum FixtureHygiene {
    /// Environment variables holding credentials, and how to search for their values.
    /// `EH_SP` and `EH_USER_AGENT` are capture settings, not secrets.
    public static let credentialEnvironmentKinds: [String: SecretKind] = [
        "EH_IPB_MEMBER_ID": .numeric,
        "EH_USERNAME": .word,
        "EH_IPB_PASS_HASH": .literal,
        "EH_IGNEOUS": .literal,
        "EH_SK": .literal,
        "EH_HATH_PERKS": .literal,
        "EH_STAR": .literal,
        "EH_YAY": .literal,
        "EH_IQ": .literal,
        "EH_CF_CLEARANCE": .literal,
        "EH_CF_DUID": .literal,
    ]

    /// Credential variables whose values the local secrets file keeps, so offline scans cover them.
    public static let persistedCredentialVariables: Set<String> = ["EH_IPB_MEMBER_ID", "EH_USERNAME"]

    /// Literal secrets shorter than this many characters are not searched for: they would match ordinary text.
    public static let minimumLiteralLength = 4

    // MARK: Encodings

    /// The forms a value may take in a page, in this fixed order with duplicates kept: as is (0), HTML-escaped (1),
    /// percent-encoded (2), percent-encoded with `+` for spaces (3), HTML-escaped with the other spellings of `'`
    /// (`&#39;`, `&#x27;`, `&apos;`; 4-6), JSON-escaped (7), HTML-escaped with `&` and `"` as decimal character
    /// references `&#38;` and `&#34;` (8) or as hex ones `&#x26;` and `&#x22;` (9), and JSON-escaped without escaping
    /// `/` (10). Index `i` is the same encoding for every value, so a form of one value pairs with the same form of
    /// another: the capture tool replaces each form of a secret with that form of its mask. New forms are only ever
    /// appended, so an index keeps its meaning.
    public static func encodedForms(of value: String) -> [String] {
        let percent = percentEncoded(value)
        return [
            value,
            htmlEscaped(value, apostrophe: "&#039;"),
            percent,
            percent.replacingOccurrences(of: "%20", with: "+"),
            htmlEscaped(value, apostrophe: "&#39;"),
            htmlEscaped(value, apostrophe: "&#x27;"),
            htmlEscaped(value, apostrophe: "&apos;"),
            jsonEscaped(value),
            htmlEscaped(value, apostrophe: "&#039;", ampersand: "&#38;", quote: "&#34;"),
            htmlEscaped(value, apostrophe: "&#039;", ampersand: "&#x26;", quote: "&#x22;"),
            jsonEscaped(value, escapesSlash: false),
        ]
    }

    /// `encodedForms(of:)` with duplicates dropped, order kept.
    public static func variants(of value: String) -> [String] {
        var seen = Set<String>()
        return encodedForms(of: value).filter { seen.insert($0).inserted }
    }

    /// `&`, `<`, `>`, `"` and `'` as character references; `&lt;` and `&gt;` always, the others as given.
    private static func htmlEscaped(
        _ value: String, apostrophe: String, ampersand: String = "&amp;", quote: String = "&quot;"
    ) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": result += ampersand
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += quote
            case "'": result += apostrophe
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// JSON string escaping as PHP's `json_encode` does by default: `\/`, `\"`, `\\`, and `\uXXXX` with lowercase
    /// hex for every non-ASCII character (a surrogate pair beyond the BMP). With `escapesSlash` false, `/` stays as it
    /// is, as with `JSON_UNESCAPED_SLASHES` and most other encoders.
    private static func jsonEscaped(_ value: String, escapesSlash: Bool = true) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "/" where escapesSlash: result += #"\/"#
            case "\"": result += #"\""#
            case "\\": result += #"\\"#
            case _ where scalar.isASCII: result.unicodeScalars.append(scalar)
            default:
                for unit in String(scalar).utf16 {
                    let hex = String(unit, radix: 16)
                    result += #"\u"# + String(repeating: "0", count: 4 - hex.count) + hex
                }
            }
        }
        return result
    }

    /// Keeps `A-Z a-z 0-9 - . _ ~`; every other UTF-8 byte becomes `%XX` with uppercase hex.
    private static func percentEncoded(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".unicodeScalars)
        var result = String.UnicodeScalarView()
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                result.append(Unicode.Scalar(byte))
            default:
                result.append("%")
                result.append(hex[Int(byte >> 4)])
                result.append(hex[Int(byte & 0x0F)])
            }
        }
        return String(result)
    }

    // MARK: Structural checks

    private struct StructuralRule: Sendable {
        let name: String
        let regex: NSRegularExpression
        /// Capture groups whose text is judged, in the order they appear in the pattern. Each is judged on its own;
        /// a group that takes no part in a match is not judged.
        let groups: [Int]
        /// When set, `regex` only matches inside capture group 1 of each match of `scope`; its lookarounds still see
        /// the whole text.
        let scope: NSRegularExpression?
        let isViolation: @Sendable (String) -> Bool

        init(
            name: String,
            regex: NSRegularExpression,
            groups: [Int],
            scope: NSRegularExpression? = nil,
            isViolation: @escaping @Sendable (String) -> Bool
        ) {
            self.name = name
            self.regex = regex
            self.groups = groups
            self.scope = scope
            self.isViolation = isViolation
        }
    }

    /// Structural rule names, as reported in `HygieneViolation.rule` and accepted by `violatingCaptures(ofRule:in:)`.
    public static let apikeyRule = "apikey"
    public static let apiuidRule = "apiuid"
    public static let cookieRule = "cookie"
    public static let ipv4Rule = "ipv4"
    public static let favnoteRule = "favnote"
    public static let glfnoteRule = "glfnote"
    /// The account's torrent key on `home.php`, after "Your current key is:".
    public static let torrentKeyRule = "torrentkey"
    /// The `<uid>-<key>` path segment of a personalized torrent download link, or of an `ehtracker.org` announce URL.
    public static let torrentLinkRule = "torrentlink"
    /// The other values of tracker URLs: the number before `/announce` on `ehtracker.org`, and the number and the key
    /// segment after `/get/` (or `/torrent/`) of a torrent download link.
    public static let trackerRule = "tracker"
    /// Every number in the element text of the `home.php` sections (a heading followed by a `homebox`) other than
    /// Image Limits: EHTracker, Total GP Gained, Toplists, Moderation Power, and any section the site adds later.
    public static let homeStatsRule = "homestats"
    /// Fail-closed backstop for `ehtracker.org` URLs (with or without a port, with or without a path): every path
    /// segment other than `get`, `torrent`, `announce` and `<40 hex digits>.torrent`, every query value (a query item
    /// without `=` is judged whole, as a value) and the fragment after `#` (one segment, `/` included) must be masked.
    /// Check only: the capture tool masks the shapes the rules above know, so a shape none of them knows makes the
    /// writer refuse instead of letting it through.
    public static let trackerURLRule = "trackerurl"
    /// An announce URL on any other host: `/<n>/announce`, `/<n>/<uid>-<key>/announce` or `/<uid>-<key>/announce`.
    /// Masked in place only: the capture tool never takes its values as secrets, since an ordinary link of that
    /// shape (`/2024/announce`) would otherwise rewrite years and page numbers everywhere.
    public static let announceRule = "announce"
    /// An inline `style` on a tag element (`class` token `gt`, `gtl`, `gtw` or `gtb`, the class quoted or not): list
    /// pages and toplists color the tags of the account's My Tags, detail pages fade some. Any such style is a
    /// violation, and the capture tool deletes the whole attribute: whether a tag has one at all tells it is in My Tags.
    public static let tagStyleRule = "tagstyle"
    /// The count in "Filtered N galleries from this page": it follows from the account's tag filters.
    public static let filteredRule = "filtered"
    /// The account's balances after "Current Funds" on the archiver popup (GP and Credits); the label's words may be
    /// split by a no-break space (`&nbsp;`, `&#160;`).
    public static let fundsRule = "funds"
    /// A list page that says the account's filters hid galleries from it ("Filtered N galleries from this page", N
    /// masked or not). Which galleries are missing tells the account's hidden tags to anyone who requests the same
    /// range unfiltered, and masking N does not change that, so a list must be captured with the site's filters
    /// disabled (user decision, 2026-11-05). Check only: every match is a violation, and nothing but capturing the
    /// page again fixes it. Constructed fixtures that stand for a filtered list are exempted one by one
    /// (`constructedExemptions`).
    public static let filteredListRule = "filteredlist"
    /// A forum key of 32 hex digits: the session id (`s`), the log-out key (`k`), `auth_key` or `md5check` in a query
    /// (after `?`, `&`, `&amp;` or `;`); the same names and the page script's `ipb_var_s`, `ipb_md5_check`,
    /// `secure_hash` and `session_id` assigned in a script or JSON (`= "…"`, `: "…"`, `['…'] = '…'`, JSON-escaped
    /// quotes too); and the value of a hidden input named `s`, `k`, `auth_key` or `md5check`. IPB forum pages put them
    /// in their links, scripts and forms, so pages saved from a browser and imported offline have them. The session
    /// id and log-out key change with the session, but `auth_key` and `md5check` derive from the member's login key and
    /// stay the same. Masked in place; the capture tool also searches for each value in every text of the run, but
    /// never keeps it in the secrets file (it is a token).
    public static let forumKeyRule = "forumkey"
    /// What a page shows of the account's favorites: the `style` or `title` of a list row's `posted_<gid>` element (a
    /// favorited gallery's date takes its category's color and name), anything inside a gallery page's `#fav` (the
    /// category icon), a `#favoritelink` that says anything but "Add to Favorites", the favorites popup's `favdel`
    /// choice (offered only for a gallery already in favorites), and a category name other than the site's defaults
    /// "Favorites 0"-"Favorites 9" (or masked): uconfig's `favorite_<n>` inputs, the popup's names, the title of a
    /// category icon (`class="i"`) and the name right after it on favorites.php, and favorites.php's `fav<n>` options.
    /// Check only: the capture tool refuses such a page rather than rewriting it (capture other targets, or later).
    /// The private pages under `local/` show the account's favorites by design and may (`isAllowedInPrivatePage`);
    /// constructed fixtures that stand for a favorited state are exempted one by one (`constructedExemptions`).
    public static let favoriteMarkRule = "favmark"
    /// What a public page shows of the account's own activity besides favorites: its
    /// rating (a star element whose classes include `irr`, `irg`, `irb` or `iry`, on a list row or `#rating_image`;
    /// `ir` alone is the average), its tag votes (an element of class `tup` or `tdn`, the tag links of `#taglist`), its
    /// comment votes (a non-empty `style` on `comment_vote_up_<n>` or `comment_vote_down_<n>`) and its own comments
    /// (`edit_comment(`, the call of their Edit link). Check only, as `favmark`: the capture tool refuses such a page
    /// rather than rewriting it (capture other targets, or later). The private pages under `local/` may show them
    /// (`isAllowedInPrivatePage`); constructed fixtures that stand for a rated or voted state are exempted one by one
    /// (`constructedExemptions`).
    public static let accountMarkRule = "accountmark"

    /// Structural rules a private page under `local/` may break: it shows the account's own state by design.
    public static let privatePageRules: Set<String> = [favoriteMarkRule, accountMarkRule]

    /// The pages that show the account's own preferences (user decision, 2026-11-04) and its forum profile (2026-11-05),
    /// by the path the capture plan gives them: mytags, the three favorites lists and the watched list of each site,
    /// and the forum profile. They are kept only under the git-ignored `local/` (`local/<path>`), never at these
    /// paths. The capture tool stores them there (`PrivateFixtures`); the checked-in scan fails when one of these
    /// paths exists under `eh/` or `ex/` or has a `manifest.json` entry, however it got there.
    public static let privatePagePaths: [String] = [
        "eh/account/mytags.html",
        "eh/list/favorites.html",
        "eh/list/favorites-cat0.html",
        "eh/list/favorites-search.html",
        "eh/list/watched.html",
        "ex/account/mytags.html",
        "ex/list/favorites.html",
        "ex/list/favorites-cat0.html",
        "ex/list/favorites-search.html",
        "ex/list/watched.html",
        "eh/forum/profile.html",
    ]

    /// Whether `violation` is one a private page may have: a `privatePageRules` rule in a file under `local/`. The
    /// checked-in scans and the capture tool's gate let these through; nowhere else is this allowed.
    public static func isAllowedInPrivatePage(_ violation: HygieneViolation) -> Bool {
        violation.file.hasPrefix("local/") && privatePageRules.contains(violation.rule)
    }

    /// Constructed fixtures that break a structural rule on purpose, by path under `constructed/`, with the rules
    /// each may break. Every entry says why. Nothing else is exempt, and a captured fixture never is (see `isExempt`).
    /// Shared by the checked-in scan (`EHFixturesTests`) and the capture tool's `resanitize --constructed`.
    public static let constructedExemptions: [String: Set<String>] = [
        // Stands for a list the account's filters thinned out: the "Filtered" line (its N masked) and its Disable
        // Filters link, on the galleries of a list captured with filters disabled. M1's list parser tests read it.
        "constructed/eh/list-filtered.html": [filteredListRule],
        // Stands for the account's own favorites.php: every row is favorited (its posted date has a category's
        // color and name) and the category bar names the ten categories, all made up ("Fake Folder N"); one row
        // shows the account's own rating (`ir irb`). M1's list parser tests read it.
        "constructed/eh/list-favorites.html": [favoriteMarkRule, accountMarkRule],
        // Stands for a gallery page of a gallery in the account's favorites, which the account rated, voted on and
        // commented: the category icon in `#fav` and a made-up category name ("Fake Folder 3") in `#favoritelink`,
        // `ir irr` on `#rating_image`, `tup` and `tdn` on two tag links, a styled Vote+ link and an `edit_comment`
        // link, on a copy of eh/gallery/detail.html. M1's detail parser tests read it.
        "constructed/eh/detail-favorited.html": [favoriteMarkRule, accountMarkRule],
        // Stands for the account's own mytags page: the tag previews carry the colors the site draws the account's
        // tags in, which are this page's content (made up, like every tag, tagset and number on it). M1's mytags
        // parser tests read it.
        "constructed/eh/account-mytags.html": [tagStyleRule],
    ]

    /// Whether `constructedExemptions` allows `violation`: only in a file under `constructed/`, and only for the
    /// rules listed for that file.
    public static func isExempt(_ violation: HygieneViolation) -> Bool {
        violation.file.hasPrefix("constructed/")
            && constructedExemptions[violation.file]?.contains(violation.rule) == true
    }

    private static func compile(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Constant patterns; the tests compile every one of them.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// A path separator as a URL may be spelled in a page: `/`, JSON's `\/`, percent-encoded `%2F`, or the
    /// character references `&#47;` and `&#x2F;`.
    private static let urlSeparator = #"(?:/|\\/|%2[Ff]|&#0*47;|&#[xX]0*2[Ff];)"#

    /// One path segment's value: everything up to the next separator, query, fragment, quote, markup, entity or
    /// whitespace.
    private static let segmentValue = #"[^/\\%\s'"<>?#&]+"#

    /// The tracker's own host, with an optional port.
    private static let trackerHost = #"ehtracker\.org(?::\d+)?"#

    /// The `home.php` sections whose numbers can identify the account: a heading (tags allowed inside), then the
    /// first div whose classes include `homebox` before the next heading (other markup may come between), except
    /// Image Limits. Each runs to the next heading, the footer or the end of the page.
    private static let homeStatsSection = compile(
        #"<h2\b[^>]*>(?!(?:\s|&nbsp;|<[^>]*>)*Image\s+Limits(?:\s|&nbsp;|<[^>]*>)*</h2>)(?:(?!</h2>).)*</h2>"#
            + #"(?:(?!<h2\b).)*?"#
            + #"<div\b[^>]*\bclass\s*=\s*["'][^"']*\bhomebox\b[^"']*["'][^>]*>"#
            + #"(.*?)(?=<h2\b|<div\b[^>]*\bclass\s*=\s*["'][^"']*\bdp\b|</body>|\z)"#,
        [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// A number in element text (the next angle bracket is "<", or none follows), as `homestats` and `funds` judge it.
    private static let elementTextNumber =
        #"(?<![A-Za-z0-9_.,%]|&#)(\d+(?:[.,]\d+)*)(?![0-9_]|[.,]\d)(?=[^<>]*(?:<|\z))"#

    /// Whitespace, or a no-break space written as `&nbsp;`, `&#160;` or `&#xA0;`.
    private static let textSpace = #"(?:\s|&nbsp;|&#0*160;|&#[xX]0*[aA]0;)"#

    /// What may stand between the words of a list page's "Filtered N galleries" line: a `textSpace` or a tag.
    private static let listTextGap = #"(?:\#(textSpace)|<[^>]*>)"#

    /// "Filtered N galleries" (or "gallery"), N in group 1; shared by `filtered` and `filteredlist`.
    private static let filteredLine = compile(
        #"Filtered\#(listTextGap)+(\d+(?:[.,]\d+)*)\#(listTextGap)+galler(?:y|ies)\b"#, .caseInsensitive
    )

    /// The archiver popup's funds after "Current Funds" (`textSpace` between and around the words and the colon): up
    /// to the next `</p>`, which also covers the next paragraph when the label ends its own (or is followed by a
    /// `<p>`). Only when no `</p>` follows anywhere do the funds stop at the next `<p` or `</div>`, else at the end of
    /// the text: markup between the label and the `</p>` never cuts the range short.
    private static let fundsSection = compile(
        #"Current\#(textSpace)+Funds\#(textSpace)*:?\#(textSpace)*(?:(?:</p>)?\s*<p\b[^>]*>)?"#
            + #"(.*?)(?:</p>|(?=(?:<p\b|</div>)(?:(?!</p>).)*+\z)|\z)"#,
        [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// The path, query and fragment of an `ehtracker.org` URL, for `trackerurl`; each may be missing. A segment may
    /// hold `%XX` escapes other than `%2F`.
    private static let trackerURLPath = compile(
        #"\#(trackerHost)((?:\#(urlSeparator)(?:[^/\\%\s'"<>?#&]|%(?!2[Ff])[0-9A-Fa-f]{2})*)*"#
            + #"(?:\?[^\s'"<>#]*)?(?:#[^\s'"<>]*)?)"#,
        .caseInsensitive
    )

    /// What starts a query item: `?`, `;`, or `&` written as is or as `&amp;` (atomic, so the `amp` of `&amp;` is
    /// never read as an item).
    private static let querySeparator = #"(?>[?;]|&(?:amp;)?)"#

    /// True for the parts of a tracker URL path that carry no personal data.
    private static func isFixedTrackerSegment(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        if lower == "get" || lower == "torrent" || lower == "announce" { return true }
        let hash = lower.dropLast(".torrent".count)
        return lower.hasSuffix(".torrent") && hash.count == 40 && hash.allSatisfy(\.isHexDigit)
    }

    private static let structuralRules: [StructuralRule] = [
        StructuralRule(
            name: apikeyRule, regex: compile(#"var\s*apikey\s*=\s*"([^"]*)""#), groups: [1],
            isViolation: { !isMasked($0) }
        ),
        StructuralRule(
            name: apiuidRule, regex: compile(#"var\s*apiuid\s*=\s*(\d+)"#), groups: [1],
            isViolation: { !$0.allSatisfy { $0 == "1" } }
        ),
        StructuralRule(
            name: cookieRule,
            regex: compile(
                #"(?<![A-Za-z0-9_])(ipb_member_id|ipb_pass_hash|ipb_session_id|igneous|sk|hath_perks|star|yay|iq|cf_clearance|cf_duid)=([^;&"'\s<]+)"#
            ),
            groups: [2],
            isViolation: { !isMasked($0) }
        ),
        StructuralRule(
            // A dot next to the address only blocks the match when it continues a number ("1.2.3.4.5"),
            // so a sentence-final "8.8.8.8." is still caught.
            name: ipv4Rule,
            regex: compile(#"(?<![0-9]|[0-9]\.)(\d{1,3}(?:\.\d{1,3}){3})(?![0-9]|\.[0-9])"#),
            groups: [1],
            isViolation: { isForeignIPv4($0) }
        ),
        StructuralRule(
            name: favnoteRule,
            regex: compile(#"<textarea[^>]*name="favnote"[^>]*>(.*?)</textarea>"#, .dotMatchesLineSeparators),
            groups: [1],
            isViolation: { note in
                let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && trimmed != "[favnote]"
            }
        ),
        StructuralRule(
            // Also spans lines, so a multi-line note cannot slip past the check. Galleries without a note may
            // still render an empty div.
            name: glfnoteRule,
            regex: compile(#"<div[^>]*class="glfnote"[^>]*>(.*?)</div>"#, .dotMatchesLineSeparators),
            groups: [1],
            isViolation: { note in
                let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && trimmed != "Note: [favnote]"
            }
        ),
        StructuralRule(
            // home.php: `Your current key is: <span style="font-weight:bold">KEY</span>`. The words may be split by
            // any whitespace, the colon may be missing, and up to two tags and `&nbsp;`/`&#160;` may come before the
            // key, which ends at markup, whitespace, an entity or a quote.
            name: torrentKeyRule,
            regex: compile(
                #"Your\s+current\s+key\s+is\s*:?(?:\s|&nbsp;|&#160;)*(?:<[^>]*>(?:\s|&nbsp;|&#160;)*){0,2}([^<>\s&"']+)"#,
                .caseInsensitive
            ),
            groups: [1],
            isViolation: { !isMasked($0) }
        ),
        StructuralRule(
            // gallerytorrents.php: `…/get/<n>/<key>/<uid>-<key>/<info hash>.torrent`, and an `ehtracker.org` announce
            // URL with a personal segment, `…/[<n>/]<uid>-<key>/announce`. The uid and the key are judged separately,
            // so masking keeps the "-"; the key runs to the next separator.
            name: torrentLinkRule,
            regex: compile(
                #"\#(urlSeparator)(?:get|torrent)\#(urlSeparator)\d+\#(urlSeparator)(?:\#(segmentValue)\#(urlSeparator))??"#
                    + #"(\d+)-(\#(segmentValue))\#(urlSeparator)[0-9A-Fa-f]{40}\.torrent"#
                    + #"|\#(trackerHost)\#(urlSeparator)(?:\d+\#(urlSeparator))?(\d+)-(\#(segmentValue))\#(urlSeparator)"#
                    + #"announce(?![A-Za-z0-9_])"#,
                .caseInsensitive
            ),
            groups: [1, 2, 3, 4],
            isViolation: { !isMasked($0) }
        ),
        StructuralRule(
            // gallerytorrents.php: `http://ehtracker.org/<n>/announce` (with or without a personal segment after
            // <n>), and the `<n>/<key>/` after `/get/` of both download links. Whether <n> is the same for every user
            // could not be verified offline, so it is masked like a per-user value. Announce URLs on other hosts are
            // `announceRule`'s.
            name: trackerRule,
            regex: compile(
                #"\#(trackerHost)\#(urlSeparator)(\d+)\#(urlSeparator)(?:\d+-\#(segmentValue)\#(urlSeparator))?"#
                    + #"announce(?![A-Za-z0-9_])"#
                    + #"|\#(urlSeparator)(?:get|torrent)\#(urlSeparator)(\d+)\#(urlSeparator)"#
                    + #"(?:(\#(segmentValue))\#(urlSeparator))??(?:\d+-\#(segmentValue)\#(urlSeparator))?[0-9A-Fa-f]{40}\.torrent"#,
                .caseInsensitive
            ),
            groups: [1, 2, 3],
            isViolation: { !isMasked($0) }
        ),
        StructuralRule(
            // A number in element text (the next angle bracket is "<"), not after a letter, digit, "_", "%", a
            // decimal mark or a "&#" character reference, so attributes, words, entities and escapes stay intact. A
            // unit may follow directly ("2.50GiB").
            name: homeStatsRule,
            regex: compile(elementTextNumber),
            groups: [1],
            scope: homeStatsSection,
            isViolation: { !isMasked($0) }
        ),
        StructuralRule(
            // Each path segment, each query value, each query item without "=" (whole) and the fragment of an
            // `ehtracker.org` URL, judged on its own (see `trackerURLRule`). Query names are not judged; a value after
            // an empty name ("?=") is. The item is possessive so "?ab=c" is never read as the item "a". A "#" that
            // starts a character reference (the "&#47;" separator) is no fragment.
            name: trackerURLRule,
            regex: compile(
                #"\#(urlSeparator)((?:[^/\\%\s'"<>?#&]|%(?!2[Ff])[0-9A-Fa-f]{2})+)"#
                    + #"|\#(querySeparator)([^=&;#\s'"<>]*)=([^&;#\s'"<>]*)"#
                    + #"|\#(querySeparator)([^=&;#\s'"<>]++)(?!=)"#
                    + #"|(?<!&)#([^\s'"<>]*)"#
            ),
            groups: [1, 3, 4, 5],
            scope: trackerURLPath,
            isViolation: { !isFixedTrackerSegment($0) && !isMasked($0) }
        ),
        StructuralRule(
            // `/<n>/announce`, `/<n>/<uid>-<key>/announce` or `/<uid>-<key>/announce` on a host other than the
            // tracker's (a URL right after `ehtracker.org` is `trackerRule`'s). See `announceRule`.
            name: announceRule,
            regex: compile(
                // Not right after the tracker's host (also with a port, or the "/" of a JSON "\/").
                #"(?<!ehtracker\.org)(?<!ehtracker\.org\\)(?<!ehtracker\.org:\d{1,5})(?<!ehtracker\.org:\d{1,5}\\)"#
                    + #"\#(urlSeparator)(?:(\d+)\#(urlSeparator)(?:(\d+)-(\#(segmentValue))\#(urlSeparator))?"#
                    + #"|(\d+)-(\#(segmentValue))\#(urlSeparator))announce(?![A-Za-z0-9_])"#,
                .caseInsensitive
            ),
            groups: [1, 2, 3, 4, 5],
            isViolation: { !isMasked($0) }
        ),
        StructuralRule(
            // The `style` attribute (with the whitespace before it) of an opening tag whose class has a tag token,
            // the class quoted or not (`class=gt`, one token up to whitespace or ">"). Every one is a violation,
            // colored or not; see `tagStyleRule`.
            name: tagStyleRule,
            regex: compile(
                #"<[A-Za-z][A-Za-z0-9]*\b(?=[^>]*\bclass\s*=\s*(?:"(?:[^"]*\s)?gt[lwb]?(?:\s[^"]*)?"|'(?:[^']*\s)?gt[lwb]?(?:\s[^']*)?'"#
                    + #"|gt[lwb]?(?=[\s>])))"#
                    + #"[^>]*?(\s+style\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))"#,
                .caseInsensitive
            ),
            groups: [1],
            isViolation: { _ in true }
        ),
        StructuralRule(
            // "Filtered N galleries from this page" (tags and no-break spaces around N allowed).
            name: filteredRule,
            regex: filteredLine,
            groups: [1],
            isViolation: { !isMasked($0) }
        ),
        StructuralRule(
            // Every number in element text of the "Current Funds" paragraph (GP, Credits), thousands separators kept.
            name: fundsRule,
            regex: compile(elementTextNumber),
            groups: [1],
            scope: fundsSection,
            isViolation: { !isMasked($0) }
        ),
        StructuralRule(
            // The same line as `filtered`, whatever N is; see `filteredListRule`.
            name: filteredListRule,
            regex: filteredLine,
            groups: [1],
            isViolation: { _ in true }
        ),
        StructuralRule(
            // Exactly 32 hex digits, in one of three places (see `forumKeyRule`): a query parameter; a script or JSON
            // assignment (a quote, a JSON escape or a "]" may close the name, a quote may open the value); a hidden
            // input's value, its name anywhere in the tag. A query parameter matches the first alternative only.
            name: forumKeyRule,
            regex: compile(
                #"[?&;](?:amp;)?(s|k|auth_key|md5check)=([0-9A-Fa-f]{32})(?![0-9A-Fa-f])"#
                    + #"|(?<![A-Za-z0-9_])(?:s|k|auth_key|md5check|ipb_var_s|ipb_md5_check|secure_hash|session_id)"#
                    + #"\\?["']?\]?\s*[:=]\s*\\?["']?([0-9A-Fa-f]{32})(?![0-9A-Fa-f])"#
                    + #"|<input\b(?=[^>]*\bname\s*=\s*["']?(?:s|k|auth_key|md5check)["'\s>/])[^>]*\bvalue\s*=\s*["']?"#
                    + #"([0-9A-Fa-f]{32})(?![0-9A-Fa-f])"#
            ),
            groups: [2, 3, 4],
            isViolation: { !isMasked($0) }
        ),
        // `favmark` (see `favoriteMarkRule`) in eight parts, each its own pattern so none hides another's match.
        StructuralRule(
            // A list row's `posted_<gid>` element with a `style` or `title`, in any attribute order: one per element.
            name: favoriteMarkRule,
            regex: compile(
                #"<[A-Za-z][A-Za-z0-9]*\b(?=[^>]*\bid\s*=\s*["']?posted_\d+)[^>]*?"#
                    + #"(\s(?:style|title)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))"#,
                .caseInsensitive
            ),
            groups: [1],
            isViolation: { _ in true }
        ),
        StructuralRule(
            // Anything but whitespace inside a gallery page's `#fav`, up to its first `</div>`.
            name: favoriteMarkRule,
            regex: compile(
                #"<div\b(?=[^>]*\bid\s*=\s*["']?fav["'\s>])[^>]*>(.*?)</div>"#,
                [.caseInsensitive, .dotMatchesLineSeparators]
            ),
            groups: [1],
            isViolation: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        ),
        StructuralRule(
            // A gallery page's `#favoritelink` whose text (tags and no-break spaces aside) is not the unfavorited one.
            name: favoriteMarkRule,
            regex: compile(
                #"<a\b(?=[^>]*\bid\s*=\s*["']?favoritelink["'\s>])[^>]*>(.*?)</a>"#,
                [.caseInsensitive, .dotMatchesLineSeparators]
            ),
            groups: [1],
            isViolation: { elementText($0) != "Add to Favorites" }
        ),
        StructuralRule(
            // The favorites popup's "Remove from Favorites" choice, as an id or a value.
            name: favoriteMarkRule,
            regex: compile(#"\b(?:id|value)\s*=\s*["']?(favdel)(?![A-Za-z0-9_])"#, .caseInsensitive),
            groups: [1],
            isViolation: { _ in true }
        ),
        StructuralRule(
            // uconfig's category names: the value of each `favorite_<n>` input, quoted either way or not.
            name: favoriteMarkRule,
            regex: compile(
                #"<input\b(?=[^>]*\bname\s*=\s*["']?favorite_\d["'\s>/])[^>]*\bvalue\s*=\s*"#
                    + #"(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#,
                .caseInsensitive
            ),
            groups: [1, 2, 3],
            isViolation: { !isDefaultFavoriteName($0) }
        ),
        StructuralRule(
            // The favorites popup's names: the text of an element whose `onclick` clicks a `fav<n>` choice.
            name: favoriteMarkRule,
            regex: compile(
                #"\bonclick\s*=\s*"[^"]*getElementById\(\s*'fav\d'\s*\)[^"]*"[^>]*>([^<]*)<"#, .caseInsensitive
            ),
            groups: [1],
            isViolation: { !isDefaultFavoriteName($0) }
        ),
        StructuralRule(
            // A category icon (`class="i"`, quoted or not) and its title.
            name: favoriteMarkRule,
            regex: compile(
                #"<[A-Za-z][A-Za-z0-9]*\b(?=[^>]*\bclass\s*=\s*(?:"(?:[^"]*\s)?i(?:\s[^"]*)?""#
                    + #"|'(?:[^']*\s)?i(?:\s[^']*)?'|i(?=[\s>])))[^>]*\btitle\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
                .caseInsensitive
            ),
            groups: [1, 2],
            isViolation: { !isDefaultFavoriteName($0) }
        ),
        StructuralRule(
            // favorites.php: the name in the element right after an empty category icon, and the `fav<n>` options.
            name: favoriteMarkRule,
            regex: compile(
                #"<div\b(?=[^>]*\bclass\s*=\s*["']?i["'\s>])[^>]*>\s*</div>\s*<div\b[^>]*>([^<]*)</div>"#
                    + #"|<option\b(?=[^>]*\bvalue\s*=\s*["']?fav\d["'\s>])[^>]*>([^<]*)</option>"#,
                .caseInsensitive
            ),
            groups: [1, 2],
            isViolation: { !isDefaultFavoriteName($0) }
        ),
        // `accountmark` (see `accountMarkRule`) in four parts, each its own pattern so none hides another's match.
        StructuralRule(
            // The account's rating: a star element with a colored class (`ir irr`; the parsers read the same four).
            name: accountMarkRule,
            regex: compile(classTokenPattern(#"ir[rgby]"#), .caseInsensitive),
            groups: [1, 2, 3],
            isViolation: { _ in true }
        ),
        StructuralRule(
            // The account's tag votes: an element of class `tup` or `tdn`.
            name: accountMarkRule,
            regex: compile(classTokenPattern(#"t(?:up|dn)"#), .caseInsensitive),
            groups: [1, 2, 3],
            isViolation: { _ in true }
        ),
        StructuralRule(
            // The account's comment votes: the `style` of a `comment_vote_up_<n>` or `comment_vote_down_<n>` element,
            // in any attribute order, when not empty (`style="color:blue"`).
            name: accountMarkRule,
            regex: compile(
                #"<[A-Za-z][A-Za-z0-9]*\b(?=[^>]*\bid\s*=\s*["']?comment_vote_(?:up|down)_\d+)[^>]*?"#
                    + #"\sstyle\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
                .caseInsensitive
            ),
            groups: [1, 2, 3],
            isViolation: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        ),
        StructuralRule(
            // The account's own comments: the call of their Edit link, `edit_comment(<id>)`, wherever it is written.
            name: accountMarkRule,
            regex: compile(#"\b(edit_comment)\s*\("#, .caseInsensitive),
            groups: [1],
            isViolation: { _ in true }
        ),
    ]

    /// An opening tag whose `class` has a token matching `token` (a pattern without groups), captured in group 1
    /// (double-quoted class), 2 (single-quoted) or 3 (unquoted, one token up to whitespace or ">").
    private static func classTokenPattern(_ token: String) -> String {
        #"<[A-Za-z][A-Za-z0-9]*\b[^>]*?\bclass\s*=\s*(?:"(?:[^"]*\s)?(\#(token))(?=[\s"])[^"]*""#
            + #"|'(?:[^']*\s)?(\#(token))(?=[\s'])[^']*'|(\#(token))(?=[\s>]))"#
    }

    /// The text of an element's content: tags dropped, no-break spaces and runs of whitespace as one space, trimmed.
    private static func elementText(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"&nbsp;|&#0*160;|&#[xX]0*[aA]0;"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True for a favorites category name the site gives every account: "Favorites 0" to "Favorites 9", empty, or
    /// masked.
    private static func isDefaultFavoriteName(_ name: String) -> Bool {
        let text = elementText(name)
        let isDefault = text.range(of: #"\AFavorites [0-9]\z"#, options: .regularExpression) != nil
        return text.isEmpty || isMasked(text) || isDefault
    }

    /// True when the only letters and digits left are `1`, `a` and `A` (the output of the sanitizer's mask).
    /// Any other letter or digit, in any script, counts as unmasked.
    private static func isMasked(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar == "1" || scalar == "a" || scalar == "A" || !CharacterSet.alphanumerics.contains(scalar)
        }
    }

    /// True for a dotted quad with every octet <= 255 outside the documentation range 203.0.113.0/24.
    private static func isForeignIPv4(_ candidate: String) -> Bool {
        let octets = candidate.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return false }
        return octets[0...2] != [203, 0, 113]
    }

    /// Names of the structural rules, each once, in the order `structuralViolations` applies them.
    public static let structuralRuleNames: [String] = structuralRules.map(\.name).reduce(into: []) { names, name in
        if !names.contains(name) { names.append(name) }
    }

    /// Matches of `rule` that are violations: the whole match, and its judged captures that are violations, in
    /// pattern order. A capture that cannot be read is nil and counts as a violation rather than being skipped.
    private static func violatingMatches(
        of rule: StructuralRule, in text: String
    ) -> [(match: NSRange, captures: [Range<String.Index>?])] {
        let whole = NSRange(text.startIndex..., in: text)
        let ranges = rule.scope.map { scope in
            scope.matches(in: text, range: whole).map { $0.range(at: 1) }.filter { $0.location != NSNotFound }
        } ?? [whole]
        return ranges.flatMap { range in
            rule.regex.matches(in: text, options: .withTransparentBounds, range: range).compactMap { match in
                var captures: [Range<String.Index>?] = []
                for group in rule.groups where match.range(at: group).location != NSNotFound {
                    guard let capture = Range(match.range(at: group), in: text) else {
                        captures.append(nil)
                        continue
                    }
                    if rule.isViolation(String(text[capture])) { captures.append(capture) }
                }
                return captures.isEmpty ? nil : (match.range, captures)
            }
        }
    }

    /// Rule-based checks that need no secrets: unmasked apikey, apiuid and login cookies, foreign IPv4 addresses,
    /// favorite notes, torrent keys and tracker links, the account statistics on `home.php`, tag styles, the
    /// "Filtered" line and count, the archiver's funds, forum session keys, favorite marks and the account's ratings,
    /// votes and own comments. One violation per offending match, in rule order (a rule in several parts, part by
    /// part).
    public static func structuralViolations(in text: String, file: String) -> [HygieneViolation] {
        let lines = LineIndex(text)
        return structuralRules.flatMap { rule in
            violatingMatches(of: rule, in: text).map { violating in
                HygieneViolation(file: file, rule: rule.name, line: lines.line(at: violating.match.location))
            }
        }
    }

    /// The judged text (the capture groups) of every match of one structural rule that `structuralViolations`
    /// reports, in order; for a rule that judges several groups, each violating group of a match, in pattern order.
    /// A capture that cannot be read is reported there but not returned here. The capture tool masks or replaces
    /// these ranges and mines them for secrets, so it fixes exactly what the check flags.
    /// - Parameter rule: One of `structuralRuleNames` (`apikeyRule`, `apiuidRule`, ...).
    public static func violatingCaptures(ofRule rule: String, in text: String) -> [Range<String.Index>] {
        let parts = structuralRules.filter { $0.name == rule }
        guard !parts.isEmpty else { preconditionFailure("unknown structural rule: \(rule)") }
        let captures = parts.flatMap { part in
            violatingMatches(of: part, in: text).flatMap { $0.captures.compactMap { $0 } }
        }
        // A rule in several parts (`favmark`, `accountmark`): every part's captures, in text order.
        return parts.count == 1 ? captures : captures.sorted { $0.lowerBound < $1.lowerBound }
    }

    // MARK: Known secrets

    /// Every occurrence of any variant of any secret, as `secret:<kind>` violations. Matching ignores case.
    public static func secretViolations(in text: String, file: String, secrets: [KnownSecret]) -> [HygieneViolation] {
        let lines = LineIndex(text)
        var violations: [HygieneViolation] = []
        var seen = Set<KnownSecret>()
        for secret in secrets where seen.insert(secret).inserted {
            for occurrence in occurrences(of: secret, in: text) {
                violations.append(HygieneViolation(
                    file: file, rule: "secret:\(secret.kind.rawValue)", line: lines.line(at: occurrence.range.location)
                ))
            }
        }
        return violations
    }

    /// Every occurrence of `secret` that `secretViolations` reports, in order: its range, and the index in
    /// `encodedForms(of: secret.value)` of the form that matched (the first index when forms repeat). Matching
    /// ignores case. Empty for an empty value or a literal shorter than `minimumLiteralLength`; an occurrence whose
    /// range cannot be expressed in `text` is reported by the check but not returned.
    public static func secretMatches(of secret: KnownSecret, in text: String) -> [(range: Range<String.Index>, form: Int)] {
        occurrences(of: secret, in: text).compactMap { occurrence in
            Range(occurrence.range, in: text).map { ($0, occurrence.form) }
        }
    }

    private static func occurrences(of secret: KnownSecret, in text: String) -> [(range: NSRange, form: Int)] {
        guard let search = searchPattern(for: secret) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return search.regex.matches(in: text, range: whole).map { match in
            // Exactly one alternative's group takes part in a match.
            let group = search.forms.indices.first { match.range(at: $0 + 1).location != NSNotFound }
            return (match.range, group.map { search.forms[$0] } ?? 0)
        }
    }

    /// Escapes that may end right before a numeric or word secret and still leave it a separate token: a complete
    /// `%XX` ("uploader%3ASora"), and JSON's `\uXXXX` and `\b \f \n \r \t` ("\u3010Sora\u3011").
    private static let escapeBoundary = #"(?<=%[0-9A-Fa-f]{2})|(?<=\\u[0-9A-Fa-f]{4})|(?<=\\[bfnrt])"#

    /// One alternation over the secret's variants, longest first so each occurrence matches once and in full
    /// (equal lengths keep form order). Each alternative is a capture group; `forms[k]` is the index in
    /// `encodedForms(of:)` of group `k + 1`.
    /// - Returns: nil: the value is empty, or a literal shorter than `minimumLiteralLength`.
    private static func searchPattern(for secret: KnownSecret) -> (regex: NSRegularExpression, forms: [Int])? {
        guard !secret.value.isEmpty,
              secret.kind != .literal || secret.value.count >= minimumLiteralLength else { return nil }
        let encoded = encodedForms(of: secret.value)
        let forms = encoded.indices
            .filter { encoded.firstIndex(of: encoded[$0]) == $0 }
            .sorted { lhs, rhs in
                let (lhsLength, rhsLength) = (encoded[lhs].utf16.count, encoded[rhs].utf16.count)
                return lhsLength != rhsLength ? lhsLength > rhsLength : lhs < rhs
            }
        let alternatives = forms
            .map { "(\(NSRegularExpression.escapedPattern(for: encoded[$0])))" }
            .joined(separator: "|")
        let body = "(?:\(alternatives))"
        let pattern = switch secret.kind {
        case .numeric: "(?:(?<![0-9])|\(escapeBoundary))\(body)(?![0-9])"
        case .word: "(?:(?<![A-Za-z0-9_])|\(escapeBoundary))\(body)(?![A-Za-z0-9_])"
        case .literal: body
        }
        do {
            return (try NSRegularExpression(pattern: pattern, options: .caseInsensitive), forms)
        } catch {
            // Escaped alternatives always compile. Crash rather than skip the secret, and keep the pattern and the
            // error (both may echo the value) out of the message.
            preconditionFailure("secret pattern failed to compile (kind: \(secret.kind))")
        }
    }

    /// Non-empty credential values from `environment` with the variable each came from, sorted by variable name
    /// (as `knownSecrets`). Values are trimmed; capture settings such as `EH_SP` are not credentials.
    public static func namedCredentialSecrets(environment: [String: String]) -> [(variable: String, secret: KnownSecret)] {
        credentialEnvironmentKinds.sorted(by: { $0.key < $1.key }).compactMap { name, kind in
            let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : (name, KnownSecret(kind: kind, value: value))
        }
    }

    /// Credentials from `environment` (see `credentialEnvironmentKinds`) followed by those in `secretsFile`.
    /// Values are trimmed, empty ones dropped, duplicates removed. A missing or unreadable file adds nothing.
    public static func knownSecrets(environment: [String: String], secretsFile: URL?) -> [KnownSecret] {
        var secrets: [KnownSecret] = []
        for (name, kind) in credentialEnvironmentKinds.sorted(by: { $0.key < $1.key }) {
            let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { secrets.append(KnownSecret(kind: kind, value: value)) }
        }
        if let secretsFile, let text = try? String(contentsOf: secretsFile, encoding: .utf8) {
            secrets += parseSecretsFile(text)
        }
        var seen = Set<KnownSecret>()
        return secrets.filter { seen.insert($0).inserted }
    }

    // MARK: Secrets file

    /// Parses `<kind>\t<value>` lines. Blank lines, `#` comments, unknown kinds and lines without a tab are skipped;
    /// values are trimmed of spaces and tabs.
    public static func parseSecretsFile(_ text: String) -> [KnownSecret] {
        var secrets: [KnownSecret] = []
        var seen = Set<KnownSecret>()
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let tab = line.firstIndex(of: "\t"),
                  let kind = SecretKind(rawValue: line[..<tab].trimmingCharacters(in: .whitespaces)) else { continue }
            let value = line[line.index(after: tab)...].trimmingCharacters(in: .whitespaces)
            let secret = KnownSecret(kind: kind, value: value)
            if !value.isEmpty, seen.insert(secret).inserted { secrets.append(secret) }
        }
        return secrets
    }

    /// The secrets file format read by `parseSecretsFile`, with a header comment. Values that would not read back
    /// unchanged are dropped: empty ones, and ones containing a line break or a tab (the capture tool also records
    /// each line of a multi-line value on its own).
    public static func renderSecretsFile(_ secrets: [KnownSecret]) -> String {
        var lines = [
            "# Eros fixture secrets: values that must never appear in a fixture.",
            "# Local only: git-ignored, mode 0600, never commit. One \"<kind><TAB><value>\" per line;",
            "# kinds: numeric, word, literal.",
        ]
        var seen = Set<KnownSecret>()
        for secret in secrets where isRenderable(secret.value) && seen.insert(secret).inserted {
            lines.append("\(secret.kind.rawValue)\t\(secret.value)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isRenderable(_ value: String) -> Bool {
        !value.isEmpty && !value.contains { $0.isNewline || $0 == "\t" }
    }

    // MARK: Local leak check

    /// Rule name of the leak check: a value that only the private pages under `local/` show.
    public static let localLeakRule = "localleak"

    /// How many values of each kind the private pages hold, before any is let through. Counts only, so it is safe to
    /// print and to `#expect` on.
    public struct LocalValueCounts: Sendable, Equatable, CustomStringConvertible {
        /// Namespaced tag names ("ns:tag") and bare tags, from mytags pages.
        public let tagNames: Int
        /// Tagset names other than the site's default "Tagset #<n>", from mytags pages.
        public let tagsets: Int
        /// Gallery titles, from favorites and watched pages.
        public let titles: Int
        /// Gallery links, from favorites and watched pages.
        public let links: Int

        public var description: String {
            "tag names \(tagNames), tagsets \(tagsets), titles \(titles), links \(links)"
        }
    }

    /// A file the leak check searches, with the text of the checked-in fixture it was edited from (its manifest
    /// `derivedFrom`), if any: what that text shows is let through in this file, and nowhere else. With
    /// `allowsPublicWords`, a bare tag that some public text shows is an ordinary word here and let through too (for
    /// the repository's code and docs; never for fixtures). Printing, debug-printing or dumping one shows only `file`.
    public struct LeakSearchFile: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let file: String
        public let text: String
        public let derivedFromText: String?
        public let allowsPublicWords: Bool

        public init(file: String, text: String, derivedFromText: String? = nil, allowsPublicWords: Bool = false) {
            self.file = file
            self.text = text
            self.derivedFromText = derivedFromText
            self.allowsPublicWords = allowsPublicWords
        }

        public var description: String { "LeakSearchFile(\(file))" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["file": file], displayStyle: .struct) }
    }

    /// The values of the private pages, by kind, lower-cased (ASCII). Holds the real values when given the real
    /// pages: never `#expect` on it or print it.
    struct LocalValues {
        /// Namespaced tag names, "ns:tag".
        var tagNames = Set<String>()
        /// The tags without their namespace.
        var bareTags = Set<String>()
        var tagsets = Set<String>()
        var titles = Set<String>()
        var links = Set<String>()

        /// Every value once.
        var all: [String] { Array(tagNames.union(bareTags).union(tagsets).union(titles).union(links)) }

        /// Whether `token` is spelled as a tag (`leakForms(of:isTag:)`).
        func isTag(_ token: String) -> Bool { tagNames.contains(token) || bareTags.contains(token) }

        var counts: LocalValueCounts {
            LocalValueCounts(
                tagNames: tagNames.count + bareTags.count, tagsets: tagsets.count, titles: titles.count,
                links: links.count
            )
        }
    }

    /// A `title` attribute, its value quoted either way (group 1 or 2).
    private static let titleAttribute = compile(
        #"(?<![A-Za-z0-9_-])title\s*=\s*(?:"([^"]*)"|'([^']*)')"#, .caseInsensitive
    )

    /// A namespaced tag name as mytags pages title their tags: a lower-case namespace, ":", then the tag (group 1).
    /// The page's other titles (its tips, the weight inputs) do not start that way and never match.
    private static let namespacedTag = compile(#"\A[a-z]+:(.+)\z"#, .dotMatchesLineSeparators)

    /// mytags' tagset chooser: the `select` whose `onchange` mentions "tagset"; its options in group 1.
    private static let tagsetSelect = compile(
        #"<select\b(?=[^>]*\bonchange\s*=\s*["'][^"']*tagset)[^>]*>(.*?)</select>"#,
        [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// An option's text (group 1).
    private static let optionText = compile(#"<option\b[^>]*>([^<]*)</option>"#, .caseInsensitive)

    /// The tag count the tagset chooser puts after each name, " (47)".
    private static let tagsetCount = compile(#"\s*\(\d+\)\s*\z"#)

    /// The name the site gives a new tagset.
    private static let defaultTagsetName = compile(#"\ATagset #\d+\z"#, .caseInsensitive)

    /// A gallery title on a list page: the text of the element whose class has the token `glink` (group 1).
    private static let galleryTitle = compile(
        #"<[A-Za-z][A-Za-z0-9]*\b(?=[^>]*\bclass\s*=\s*(?:"(?:[^"]*\s)?glink(?:\s[^"]*)?""#
            + #"|'(?:[^']*\s)?glink(?:\s[^']*)?'|glink(?=[\s>])))[^>]*>([^<]*)<"#,
        .caseInsensitive
    )

    /// A gallery link's `/g/<gid>/<token>/` (any `urlSeparator`; the trailing one may be missing): the gid in group 1,
    /// the token of 10 hex digits in group 2.
    private static let galleryLink = compile(
        #"\#(urlSeparator)g\#(urlSeparator)(\d+)\#(urlSeparator)([0-9A-Fa-f]{10})(?![0-9A-Za-z])"#, .caseInsensitive
    )

    /// A token for a gallery link, as the leak check writes it: `/g/<gid>/<token>/`.
    private static let galleryLinkToken = compile(#"\A/g/(\d+)/([0-9a-f]{10})/\z"#)

    /// A character reference: decimal (group 1), hex (group 2) or one of the named ones in `namedReferences` (group 3).
    private static let characterReference = compile(
        #"&(?:#([0-9]{1,7})|#[xX]([0-9A-Fa-f]{1,6})|(amp|lt|gt|quot|apos));"#
    )

    private static let namedReferences = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]

    /// The text of the first group of each match of `regex` in `text` that takes part, character references resolved
    /// and trimmed; empty ones dropped.
    private static func capturedTexts(_ regex: NSRegularExpression, in text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let groups = 1..<max(match.numberOfRanges, 1)
            let range = groups.lazy.compactMap { Range(match.range(at: $0), in: text) }.first
            let value = range.map { htmlUnescaped(String(text[$0])).trimmingCharacters(in: .whitespacesAndNewlines) }
            return value?.isEmpty == false ? value : nil
        }
    }

    /// What the leak check looks for, from the private pages:
    /// - mytags pages: every namespaced tag name ("ns:tag", from the `title` attributes) and its bare tag, and every
    ///   tagset name in the tagset chooser (its tag count dropped) other than the site's default "Tagset #<n>";
    /// - favorites and watched pages: every gallery link `/g/<gid>/<token>/` and every gallery title (`glink`).
    ///
    /// Holds the real values when given the real pages: never `#expect` on it or print it.
    static func localValues(myTags: [String], lists: [String]) -> LocalValues {
        var values = LocalValues()
        for page in myTags {
            for title in capturedTexts(titleAttribute, in: page) {
                let whole = NSRange(title.startIndex..., in: title)
                guard let tag = namespacedTag.firstMatch(in: title, range: whole),
                      let bareRange = Range(tag.range(at: 1), in: title) else { continue }
                let bare = title[bareRange].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !bare.isEmpty else { continue }
                values.tagNames.insert(asciiLowercased(title))
                values.bareTags.insert(asciiLowercased(bare))
            }
            for options in tagsetSelect.matches(in: page, range: NSRange(page.startIndex..., in: page)) {
                guard let range = Range(options.range(at: 1), in: page) else { continue }
                for option in capturedTexts(optionText, in: String(page[range])) {
                    let name = tagsetCount.stringByReplacingMatches(
                        in: option, range: NSRange(option.startIndex..., in: option), withTemplate: ""
                    )
                    let whole = NSRange(name.startIndex..., in: name)
                    let isDefault = defaultTagsetName.firstMatch(in: name, range: whole) != nil
                    if !name.isEmpty, !isDefault { values.tagsets.insert(asciiLowercased(name)) }
                }
            }
        }
        for page in lists {
            for match in galleryLink.matches(in: page, range: NSRange(page.startIndex..., in: page)) {
                guard let gid = Range(match.range(at: 1), in: page),
                      let token = Range(match.range(at: 2), in: page) else { continue }
                values.links.insert("/g/\(page[gid])/\(asciiLowercased(String(page[token])))/")
            }
            for title in capturedTexts(galleryTitle, in: page) { values.titles.insert(asciiLowercased(title)) }
        }
        return values
    }

    /// How many values of each kind `myTags` and `lists` hold (see `localValues`).
    public static func localValueCounts(myTags: [String], lists: [String]) -> LocalValueCounts {
        localValues(myTags: myTags, lists: lists).counts
    }

    /// The local leak check: one `localleak` violation per line of each file that holds a value of the private pages
    /// (`localValues`) its `derivedFromText` does not show; a file without one lets nothing through, except that with
    /// `allowsPublicWords` a bare tag that one of `publicTexts` shows counts as an ordinary word. Never reports the
    /// value.
    public static func localLeakViolations(
        myTags: [String], lists: [String], publicTexts: [String] = [], searching files: [LeakSearchFile]
    ) -> [HygieneViolation] {
        let values = localValues(myTags: myTags, lists: lists)
        let tokens = values.all
        guard !tokens.isEmpty else { return [] }
        let forms = { (token: String) in leakForms(of: token, isTag: values.isTag(token)) }
        let every = LeakMatcher(tokens: tokens, forms: forms)
        var publicWords = Set<Int>()
        if files.contains(where: \.allowsPublicWords) {
            for text in publicTexts {
                publicWords.formUnion(every.tokensFound(in: text).filter { values.bareTags.contains(tokens[$0]) })
            }
        }
        // One matcher per set of let-through values; most files share the empty set or the public words.
        var matchers: [Set<Int>: LeakMatcher] = [[]: every]
        return files.flatMap { item in
            var shown = item.allowsPublicWords ? publicWords : []
            if let source = item.derivedFromText { shown.formUnion(every.tokensFound(in: source)) }
            let matcher = matchers[shown] ?? LeakMatcher(
                tokens: tokens.indices.filter { !shown.contains($0) }.map { tokens[$0] }, forms: forms
            )
            matchers[shown] = matcher
            return matcher.lines(in: item.text).map { HygieneViolation(file: item.file, rule: localLeakRule, line: $0) }
        }
    }

    /// Values that only the local private pages show: namespaced tag names ("ns:tag" and the bare tag) from the
    /// title attributes in mytags pages, and /g/<gid>/<token>/ links from favorites and watched pages, minus any
    /// that also appear in `publicTexts`. Also the tagset names and gallery titles of `localValues`.
    ///
    /// A value appears in a text when the leak check would find it there, in any of the spellings it looks for, so a
    /// text that spells a tag or a gallery another way still shows it, and a longer tag or another gallery does not.
    /// Holds the real values when given the real pages: never `#expect` on it or print it; take its `count`, or hand
    /// it to `leakViolations`. Not public for that reason.
    static func localOnlyTokens(myTags: [String], lists: [String], publicTexts: [String]) -> Set<String> {
        let values = localValues(myTags: myTags, lists: lists)
        let tokens = values.all
        guard !tokens.isEmpty, !publicTexts.isEmpty else { return Set(tokens) }
        let matcher = LeakMatcher(tokens: tokens) { leakForms(of: $0, isTag: values.isTag($0)) }
        var shown = Set<Int>()
        for text in publicTexts { shown.formUnion(matcher.tokensFound(in: text)) }
        return Set(tokens.indices.filter { !shown.contains($0) }.map { tokens[$0] })
    }

    /// One violation per line holding any token (case-insensitive); never the token itself.
    ///
    /// Each token is searched for in the spellings `leakForms(of:isTag:)` gives, every token other than a gallery link
    /// spelled as a tag. An occurrence must not touch an ASCII letter or digit on a side where the spelling has one,
    /// except right after an escape (`%XX`, `\uXXXX`, `\b \f \n \r \t`), as for word secrets; any other character (`_`,
    /// `:`, `/`, a quote, a non-ASCII letter) is a boundary.
    public static func leakViolations(in text: String, file: String, tokens: Set<String>) -> [HygieneViolation] {
        guard !tokens.isEmpty else { return [] }
        return LeakMatcher(tokens: Array(tokens)) { leakForms(of: $0, isTag: true) }.lines(in: text).map { line in
            HygieneViolation(file: file, rule: localLeakRule, line: line)
        }
    }

    /// The spellings the leak check searches for.
    /// - A gallery link `/g/<gid>/<token>/`: the token on its own (so `t=<token>`, `token=<token>`, `var token`,
    ///   JSON in any layout and `&#47;` separators too), `<gid>/<token>` in every `encodedForms` spelling (`/g/` and
    ///   `/mpv/` links on any host, `/` written as `\/` or `%2F`), and the API's compact JSON pairs `<gid>,"<token>"`
    ///   (`gidlist`) and `"gid":<gid>,"token":"<token>"` (`gmetadata`). A token is 40 random bits, so another value
    ///   matching it by chance is not a concern.
    /// - Any other value: every `encodedForms` spelling; for a tag (`isTag`) with spaces, also with them written as
    ///   `_` (gallery pages' tag ids) in every spelling, or as `+` (`/tag/` links).
    private static func leakForms(of token: String, isTag: Bool) -> [String] {
        let whole = NSRange(token.startIndex..., in: token)
        if let link = galleryLinkToken.firstMatch(in: token, range: whole),
           let gid = Range(link.range(at: 1), in: token), let key = Range(link.range(at: 2), in: token) {
            let (gid, key) = (token[gid], token[key])
            return [String(key)] + variants(of: "\(gid)/\(key)")
                + [#"\#(gid),"\#(key)""#, #""gid":\#(gid),"token":"\#(key)""#]
        }
        var forms = variants(of: token)
        if isTag, token.contains(" ") {
            forms += variants(of: token.replacingOccurrences(of: " ", with: "_"))
            forms.append(token.replacingOccurrences(of: " ", with: "+"))
        }
        return forms
    }

    /// `value` with its character references resolved: decimal, hex, and `&amp; &lt; &gt; &quot; &apos;`. Anything
    /// else, including a reference to no valid character, stays as written.
    private static func htmlUnescaped(_ value: String) -> String {
        var result = ""
        var rest = value.startIndex
        for match in characterReference.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let range = Range(match.range, in: value) else { continue }
            let decimal = Range(match.range(at: 1), in: value).flatMap { UInt32(value[$0]) }
            let hex = Range(match.range(at: 2), in: value).flatMap { UInt32(value[$0], radix: 16) }
            let named = Range(match.range(at: 3), in: value).flatMap { namedReferences[String(value[$0])] }
            guard let character = named ?? (decimal ?? hex).flatMap(Unicode.Scalar.init).map({ String(Character($0)) })
            else { continue }
            result += value[rest..<range.lowerBound] + character
            rest = range.upperBound
        }
        return result + value[rest...]
    }

    /// `value` with `A-Z` lower-cased and every other character unchanged, as `LeakMatcher` compares text.
    private static func asciiLowercased(_ value: String) -> String {
        String(decoding: value.utf8.map(LeakMatcher.lowercased), as: UTF8.self)
    }
}

/// Maps UTF-16 offsets (as in `NSRange`) to 1-based line numbers.
private struct LineIndex {
    /// UTF-16 offsets of every "\n", ascending.
    private let newlines: [Int]

    init(_ text: String) {
        var offsets: [Int] = []
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A {
            offsets.append(offset)
        }
        newlines = offsets
    }

    /// One plus the number of newlines before `offset`.
    func line(at offset: Int) -> Int {
        var low = 0
        var high = newlines.count
        while low < high {
            let mid = (low + high) / 2
            if newlines[mid] < offset { low = mid + 1 } else { high = mid }
        }
        return low + 1
    }
}

/// Finds the spellings of many tokens at once, ignoring ASCII case: a byte trie over the lower-cased UTF-8 of every
/// spelling, so hundreds of tokens over megabytes of fixtures take one pass per text. Boundaries as described at
/// `FixtureHygiene.leakViolations(in:file:tokens:)`.
private struct LeakMatcher {
    /// Each node's children by byte; node 0 is the root.
    private var children: [[UInt8: Int]] = [[:]]
    /// For each node, the tokens (indices into the `tokens` given to `init`) one of whose spellings ends there.
    private var ends: [[Int]] = [[]]

    init(tokens: [String], forms: (String) -> [String]) {
        for (index, token) in tokens.enumerated() {
            for form in forms(token) where !form.isEmpty {
                var node = 0
                for byte in form.utf8.map(Self.lowercased) {
                    if let next = children[node][byte] {
                        node = next
                    } else {
                        children.append([:])
                        ends.append([])
                        children[node][byte] = children.count - 1
                        node = children.count - 1
                    }
                }
                if !ends[node].contains(index) { ends[node].append(index) }
            }
        }
    }

    /// Indices of the tokens with an occurrence in `text`.
    func tokensFound(in text: String) -> Set<Int> {
        let bytes = text.utf8.map(Self.lowercased)
        var found = Set<Int>()
        for start in bytes.indices { found.formUnion(tokens(at: start, in: bytes)) }
        return found
    }

    /// The 1-based lines of `text` holding an occurrence of any token, ascending, each once. An occurrence counts on
    /// the line where it starts.
    func lines(in text: String) -> [Int] {
        let bytes = text.utf8.map(Self.lowercased)
        var lines: [Int] = []
        var line = 1
        var start = 0
        while start < bytes.count {
            if bytes[start] == UInt8(ascii: "\n") {
                line += 1
            } else if !tokens(at: start, in: bytes).isEmpty {
                lines.append(line)
                // One per line: go on at the line's end.
                while start < bytes.count, bytes[start] != UInt8(ascii: "\n") { start += 1 }
                continue
            }
            start += 1
        }
        return lines
    }

    /// The tokens one of whose spellings occurs at `start` of the lower-cased `bytes`, within the boundaries.
    private func tokens(at start: Int, in bytes: [UInt8]) -> [Int] {
        guard var node = children[0][bytes[start]] else { return [] }
        if Self.isAlphanumeric(bytes[start]), !Self.isBoundary(before: start, in: bytes) { return [] }
        var found: [Int] = []
        var end = start + 1
        while true {
            if !ends[node].isEmpty,
               !Self.isAlphanumeric(bytes[end - 1]) || end == bytes.count || !Self.isAlphanumeric(bytes[end]) {
                found += ends[node]
            }
            guard end < bytes.count, let next = children[node][bytes[end]] else { return found }
            node = next
            end += 1
        }
    }

    static func lowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 0x20 : byte
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    /// Whether a spelling that starts with a letter or digit may start at `start`: nothing, or no ASCII letter or
    /// digit, comes right before it, or an escape ends there (a complete `%XX`, JSON's `\uXXXX` or `\b \f \n \r \t`),
    /// as `FixtureHygiene.escapeBoundary` allows for word secrets.
    private static func isBoundary(before start: Int, in bytes: [UInt8]) -> Bool {
        guard start > 0, isAlphanumeric(bytes[start - 1]) else { return true }
        if start >= 3, bytes[start - 3] == UInt8(ascii: "%"),
           isHexDigit(bytes[start - 2]), isHexDigit(bytes[start - 1]) {
            return true
        }
        if start >= 6, bytes[start - 6] == UInt8(ascii: "\\"), bytes[start - 5] == UInt8(ascii: "u"),
           bytes[(start - 4)..<start].allSatisfy(isHexDigit) {
            return true
        }
        return start >= 2 && bytes[start - 2] == UInt8(ascii: "\\") && "bfnrt".utf8.contains(bytes[start - 1])
    }
}
