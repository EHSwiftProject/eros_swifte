import EHFixtures
import Foundation

/// Everything that must not reach a fixture: credentials, extra secrets (e.g. from the local secrets file) and
/// personal data discovered in captured pages, plus the foreign IPv4 addresses seen, in order.
/// `warnings` describe secrets that cannot be fully handled; they never contain a value. Printing, debug-printing
/// or dumping a set shows only counts and warnings.
public struct SecretSet: Sendable {
    /// Credentials, extra secrets and discovered secrets.
    public private(set) var all: Set<KnownSecret>
    /// What the local secrets file keeps: discovered and extra secrets plus the credentials of
    /// `FixtureHygiene.persistedCredentialVariables` (username, member id), minus any value that is another
    /// credential's and the discovered forum keys (a token is never kept).
    public private(set) var persistable: Set<KnownSecret>
    /// Foreign IPv4 addresses (see `FixtureHygiene.ipv4Rule`) in order of first discovery.
    public private(set) var ipv4InOrder: [String]
    /// Explanations, each at most once; never a value.
    public private(set) var warnings: [String]

    /// Values of the credentials that are not persisted.
    private let credentialValues: Set<String>
    private var seenIPv4: Set<String> = []
    /// All-digit tracker values (`FixtureHygiene.trackerRule`) seen so far.
    private var trackerNumbers: Set<String> = []
    /// Gallery ids seen so far in `/g/<gid>/`, `/mpv/<gid>/`, `/s/<key>/<gid>-<page>` and `gid=`/`"gid":` forms.
    private var galleryIDs: Set<String> = []
    /// Tracker numbers this set added itself, and takes back if one later turns out to be a gallery id.
    private var adoptedTrackerNumbers: Set<String> = []

    /// Discovered keys (the torrent key, a link key, a tracker key segment) shorter than this are only masked in
    /// place: a short value is more likely a word a rule picked up than a key. The real ones have 10 to 19.
    static let minimumDiscoveredKeyLength = 8
    /// Discovered numbers (a link uid, a tracker number) shorter than this are only masked in place: a short number
    /// is more likely a year, a count or a page. The real ones have 7 digits; the account's own uid is a credential
    /// and searched for anyway.
    static let minimumDiscoveredNumberLength = 5

    public init(credentialSecrets: [KnownSecret], extraSecrets: [KnownSecret]) {
        self.init(namedCredentials: credentialSecrets.map { (nil, $0) }, extraSecrets: extraSecrets)
    }

    /// - Parameter namedCredentials: Credentials with the variable each came from, used to name it in warnings.
    init(namedCredentials: [(name: String?, secret: KnownSecret)], extraSecrets: [KnownSecret]) {
        all = []
        persistable = []
        ipv4InOrder = []
        warnings = []
        let isPersisted = { (name: String?) in name.map(FixtureHygiene.persistedCredentialVariables.contains) ?? false }
        credentialValues = Set(namedCredentials.filter { !isPersisted($0.name) }.map(\.secret.value))
        for (name, secret) in namedCredentials where !secret.value.isEmpty {
            let label = name ?? "a credential"
            if Self.isShortLiteral(secret) {
                warn("\(label) is shorter than \(FixtureHygiene.minimumLiteralLength) characters: "
                    + "it is masked only where it appears as a cookie value, not searched for elsewhere")
            }
            warnIfMaskingFallsShort(secret, label: label)
            all.insert(secret)
            // A set, so a member id also found in a personal link is kept once.
            if isPersisted(name) { persistable.insert(secret) }
        }
        for secret in extraSecrets where !secret.value.isEmpty {
            if Self.isShortLiteral(secret) {
                warn("an extra secret is shorter than \(FixtureHygiene.minimumLiteralLength) characters: "
                    + "it is not searched for")
            }
            warnIfMaskingFallsShort(secret, label: "an extra secret")
            all.insert(secret)
            if !credentialValues.contains(secret.value) { persistable.insert(secret) }
        }
    }

    // MARK: Discovery

