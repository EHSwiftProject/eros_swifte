import EHFixtures
import Foundation
import Synchronization

/// Rewrites captured text so it passes `FixtureHygiene`'s checks. Every rewrite uses the checks' own matches
/// (`violatingCaptures`, `secretMatches`), so what the sanitizer fixes is exactly what the checks flag.
/// Printing, debug-printing or dumping a sanitizer shows only counts.
public struct Sanitizer: Sendable {
    /// `SecretSet.all`, longest value first (ties by kind, then value) so the output does not depend on set order.
    private let secrets: [KnownSecret]
    /// Shared by copies of this sanitizer, so an address gets the same stand-in in every text.
    private let standIns: IPv4StandIns

    public init(secrets: SecretSet) {
        self.secrets = secrets.all.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.value < rhs.value
        }
        standIns = IPv4StandIns(discovered: secrets.ipv4InOrder)
    }

    /// The structural rules whose flagged values are masked in place (`mask`), in the order they are applied.
    /// Every structural rule but `ipv4` (stand-ins), the two note rules (placeholders), `tagstyle` (the attribute is
    /// deleted), `trackerurl` (check only: it flags tracker URL shapes the other rules do not know, so the writer
    /// refuses them), `filteredlist` (check only: no rewrite brings back what the filters hid), `favmark` (check
    /// only: a page showing the account's favorites is refused rather than rewritten) and `accountmark` (check only:
    /// a page showing the account's own ratings, tag votes or comments is refused rather than rewritten) is here.
    static let maskedRules = [
        FixtureHygiene.apikeyRule, FixtureHygiene.apiuidRule, FixtureHygiene.cookieRule,
        FixtureHygiene.torrentKeyRule, FixtureHygiene.torrentLinkRule, FixtureHygiene.trackerRule,
        FixtureHygiene.homeStatsRule, FixtureHygiene.announceRule, FixtureHygiene.filteredRule,
        FixtureHygiene.fundsRule, FixtureHygiene.forumKeyRule,
    ]

    /// Applies, in order:
    /// 1. non-empty favorite notes become placeholders, and the inline `style` of every tag element (`tagstyle`) is
    ///    deleted;
    /// 2. the values of `maskedRules` that the check flags are masked: apikey, apiuid, login cookies, the torrent key,
    ///    the uid, keys and numbers of tracker links and other announce URLs, the account statistics on `home.php`,
    ///    the "Filtered N galleries" count, the archiver's funds and the forum's session keys;
    /// 3. every encoded form of every known secret becomes the same encoding of its mask (so HTML entities, numeric
    ///    character references and JSON escapes stay valid);
    /// 4. discovered foreign IPv4 addresses become their 203.0.113.0/24 stand-ins;
    /// 5. foreign addresses left over from masking (a secret "node-10.0.0.5" masks to "aaaa-11.1.1.1") get the next
    ///    free stand-ins, numbered after the discovered ones.
    ///
    /// Matching ignores case throughout. Past 254 stand-ins an address is left as it is (`sanitizeCaptures` then
    /// throws, and the writer's check would reject it).
    public func sanitize(_ text: String) -> String {
        sanitize(text, exempting: [])
    }

    /// As `sanitize(_:)`, but leaves alone the structural rewrites of the rules in `exemptRules` (rule names as in
    /// `FixtureHygiene.structuralRuleNames`). Secrets and IP stand-ins are still replaced. Only `tagstyle` (a
    /// deletion) has a rewrite that can be skipped: the other rules only mask values, and masking never removes
    /// what an exemption stands for (a constructed "Filtered N galleries" line keeps its count masked).
    public func sanitize(_ text: String, exempting exemptRules: Set<String>) -> String {
        var text = text
        let favnotes = FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.favnoteRule, in: text)
        text = Self.rewrite(text, favnotes.map { ($0, "[favnote]") })
        let glfnotes = FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.glfnoteRule, in: text)
        text = Self.rewrite(text, glfnotes.map { ($0, "Note: [favnote]") })
        // The whole attribute goes: a tag having a style at all tells it is in the account's My Tags.
        if !exemptRules.contains(FixtureHygiene.tagStyleRule) {
            let tagStyles = FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.tagStyleRule, in: text)
            text = Self.rewrite(text, tagStyles.map { ($0, "") })
        }
        for rule in Self.maskedRules {
            let values = FixtureHygiene.violatingCaptures(ofRule: rule, in: text)
            text = Self.rewrite(text, values.map { ($0, Self.maskStructural(String(text[$0]))) })
        }
        for secret in secrets {
            let maskedForms = FixtureHygiene.encodedForms(of: Self.mask(secret.value))
            let matches = FixtureHygiene.secretMatches(of: secret, in: text)
            text = Self.rewrite(text, matches.map { ($0.range, maskedForms[$0.form]) })
        }
        text = rewriteAddresses(in: text) { standIns.discovered($0) }
        text = rewriteAddresses(in: text) { standIns.standIn(for: $0) }
        return text
    }

    /// True once some address could not get a stand-in: more than 254 discovered and left-over addresses in all.
    var ranOutOfStandIns: Bool { standIns.ranOut }

    /// Replaces each Character: ASCII digits with "1", ASCII lowercase with "a", ASCII uppercase with "A"; any
    /// other letter with "A" if uppercase, else "a"; any other number with "1"; everything else stays. The
    /// Character count is unchanged, and a hex string stays hex.
    public static func mask(_ value: String) -> String {
        var result = ""
        for character in value {
            if let ascii = character.asciiValue, character.isASCII {
                switch ascii {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): result.append("1")
                case UInt8(ascii: "a")...UInt8(ascii: "z"): result.append("a")
                case UInt8(ascii: "A")...UInt8(ascii: "Z"): result.append("A")
                default: result.append(character)
                }
            } else if character.isLetter {
                result.append(character.isUppercase ? "A" : "a")
            } else if character.isNumber {
                result.append("1")
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// `mask(value)` for a value a structural rule judges (one of `maskedRules`). A dotted quad in the mask
    /// ("x-1.0.1.1-y" masks to "a-1.1.1.1-a") would read as a foreign address, and a 203.0.113.x stand-in is not
    /// masked text, so the quad's digits are masked as "a" instead: only that satisfies both checks.
    private static func maskStructural(_ value: String) -> String {
        let masked = mask(value)
        let quads = FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.ipv4Rule, in: masked)
        return rewrite(masked, quads.map { ($0, masked[$0].replacingOccurrences(of: "1", with: "a")) })
    }

    /// Replaces each foreign IPv4 address for which `standIn` has a value.
    private func rewriteAddresses(in text: String, _ standIn: (String) -> String?) -> String {
        let addresses = FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.ipv4Rule, in: text)
        return Self.rewrite(text, addresses.compactMap { range in standIn(String(text[range])).map { (range, $0) } })
    }

    /// `text` with each range replaced; the ranges are ascending and do not overlap, as regex matches are.
    private static func rewrite(_ text: String, _ replacements: [(Range<String.Index>, String)]) -> String {
        guard !replacements.isEmpty else { return text }
        var result = ""
        var position = text.startIndex
        for (range, replacement) in replacements {
            result += text[position..<range.lowerBound]
            result += replacement
            position = range.upperBound
        }
        result += text[position...]
        return result
    }
}

