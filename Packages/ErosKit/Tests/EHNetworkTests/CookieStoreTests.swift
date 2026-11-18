import EHModels
import EHNetwork
import EHParsing
import Foundation
import Synchronization
import Testing

@Suite struct CookieStoreTests {
    private static let ehURL = URL(string: "https://e-hentai.org/")!
    private static let exURL = URL(string: "https://exhentai.org/")!
    private static let forumsURL = URL(string: "https://forums.e-hentai.org/index.php")!
    /// One fixed time for SetCookieParser, so results never depend on the clock.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let memberID = "1234567"
    private static let passHash = "0123456789abcdef0123456789abcdef"
    /// Made-up values for the ten injected cookies; every value is unique so a leak is easy to spot.
    private static let injected: [String: String] = [
        "ipb_member_id": memberID,
        "ipb_pass_hash": passHash,
        "igneous": "igneous-fake-0001",
        "hath_perks": "perks-fake-0002",
        "sk": "sk-fake-0003",
        "star": "star-fake-0004",
        "yay": "yay-fake-0005",
        "iq": "iq-fake-0006",
        "cf_clearance": "clearance-fake-0007",
        "cf_duid": "duid-fake-0008",
    ]
    private static let identity = [CookieNames.memberID: memberID, CookieNames.passHash: passHash]

    /// A loaded store on an empty in-memory vault, with the given jars.
    private static func makeStore(
        eh: [String: String] = [:], ex: [String: String] = [:]
    ) async throws -> (CookieStore, InMemoryVault) {
        let vault = InMemoryVault()
        let store = CookieStore(vault: vault)
        try await store.load()
        if !eh.isEmpty { try await store.set(eh, for: [.eh]) }
        if !ex.isEmpty { try await store.set(ex, for: [.ex]) }
        return (store, vault)
    }

    /// The snapshot the vault holds, decoded.
    private static func persisted(_ vault: InMemoryVault) throws -> SessionSnapshot? {
        try vault.read().map { try JSONDecoder().decode(SessionSnapshot.self, from: $0) }
    }

    /// The cookies of one `Set-Cookie` header value.
    private static func parsed(_ header: String, from url: URL) -> [ParsedCookie] {
        SetCookieParser.cookies(headerFields: ["Set-Cookie": header], url: url, now: now)
    }

    private static func cookie(
        _ name: String, _ value: String, domain: String?, isDeletion: Bool = false
    ) -> ParsedCookie {
        ParsedCookie(name: name, value: value, domain: domain, expiresAt: nil, isDeletion: isDeletion)
    }

    // MARK: - Cookie header

