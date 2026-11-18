import EHFixtures
import EHParsing
import Foundation
import Testing

@Suite struct SetCookieParserTests {
    private static let fixture = "constructed/eh/login-set-cookie.txt"
    private static let loginURL = URL(string: "https://forums.e-hentai.org/index.php?act=Login&CODE=01")!
    /// One fixed time for every call. It only anchors Max-Age; HTTPCookie dates other expiries from its own clock.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Tolerance for `expiresAt`: HTTPCookie dates a far-future expiry from the moment it parses, so two parses
    /// that straddle a second boundary can differ by one second.
    private static let expiryTolerance: TimeInterval = 2

    /// The header values of the fixture's `Set-Cookie:` lines, in file order.
    private static func headerValues() throws -> [String] {
        let prefix = "Set-Cookie: "
        let lines = try Fixtures.string(fixture).split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.allSatisfy { $0.hasPrefix(prefix) })
        return lines.map { String($0.dropFirst(prefix.count)) }
    }

    /// Each line parsed on its own.
    private static func cookiesLineByLine() throws -> [ParsedCookie] {
        try headerValues().flatMap { value in
            SetCookieParser.cookies(headerFields: ["Set-Cookie": value], url: loginURL, now: now)
        }
    }

    /// Whether two parses agree on every field. `expiresAt` may differ by up to `expiryTolerance`, since each parse
    /// reads the clock separately; name, value, domain and deletion status must match exactly.
    private static func sameCookies(_ lhs: [ParsedCookie], _ rhs: [ParsedCookie]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.name == right.name
                && left.value == right.value
                && left.domain == right.domain
                && left.isDeletion == right.isDeletion
                && sameExpiry(left.expiresAt, right.expiresAt)
        }
    }

    /// Both session cookies, or both expiries within `expiryTolerance` of each other.
    private static func sameExpiry(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return abs(left.timeIntervalSince(right)) <= expiryTolerance
        default:
            return false
        }
    }

    @Test func loginCookiesParse() throws {
        let cookies = try Self.cookiesLineByLine()
        #expect(cookies.count == 5)
        let fileNames = try Self.headerValues().map { String($0.prefix { $0 != "=" }) }
        #expect(cookies.map(\.name) == fileNames)
        let entry = try Fixtures.manifest().entries.first { $0.path == Self.fixture }
        #expect(entry?.setCookieNames == fileNames)
        #expect(cookies.allSatisfy { $0.domain == ".e-hentai.org" })
        #expect(cookies.filter(\.isDeletion).map(\.name) == ["ipb_anonlogin"])
        #expect(cookies.allSatisfy { !$0.value.isEmpty })
    }

    @Test func commaJoinedHeaderParses() throws {
        let joined = try Self.headerValues().joined(separator: ", ")
        let cookies = SetCookieParser.cookies(headerFields: ["Set-Cookie": joined], url: Self.loginURL, now: Self.now)
        let lineByLine = try Self.cookiesLineByLine()
        #expect(Self.sameCookies(cookies, lineByLine))
    }

    @Test func maxAgeZeroIsADeletion() {
        let cookies = SetCookieParser.cookies(headerFields: ["Set-Cookie": "x=1; Max-Age=0"], url: Self.loginURL)
        #expect(cookies.map(\.name) == ["x"])
        #expect(cookies.first?.isDeletion == true)
        let kept = SetCookieParser.cookies(headerFields: ["Set-Cookie": "x=1; Max-Age=3600"], url: Self.loginURL)
        #expect(kept.first?.isDeletion == false)
    }

    /// A Max-Age expiry counts from receipt, so an earlier `now` does not bring a dead cookie back.
    @Test func maxAgeZeroIsADeletionWhateverNow() {
        let past = Date(timeIntervalSince1970: 0)
        let gone = SetCookieParser.cookies(headerFields: ["Set-Cookie": "x=1; Max-Age=0"], url: Self.loginURL, now: past)
        #expect(gone.map(\.isDeletion) == [true])
        let kept = SetCookieParser.cookies(
            headerFields: ["Set-Cookie": "x=1; Max-Age=3600"], url: Self.loginURL, now: past
        )
        #expect(kept.map(\.isDeletion) == [false])
    }

    @Test func domainMatchingFollowsRFC6265() {
        func cookie(_ domain: String?) -> ParsedCookie {
            ParsedCookie(name: "x", value: "1", domain: domain, expiresAt: nil, isDeletion: false)
        }
        let eh = cookie(".e-hentai.org")
        #expect(eh.domainMatches(host: "e-hentai.org"))
        #expect(eh.domainMatches(host: "forums.e-hentai.org"))
        #expect(eh.domainMatches(host: "a.b.e-hentai.org"))
        #expect(!eh.domainMatches(host: "abc.hath.network"))
        #expect(!eh.domainMatches(host: "e-hentai.org.evil.com"))
        #expect(!eh.domainMatches(host: "evil-e-hentai.org"))
        #expect(!eh.domainMatches(host: "exhentai.org"))
        #expect(!eh.domainMatches(host: ""))
        // Case and one trailing dot, on either side.
        #expect(eh.domainMatches(host: "FORUMS.E-Hentai.ORG."))
        #expect(cookie(".E-HENTAI.ORG.").domainMatches(host: "forums.e-hentai.org"))
        #expect(!eh.domainMatches(host: "forums.e-hentai.org.."))

        // Host-only: only the very host.
        let hostOnly = cookie("forums.e-hentai.org")
        #expect(hostOnly.domainMatches(host: "forums.e-hentai.org"))
        #expect(hostOnly.domainMatches(host: "Forums.E-Hentai.Org."))
        #expect(!hostOnly.domainMatches(host: "a.forums.e-hentai.org"))
        #expect(!hostOnly.domainMatches(host: "e-hentai.org"))

        // IP addresses: only equal.
        #expect(cookie(".0.113.5").domainMatches(host: "203.0.113.5") == false)
        #expect(cookie(".203.0.113.5").domainMatches(host: "203.0.113.5"))
        #expect(cookie("203.0.113.5").domainMatches(host: "203.0.113.5"))
        #expect(cookie(".db8::1").domainMatches(host: "2001:db8::1") == false)
        #expect(cookie("2001:db8::1").domainMatches(host: "2001:DB8::1"))

        #expect(!cookie(nil).domainMatches(host: "e-hentai.org"))
        #expect(!cookie("").domainMatches(host: "e-hentai.org"))
        #expect(!cookie(".").domainMatches(host: "e-hentai.org"))
    }

    /// The domains HTTPCookie gives parsed cookies follow the convention `domainMatches(host:)` reads.
    @Test func parsedCookiesMatchOnlyTheirDomains() {
        func parsed(_ header: String, from url: String) -> ParsedCookie? {
            SetCookieParser.cookies(headerFields: ["Set-Cookie": header], url: URL(string: url)!, now: Self.now).first
        }
        let foreign = parsed("ipb_pass_hash=a; path=/; domain=.e-hentai.org", from: "https://abc.hath.network/h/x")
        #expect(foreign?.domain == ".e-hentai.org")
        #expect(foreign?.domainMatches(host: "abc.hath.network") == false)
        let crossSite = parsed("igneous=a; path=/; domain=.exhentai.org", from: Self.loginURL.absoluteString)
        #expect(crossSite?.domainMatches(host: "forums.e-hentai.org") == false)
        let withoutDot = parsed("sk=a; path=/; domain=e-hentai.org", from: Self.loginURL.absoluteString)
        #expect(withoutDot?.domain == ".e-hentai.org")
        #expect(withoutDot?.domainMatches(host: "forums.e-hentai.org") == true)
        let hostOnly = parsed("sk=a; path=/", from: Self.loginURL.absoluteString)
        #expect(hostOnly?.domainMatches(host: "forums.e-hentai.org") == true)
        #expect(hostOnly?.domainMatches(host: "e-hentai.org") == false)
    }

    @Test func lowercaseHeaderKeyWorks() throws {
        let joined = try Self.headerValues().joined(separator: ", ")
        let canonical = SetCookieParser.cookies(headerFields: ["Set-Cookie": joined], url: Self.loginURL, now: Self.now)
        for key in ["set-cookie", "SET-COOKIE"] {
            let cookies = SetCookieParser.cookies(
                headerFields: [key: joined, "content-type": "text/html"], url: Self.loginURL, now: Self.now
            )
            #expect(Self.sameCookies(cookies, canonical), "\(key)")
        }
        #expect(canonical.count == 5)
    }

    @Test func deletionForms() {
        func cookie(_ header: String) -> ParsedCookie? {
            SetCookieParser.cookies(headerFields: ["Set-Cookie": header], url: Self.loginURL, now: Self.now).first
        }
        #expect(cookie("x=; path=/")?.isDeletion == true)
        #expect(cookie("x=deleted; path=/")?.isDeletion == true)
        #expect(cookie("x=1; expires=Thu, 01-Jan-1970 00:00:01 GMT; path=/")?.isDeletion == true)
        #expect(cookie("x=1; path=/")?.isDeletion == false)
        #expect(cookie("x=1; path=/")?.expiresAt == nil)
        // Without a domain attribute the cookie belongs to the request's host.
        #expect(cookie("x=1; path=/")?.domain == "forums.e-hentai.org")
    }

    @Test func noSetCookieHeaderGivesNothing() {
        #expect(SetCookieParser.cookies(headerFields: [:], url: Self.loginURL).isEmpty)
        #expect(SetCookieParser.cookies(headerFields: ["content-type": "text/html"], url: Self.loginURL).isEmpty)
    }
}