extension Sanitizer: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "Sanitizer(secrets: \(secrets.count), ipv4 stand-ins: \(standIns.count))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["secrets": secrets.count, "ipv4StandIns": standIns.count], displayStyle: .struct)
    }
}

/// Stand-ins for foreign IPv4 addresses: the i-th address (from 1) becomes 203.0.113.i, up to 254. Discovered
/// addresses are numbered first, in discovery order; addresses left over from masking follow as they are met.
final class IPv4StandIns: Sendable {
    static let capacity = 254

    private struct State {
        var standIns: [String: String] = [:]
        var ranOut = false
    }

    private let discoveredStandIns: [String: String]
    private let state: Mutex<State>

    init(discovered: [String]) {
        var standIns: [String: String] = [:]
        for (index, address) in discovered.prefix(Self.capacity).enumerated() {
            standIns[address] = "203.0.113.\(index + 1)"
        }
        discoveredStandIns = standIns
        state = Mutex(State(standIns: standIns, ranOut: discovered.count > Self.capacity))
    }

    /// The stand-in of a discovered address, or nil.
    func discovered(_ address: String) -> String? {
        discoveredStandIns[address]
    }

    /// The stand-in for `address`, giving a new address the next free one; nil once all are taken.
    func standIn(for address: String) -> String? {
        state.withLock { state in
            if let known = state.standIns[address] { return known }
            guard state.standIns.count < Self.capacity else {
                state.ranOut = true
                return nil
            }
            let standIn = "203.0.113.\(state.standIns.count + 1)"
            state.standIns[address] = standIn
            return standIn
        }
    }