    @Test func injectsNWAndTheTenCookies() async throws {
        #expect(CookieNames.injected == [
            "ipb_member_id", "ipb_pass_hash", "igneous", "hath_perks", "sk", "star", "yay", "iq", "cf_clearance", "cf_duid",
        ])
        var jar = Self.injected
        jar[CookieNames.profile] = "sp-fake-0009"
        let (store, _) = try await Self.makeStore(eh: jar)
        let header = try #require(await store.cookieHeader(for: URL(string: "https://e-hentai.org/g/1/abc/")!))
        #expect(header.hasPrefix("nw=1; "))
        let expected = ["nw=1"] + CookieNames.injected.map { "\($0)=\(Self.injected[$0]!)" } + ["sp=sp-fake-0009"]
        #expect(header == expected.joined(separator: "; "))
    }

    @Test func otherCookiesFollowSPByName() async throws {
        let (store, _) = try await Self.makeStore(eh: ["zz": "z-fake", "aa": "a-fake", "sp": "sp-fake", "sk": "sk-fake"])
        #expect(await store.cookieHeader(for: Self.ehURL) == "nw=1; sk=sk-fake; sp=sp-fake; aa=a-fake; zz=z-fake")
    }

    @Test func otherHostsGetNoCookieHeader() async throws {
        let (store, _) = try await Self.makeStore(eh: Self.injected, ex: Self.injected)
        for url in [
            "https://ehgt.org/t/ab/cd/x.jpg", "https://x.hath.network/h/abc/x.jpg", "https://api.github.com/",
            "https://e-hentai.org.example.com/",
        ] {
            #expect(await store.cookieHeader(for: URL(string: url)!) == nil, "\(url)")
        }
    }

    @Test func loggedOutStillSendsNW() async throws {
        let (store, _) = try await Self.makeStore()
        #expect(await store.cookieHeader(for: Self.ehURL) == "nw=1")
        #expect(await store.cookieHeader(for: Self.exURL) == "nw=1")
        #expect(await store.cookieHeader(for: Self.forumsURL) == "nw=1")
    }

    @Test func sitesUseTheirOwnJars() async throws {
        let (store, _) = try await Self.makeStore(eh: ["sp": "5"], ex: ["sp": "6"])
        #expect(await store.cookieHeader(for: URL(string: "https://forums.e-hentai.org/index.php")!) == "nw=1; sp=5")
        #expect(await store.cookieHeader(for: URL(string: "https://s.exhentai.org/t/x.jpg")!) == "nw=1; sp=6")
    }

    @Test func headerCanExcludeUserAgentBoundNames() async throws {
        let jar = Self.injected.merging([
            "__cf_bm": "bm-fake-0001", "_cfuvid": "uvid-fake-0002", "cf_chl_prog": "chl-fake-0003",
            "ipb_session_id": "session-fake-0004", "cf": "plain-fake-0005",
        ]) { $1 }
        let (store, _) = try await Self.makeStore(eh: jar)
        let header = try #require(await store.cookieHeader(for: Self.ehURL, excludingUserAgentBound: true))
        for name in ["cf_clearance", "cf_duid", "__cf_bm", "_cfuvid", "cf_chl_prog"] {
            #expect(!header.contains("\(name)="), Comment(rawValue: name))
        }
        #expect(header.contains("ipb_session_id=session-fake-0004"))
        #expect(header.contains("cf=plain-fake-0005"))
        #expect(try #require(await store.cookieHeader(for: Self.ehURL)).contains("__cf_bm=bm-fake-0001"))

        try await store.removeUserAgentBound(for: [.eh])
        #expect(await store.snapshot().cookies[.eh]?.keys.sorted() == [
            "cf", "hath_perks", "igneous", "ipb_member_id", "ipb_pass_hash", "ipb_session_id", "iq", "sk", "star", "yay",
        ])
    }

    @Test func headerCanExcludeNames() async throws {
        let (store, _) = try await Self.makeStore(eh: Self.injected)
        let header = try #require(
            await store.cookieHeader(for: Self.ehURL, excluding: [CookieNames.clearance, "cf_duid"])
        )
        #expect(!header.contains("cf_clearance="))
        #expect(!header.contains("cf_duid="))
        let expected = ["nw=1"] + CookieNames.injected.dropLast(2).map { "\($0)=\(Self.injected[$0]!)" }
        #expect(header == expected.joined(separator: "; "))
    }

    // MARK: - Response cookies

    @Test func responseCookiesAreWrittenBack() async throws {
        let (store, _) = try await Self.makeStore(eh: Self.identity, ex: ["igneous": "igneous-fake-0001"])
        let cookies = Self.parsed("sk=sk-new-0011; path=/; domain=.e-hentai.org", from: Self.ehURL)
            + Self.parsed("hath_perks=perks-new-0012; path=/; domain=.e-hentai.org", from: Self.ehURL)
        try await store.ingest(cookies, from: Self.ehURL)
        let snapshot = await store.snapshot()
        #expect(snapshot.cookies[.eh] == Self.identity.merging(["sk": "sk-new-0011", "hath_perks": "perks-new-0012"]) { $1 })
        #expect(snapshot.cookies[.ex] == ["igneous": "igneous-fake-0001"])
    }

    @Test func mysteryOrEmptyIgneousIsIgnored() async throws {
        let (store, _) = try await Self.makeStore(ex: ["igneous": "igneous-fake-0001"])
        let mystery = Self.parsed("igneous=mystery; path=/; domain=.exhentai.org", from: Self.exURL)
        let empty = Self.parsed("igneous=; path=/; domain=.exhentai.org", from: Self.exURL)
        // SetCookieParser reads an empty value as a deletion; it must not remove the stored igneous either.
        #expect(empty.map(\.isDeletion) == [true])
        try await store.ingest(mystery + empty, from: Self.exURL)
        try await store.ingest([Self.cookie("igneous", "", domain: ".exhentai.org")], from: Self.exURL)
        #expect(await store.snapshot().cookies[.ex] == ["igneous": "igneous-fake-0001"])
    }

    @Test func deletionRemovesTheCookie() async throws {
        let (store, _) = try await Self.makeStore(eh: Self.identity.merging(["sk": "sk-fake-0003"]) { $1 })
        let deletion = Self.parsed(
            "sk=deleted; expires=Thu, 01-Jan-1970 00:00:01 GMT; path=/; domain=.e-hentai.org", from: Self.ehURL
        )
        #expect(deletion.map(\.isDeletion) == [true])
        try await store.ingest(deletion, from: Self.ehURL)
        #expect(await store.snapshot().cookies[.eh] == Self.identity)
    }

    @Test func invalidServerValuesAreSkipped() async throws {
        let (store, _) = try await Self.makeStore(eh: Self.identity)
        try await store.ingest([
            Self.cookie("sk", "a\u{07}b", domain: ".e-hentai.org"),
            Self.cookie("bad name", "value-fake-0013", domain: ".e-hentai.org"),
            Self.cookie("iq", "a\r\nSet-Cookie: x=y", domain: ".e-hentai.org"),
            Self.cookie("star", "star-fake-0004", domain: ".e-hentai.org"),
        ], from: Self.ehURL)
        #expect(await store.snapshot().cookies[.eh] == Self.identity.merging(["star": "star-fake-0004"]) { $1 })
    }

    @Test func nwIsNeverStored() async throws {
        let (store, vault) = try await Self.makeStore(eh: Self.identity)
        let before = try vault.read()
        let snapshot = await store.snapshot()
        try await store.ingest(Self.parsed("nw=1; path=/; domain=.e-hentai.org", from: Self.ehURL), from: Self.ehURL)
        try await store.ingest([Self.cookie("nw", "1", domain: nil)], from: Self.ehURL)
        try await store.set(["nw": "1"], for: [.eh, .ex])
        #expect(await store.snapshot() == snapshot)
        #expect(try vault.read() == before)
        let header = try #require(await store.cookieHeader(for: Self.ehURL))
        #expect(header.components(separatedBy: "; ").filter { $0.hasPrefix("nw=") } == ["nw=1"])
        #expect(header.hasPrefix("nw=1; "))
    }

    // MARK: - Which jar a response cookie belongs to

    /// An H@H node can neither write nor delete the site's cookies, even though HTTPCookie parses them.
    @Test func foreignDomainCookiesAreDropped() async throws {
        let (store, vault) = try await Self.makeStore(eh: Self.identity)
        let before = try vault.read()
        let snapshot = await store.snapshot()
        for node in ["https://abc.hath.network/h/abc/x.jpg", "https://a.b.hath.network:2468/h/abc/x.jpg"] {
            let url = URL(string: node)!
            let cookies = Self.parsed("ipb_pass_hash=forged-hash-0010; path=/; domain=.e-hentai.org", from: url)
                + Self.parsed(
                    "ipb_member_id=deleted; expires=Thu, 01-Jan-1970 00:00:01 GMT; path=/; domain=.e-hentai.org", from: url
                )
            #expect(cookies.map(\.domain) == [".e-hentai.org", ".e-hentai.org"], "\(node)")
            #expect(cookies.map(\.isDeletion) == [false, true], "\(node)")
            try await store.ingest(cookies, from: url)
        }
        #expect(await store.snapshot() == snapshot)
        #expect(try vault.read() == before)
    }

    /// `domainMatches` accepts a public suffix such as ".org"; the site lookup on the cookie's domain drops it.
    @Test func publicSuffixDomainsAreDropped() async throws {
        let (store, _) = try await Self.makeStore(eh: Self.identity.merging(["sk": "sk-fake-0003"]) { $1 })
        let snapshot = await store.snapshot()
        let write = Self.cookie("star", "star-fake-0004", domain: ".org")
        let deletion = Self.cookie("sk", "", domain: ".org", isDeletion: true)
        #expect(write.domainMatches(host: "e-hentai.org"))
        try await store.ingest([write, deletion], from: Self.ehURL)
        #expect(await store.snapshot() == snapshot)
    }

    @Test func hostOnlyCookiesFromOtherHostsAreDropped() async throws {
        let (store, _) = try await Self.makeStore(eh: Self.identity)
        let snapshot = await store.snapshot()
        let ehgt = URL(string: "https://ehgt.org/t/ab/cd/x.jpg")!
        let parsed = Self.parsed("sk=sk-fake-0003; path=/", from: ehgt)
        #expect(parsed.map(\.domain) == ["ehgt.org"])
        try await store.ingest(parsed + [Self.cookie("star", "star-fake-0004", domain: nil)], from: ehgt)
        #expect(await store.snapshot() == snapshot)
    }

    @Test func subdomainResponsesWriteTheSiteJar() async throws {
        let (store, _) = try await Self.makeStore()
        let login = URL(string: "https://forums.e-hentai.org/index.php?act=Login&CODE=01")!
        let cookies = Self.parsed("ipb_member_id=\(Self.memberID); path=/; domain=.e-hentai.org", from: login)
            + Self.parsed("ipb_pass_hash=\(Self.passHash); path=/; domain=.e-hentai.org", from: login)
        try await store.ingest(cookies, from: login)
        let snapshot = await store.snapshot()
        #expect(snapshot.cookies[.eh] == Self.identity)
        #expect(snapshot.cookies[.ex] == nil)
        #expect(await store.isLoggedIn)
    }

    @Test func crossSiteDomainsAreDropped() async throws {
        let (store, _) = try await Self.makeStore(eh: Self.identity, ex: ["igneous": "igneous-fake-0001"])
        let snapshot = await store.snapshot()
        let cookies = Self.parsed("igneous=igneous-forged-0014; path=/; domain=.exhentai.org", from: Self.ehURL)
            + Self.parsed("sk=deleted; Max-Age=0; path=/; domain=.exhentai.org", from: Self.ehURL)
        #expect(cookies.count == 2)
        try await store.ingest(cookies, from: Self.ehURL)
        try await store.ingest([Self.cookie("igneous", "", domain: ".exhentai.org", isDeletion: true)], from: Self.ehURL)
        #expect(await store.snapshot() == snapshot)
    }

    @Test func hostOnlyCookiesGoToTheResponseSite() async throws {
        let (store, _) = try await Self.makeStore()
        try await store.ingest(Self.parsed("star=star-fake-0004; path=/", from: Self.forumsURL), from: Self.forumsURL)
        let thumbnails = URL(string: "https://s.exhentai.org/t/x.jpg")!
        try await store.ingest([Self.cookie("sk", "sk-fake-0003", domain: nil)], from: thumbnails)
        let snapshot = await store.snapshot()
        #expect(snapshot.cookies[.eh] == ["star": "star-fake-0004"])
        #expect(snapshot.cookies[.ex] == ["sk": "sk-fake-0003"])
    }

    // MARK: - WebView cookies

    /// A WebView holds both sites' cookies: each counts as a response from its own domain, in one vault write.
    @Test func webViewCookiesGoToTheirOwnSites() async throws {
        let vault = UnreadableVault(data: nil)
        vault.makeReadable()
        let store = CookieStore(vault: vault)
        try await store.load()
        try await store.set(["star": "star-fake-0004", "iq": "iq-fake-0006"], for: [.eh])
        let writes = vault.writes
        let cookies = [
            Self.cookie(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org"),
            Self.cookie(CookieNames.clearance, "clearance-fake-eh", domain: ".e-hentai.org"),
            Self.cookie("ipb_session_id", "session-fake-0001", domain: "forums.e-hentai.org"),
            Self.cookie(CookieNames.clearance, "clearance-fake-ex", domain: ".exhentai.org"),
            Self.cookie(CookieNames.igneous, "igneous-fake-0001", domain: ".exhentai.org"),
            Self.cookie("nw", "1", domain: ".exhentai.org"),
            Self.cookie("star", "", domain: ".e-hentai.org", isDeletion: true),
            // Without a domain (or with an empty one): the fallback's site.
            Self.cookie("yay", "yay-fake-0005", domain: nil),
            Self.cookie("sk", "sk-fake-0003", domain: ""),
            // Neither site: dropped.
            Self.cookie("hath", "hath-fake-0001", domain: ".hath.network"),
            Self.cookie("suffix", "suffix-fake-0001", domain: ".org"),
            Self.cookie("thumbs", "thumbs-fake-0001", domain: "ehgt.org"),
        ]
        try await store.ingestWebViewCookies(cookies, fallback: Self.forumsURL)
        let snapshot = await store.snapshot()
        #expect(snapshot.cookies[.eh] == [
            CookieNames.memberID: Self.memberID, CookieNames.clearance: "clearance-fake-eh",
            "ipb_session_id": "session-fake-0001", "yay": "yay-fake-0005", "sk": "sk-fake-0003", "iq": "iq-fake-0006",
        ])
        #expect(snapshot.cookies[.ex] == [CookieNames.clearance: "clearance-fake-ex", CookieNames.igneous: "igneous-fake-0001"])
        #expect(vault.writes == writes + 1)
        #expect(try vault.bytes.map { try JSONDecoder().decode(SessionSnapshot.self, from: $0) } == snapshot)
        // Nothing new: no write.
        try await store.ingestWebViewCookies(cookies, fallback: Self.forumsURL)
        #expect(vault.writes == writes + 1)
    }

    /// With an expected member, the cookies are written only while that member is signed in.
    @Test func webViewCookiesNeedTheExpectedMember() async throws {
        let (store, vault) = try await Self.makeStore(eh: Self.identity)
        let bytes = try vault.read()
        let cookies = [
            Self.cookie(CookieNames.memberID, "7654321", domain: ".e-hentai.org"),
            Self.cookie("sk", "sk-fake-0003", domain: ".e-hentai.org"),
        ]
        try await store.ingestWebViewCookies(cookies, fallback: Self.forumsURL, expectedMemberID: 7_654_321)
        #expect(await store.snapshot().cookies[.eh] == Self.identity)
        #expect(try vault.read() == bytes)

        try await store.ingestWebViewCookies(
            [Self.cookie("sk", "sk-fake-0003", domain: ".e-hentai.org")], fallback: Self.forumsURL,
            expectedMemberID: 1_234_567
        )
        #expect(await store.snapshot().cookies[.eh]?["sk"] == "sk-fake-0003")

        // Logged out meanwhile: nothing is written either, even with the expected identity in the batch.
        try await store.reset()
        try await store.ingestWebViewCookies(
            [Self.cookie(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org"), cookies[1]],
            fallback: Self.forumsURL, expectedMemberID: 1_234_567
        )
        #expect(await store.snapshot() == .empty)
    }

    /// With an expected member, one `ipb_member_id` in the batch that is not that member's (an earlier account's
    /// host-only cookie, the forum's "0", a deletion, an empty value, another site's) refuses the whole batch.
    @Test(arguments: [
        ("forums.e-hentai.org", "7654321", false),
        (".e-hentai.org", "0", false),
        (".e-hentai.org", "", true),
        (".e-hentai.org", "", false),
        (".exhentai.org", "7654321", false),
        (".exhentai.org", "00", false),
    ])
    func webViewCookiesWithAnotherIdentityAreRefused(domain: String, value: String, isDeletion: Bool) async throws {
        let (store, vault) = try await Self.makeStore(eh: Self.identity, ex: Self.identity)
        let before = await store.snapshot()
        let bytes = try vault.read()
        let cookies = [
            Self.cookie(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org"),
            Self.cookie("sk", "sk-fake-0003", domain: ".e-hentai.org"),
            Self.cookie(CookieNames.memberID, value, domain: domain, isDeletion: isDeletion),
            Self.cookie(CookieNames.igneous, "igneous-fake-0001", domain: ".exhentai.org"),
        ]
        try await store.ingestWebViewCookies(cookies, fallback: Self.forumsURL, expectedMemberID: 1_234_567)
        #expect(await store.snapshot() == before)
        #expect(try vault.read() == bytes)
    }

    /// Every `ipb_member_id` the expected one: written as usual. Without an expected member nothing is checked.
    @Test func webViewCookiesWithTheExpectedIdentityAreWritten() async throws {
        let (store, _) = try await Self.makeStore(eh: Self.identity)
        let cookies = [
            Self.cookie(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org"),
            Self.cookie(CookieNames.memberID, Self.memberID, domain: "forums.e-hentai.org"),
            Self.cookie(CookieNames.memberID, Self.memberID, domain: ".exhentai.org"),
            Self.cookie("sk", "sk-fake-0003", domain: ".e-hentai.org"),
        ]
        try await store.ingestWebViewCookies(cookies, fallback: Self.forumsURL, expectedMemberID: 1_234_567)
        #expect(await store.snapshot().cookies[.eh] == Self.identity.merging(["sk": "sk-fake-0003"]) { $1 })
        #expect(await store.snapshot().cookies[.ex] == [CookieNames.memberID: Self.memberID])

        // A batch without ipb_member_id passes.
        try await store.ingestWebViewCookies(
            [Self.cookie("star", "star-fake-0004", domain: ".e-hentai.org")], fallback: Self.forumsURL,
            expectedMemberID: 1_234_567
        )
        #expect(await store.snapshot().cookies[.eh]?["star"] == "star-fake-0004")

        // expectedMemberID nil (the web login): another id is written as before.
        try await store.ingestWebViewCookies(
            [Self.cookie(CookieNames.memberID, "7654321", domain: ".e-hentai.org")], fallback: Self.forumsURL
        )
        #expect(await store.memberID == 7_654_321)
    }

    // MARK: - Validation

    @Test(arguments: ["a\r\nb", "a;b", "a\u{07}b", ""])
    func rejectsControlCharacters(value: String) async throws {
        let (store, vault) = try await Self.makeStore(eh: Self.identity)
        let before = try vault.read()
        let snapshot = await store.snapshot()
        await #expect(throws: CookieValueError.invalid(name: "sk")) {
            try await store.set(["sk": value, "star": "star-fake-0004"], for: [.eh, .ex])
        }
        #expect(await store.snapshot() == snapshot)
        #expect(try vault.read() == before)
    }

    @Test(arguments: ["a\u{00}b", "a\u{1F}b", "a\u{7F}b", "a\tb", "a\nb"])
    func rejectsTheWholeControlRange(value: String) async throws {
        let (store, _) = try await Self.makeStore()
        await #expect(throws: CookieValueError.invalid(name: "sk")) {
            try await store.set(["sk": value], for: [.eh])
        }
        #expect(await store.snapshot() == .empty)
    }

    @Test(arguments: ["", "a b", "a=b", "a;b", "a,b", "(a)", "é"])
    func rejectsNamesThatAreNotTokens(name: String) async throws {
        let (store, _) = try await Self.makeStore()
        await #expect(throws: CookieValueError.invalid(name: name)) {
            try await store.set([name: "value-fake-0013"], for: [.eh])
        }
        #expect(await store.snapshot() == .empty)
    }

    // MARK: - Persistence

    @Test func everyChangeIsPersisted() async throws {
        let (store, vault) = try await Self.makeStore()
        try await store.set(Self.injected, for: [.eh, .ex])
        #expect(try Self.persisted(vault) == (await store.snapshot()))
        try await store.remove([CookieNames.clearance, "cf_duid"], for: [.ex])
        #expect(try Self.persisted(vault) == (await store.snapshot()))
        try await store.ingest(Self.parsed("sk=sk-new-0011; path=/; domain=.e-hentai.org", from: Self.ehURL), from: Self.ehURL)
        #expect(try Self.persisted(vault) == (await store.snapshot()))
        try await store.setAccount(AccountInfo(method: .password, username: "made-up-user"))
        #expect(try Self.persisted(vault) == (await store.snapshot()))
        try await store.setAccount(nil)
        #expect(try Self.persisted(vault) == (await store.snapshot()))
        let snapshot = await store.snapshot()
        #expect(snapshot.cookies[.eh]?["sk"] == "sk-new-0011")
        #expect(snapshot.cookies[.ex]?[CookieNames.clearance] == nil)
        #expect(snapshot.account == nil)
    }

    @Test func loadRestoresTheSnapshot() async throws {
        let (store, vault) = try await Self.makeStore(eh: Self.injected, ex: ["igneous": "igneous-fake-0001", "sp": "6"])
        try await store.setAccount(AccountInfo(
            method: .web, username: "made-up-user", displayName: "Made Up Name",
            avatarURL: URL(string: "https://forums.e-hentai.org/uploads/av-fake.png"), profileFetchedAt: Self.now
        ))
        let restored = CookieStore(vault: vault)
        #expect(await restored.snapshot() == .empty)
        try await restored.load()
        #expect(await restored.snapshot() == (await store.snapshot()))
        #expect(await restored.cookieHeader(for: Self.exURL) == "nw=1; igneous=igneous-fake-0001; sp=6")

        let fresh = CookieStore(vault: InMemoryVault())
        try await fresh.load()
        #expect(await fresh.snapshot() == .empty)
    }

    @Test func corruptVaultDataFailsToLoad() async throws {
        let vault = InMemoryVault(data: Data("not json".utf8))
        let store = CookieStore(vault: vault)
        await #expect(throws: (any Error).self) { try await store.load() }
        #expect(await store.snapshot() == .empty)
        #expect(await store.isLoaded == false)
        try await store.ingest(Self.parsed("sk=sk-new-0011; path=/; domain=.e-hentai.org", from: Self.ehURL), from: Self.ehURL)
        #expect(try vault.read() == Data("not json".utf8))
    }

    // MARK: - Load state

    /// A real session's vault bytes and snapshot.
    private static func session() async throws -> (Data, SessionSnapshot) {
        let (store, vault) = try await makeStore(eh: identity.merging(["sk": "sk-fake-0003"]) { $1 }, ex: ["igneous": "igneous-fake-0001"])
        try await store.setAccount(AccountInfo(method: .password, username: "made-up-user"))
        return (try #require(try vault.read()), await store.snapshot())
    }

    @Test func storesStartNotLoaded() async throws {
        let (bytes, snapshot) = try await Self.session()
        let vault = InMemoryVault(data: bytes)
        let store = CookieStore(vault: vault)
        #expect(await store.isLoaded == false)
        await #expect(throws: CookieStoreError.notLoaded) { try await store.set(["star": "star-fake-0004"], for: [.eh]) }
        #expect(try vault.read() == bytes)
        try await store.load()
        #expect(await store.isLoaded)
        #expect(await store.snapshot() == snapshot)
    }

    /// Before the first unlock the Keychain cannot be read; responses still work, but nothing reaches the vault.
    @Test func ingestAfterAFailedLoadStaysInMemory() async throws {
        let (bytes, _) = try await Self.session()
        let vault = UnreadableVault(data: bytes)
        let store = CookieStore(vault: vault)
        await #expect(throws: UnreadableVault.ReadFailure.self) { try await store.load() }
        #expect(await store.isLoaded == false)
        try await store.ingest(Self.parsed("star=star-fake-0004; path=/; domain=.e-hentai.org", from: Self.ehURL), from: Self.ehURL)
        #expect(await store.snapshot().cookies[.eh] == ["star": "star-fake-0004"])
        #expect(await store.cookieHeader(for: Self.ehURL) == "nw=1; star=star-fake-0004")
        #expect(vault.bytes == bytes)
        #expect(vault.writes == 0)
    }

    @Test func changesAfterAFailedLoadThrowNotLoaded() async throws {
        let (bytes, _) = try await Self.session()
        let vault = UnreadableVault(data: bytes)
        let store = CookieStore(vault: vault)
        await #expect(throws: UnreadableVault.ReadFailure.self) { try await store.load() }
        try await store.ingest(Self.parsed("star=star-fake-0004; path=/; domain=.e-hentai.org", from: Self.ehURL), from: Self.ehURL)
        let memory = await store.snapshot()
        await #expect(throws: CookieStoreError.notLoaded) { try await store.set(["sk": "sk-new-0011"], for: [.eh]) }
        await #expect(throws: CookieStoreError.notLoaded) { try await store.remove(["star"], for: [.eh]) }
        await #expect(throws: CookieStoreError.notLoaded) {
            try await store.setAccount(AccountInfo(method: .cookie))
        }
        #expect(await store.snapshot() == memory)
        #expect(await store.isLoggedIn == false)
        #expect(vault.bytes == bytes)
        #expect(vault.writes == 0)
    }

    /// Logging out always works: it deletes the vault, and the store is loaded and empty afterwards.
    @Test func resetAfterAFailedLoadDeletesTheVault() async throws {
        let (bytes, _) = try await Self.session()
        let vault = UnreadableVault(data: bytes)
        let store = CookieStore(vault: vault)
        await #expect(throws: UnreadableVault.ReadFailure.self) { try await store.load() }
        try await store.reset()
        #expect(vault.bytes == nil)
        #expect(await store.isLoaded)
        #expect(await store.snapshot() == .empty)
        try await store.set(Self.identity, for: [.eh])
        #expect(vault.writes == 1)
        let written = try #require(vault.bytes)
        #expect(try JSONDecoder().decode(SessionSnapshot.self, from: written) == (await store.snapshot()))
        #expect(await store.isLoggedIn)
    }

    @Test func retriedLoadTakesTheVaultContents() async throws {
        let (bytes, snapshot) = try await Self.session()
        let vault = UnreadableVault(data: bytes)
        let store = CookieStore(vault: vault)
        await #expect(throws: UnreadableVault.ReadFailure.self) { try await store.load() }
        try await store.ingest(Self.parsed("star=star-fake-0004; path=/; domain=.e-hentai.org", from: Self.ehURL), from: Self.ehURL)
        vault.makeReadable()
        try await store.load()
        #expect(await store.isLoaded)
        #expect(await store.snapshot() == snapshot)
        #expect(vault.writes == 0)
        try await store.set(["star": "star-fake-0004"], for: [.eh])
        #expect(vault.writes == 1)
        #expect(await store.snapshot().cookies[.eh]?["sk"] == "sk-fake-0003")
    }

    @Test func failedWritesLeaveTheStoreUnchanged() async throws {
        let (source, sourceVault) = try await Self.makeStore(eh: Self.identity)
        try await source.setAccount(AccountInfo(method: .cookie))
        let store = CookieStore(vault: FailingVault(stored: try sourceVault.read()))
        try await store.load()
        let snapshot = await store.snapshot()
        #expect(snapshot == (await source.snapshot()))
        await #expect(throws: FailingVault.Failure.self) { try await store.set(["sk": "sk-fake-0003"], for: [.eh]) }
        await #expect(throws: FailingVault.Failure.self) { try await store.remove([CookieNames.memberID], for: [.eh]) }
        await #expect(throws: FailingVault.Failure.self) {
            try await store.ingest(Self.parsed("sk=sk-new-0011; path=/; domain=.e-hentai.org", from: Self.ehURL), from: Self.ehURL)
        }
        await #expect(throws: FailingVault.Failure.self) { try await store.setAccount(nil) }
        await #expect(throws: FailingVault.Failure.self) { try await store.reset() }
        #expect(await store.snapshot() == snapshot)
    }

    @Test func resetClearsEverything() async throws {
        let (store, vault) = try await Self.makeStore(eh: Self.injected, ex: Self.injected)
        try await store.setAccount(AccountInfo(method: .password, username: "made-up-user"))
        try await store.reset()
        #expect(await store.snapshot() == .empty)
        #expect(try vault.read() == nil)
        #expect(await store.isLoggedIn == false)
        #expect(await store.cookieHeader(for: Self.ehURL) == "nw=1")
    }

    // MARK: - Sessions

    /// The epoch goes up on every reset (and only when it worked); loading does not change it.
    @Test func resetBeginsANewEpoch() async throws {
        let (store, _) = try await Self.makeStore(eh: Self.identity)
        let first = await store.epoch
        try await store.reset()
        #expect(await store.epoch == first + 1)
        try await store.load()
        #expect(await store.epoch == first + 1)

        let failing = CookieStore(vault: FailingVault(stored: nil))
        try await failing.load()
        let before = await failing.epoch
        await #expect(throws: FailingVault.Failure.self) { try await failing.reset() }
        #expect(await failing.epoch == before)
    }

    /// Cookies of a response to a request read in an earlier epoch are dropped whole: nothing in the jars, nothing
    /// in the vault, nothing thrown. The current epoch, or none, writes as before.
    @Test func earlierEpochsWriteNothing() async throws {
        let (store, vault) = try await Self.makeStore(eh: Self.identity)
        let ended = await store.epoch
        try await store.reset()
        let late = Self.parsed("sk=sk-late-0001; path=/; domain=.e-hentai.org", from: Self.ehURL)
        try await store.ingest(late, from: Self.ehURL, epoch: ended)
        try await store.ingestWebViewCookies(
            [Self.cookie("hath_perks", "perks-late-0002", domain: ".e-hentai.org")], fallback: Self.ehURL, epoch: ended
        )
        #expect(await store.snapshot() == .empty)
        #expect(try vault.read() == nil)

        try await store.ingest(late, from: Self.ehURL, epoch: await store.epoch)
        try await store.ingestWebViewCookies(
            [Self.cookie("hath_perks", "perks-late-0002", domain: ".e-hentai.org")], fallback: Self.ehURL,
            epoch: await store.epoch
        )
        try await store.ingest(Self.parsed("yay=yay-late-0003; path=/; domain=.e-hentai.org", from: Self.ehURL), from: Self.ehURL)
        #expect(await store.snapshot().cookies[.eh] == ["sk": "sk-late-0001", "hath_perks": "perks-late-0002", "yay": "yay-late-0003"])
        #expect(try Self.persisted(vault) == (await store.snapshot()))
    }

    // MARK: - Login state and privacy

    @Test func isLoggedInNeedsTheIdentityPair() async throws {
        let cases: [([String: String], Bool)] = [
            ([CookieNames.memberID: Self.memberID], false),
            ([CookieNames.passHash: Self.passHash], false),
            ([CookieNames.memberID: "0", CookieNames.passHash: Self.passHash], false),
            ([CookieNames.memberID: "abc", CookieNames.passHash: Self.passHash], false),
            ([CookieNames.memberID: "+1234567", CookieNames.passHash: Self.passHash], false),
            (Self.identity, true),
        ]
        for (jar, expected) in cases {
            let (store, _) = try await Self.makeStore(eh: jar)
            #expect(await store.isLoggedIn == expected, "\(jar.keys.sorted())")
        }
        let (exOnly, _) = try await Self.makeStore(ex: Self.identity)
        #expect(await exOnly.isLoggedIn == false)
        #expect(await exOnly.memberID == nil)
        let (loggedIn, _) = try await Self.makeStore(eh: Self.identity)
        #expect(await loggedIn.memberID == 1_234_567)
    }

    @Test func descriptionsShowNoValues() async throws {
        var jar = Self.injected
        jar[CookieNames.profile] = "sp-fake-0009"
        let (store, _) = try await Self.makeStore(eh: jar, ex: ["igneous": "igneous-ex-fake-0015"])
        try await store.setAccount(AccountInfo(method: .password, username: "made-up-user", displayName: "Made Up Name"))
        let snapshot = await store.snapshot()
        var dumpedSnapshot = ""
        dump(snapshot, to: &dumpedSnapshot)
        var dumpedStore = ""
        dump(store, to: &dumpedStore)
        let secrets = Array(jar.values) + ["igneous-ex-fake-0015", "made-up-user", "Made Up Name"]
        let text = String(describing: snapshot)
        for name in CookieNames.injected + [CookieNames.profile] {
            #expect(text.contains(name), "\(name)")
        }
        for output in [text, String(reflecting: snapshot), dumpedSnapshot, String(describing: store), dumpedStore] {
            for secret in secrets {
                #expect(!output.contains(secret))
            }
        }
    }
}

/// A vault whose writes and deletes always fail; reads return `stored`.
struct FailingVault: CredentialVault {
    struct Failure: Error {}

    let stored: Data?

    func read() throws -> Data? { stored }
    func write(_ data: Data) throws { throw Failure() }
    func delete() throws { throw Failure() }
}

/// A vault whose reads fail until `makeReadable()`, like a Keychain before the first unlock; writes and deletes
/// work and writes are counted.
final class UnreadableVault: CredentialVault {
    struct ReadFailure: Error {}

    private struct State {
        var data: Data?
        var readable = false
        var writes = 0
    }

    private let state: Mutex<State>

    init(data: Data?) {
        state = Mutex(State(data: data))
    }

    var bytes: Data? { state.withLock { $0.data } }
    var writes: Int { state.withLock { $0.writes } }

    func makeReadable() {
        state.withLock { $0.readable = true }
    }

    func read() throws -> Data? {
        let (readable, data) = state.withLock { ($0.readable, $0.data) }
        guard readable else { throw ReadFailure() }
        return data
    }

    func write(_ data: Data) throws {
        state.withLock {
            $0.data = data
            $0.writes += 1
        }
    }

    func delete() throws {
        state.withLock { $0.data = nil }
    }
}