    /// The longest inner markup of a `#profilename` element that still counts as a name.
    static let maximumProfileNameMarkup = 256
    /// Pieces of a name split by markup shorter than this are not collected as secrets of their own.
    static let minimumNamePartLength = 4

    /// A `div` whose `id` is `profilename` (other attributes in any order, either quote or none), up to its first
    /// `</div>`; group 1 is the inner markup, which may nest inline elements such as `<font>`. The inner markup is
    /// capped at `maximumProfileNameMarkup` characters: longer is not a nickname, and an unbounded lazy match would
    /// make a page full of unclosed `<div id="profilename">` take quadratic time.
    private static let profileName = compile(
        #"<div\b(?=[^>]*(?<![\w-])id\s*=\s*["']?profilename["'\s>/])[^>]*>((?:(?!</div>)[\s\S]){0,"#
            + "\(maximumProfileNameMarkup)"
            + #"})</div>"#
    )
    private static let htmlTag = compile(#"<[^>]*>"#, .dotMatchesLineSeparators)
    private static let glfnoteText = compile(#"Note: (.+)"#, .dotMatchesLineSeparators)
    /// A gallery id: in a gallery, multi-page viewer or image page path (JSON-escaped slashes too), or as a `gid`
    /// parameter, attribute or JSON key.
    private static let galleryID = compile(
        #"\\?/(?:g|mpv)\\?/(\d+)\\?/|\\?/s\\?/[0-9a-f]{10}\\?/(\d+)-\d+|\bgid["']?\s*[:=]\s*["']?(\d+)"#
    )

    /// The non-empty names in `#profilename` elements: the text inside, tags removed, HTML-unescaped and trimmed. The one rule both the discovery above
    /// and the offline import use to find the profile name, so a page the import accepts is a page whose name is discovered.
    static func profileNames(in text: String) -> [String] {
        profileNameTexts(in: text).map(\.full).filter { !$0.isEmpty }
    }

    /// Each `#profilename` element's whole name and, only when markup splits it so that the whole name does not appear
    /// as continuous text anywhere in `text` (in any of its encoded forms), the text pieces between the tags, all
    /// unescaped and trimmed: a name like `Tom <i>Jerry</i>` never appears whole in the page, so the pieces are what
    /// must be masked. A piece shorter than `minimumNamePartLength` is dropped: it would be a common word ("The"),
    /// and a word in the persistent secrets file masks that word in every fixture.
    private static func profileNameTexts(in text: String) -> [(full: String, parts: [String])] {
        captures(of: profileName, in: text).map { inner in
            let unescape = { (piece: String) in htmlUnescaped(piece).trimmingCharacters(in: .whitespacesAndNewlines) }
            let range = NSRange(inner.startIndex..., in: inner)
            let full = unescape(htmlTag.stringByReplacingMatches(in: inner, range: range, withTemplate: ""))
            let parts = htmlTag.stringByReplacingMatches(in: inner, range: range, withTemplate: "\u{0}")
                .split(separator: "\u{0}").map { unescape(String($0)) }.filter { !$0.isEmpty }
            let appears = FixtureHygiene.encodedForms(of: full).contains { text.localizedCaseInsensitiveContains($0) }
            let useful = parts.filter { $0.count >= minimumNamePartLength }
            return (full, parts.count > 1 && !appears ? useful : [])
        }
    }

    private static func compile(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Constant patterns, exercised by the tests.
        try! NSRegularExpression(pattern: pattern, options: options.union(.caseInsensitive))
    }

    /// Adds the personal data found in `text`: the apikey (literal), apiuid (numeric), the torrent key, the uid and
    /// key of personal torrent links and the key segment of tracker links (numeric when all digits, else literal),
    /// tracker numbers (numeric), profile name (word), favorite notes (literal), forum keys (literal, to `all` only:
    /// tokens never go to the secrets file) and foreign IPv4 addresses. All but the profile name come from the same
    /// matches `FixtureHygiene.structuralViolations` flags.
    ///
    /// Some values are only masked in place, not searched for elsewhere:
    /// - a torrent key that does not look like one (see `looksLikeTorrentKey`): a word after the label rather than a
    ///   key, whatever tag it sits in;
    /// - tracker URL keys shorter than `minimumDiscoveredKeyLength` and numbers shorter than
    ///   `minimumDiscoveredNumberLength`;
    /// - anything from announce URLs on other hosts (`FixtureHygiene.announceRule`): `/2024/announce` would
    ///   otherwise rewrite every year 2024;
    /// - `home.php` statistics (short, common numbers);
    /// - a tracker number that equals a gallery id seen in any text so far, before or after (when a gallery has no
    ///   older version, the tracker number is its own public gid; replacing it everywhere would break gallery links).
    ///
    /// Matching ignores case.
    public mutating func discover(in text: String) {
        for range in FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.apikeyRule, in: text) {
            let key = String(text[range])
            if key.unicodeScalars.allSatisfy(Self.isASCIIHexDigit) {
                addDiscovered(KnownSecret(kind: .literal, value: key), label: "a discovered apikey", shortWarning: "a "
                    + "discovered apikey shorter than \(FixtureHygiene.minimumLiteralLength) characters is only masked in place")
            }
        }
        for range in FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.apiuidRule, in: text) {
            addDiscovered(KnownSecret(kind: .numeric, value: String(text[range])), label: "a discovered apiuid")
        }
        for range in FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.torrentKeyRule, in: text) {
            let key = String(text[range])
            // The tag around it proves nothing: a bold word after the label sits in the same tag.
            guard Self.looksLikeTorrentKey(key) else {
                warn("a torrent key shorter than \(Self.minimumDiscoveredKeyLength) characters, or one that reads as a "
                    + "word (not only ASCII letters and digits, or no digit and no capital after the first letter), is "
                    + "only masked in place: it may be a word after the label rather than a key")
                continue
            }
            addDiscovered(KnownSecret(kind: Self.kind(of: key), value: key), label: "a discovered torrent key")
        }
        // Searched for in every text of the run (percent-encoded, in JSON or elsewhere), never written to the secrets
        // file: the session id and log-out key are tokens, like the login cookies.
        for range in FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.forumKeyRule, in: text) {
            addToken(KnownSecret(kind: .literal, value: String(text[range])), label: "a discovered forum key")
        }
        // Only tracker URLs (on ehtracker.org, or download links ending in an info hash): announce URLs on other hosts
        // are `FixtureHygiene.announceRule`'s and only masked in place.
        for range in FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.torrentLinkRule, in: text) {
            addTrackerValue(String(text[range]), label: "a discovered torrent link key or uid", numbersAreSecrets: true)
        }
        for range in FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.trackerRule, in: text) {
            addTrackerValue(String(text[range]), label: "a discovered tracker key", numbersAreSecrets: false)
        }
        for match in Self.galleryID.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for group in 1...3 {
                if let range = Range(match.range(at: group), in: text) { galleryIDs.insert(String(text[range])) }
            }
        }
        reconcileTrackerNumbers()
        for (full, parts) in Self.profileNameTexts(in: text) {
            for unescaped in [full] + parts where !unescaped.isEmpty {
                // A name already masked (in a fixture being sanitized again) is not a new secret.
                guard !Self.isMaskedText(unescaped) else { continue }
                addDiscovered(KnownSecret(kind: .word, value: unescaped), label: "a discovered username")
            }
        }
        for range in FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.favnoteRule, in: text) {
            addNote(String(text[range]))
        }
        for range in FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.glfnoteRule, in: text) {
            for note in Self.captures(of: Self.glfnoteText, in: String(text[range])) {
                addNote(note)
            }
        }
        for range in FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.ipv4Rule, in: text) {
            let address = String(text[range])
            if seenIPv4.insert(address).inserted { ipv4InOrder.append(address) }
        }
    }

    /// A favorite note, unescaped (pages HTML-escape it). The text as it appeared is added too, but only when it is
    /// not simply an encoded form of the unescaped note: replacing "Tom &amp; Jerry" as a secret of its own would
    /// mask the entity into "&aaa;". A note spanning several lines or tab-separated parts also adds each part, so
    /// every part survives the line-based secrets file.
    private mutating func addNote(_ note: String) {
        let raw = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let unescaped = htmlUnescaped(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        var values = [unescaped]
        if !FixtureHygiene.encodedForms(of: unescaped).contains(raw) { values.append(raw) }
        for value in values {
            addDiscovered(KnownSecret(kind: .literal, value: value), label: "a favnote", shortWarning: "a favnote "
                + "shorter than \(FixtureHygiene.minimumLiteralLength) characters is only redacted in place")
            let parts = value.split(whereSeparator: { $0.isNewline || $0 == "\t" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard parts.count > 1 else { continue }
            for part in parts {
                addDiscovered(KnownSecret(kind: .literal, value: part), label: "a line of a favnote", shortWarning: "a line "
                    + "of a multi-line favnote is shorter than \(FixtureHygiene.minimumLiteralLength) characters and is "
                    + "not searched for on its own")
            }
        }
    }

    /// A value of a tracker URL: a key of at least `minimumDiscoveredKeyLength` characters becomes a literal secret,
    /// a number of at least `minimumDiscoveredNumberLength` digits a numeric one (a uid, `numbersAreSecrets`) or a
    /// tracker number candidate (see `reconcileTrackerNumbers`). Shorter ones are only masked in place.
    private mutating func addTrackerValue(_ value: String, label: String, numbersAreSecrets: Bool) {
        if Self.kind(of: value) == .numeric {
            guard value.count >= Self.minimumDiscoveredNumberLength else {
                warn("a tracker uid or number shorter than \(Self.minimumDiscoveredNumberLength) digits is only masked in place")
                return
            }
            if numbersAreSecrets {
                addDiscovered(KnownSecret(kind: .numeric, value: value), label: label)
            } else {
                trackerNumbers.insert(value)
            }
        } else {
            guard value.count >= Self.minimumDiscoveredKeyLength else {
                warn("a tracker key shorter than \(Self.minimumDiscoveredKeyLength) characters is only masked in place")
                return
            }
            addDiscovered(KnownSecret(kind: .literal, value: value), label: label)
        }
    }

    /// Tracker numbers become numeric secrets unless they are gallery ids; one adopted earlier is taken back once a
    /// later text shows it as a gallery id, so the result does not depend on the order of the texts.
    private mutating func reconcileTrackerNumbers() {
        for number in adoptedTrackerNumbers.intersection(galleryIDs) {
            let secret = KnownSecret(kind: .numeric, value: number)
            all.remove(secret)
            persistable.remove(secret)
            adoptedTrackerNumbers.remove(number)
        }
        for number in trackerNumbers.subtracting(galleryIDs).subtracting(adoptedTrackerNumbers).sorted() {
            let secret = KnownSecret(kind: .numeric, value: number)
            // Already known (a credential, an extra secret or another discovery): not this set's to take back.
            guard !all.contains(secret) else { continue }
            addDiscovered(secret, label: "a discovered tracker number")
            adoptedTrackerNumbers.insert(number)
        }
    }

    /// Adds a discovered token to `all` only: searched for in this run, never kept in the secrets file.
    private mutating func addToken(_ secret: KnownSecret, label: String) {
        guard !secret.value.isEmpty, !Self.isShortLiteral(secret) else { return }
        if all.insert(secret).inserted { warnIfMaskingFallsShort(secret, label: label) }
    }

    /// Adds a discovered secret to `all`, and to `persistable` unless its value is a non-persisted credential's. A literal too
    /// short to search for is dropped instead, with `shortWarning`.
    private mutating func addDiscovered(_ secret: KnownSecret, label: String, shortWarning: String? = nil) {
        guard !secret.value.isEmpty else { return }
        // Found another way too, so it stays even if it later turns out to be a gallery id.
        if secret.kind == .numeric { adoptedTrackerNumbers.remove(secret.value) }
        if Self.isShortLiteral(secret) {
            if let shortWarning { warn(shortWarning) }
            return
        }
        if all.insert(secret).inserted { warnIfMaskingFallsShort(secret, label: label) }
        if !credentialValues.contains(secret.value) { persistable.insert(secret) }
    }

    /// Warns, by `label` only, when masking cannot hide `secret` (its mask is itself, so the check will reject any
    /// fixture holding it) or leaves a dotted quad that reads as a foreign address (the sanitizer then gives it a
    /// stand-in, or masks it as letters inside a cookie value).
    private mutating func warnIfMaskingFallsShort(_ secret: KnownSecret, label: String) {
        let masked = Sanitizer.mask(secret.value)
        if masked == secret.value {
            warn("\(label) is unchanged by masking, so any fixture containing it is rejected")
        }
        if !FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.ipv4Rule, in: masked).isEmpty {
            warn("\(label) contains a dotted quad, which masking turns into an address; it is replaced by a "
                + "203.0.113.0/24 stand-in")
        }
    }

    /// Appends `message` unless it is already there. Callers pass explanations only, never a value.
    mutating func warn(_ message: String) {
        if !warnings.contains(message) { warnings.append(message) }
    }

    /// At least `minimumDiscoveredKeyLength` characters, only ASCII letters and digits, and a digit or a capital
    /// letter after the first character, as a random key almost always has. "Downloads" or "Unavailable" after the
    /// label do not qualify; neither does a rare key that is all lowercase letters or capitalized like a word (the
    /// price of not taking words for keys; `torrentkey` still masks it in place).
    static func looksLikeTorrentKey(_ key: String) -> Bool {
        key.count >= minimumDiscoveredKeyLength
            && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            && (key.contains(where: \.isNumber) || key.dropFirst().contains(where: \.isUppercase))
    }

    private static func isShortLiteral(_ secret: KnownSecret) -> Bool {
        secret.kind == .literal && secret.value.count < FixtureHygiene.minimumLiteralLength
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    /// True when the only letters and digits are `1`, `a` and `A`, as `Sanitizer.mask` leaves them.
    private static func isMaskedText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0 == "1" || $0 == "a" || $0 == "A" || !CharacterSet.alphanumerics.contains($0) }
    }

    /// Numeric when the value is all ASCII digits, else literal.
    private static func kind(of value: String) -> SecretKind {
        value.unicodeScalars.allSatisfy(isASCIIDigit) ? .numeric : .literal
    }

    private static func isASCIIHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
    }

    /// Capture group 1 of every match.
    private static func captures(of regex: NSRegularExpression, in text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

// Printing, debug-printing or dumping shows counts and warnings only: the stored addresses and credential values
// must not reach a log.
extension SecretSet: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "SecretSet(all: \(all.count), persistable: \(persistable.count), ipv4: \(ipv4InOrder.count), "
            + "warnings: \(warnings))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "all": all.count, "persistable": persistable.count, "ipv4": ipv4InOrder.count, "warnings": warnings,
            ],
            displayStyle: .struct
        )
    }
}

/// The spellings of `&` that `FixtureHygiene.encodedForms` uses, replaced in one pass so "&amp;#38;" becomes "&#38;",
/// not "&".
private let escapedAmpersand = try! NSRegularExpression(pattern: "&(?:amp|#38|#x26);")

/// Undoes the HTML escaping `FixtureHygiene.encodedForms` applies: `&lt; &gt;`, the spellings of `"` (`&quot;`,
/// `&#34;`, `&#x22;`) and of `'`, and the spellings of `&` (`&amp;`, `&#38;`, `&#x26;`) last so "&amp;lt;" becomes
/// "&lt;", not "<".
func htmlUnescaped(_ text: String) -> String {
    var result = text
    for (entity, character) in [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#34;", "\""), ("&#x22;", "\""), ("&#039;", "'"),
        ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"),
    ] {
        result = result.replacingOccurrences(of: entity, with: character)
    }
    return escapedAmpersand.stringByReplacingMatches(
        in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "&"
    )
}