    var count: Int { state.withLock { $0.standIns.count } }
    var ranOut: Bool { state.withLock { $0.ranOut } }
}

/// Why captures cannot be sanitized.
public enum SanitizeError: Error, Equatable {
    /// The body of the fixture at this path is not valid UTF-8.
    case notUTF8(String)
    /// More than 254 distinct foreign IPv4 addresses, discovered or left over from masking: 203.0.113.0/24 cannot
    /// stand in for them one to one.
    case tooManyIPAddresses
    /// Public pages show the account as uploader, torrent uploader or commenter, or could not be checked for it (see
    /// `OwnContentCheck`); never holds a value.
    case ownContent([HygieneViolation])
}

/// Sanitizes a capture run. First discovers secrets in every body, URL and `Location` header, so a secret found on
/// one page is also removed from all others; then rewrites them.
/// - Returns: The sanitized captures, in input order, and the secrets used (for `FixtureWriter`). Both print
///   without values.
/// - Throws: `SanitizeError`; `.ownContent` when a public page shows the account as uploader, torrent uploader or
///   commenter, or cannot be checked for it, judged on the unmasked values before anything is masked.
public func sanitizeCaptures(
    _ raws: [RawCapture],
    credentials: CaptureCredentials,
    extraSecrets: [KnownSecret]
) throws -> (captures: [SanitizedCapture], secrets: SecretSet) {
    var bodies: [String] = []
    for raw in raws {
        guard let body = String(validating: raw.body, as: UTF8.self) else {
            throw SanitizeError.notUTF8(raw.fixturePath)
        }
        bodies.append(body)
    }

    var secrets = SecretSet(
        namedCredentials: credentials.namedSecrets.map { (name: $0.name, secret: $0.secret) },
        extraSecrets: extraSecrets
    )
    for (raw, body) in zip(raws, bodies) {
        secrets.discover(in: body)
        secrets.discover(in: raw.url.absoluteString)
        if let location = raw.header("Location") { secrets.discover(in: location) }
    }
    guard secrets.ipv4InOrder.count <= IPv4StandIns.capacity else { throw SanitizeError.tooManyIPAddresses }

    let identity = OwnIdentity(
        secrets: secrets,
        memberIDs: credentials.namedSecrets.filter { $0.name == CaptureCredentials.memberIDVariable }.map(\.secret.value)
    )
    let ownContent = OwnContentCheck.findings(in: raws, identity: identity)
    guard ownContent.isEmpty else { throw SanitizeError.ownContent(ownContent) }

    let sanitizer = Sanitizer(secrets: secrets)
    let timestamp = Date.ISO8601FormatStyle(timeZone: .gmt)
    let captures = zip(raws, bodies).map { raw, body in
        let entry = FixtureEntry(
            path: raw.fixturePath,
            site: raw.site,
            source: .captured,
            method: raw.method,
            url: sanitizer.sanitize(raw.url.absoluteString),
            status: raw.status,
            contentType: raw.header("Content-Type"),
            location: raw.header("Location").map(sanitizer.sanitize),
            setCookieNames: raw.setCookieNames,
            capturedAt: timestamp.format(raw.capturedAt)
        )
        return SanitizedCapture(entry: entry, body: Data(sanitizer.sanitize(body).utf8))
    }
    guard !sanitizer.ranOutOfStandIns else { throw SanitizeError.tooManyIPAddresses }
    return (captures, secrets)
}
