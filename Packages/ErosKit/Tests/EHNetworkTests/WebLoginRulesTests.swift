import EHModels
import EHNetwork
import EHParsing
import Foundation
import Testing

/// Every cookie value is made up ("<name>-fake-…", member id 1234567).
@Suite struct WebLoginRulesTests {
    /// One fixed time, so expiry never depends on the clock.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let memberID = "1234567"
    private static let passHash = "0123456789abcdef0123456789abcdef"

    private static func httpCookie(
        _ name: String, _ value: String, domain: String, expires: Date? = nil
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
        if let expires { properties[.expires] = expires }
        return try #require(HTTPCookie(properties: properties))
    }

    private static func cookie(_ name: String, _ value: String, domain: String?, isDeletion: Bool = false) -> ParsedCookie {
        ParsedCookie(name: name, value: value, domain: domain, expiresAt: nil, isDeletion: isDeletion)
    }

    // MARK: - Completion

    @Test func loginCompletesOnlyOnIndexWithoutQuery() throws {
        let completion = try #require(URL(string: "https://forums.e-hentai.org/index.php"))
        #expect(WebLoginRules.isCompletion(completion))
        #expect(WebLoginRules.isCompletion(try #require(URL(string: "https://FORUMS.E-HENTAI.ORG/index.php"))))
        // An empty query is none (as Flutter's queryParameters.isEmpty); a fragment does not matter.
        #expect(WebLoginRules.isCompletion(try #require(URL(string: "https://forums.e-hentai.org/index.php?"))))
        #expect(WebLoginRules.isCompletion(try #require(URL(string: "https://forums.e-hentai.org/index.php#top"))))
        for text in [
            "https://forums.e-hentai.org/index.php?act=Login",
            "https://forums.e-hentai.org/index.php?act=Login&CODE=01",
            "https://forums.e-hentai.org/index.php?showuser=1",
            "http://forums.e-hentai.org/index.php",
            "https://forums.e-hentai.org:8443/index.php",
            "https://forums.e-hentai.org/",
            "https://forums.e-hentai.org/index.php/",
            "https://forums.e-hentai.org/other/index.php",
            "https://e-hentai.org/index.php",
            "https://exhentai.org/index.php",
            "https://forums.e-hentai.org.example.com/index.php",
            "https://example.com/index.php",
            "about:blank",
        ] {
            let url = try #require(URL(string: text))
            #expect(!WebLoginRules.isCompletion(url), "\(text)")
        }
    }

    // MARK: - Site cookies

    @Test func onlySiteCookiesAreTaken() throws {
        let cookies = [
            try Self.httpCookie(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org"),
            try Self.httpCookie("ipb_session_id", "session-fake-0001", domain: "forums.e-hentai.org"),
            try Self.httpCookie(CookieNames.igneous, "igneous-fake-0002", domain: ".exhentai.org"),
            try Self.httpCookie("other", "other-fake-0003", domain: ".example.com"),
            try Self.httpCookie("hath", "hath-fake-0004", domain: ".hath.network"),
            try Self.httpCookie("thumbs", "thumbs-fake-0005", domain: "ehgt.org"),
        ]
        let taken = WebLoginRules.siteCookies(from: cookies, now: Self.now)
        #expect(Set(taken.map(\.name)) == [CookieNames.memberID, "ipb_session_id", CookieNames.igneous])
        #expect(taken.allSatisfy { !$0.isDeletion })
        let byName = Dictionary(uniqueKeysWithValues: taken.map { ($0.name, $0) })
        #expect(byName[CookieNames.memberID]?.domain == ".e-hentai.org")
        #expect(byName[CookieNames.memberID]?.value == Self.memberID)
        #expect(byName["ipb_session_id"]?.domain == "forums.e-hentai.org")
        #expect(byName[CookieNames.igneous]?.domain == ".exhentai.org")
        #expect(byName[CookieNames.igneous]?.value == "igneous-fake-0002")
    }

    /// One name held for a whole site and for one of its hosts: the host's cookie comes last, so it wins in a jar.
    @Test func hostCookiesComeAfterSiteCookies() throws {
        let cookies = [
            try Self.httpCookie("ipb_session_id", "session-fake-host", domain: "forums.e-hentai.org"),
            try Self.httpCookie("ipb_session_id", "session-fake-site", domain: ".e-hentai.org"),
        ]
        for order in [cookies, cookies.reversed()] {
            let taken = WebLoginRules.siteCookies(from: order, now: Self.now)
            #expect(taken.map(\.value) == ["session-fake-site", "session-fake-host"])
        }
    }

    @Test func expiredCookiesBecomeDeletions() throws {
        let cookies = [
            try Self.httpCookie("sk", "sk-fake-0001", domain: ".e-hentai.org", expires: Self.now.addingTimeInterval(-60)),
            try Self.httpCookie("star", "star-fake-0002", domain: ".e-hentai.org", expires: Self.now),
            try Self.httpCookie("yay", "yay-fake-0003", domain: ".e-hentai.org", expires: Self.now.addingTimeInterval(60)),
            try Self.httpCookie("iq", "iq-fake-0004", domain: ".e-hentai.org"),
        ]
        let taken = Dictionary(
            uniqueKeysWithValues: WebLoginRules.siteCookies(from: cookies, now: Self.now).map { ($0.name, $0) }
        )
        #expect(taken["sk"]?.isDeletion == true)
        #expect(taken["star"]?.isDeletion == true)
        #expect(taken["yay"]?.isDeletion == false)
        #expect(taken["yay"]?.expiresAt == Self.now.addingTimeInterval(60))
        #expect(taken["iq"]?.isDeletion == false)
        #expect(taken["iq"]?.expiresAt == nil)
    }

    @Test func clearanceCookiesAreNotPushed() {
        for name in ["cf_clearance", "cf_duid", "__cf_bm", "_cfuvid", "cf_chl_prog", "cf_chl_rc_i"] {
            #expect(WebLoginRules.isNotPushedToWebView(name), Comment(rawValue: name))
        }
        for name in ["sk", "igneous", "ipb_session_id", "cf", "xcf_clearance", "_cf_bm"] {
            #expect(!WebLoginRules.isNotPushedToWebView(name), Comment(rawValue: name))
        }
    }

    @Test func consistencyIgnoresEveryUserAgentBoundCookieMissingFromTheWebView() {
        let snapshot = SessionSnapshot(cookies: [.eh: [
            CookieNames.memberID: Self.memberID, "__cf_bm": "bm-fake-0001", "_cfuvid": "uvid-fake-0002",
            "cf_chl_prog": "chl-fake-0003", "ipb_session_id": "session-fake-0004",
        ]])
        let web = [
            Self.cookie(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org"),
            Self.cookie("nw", "1", domain: ".e-hentai.org"),
        ]
        let result = SessionConsistency.compare(snapshot: snapshot, webCookies: web, sessionUserAgent: "A", webUserAgent: "A")
        #expect(result.missingInWebView == ["ipb_session_id"])
    }

    // MARK: - Consistency

    @Test func consistencyComparesNamesAndValues() {
        let snapshot = SessionSnapshot(cookies: [
            .eh: [
                CookieNames.memberID: Self.memberID, CookieNames.passHash: Self.passHash, "sk": "sk-fake-jar",
                "star": "star-fake-0001", CookieNames.clearance: "clearance-fake-0002",
            ],
            .ex: [CookieNames.memberID: Self.memberID, CookieNames.igneous: "igneous-fake-0003"],
        ])
        let web = [
            Self.cookie(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org"),
            Self.cookie(CookieNames.passHash, Self.passHash, domain: ".e-hentai.org"),
            Self.cookie("sk", "sk-fake-web", domain: ".e-hentai.org"),
            Self.cookie("nw", "1", domain: ".e-hentai.org"),
            Self.cookie(CookieNames.memberID, Self.memberID, domain: ".exhentai.org"),
            Self.cookie(CookieNames.igneous, "igneous-fake-0003", domain: ".exhentai.org"),
            Self.cookie("nw", "1", domain: ".exhentai.org"),
            // Of neither site: not compared.
            Self.cookie("other", "other-fake-0004", domain: ".example.com"),
        ]
        let result = SessionConsistency.compare(
            snapshot: snapshot, webCookies: web, sessionUserAgent: "FakeWebKit/1", webUserAgent: "FakeWebKit/1"
        )
        #expect(result.differingValues == ["sk"])
        #expect(result.missingInWebView == ["star"])
        #expect(result.missingInStore == [])
        #expect(result.userAgentMatches)

        // A cookie only the WebView holds is missing in the store, a cf_* one too; a deletion is no cookie.
        let more = web + [
            Self.cookie("ipb_session_id", "session-fake-0005", domain: "forums.e-hentai.org"),
            Self.cookie(CookieNames.clearance, "clearance-fake-0006", domain: ".exhentai.org"),
            Self.cookie("star", "", domain: ".e-hentai.org", isDeletion: true),
        ]
        let second = SessionConsistency.compare(
            snapshot: snapshot, webCookies: more, sessionUserAgent: "FakeWebKit/1", webUserAgent: "FakeWebKit/1"
        )
        #expect(second.missingInStore == [CookieNames.clearance, "ipb_session_id"])
        #expect(second.missingInWebView == ["star"])
        #expect(second.differingValues == ["sk"])

        // Pushed as it is (no cf_*, plus nw=1): consistent.
        let pushed = SessionSnapshot(cookies: [.eh: [CookieNames.memberID: Self.memberID, CookieNames.clearance: "clearance-fake-0002"]])
        let same = SessionConsistency.compare(
            snapshot: pushed,
            webCookies: [
                Self.cookie(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org"),
                Self.cookie("nw", "1", domain: ".e-hentai.org"),
                Self.cookie("nw", "1", domain: ".exhentai.org"),
            ],
            sessionUserAgent: "FakeWebKit/1", webUserAgent: "FakeWebKit/1"
        )
        #expect(same.missingInWebView.isEmpty && same.missingInStore.isEmpty && same.differingValues.isEmpty)
    }

    @Test func consistencyComparesTheUserAgent() {
        let differing = SessionConsistency.compare(
            snapshot: .empty, webCookies: [], sessionUserAgent: "FakeChrome/1", webUserAgent: "FakeWebKit/1"
        )
        #expect(!differing.userAgentMatches)
        let matching = SessionConsistency.compare(
            snapshot: .empty, webCookies: [], sessionUserAgent: "FakeWebKit/1", webUserAgent: "FakeWebKit/1"
        )
        #expect(matching.userAgentMatches)
    }

    @Test func consistencyDescriptionHasNoValues() {
        let snapshot = SessionSnapshot(cookies: [
            .eh: [CookieNames.memberID: Self.memberID, CookieNames.passHash: Self.passHash, "sk": "sk-fake-jar"],
        ])
        let web = [
            Self.cookie(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org"),
            Self.cookie("sk", "sk-fake-web", domain: ".e-hentai.org"),
            Self.cookie("yay", "yay-fake-web", domain: ".e-hentai.org"),
        ]
        let result = SessionConsistency.compare(
            snapshot: snapshot, webCookies: web, sessionUserAgent: "FakeWebKit/1", webUserAgent: "FakeWebKit/1"
        )
        var dumped = ""
        dump(result, to: &dumped)
        for text in [String(describing: result), String(reflecting: result), dumped] {
            for secret in [Self.memberID, Self.passHash, "sk-fake-jar", "sk-fake-web", "yay-fake-web"] {
                #expect(!text.contains(secret))
            }
        }
        let description = String(describing: result)
        for name in [CookieNames.passHash, "sk", "yay"] {
            #expect(description.contains(name))
        }
        #expect(description.contains("userAgentMatches: true"))
    }
}
