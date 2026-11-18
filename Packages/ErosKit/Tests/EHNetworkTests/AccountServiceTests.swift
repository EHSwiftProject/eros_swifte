import EHFixtures
import EHModels
import EHNetwork
import EHNetworkTesting
import EHParsing
import Foundation
import Synchronization
import Testing

/// Every request in this suite goes to `MockURLProtocol`; none reaches the network, so no test changes a real account.
/// Every credential is made up: member id 1234567, pass hash 0123…cdef, igneous in the masked form, cookie values
/// "<name>-fake-…". The captured settings page holds the account's own profile names and numbers: it is checked by
/// structure only, every such value bound to a Boolean before `#expect`.
@Suite struct AccountServiceTests {
    private static let memberID = "1234567"
    private static let passHash = "0123456789abcdef0123456789abcdef"
    private static let identity = [CookieNames.memberID: memberID, CookieNames.passHash: passHash]
    /// The masked form (letters and digits only "a" and "1").
    private static let igneous = "a1a1a1a1a1a1a1a1a"
    private static let webKitUserAgent = "FakeWebKit/1"
    private static let password = "fake-password-0001"

    private static let ehUConfig = EHEndpoints.uconfig(site: .eh)
    private static let exUConfig = EHEndpoints.uconfig(site: .ex)

    // MARK: - Pages

    private static func page(_ path: String) throws -> String {
        try Fixtures.string(path)
    }

    /// Profiles 1 "Fake Default" (selected), 5 "Eros-FE", 6 "Fake Other"; the captured settings form.
    private static func erosUnselected() throws -> String {
        try page("constructed/eh/uconfig-eros-unselected.html")
    }

    /// `erosUnselected()` with profile 5, Eros-FE, selected.
    private static func erosSelected() throws -> String {
        try replacing(
            #"<option value="1" selected="selected">Fake Default</option><option value="5">Eros-FE</option>"#,
            with: #"<option value="1">Fake Default</option><option value="5" selected="selected">Eros-FE</option>"#,
            in: erosUnselected()
        )
    }

    /// Profiles 1 "Fake Default" (selected) and 6 "Fake Other"; the captured settings form.
    private static func withoutEros() throws -> String {
        try page("constructed/eh/uconfig-without-eros.html")
    }

    /// `withoutEros()` after creating Eros-FE: a new profile 7, selected.
    private static func erosCreated() throws -> String {
        try replacing(
            #"<option value="1" selected="selected">Fake Default</option><option value="6">Fake Other</option>"#,
            with: #"<option value="1">Fake Default</option><option value="6">Fake Other</option>"#
                + #"<option value="7" selected="selected">Eros-FE</option>"#,
            in: withoutEros()
        )
    }

    /// Neither the profile selector nor the settings form: UConfigParser throws.
    private static let notASettingsPage = Data("<html><body><p>Fake page</p></body></html>".utf8)

    /// The profile selector without Eros-FE, but no settings form (as a page that is not the account's settings).
    private static let selectorWithoutForm = Data("""
        <html><body><form id="profile_form" action="" method="post">\
        <input type="hidden" id="profile_action" name="profile_action" value="" />\
        <select name="profile_set" onchange="do_profile_post()"><option value="1" selected="selected">Fake Default</option>\
        </select></form></body></html>
        """.utf8)

    /// A settings form without the profile selector.
    private static let formWithoutSelector = Data("""
        <html><body><form action="" method="post"><input type="text" name="fake_text" value="1" />\
        <input type="submit" name="apply" value="Apply" /></form></body></html>
        """.utf8)

    private static func replacing(_ old: String, with new: String, in page: String) throws -> String {
        let result = page.replacingOccurrences(of: old, with: new)
        try #require(result != page, "the fixture no longer has the markup the test changes")
        return result
    }

    // MARK: - Harness

    private struct Harness {
        let service: AccountService
        let client: EHClient
        let cookies: CookieStore
        let userAgents: UserAgentStore
        let vault: InMemoryVault
        let mock: MockSession

        func requests() -> [URLRequest] { mock.requests() }

        func jar(_ site: EHSite) async -> [String: String] {
            await cookies.snapshot().cookies[site] ?? [:]
        }
    }

    /// A service on a new mock registration: a loaded cookie store with the given jars and account (unless `loaded`
    /// is false), the WebKit UA adopted, a `RecordingThrottle` unless another throttle is given. With `vault`, the
    /// store writes through it (`Harness.vault` is then its inner vault).
    private static func makeHarness(
        eh: [String: String] = [:], ex: [String: String] = [:], account: AccountInfo? = nil,
        profileSelection: ProfileSelectionMode = .automatic,
        throttle: any RequestThrottle = RecordingThrottle(), cache: ResponseCache? = nil, loaded: Bool = true,
        vault controlled: ControlledVault? = nil,
        responder: @escaping @Sendable (URLRequest) throws -> MockResponse = { _ in throw URLError(.badURL) }
    ) async throws -> Harness {
        let mock = MockURLProtocol.install(responder)
        let vault = controlled?.inner ?? InMemoryVault()
        let cookies = CookieStore(vault: controlled ?? vault)
        if loaded {
            try await cookies.load()
            if !eh.isEmpty { try await cookies.set(eh, for: [.eh]) }
            if !ex.isEmpty { try await cookies.set(ex, for: [.ex]) }
            if let account { try await cookies.setAccount(account) }
        }
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        await userAgents.load()
        _ = await userAgents.adopt(webKitUserAgent)
        let configuration = try EHClientConfiguration(sessionConfigurator: mock.configurator)
        let client = EHClient(
            configuration: configuration, cookies: cookies, userAgents: userAgents, throttle: throttle, cache: cache
        )
        let service = AccountService(client: client, cookies: cookies, profileSelection: profileSelection, retryDelay: .zero)
        return Harness(service: service, client: client, cookies: cookies, userAgents: userAgents, vault: vault, mock: mock)
    }

    /// A responder for one site's settings page: GET answers `get`, POST answers `post` (a 500 without one).
    private static func uconfig(
        site: EHSite = .eh, get: MockResponse, post: MockResponse? = nil
    ) -> @Sendable (URLRequest) throws -> MockResponse {
        { request in
            guard request.url == EHEndpoints.uconfig(site: site) else { throw URLError(.badURL) }
            if request.httpMethod == "POST" { return post ?? MockResponse(status: 500) }
            return get
        }
    }

    private static func cookie(_ name: String, _ value: String, domain: String?) -> ParsedCookie {
        ParsedCookie(name: name, value: value, domain: domain, expiresAt: nil, isDeletion: false)
    }

    /// The urlencoded fields of a request's body.
    private static func formFields(of request: URLRequest) -> [String: String] {
        let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decoded(_ part: Substring) -> String {
                part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(part)
            }
            fields[decoded(parts[0])] = parts.count > 1 ? decoded(parts[1]) : ""
        }
        return fields
    }

    private static func methodsAndURLs(_ requests: [URLRequest]) -> [String] {
        requests.map { "\($0.httpMethod ?? "?") \($0.url?.absoluteString ?? "?")" }
    }

    /// The snapshot the vault holds, decoded.
    private static func persisted(_ vault: InMemoryVault) throws -> SessionSnapshot? {
        try vault.read().map { try JSONDecoder().decode(SessionSnapshot.self, from: $0) }
    }

    /// The result of `task`, or nil after 5 seconds; a separate task waits, so one that never ends costs the timeout.
    private static func result<Value: Sendable>(of task: Task<Value, any Error>) async -> Result<Value, any Error>? {
        let box = Mutex<Result<Value, any Error>?>(nil)
        let watcher = Task { let outcome = await task.result; box.withLock { $0 = outcome } }
        defer { watcher.cancel() }
        _ = await waitUntil { box.withLock { $0 != nil } }
        return box.withLock { $0 }
    }

    // MARK: - Password login

    // The forum form is posted by the app's background WebView (account A3b): the service takes the WebView store's
    // site cookies afterwards and never sees the password.

    /// The identity pair as the WebView store holds it after the forum set it, then `extra`.
    private static func webViewIdentity(_ extra: [ParsedCookie] = []) -> [ParsedCookie] {
        [
            cookie(CookieNames.memberID, memberID, domain: ".e-hentai.org"),
            cookie(CookieNames.passHash, passHash, domain: ".e-hentai.org"),
        ] + extra
    }

    @Test func passwordLoginStoresIdentityInBothSites() async throws {
        let h = try await Self.makeHarness(eh: ["cf_duid": "duid-fake-0001"], profileSelection: .off)
        defer { h.mock.remove() }
        let cookies = Self.webViewIdentity([
            Self.cookie("sk", "sk-fake-0001", domain: ".e-hentai.org"),
            Self.cookie(CookieNames.clearance, "clearance-fake-0001", domain: ".e-hentai.org"),
        ])
        let outcome = try await h.service.completePasswordLogin(
            cookies: cookies, from: EHEndpoints.forumLogin, username: "fake-user"
        )
        #expect(outcome == LoginOutcome(memberID: 1_234_567, profile: nil))
        #expect(await h.cookies.isLoggedIn)
        #expect(await h.jar(.eh) == Self.identity.merging([
            "sk": "sk-fake-0001", "cf_clearance": "clearance-fake-0001", "cf_duid": "duid-fake-0001",
        ]) { $1 })
        // The shared cookies go to EX as well; cf_clearance and cf_duid are bound to EH's Cloudflare, igneous is EX's own.
        #expect(await h.jar(.ex) == Self.identity.merging(["sk": "sk-fake-0001"]) { $1 })
        #expect(await h.cookies.snapshot().account == AccountInfo(method: .password, username: "fake-user"))
        // Nothing is sent (the WebView posted the form); the UA is still the WebKit one.
        #expect(h.requests().isEmpty)
        #expect(await h.userAgents.current == Self.webKitUserAgent)
    }

    @Test func passwordLoginKeepsEveryUserAgentBoundCookieOutOfEX() async throws {
        let h = try await Self.makeHarness(profileSelection: .off)
        defer { h.mock.remove() }
        let cookies = Self.webViewIdentity([
            Self.cookie("sk", "sk-fake-0001", domain: ".e-hentai.org"),
            Self.cookie("__cf_bm", "bm-fake-0001", domain: ".e-hentai.org"),
            Self.cookie("_cfuvid", "uvid-fake-0002", domain: ".e-hentai.org"),
            Self.cookie("cf_chl_prog", "chl-fake-0003", domain: ".e-hentai.org"),
        ])
        _ = try await h.service.completePasswordLogin(cookies: cookies, from: EHEndpoints.forumLogin, username: "fake-user")
        #expect(await h.jar(.eh)["__cf_bm"] == "bm-fake-0001")
        #expect(await h.jar(.ex) == Self.identity.merging(["sk": "sk-fake-0001"]) { $1 })
    }

    @Test func passwordLoginWithoutMemberIDIsRejected() async throws {
        let batches: [[ParsedCookie]] = [
            [],
            [
                Self.cookie(CookieNames.memberID, "0", domain: ".e-hentai.org"),
                Self.cookie(CookieNames.passHash, Self.passHash, domain: ".e-hentai.org"),
                Self.cookie("sk", "sk-fake-0001", domain: ".e-hentai.org"),
            ],
        ]
        for batch in batches {
            let h = try await Self.makeHarness(eh: ["cf_clearance": "clearance-fake-0001"])
            defer { h.mock.remove() }
            let before = await h.cookies.snapshot()
            await #expect(throws: LoginError.rejected) {
                try await h.service.completePasswordLogin(cookies: batch, from: EHEndpoints.forumLogin, username: "fake-user")
            }
            #expect(await !h.cookies.isLoggedIn)
            // Rejected: the store is as before (what the WebView held is gone), and no settings page is asked for.
            let jar = await h.jar(.eh)
            #expect(jar[CookieNames.memberID] == nil && jar[CookieNames.passHash] == nil && jar["sk"] == nil)
            #expect(await h.cookies.snapshot() == before)
            #expect(try Self.persisted(h.vault) == before)
            #expect(h.requests().isEmpty)
        }
    }

    /// An identity left in the jar from before must not make a failed login look successful. (That the WebView does
    /// not carry the old identity into the login is `WebPasswordLoginTests.doesNotPushTheJar`.)
    @Test func staleIdentityDoesNotPassALogin() async throws {
        let h = try await Self.makeHarness(eh: Self.identity, ex: Self.identity)
        defer { h.mock.remove() }
        await #expect(throws: LoginError.rejected) {
            try await h.service.completePasswordLogin(
                cookies: [Self.cookie("sk", "sk-fake-0001", domain: ".e-hentai.org")], from: EHEndpoints.forumLogin,
                username: "fake-user"
            )
        }
        #expect(await h.cookies.snapshot() == SessionSnapshot(cookies: [.eh: Self.identity, .ex: Self.identity]))
        #expect(h.requests().isEmpty)

        let web = try await Self.makeHarness(eh: Self.identity, ex: Self.identity)
        defer { web.mock.remove() }
        let before = await web.cookies.snapshot()
        await #expect(throws: LoginError.rejected) {
            try await web.service.completeWebLogin(
                cookies: [Self.cookie("cf_clearance", "clearance-fake-0001", domain: ".e-hentai.org")],
                from: EHEndpoints.webLoginStart
            )
        }
        #expect(await web.cookies.snapshot() == before)
    }

    /// Signed in as A, a login as B that is rejected or fails on the way leaves A signed in, as it was.
    @Test func failedLoginKeepsTheSignedInAccount() async throws {
        let ehA = Self.identity.merging([CookieNames.profile: "5", "sk": "sk-fake-a"]) { $1 }
        let exA = Self.identity.merging([CookieNames.igneous: Self.igneous]) { $1 }
        let accountA = AccountInfo(method: .password, username: "fake-user-a")
        let rejected = [
            Self.cookie(CookieNames.memberID, "0", domain: ".e-hentai.org"),
            Self.cookie("sk", "sk-fake-b", domain: ".e-hentai.org"),
        ]
        // Rejected (the forum set ipb_member_id=0), and failing on the way (the vault refuses the login's first write).
        for fails in [false, true] {
            let vault = ControlledVault()
            let h = try await Self.makeHarness(eh: ehA, ex: exA, account: accountA, vault: vault)
            defer { h.mock.remove() }
            let before = await h.cookies.snapshot()
            if fails { vault.failNextWrite() }
            do {
                _ = try await h.service.completePasswordLogin(
                    cookies: fails ? Self.webViewIdentity() : rejected, from: EHEndpoints.forumLogin,
                    username: "fake-user-b"
                )
                Issue.record("the login as B succeeded")
            } catch {
                #expect(fails ? error is ControlledVault.Failure : error as? LoginError == .rejected)
            }
            #expect(await h.cookies.isLoggedIn)
            #expect(await h.cookies.snapshot() == before)
            #expect(try Self.persisted(h.vault) == before)
            #expect(h.requests().isEmpty)
        }
        // The web login as well.
        let web = try await Self.makeHarness(eh: ehA, ex: exA, account: accountA)
        defer { web.mock.remove() }
        let before = await web.cookies.snapshot()
        await #expect(throws: LoginError.rejected) {
            try await web.service.completeWebLogin(
                cookies: [Self.cookie("sk", "sk-fake-b", domain: ".e-hentai.org")], from: EHEndpoints.webLoginStart
            )
        }
        #expect(await web.cookies.snapshot() == before)
    }

    /// The service never sees the password (account A3b): it is in the form the WebView posts, and nowhere else.
    @Test func passwordStaysInTheLoginForm() async throws {
        let request = EHRequests.passwordLogin(username: "fake-user", password: Self.password)
        #expect(Self.formFields(of: request.webViewRequest())["PassWord"] == Self.password)
        for text in [request.description, String(describing: request), String(reflecting: request)] {
            #expect(!text.contains(Self.password))
        }

        let h = try await Self.makeHarness(profileSelection: .off)
        defer { h.mock.remove() }
        let outcome = try await h.service.completePasswordLogin(
            cookies: Self.webViewIdentity(), from: EHEndpoints.forumLogin, username: "fake-user"
        )
        let vaultText = String(decoding: try h.vault.read() ?? Data(), as: UTF8.self)
        #expect(!vaultText.contains(Self.password))
        let snapshot = await h.cookies.snapshot()
        var dumped = ""
        dump(snapshot, to: &dumped)
        dump(outcome, to: &dumped)
        for text in [String(describing: snapshot), String(describing: outcome), String(describing: snapshot.account), dumped] {
            #expect(!text.contains(Self.password))
        }
    }

    @Test func outcomeDescriptionsShowNoMemberID() {
        let outcome = LoginOutcome(memberID: 1_234_567, profile: .selected(5))
        var dumped = ""
        dump(outcome, to: &dumped)
        for text in [String(describing: outcome), String(reflecting: outcome), dumped] {
            #expect(!text.contains(Self.memberID))
        }
        #expect(String(describing: outcome).contains("selected(5)"))
    }

    // MARK: - Cookie login

    @Test(arguments: [
        ("12a", "0123456789abcdef0123456789abcdef"), ("0", "0123456789abcdef0123456789abcdef"),
        ("1234567", "XYZ"), ("1234567", "0123456789abcdef0123456789abcde\n"),
    ])
    func cookieLoginValidates(memberID: String, passHash: String) async throws {
        let h = try await Self.makeHarness(eh: ["cf_clearance": "clearance-fake-0001"])
        defer { h.mock.remove() }
        let before = await h.cookies.snapshot()
        let bytes = try h.vault.read()
        let expected: LoginError = memberID == Self.memberID ? .invalidPassHash : .invalidMemberID
        await #expect(throws: expected) {
            try await h.service.logIn(with: CookieCredentials(memberID: memberID, passHash: passHash))
        }
        #expect(await h.cookies.snapshot() == before)
        #expect(try h.vault.read() == bytes)
        #expect(h.requests().isEmpty)
    }

    /// `CookieCredentials.validate()` refuses what the cookie login refuses, with the same error, without any store:
    /// the app checks typed values before it touches WebKit (L006).
    @Test(arguments: [
        ("12a", "0123456789abcdef0123456789abcdef", LoginError.invalidMemberID),
        ("0", "0123456789abcdef0123456789abcdef", .invalidMemberID),
        ("99999999999999999999999", "0123456789abcdef0123456789abcdef", .invalidMemberID),
        ("１２３", "0123456789abcdef0123456789abcdef", .invalidMemberID),
        (" 1234567", "0123456789abcdef0123456789abcdef", .invalidMemberID),
        ("", "0123456789abcdef0123456789abcdef", .invalidMemberID), ("12a", "XYZ", .invalidMemberID),
        ("1234567", "XYZ", .invalidPassHash), ("1234567", "0123456789ABCDEF0123456789ABCDEF", .invalidPassHash),
        ("1234567", "0123456789abcdef0123456789abcde\n", .invalidPassHash), ("1234567", "", .invalidPassHash),
    ] as [(String, String, LoginError)])
    func validateRefusesWhatTheLoginRefuses(memberID: String, passHash: String, error: LoginError) async throws {
        let credentials = CookieCredentials(memberID: memberID, passHash: passHash)
        #expect(throws: error) { try credentials.validate() }
        let h = try await Self.makeHarness()
        defer { h.mock.remove() }
        await #expect(throws: error) { try await h.service.logIn(with: credentials) }
    }

    @Test func validateAcceptsWhatTheLoginAccepts() throws {
        try CookieCredentials(memberID: Self.memberID, passHash: Self.passHash).validate()
    }

    /// More member ids and pass hashes the rules refuse: zeros, too large for Int, non-ASCII digits, separators.
    @Test(arguments: ["00", "99999999999999999999999", "１２３", " 1234567", "1234567;", ""])
    func cookieLoginRefusesOtherMemberIDs(memberID: String) async throws {
        let h = try await Self.makeHarness()
        defer { h.mock.remove() }
        await #expect(throws: LoginError.invalidMemberID) {
            try await h.service.logIn(with: CookieCredentials(memberID: memberID, passHash: Self.passHash))
        }
        #expect(await h.cookies.snapshot() == .empty)
    }

    @Test func cookieLoginWritesBothSites() async throws {
        let h = try await Self.makeHarness(profileSelection: .off)
        defer { h.mock.remove() }
        let outcome = try await h.service.logIn(with: CookieCredentials(memberID: Self.memberID, passHash: Self.passHash))
        #expect(outcome == LoginOutcome(memberID: 1_234_567, profile: nil))
        #expect(await h.jar(.eh) == Self.identity)
        #expect(await h.jar(.ex) == Self.identity)
        #expect(await h.cookies.snapshot().account == AccountInfo(method: .cookie))
        // Not checked with the site (as the Flutter app).
        #expect(h.requests().isEmpty)
        #expect(await h.userAgents.current == Self.webKitUserAgent)
    }

    // MARK: - Web login

    @Test func webLoginNeedsTheIdentityPair() async throws {
        let h = try await Self.makeHarness(profileSelection: .off)
        defer { h.mock.remove() }
        let cookies = [
            Self.cookie(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org"),
            Self.cookie(CookieNames.passHash, Self.passHash, domain: ".e-hentai.org"),
            Self.cookie(CookieNames.clearance, "clearance-fake-0001", domain: ".e-hentai.org"),
        ]
        let outcome = try await h.service.completeWebLogin(cookies: cookies, from: EHEndpoints.webLoginStart)
        #expect(outcome == LoginOutcome(memberID: 1_234_567, profile: nil))
        #expect(await h.jar(.eh) == Self.identity.merging([CookieNames.clearance: "clearance-fake-0001"]) { $1 })
        #expect(await h.jar(.ex) == Self.identity)
        #expect(await h.cookies.snapshot().account == AccountInfo(method: .web))
        #expect(h.requests().isEmpty)
        #expect(await h.userAgents.current == Self.webKitUserAgent)

        let missing = try await Self.makeHarness(profileSelection: .off)
        defer { missing.mock.remove() }
        await #expect(throws: LoginError.rejected) {
            try await missing.service.completeWebLogin(cookies: Array(cookies.dropFirst()), from: EHEndpoints.webLoginStart)
        }
        #expect(await !missing.cookies.isLoggedIn)
        #expect(await missing.cookies.snapshot() == .empty)
    }

    /// The WebView holds both sites' cookies: each is written from its own domain, so EX's are not dropped as
    /// cookies a forums response could not set.
    @Test func webLoginWritesEachCookieToItsOwnSite() async throws {
        let h = try await Self.makeHarness(profileSelection: .off)
        defer { h.mock.remove() }
        let cookies = [
            Self.cookie(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org"),
            Self.cookie(CookieNames.passHash, Self.passHash, domain: ".e-hentai.org"),
            Self.cookie(CookieNames.clearance, "clearance-fake-eh", domain: ".e-hentai.org"),
            Self.cookie(CookieNames.clearance, "clearance-fake-ex", domain: ".exhentai.org"),
            Self.cookie(CookieNames.igneous, Self.igneous, domain: ".exhentai.org"),
            Self.cookie("ipb_session_id", "session-fake-0001", domain: "forums.e-hentai.org"),
            // Without a domain: the URL's site.
            Self.cookie("yay", "yay-fake-0001", domain: nil),
            // Neither site: dropped.
            Self.cookie("hath", "hath-fake-0001", domain: ".hath.network"),
            Self.cookie("suffix", "suffix-fake-0001", domain: ".org"),
            Self.cookie("thumbs", "thumbs-fake-0001", domain: "ehgt.org"),
        ]
        _ = try await h.service.completeWebLogin(cookies: cookies, from: EHEndpoints.webLoginStart)
        #expect(await h.jar(.eh) == Self.identity.merging([
            CookieNames.clearance: "clearance-fake-eh", "ipb_session_id": "session-fake-0001", "yay": "yay-fake-0001",
        ]) { $1 })
        #expect(await h.jar(.ex) == Self.identity.merging([
            CookieNames.clearance: "clearance-fake-ex", CookieNames.igneous: Self.igneous, "yay": "yay-fake-0001",
        ]) { $1 })
    }

    // MARK: - Eros-FE profile

    @Test func ensureProfileDoesNothingWhenSelected() async throws {
        let h = try await Self.makeHarness(eh: Self.identity, responder: Self.uconfig(get: MockResponse(body: Data(Self.erosSelected().utf8))))
        defer { h.mock.remove() }
        #expect(try await h.service.ensureErosProfile(site: .eh) == .alreadySelected(5))
        #expect(Self.methodsAndURLs(h.requests()) == ["GET \(Self.ehUConfig.absoluteString)"])
        #expect(await h.jar(.eh)[CookieNames.profile] == "5")
        #expect(await h.service.profileDiagnostics(for: .eh) == ProfileDiagnostics(
            outcome: .alreadySelected(5), serverSetProfileCookie: false, profileCookieAfter: 5
        ))
    }

    @Test func ensureProfileSelectsExistingErosFE() async throws {
        let h = try await Self.makeHarness(eh: Self.identity, responder: Self.uconfig(
            get: MockResponse(body: Data(Self.erosUnselected().utf8)),
            post: MockResponse(headers: ["Set-Cookie": "sp=5; path=/; domain=.e-hentai.org"], body: Data(Self.erosSelected().utf8))
        ))
        defer { h.mock.remove() }
        #expect(try await h.service.ensureErosProfile(site: .eh) == .selected(5))
        let requests = h.requests()
        #expect(Self.methodsAndURLs(requests) == ["GET \(Self.ehUConfig.absoluteString)", "POST \(Self.ehUConfig.absoluteString)"])
        #expect(Self.formFields(of: requests[1]) == ["profile_set": "5", "profile_action": ""])
        #expect(await h.jar(.eh)[CookieNames.profile] == "5")
        #expect(await h.service.profileDiagnostics(for: .eh) == ProfileDiagnostics(
            outcome: .selected(5), serverSetProfileCookie: true, profileCookieAfter: 5
        ))
    }

    @Test func ensureProfileSetsSPWhenTheServerDoesNot() async throws {
        let h = try await Self.makeHarness(eh: Self.identity.merging([CookieNames.profile: "1"]) { $1 }, responder: Self.uconfig(
            get: MockResponse(body: Data(Self.erosUnselected().utf8)),
            post: MockResponse(body: Data(Self.erosSelected().utf8))
        ))
        defer { h.mock.remove() }
        #expect(try await h.service.ensureErosProfile(site: .eh) == .selected(5))
        #expect(await h.jar(.eh)[CookieNames.profile] == "5")
        #expect(await h.service.profileDiagnostics(for: .eh) == ProfileDiagnostics(
            outcome: .selected(5), serverSetProfileCookie: false, profileCookieAfter: 5
        ))
    }

    /// The jar already held sp=5 while the page showed profile 1 (the server went by something else), and the
    /// answer sets sp=5 again: the jar does not change, yet the server did write it back.
    @Test func serverSettingTheSameSPIsCounted() async throws {
        let h = try await Self.makeHarness(eh: Self.identity.merging([CookieNames.profile: "5"]) { $1 }, responder: Self.uconfig(
            get: MockResponse(body: Data(Self.erosUnselected().utf8)),
            post: MockResponse(headers: ["Set-Cookie": "sp=5; path=/; domain=.e-hentai.org"], body: Data(Self.erosSelected().utf8))
        ))
        defer { h.mock.remove() }
        #expect(try await h.service.ensureErosProfile(site: .eh) == .selected(5))
        #expect(await h.service.profileDiagnostics(for: .eh) == ProfileDiagnostics(
            outcome: .selected(5), serverSetProfileCookie: true, profileCookieAfter: 5
        ))
        // An sp for the other site's domain is not this site's.
        let other = try await Self.makeHarness(eh: Self.identity, responder: Self.uconfig(
            get: MockResponse(body: Data(Self.erosUnselected().utf8)),
            post: MockResponse(headers: ["Set-Cookie": "sp=5; path=/; domain=.exhentai.org"], body: Data(Self.erosSelected().utf8))
        ))
        defer { other.mock.remove() }
        #expect(try await other.service.ensureErosProfile(site: .eh) == .selected(5))
        #expect(await other.service.profileDiagnostics(for: .eh)?.serverSetProfileCookie == false)
        #expect(await other.jar(.ex)[CookieNames.profile] == nil)
    }

    @Test func ensureProfileCreatesWhenMissing() async throws {
        let h = try await Self.makeHarness(eh: Self.identity, responder: Self.uconfig(
            get: MockResponse(body: Data(Self.withoutEros().utf8)),
            post: MockResponse(headers: ["Set-Cookie": "sp=7; path=/; domain=.e-hentai.org"], body: Data(Self.erosCreated().utf8))
        ))
        defer { h.mock.remove() }
        #expect(try await h.service.ensureErosProfile(site: .eh) == .created(7))
        let requests = h.requests()
        #expect(Self.methodsAndURLs(requests) == ["GET \(Self.ehUConfig.absoluteString)", "POST \(Self.ehUConfig.absoluteString)"])
        #expect(Self.formFields(of: requests[1]) == ["profile_action": "create", "profile_name": "Eros-FE"])
        #expect(await h.jar(.eh)[CookieNames.profile] == "7")
        #expect(await h.service.profileDiagnostics(for: .eh)?.serverSetProfileCookie == true)
    }

    /// After a create, only a new Eros-FE counts: an existing profile shown under that name is not the one created.
    /// A run creates once: the later rounds only ask for the page again.
    @Test func createdProfileMustBeNew() async throws {
        let renamed = try Self.replacing(
            #"<option value="1" selected="selected">Fake Default</option><option value="6">Fake Other</option>"#,
            with: #"<option value="1">Fake Default</option><option value="6" selected="selected">Eros-FE</option>"#,
            in: Self.withoutEros()
        )
        let h = try await Self.makeHarness(eh: Self.identity, responder: Self.uconfig(
            get: MockResponse(body: Data(Self.withoutEros().utf8)), post: MockResponse(body: Data(renamed.utf8))
        ))
        defer { h.mock.remove() }
        #expect(try await h.service.ensureErosProfile(site: .eh) == .failed)
        let get = "GET \(Self.ehUConfig.absoluteString)", post = "POST \(Self.ehUConfig.absoluteString)"
        #expect(Self.methodsAndURLs(h.requests()) == [get, post, get, get])
        #expect(Self.formFields(of: h.requests()[1])["profile_action"] == "create")
        #expect(await h.jar(.eh) == Self.identity)
    }

    /// The create's answer does not show the new profile, but the next page lists it: the run selects it.
    @Test func runSelectsWhatItCreatedWhenTheAnswerDoesNotShowIt() async throws {
        let without = try Self.withoutEros(), unselected = try Self.erosUnselected(), selected = try Self.erosSelected()
        let gets = Counter()
        let h = try await Self.makeHarness(eh: Self.identity) { request in
            guard request.url == Self.ehUConfig else { throw URLError(.badURL) }
            if request.httpMethod == "POST" {
                let isCreate = Self.formFields(of: request)["profile_action"] == "create"
                return MockResponse(body: Data((isCreate ? without : selected).utf8))
            }
            return MockResponse(body: Data((gets.next() == 1 ? without : unselected).utf8))
        }
        defer { h.mock.remove() }
        #expect(try await h.service.ensureErosProfile(site: .eh) == .selected(5))
        let actions = h.requests().filter { $0.httpMethod == "POST" }.map { Self.formFields(of: $0)["profile_action"] }
        #expect(actions == ["create", ""])
        #expect(h.requests().count == 4)
        #expect(await h.jar(.eh)[CookieNames.profile] == "5")
    }

    /// Two calls for one site at once share one run: one create.
    @Test func concurrentRunsShareOneCreate() async throws {
        let gate = GateThrottle()
        let h = try await Self.makeHarness(eh: Self.identity, throttle: gate, responder: Self.uconfig(
            get: MockResponse(body: Data(Self.withoutEros().utf8)),
            post: MockResponse(headers: ["Set-Cookie": "sp=7; path=/; domain=.e-hentai.org"], body: Data(Self.erosCreated().utf8))
        ))
        defer { h.mock.remove() }
        let service = h.service
        let first = Task { try await service.ensureErosProfile(site: .eh) }
        #expect(await waitUntil { await gate.isHolding })
        #expect(await service.profileCallers(for: .eh) == 1)
        let second = Task { try await service.ensureErosProfile(site: .eh) }
        // The second call has joined the run while its first request is held.
        #expect(await waitUntil { await service.profileCallers(for: .eh) == 2 })
        await gate.release()
        let outcomes = [try #require(await Self.result(of: first)).get(), try #require(await Self.result(of: second)).get()]
        #expect(outcomes == [.created(7), .created(7)])
        let get = "GET \(Self.ehUConfig.absoluteString)", post = "POST \(Self.ehUConfig.absoluteString)"
        #expect(Self.methodsAndURLs(h.requests()) == [get, post])
        #expect(await service.profileCallers(for: .eh) == 0)
    }

    /// When every call waiting for a run is cancelled, the run is cancelled: nothing is sent.
    @Test func cancellingEveryCallerStopsTheRun() async throws {
        let gate = GateThrottle()
        let h = try await Self.makeHarness(eh: Self.identity, throttle: gate, responder: Self.uconfig(
            get: MockResponse(body: Data(Self.withoutEros().utf8)), post: MockResponse(body: Data(Self.erosCreated().utf8))
        ))
        defer { h.mock.remove() }
        let service = h.service
        let run = Task { try await service.ensureErosProfile(site: .eh) }
        #expect(await waitUntil { await gate.isHolding })
        run.cancel()
        #expect(await waitUntil { await service.profileCallers(for: .eh) == 0 })
        await gate.release()
        let result = try #require(await Self.result(of: run))
        #expect(throws: EHNetworkError.cancelled) { try result.get() }
        #expect(h.requests().isEmpty)
        #expect(await h.jar(.eh) == Self.identity)
        #expect(await service.profileDiagnostics(for: .eh) == nil)
    }

    @Test func ensureProfileGivesUpAfterThreeRounds() async throws {
        let h = try await Self.makeHarness(eh: Self.identity, responder: Self.uconfig(get: MockResponse(body: Self.notASettingsPage)))
        defer { h.mock.remove() }
        #expect(try await h.service.ensureErosProfile(site: .eh) == .failed)
        #expect(Self.methodsAndURLs(h.requests()) == Array(repeating: "GET \(Self.ehUConfig.absoluteString)", count: 3))
        #expect(await h.jar(.eh) == Self.identity)
        #expect(await h.service.profileDiagnostics(for: .eh) == ProfileDiagnostics(
            outcome: .failed, serverSetProfileCookie: false, profileCookieAfter: nil
        ))
    }

    /// A page with the profile selector but no settings form (not the account's settings) never leads to a create.
    @Test func ensureProfileNeverCreatesFromAPageWithoutTheForm() async throws {
        let h = try await Self.makeHarness(eh: Self.identity, responder: Self.uconfig(get: MockResponse(body: Self.selectorWithoutForm)))
        defer { h.mock.remove() }
        #expect(try await h.service.ensureErosProfile(site: .eh) == .failed)
        #expect(Self.methodsAndURLs(h.requests()) == Array(repeating: "GET \(Self.ehUConfig.absoluteString)", count: 3))
        #expect(await h.jar(.eh) == Self.identity)
    }

    @Test func ensureProfileWithoutProfilesWritesNothing() async throws {
        let h = try await Self.makeHarness(eh: Self.identity, responder: Self.uconfig(get: MockResponse(body: Self.formWithoutSelector)))
        defer { h.mock.remove() }
        #expect(try await h.service.ensureErosProfile(site: .eh) == .noProfiles)
        #expect(h.requests().count == 1)
        #expect(await h.jar(.eh) == Self.identity)
    }

    /// The captured settings page: whatever its profiles, the service reads them as the parser does.
    @Test func capturedSettingsPageIsRead() async throws {
        let captured = try Self.page("eh/account/uconfig.html")
        let parsed = try UConfigParser.parse(captured)
        let h = try await Self.makeHarness(eh: Self.identity, responder: Self.uconfig(get: MockResponse(body: Data(captured.utf8))))
        defer { h.mock.remove() }
        let outcome = try await h.service.ensureErosProfile(site: .eh)
        // The captured account has Eros-FE selected: one GET, no POST, and sp is that profile's number.
        let selected = parsed.selectedProfile
        let isErosSelected = selected?.name == AccountService.erosProfileName
        #expect(isErosSelected)
        let isAlreadySelected = selected.map { outcome == .alreadySelected($0.number) } == true
        #expect(isAlreadySelected)
        let requestCount = h.requests().count
        #expect(requestCount == 1)
        let spIsTheSelectedNumber = await h.jar(.eh)[CookieNames.profile] == selected.map { String($0.number) }
        #expect(spIsTheSelectedNumber)
    }

    @Test func profileSelectionCanBeTurnedOff() async throws {
        let h = try await Self.makeHarness(profileSelection: .off)
        defer { h.mock.remove() }
        let outcome = try await h.service.completePasswordLogin(
            cookies: Self.webViewIdentity(), from: EHEndpoints.forumLogin, username: "fake-user"
        )
        #expect(outcome.profile == nil)
        #expect(h.requests().isEmpty)
        #expect(await h.service.profileDiagnostics(for: .eh) == nil)
    }

    @Test func automaticSelectionRunsAfterLogin() async throws {
        let selected = try Self.erosSelected()
        let h = try await Self.makeHarness { request in
            guard request.url == Self.ehUConfig, request.httpMethod == "GET" else { throw URLError(.badURL) }
            return MockResponse(body: Data(selected.utf8))
        }
        defer { h.mock.remove() }
        let outcome = try await h.service.completePasswordLogin(
            cookies: Self.webViewIdentity(), from: EHEndpoints.forumLogin, username: "fake-user"
        )
        #expect(outcome == LoginOutcome(memberID: 1_234_567, profile: .alreadySelected(5)))
        #expect(Self.methodsAndURLs(h.requests()) == ["GET \(Self.ehUConfig.absoluteString)"])
        #expect(await h.jar(.eh)[CookieNames.profile] == "5")
        #expect(await h.jar(.ex)[CookieNames.profile] == nil)
    }

    /// A site notice while choosing the profile: no retry, and the login still succeeds.
    @Test func profileErrorsDoNotFailTheLogin() async throws {
        let h = try await Self.makeHarness { _ in MockResponse(status: 429) }
        defer { h.mock.remove() }
        let outcome = try await h.service.completePasswordLogin(
            cookies: Self.webViewIdentity(), from: EHEndpoints.forumLogin, username: "fake-user"
        )
        #expect(outcome == LoginOutcome(memberID: 1_234_567, profile: .stopped(.tooManyRequests)))
        #expect(await h.cookies.isLoggedIn)
        #expect(h.requests().count == 1)
        #expect(await h.service.profileDiagnostics(for: .eh)?.outcome == .stopped(.tooManyRequests))
    }

    /// Any other profile error (here a 503) after a login: `.failed`, and the login stands.
    @Test func otherProfileErrorsAreFailedForTheLogin() async throws {
        let h = try await Self.makeHarness { _ in MockResponse(status: 503) }
        defer { h.mock.remove() }
        let outcome = try await h.service.completePasswordLogin(
            cookies: Self.webViewIdentity(), from: EHEndpoints.forumLogin, username: "fake-user"
        )
        #expect(outcome == LoginOutcome(memberID: 1_234_567, profile: .failed))
        #expect(await h.cookies.isLoggedIn)
        #expect(h.requests().count == 1)
    }

    /// Both sites paused (an earlier ban or 429, `BreakerThrottle`) when a login's profile run starts: the run sends
    /// nothing, and the login gets `.stopped` with the notice that began the pause, as for a notice the run met itself,
    /// not `.failed`: the app then leaves the forum profile page alone too.
    @Test(arguments: [PauseReason.tooManyRequests, .banned])
    func pauseStopsTheProfileRunOfALogin(reason: PauseReason) async throws {
        let breaker = SiteBreaker()
        let notice: ResponseIssue = reason == .banned ? .banned(remaining: nil) : .tooManyRequests
        _ = try #require(await breaker.record(notice, at: URL(string: "https://e-hentai.org/")!))
        let h = try await Self.makeHarness(
            throttle: BreakerThrottle(base: RecordingThrottle(), breaker: breaker),
            responder: Self.uconfig(get: MockResponse(body: Data(Self.erosSelected().utf8)))
        )
        defer { h.mock.remove() }
        let outcome = try await h.service.logIn(with: CookieCredentials(memberID: Self.memberID, passHash: Self.passHash))
        #expect(outcome == LoginOutcome(memberID: 1_234_567, profile: .stopped(notice)))
        #expect(await h.cookies.isLoggedIn)
        #expect(h.requests().isEmpty)
    }

    @Test func ensureProfileStopsAtASiteNotice() async throws {
        let h = try await Self.makeHarness(eh: Self.identity, responder: Self.uconfig(get: MockResponse(status: 429)))
        defer { h.mock.remove() }
        await #expect(throws: EHNetworkError.issue(.tooManyRequests)) {
            try await h.service.ensureErosProfile(site: .eh)
        }
        #expect(h.requests().count == 1)
        #expect(await h.jar(.eh) == Self.identity)
        #expect(await h.service.profileDiagnostics(for: .eh) == ProfileDiagnostics(
            outcome: .stopped(.tooManyRequests), serverSetProfileCookie: false, profileCookieAfter: nil
        ))
    }

    @Test func profileNumbersAreKeptPerSite() async throws {
        let h = try await Self.makeHarness(
            eh: Self.identity, ex: Self.identity.merging([CookieNames.profile: "9"]) { $1 },
            responder: Self.uconfig(
                get: MockResponse(body: Data(Self.erosUnselected().utf8)),
                post: MockResponse(headers: ["Set-Cookie": "sp=5; path=/; domain=.e-hentai.org"], body: Data(Self.erosSelected().utf8))
            )
        )
        defer { h.mock.remove() }
        #expect(try await h.service.ensureErosProfile(site: .eh) == .selected(5))
        #expect(await h.jar(.eh)[CookieNames.profile] == "5")
        #expect(await h.jar(.ex)[CookieNames.profile] == "9")
        #expect(await h.service.profileDiagnostics(for: .ex) == nil)
    }

    /// Logging out while a profile run waits for the throttle: the run is cancelled, its request never goes out, and
    /// nothing is written.
    @Test func logOutStopsAProfileRunInProgress() async throws {
        let gate = GateThrottle()
        let h = try await Self.makeHarness(eh: Self.identity, throttle: gate, responder: Self.uconfig(
            get: MockResponse(body: Data(Self.erosUnselected().utf8)),
            post: MockResponse(headers: ["Set-Cookie": "sp=5; path=/; domain=.e-hentai.org"], body: Data(Self.erosSelected().utf8))
        ))
        defer { h.mock.remove() }
        let service = h.service
        let run = Task { try await service.ensureErosProfile(site: .eh) }
        #expect(await waitUntil { await gate.isHolding })
        try await h.service.logOut()
        await gate.release()
        let result = try #require(await Self.result(of: run))
        #expect(throws: EHNetworkError.cancelled) { try result.get() }
        #expect(h.requests().isEmpty)
        #expect(await h.cookies.snapshot() == .empty)
        #expect(await h.service.profileDiagnostics(for: .eh) == nil)
        #expect(await service.profileCallers(for: .eh) == 0)
    }

    /// A profile run belongs to the session it was asked in (N7 m6): logging out while the call still waits for the
    /// cookie store (here behind a held vault write) ends it with `CancellationError` before it starts. It must not
    /// start for the session that follows, with the member the store has then (none after the logout), and send the
    /// settings page without an identity.
    @Test func profileRunKeepsTheSessionItWasAskedIn() async throws {
        let vault = ControlledVault()
        let h = try await Self.makeHarness(eh: Self.identity, vault: vault, responder: Self.uconfig(get: MockResponse(status: 404)))
        defer { h.mock.remove() }
        let (service, cookies) = (h.service, h.cookies)
        vault.holdNextWrite()
        let write = Task { try await cookies.set(["sk": "fake-sk"], for: [.eh]) }
        #expect(await waitUntil { vault.isHolding })
        // Queued behind the held write on the cookie store, having read the session it was asked in.
        let run = await Self.startProfileRun(on: service)
        let logOut = Task { try await service.logOut() }
        // Gives the logout time to begin its session (its first step, before it too waits for the cookie store):
        // nothing it does until the store answers can be seen from here, and the store is held.
        try await Task.sleep(for: .milliseconds(100))
        vault.release()
        try await write.value
        try await logOut.value
        let result = try #require(await Self.result(of: run))
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(h.requests().isEmpty)
        #expect(await h.service.profileDiagnostics(for: .eh) == nil)
    }

    /// Starts `ensureErosProfile(site: .eh)` on the service's own executor and returns once it waits (for the cookie
    /// store): the call has read the session it was asked in, so a logout after this ends it. A call that `Task {}`
    /// starts could reach the service after the logout and run for the session that follows.
    private static func startProfileRun(
        on service: isolated AccountService
    ) -> Task<ProfileOutcome, any Error> {
        Task.immediate { try await service.ensureErosProfile(site: .eh) }
    }

    /// Logged out, then signed in as B while A's run waits to send its create: A's create never goes out with B's
    /// cookies; B's own run creates once.
    @Test func switchingAccountsStopsTheOldRun() async throws {
        let memberB = "7654321", passHashB = "fedcba9876543210fedcba9876543210"
        let gate = GateThrottle(holding: 2)
        let h = try await Self.makeHarness(eh: Self.identity, throttle: gate, responder: Self.uconfig(
            get: MockResponse(body: Data(Self.withoutEros().utf8)), post: MockResponse(body: Data(Self.erosCreated().utf8))
        ))
        defer { h.mock.remove() }
        let service = h.service
        let runA = Task { try await service.ensureErosProfile(site: .eh) }
        // A's create POST is held at the throttle.
        #expect(await waitUntil { await gate.isHolding })
        try await service.logOut()
        let loginB = try await service.logIn(with: CookieCredentials(memberID: memberB, passHash: passHashB))
        #expect(loginB.profile == .created(7))
        await gate.release()
        let resultA = try #require(await Self.result(of: runA))
        #expect(throws: EHNetworkError.cancelled) { try resultA.get() }
        let creates = h.requests().filter { Self.formFields(of: $0)["profile_action"] == "create" }
        #expect(creates.count == 1)
        let carriesB = creates.allSatisfy { ($0.value(forHTTPHeaderField: "Cookie") ?? "").contains("ipb_member_id=\(memberB)") }
        #expect(carriesB)
        #expect(await h.cookies.memberID == 7_654_321)
    }

    /// Signing in again as the same member while the old run waits to send its create: the login cancels it, and
    /// its own run (which does not wait for the old one) creates once.
    @Test func reLoginStopsTheOldRun() async throws {
        let gate = GateThrottle(holding: 2)
        let h = try await Self.makeHarness(eh: Self.identity, throttle: gate, responder: Self.uconfig(
            get: MockResponse(body: Data(Self.withoutEros().utf8)), post: MockResponse(body: Data(Self.erosCreated().utf8))
        ))
        defer { h.mock.remove() }
        let service = h.service
        let oldRun = Task { try await service.ensureErosProfile(site: .eh) }
        #expect(await waitUntil { await gate.isHolding })
        let login = Task { try await service.logIn(with: CookieCredentials(memberID: Self.memberID, passHash: Self.passHash)) }
        let outcome = try #require(await Self.result(of: login)).get()
        #expect(outcome.profile == .created(7))
        await gate.release()
        let old = try #require(await Self.result(of: oldRun))
        #expect(throws: EHNetworkError.cancelled) { try old.get() }
        #expect(h.requests().filter { Self.formFields(of: $0)["profile_action"] == "create" }.count == 1)
    }

    /// Logging out while a login is in flight: the login writes nothing more, whatever its cookies (a rejected
    /// login does not bring the old account back; one with a full identity does not sign in after the logout), and
    /// throws `CancellationError`.
    ///
    /// The login's first vault write (`CookieStore.beginLogin()`, clearing both jars of every site cookie but the
    /// UA-bound Cloudflare ones) is held, so the login is in flight; logOut begins its session at once and then waits
    /// for the cookie store behind that write.
    @Test(arguments: [false, true])
    func logOutDuringALoginBringsNothingBack(deliversIdentity: Bool) async throws {
        let vault = ControlledVault()
        let h = try await Self.makeHarness(
            eh: Self.identity, ex: Self.identity, account: AccountInfo(method: .password, username: "fake-user-a"),
            profileSelection: .off, vault: vault
        )
        defer { h.mock.remove() }
        let service = h.service
        let earlier = vault.operations.count
        let cookies = deliversIdentity
            ? [
                Self.cookie(CookieNames.memberID, "7654321", domain: ".e-hentai.org"),
                Self.cookie(CookieNames.passHash, "fedcba9876543210fedcba9876543210", domain: ".e-hentai.org"),
            ]
            : [Self.cookie("sk", "sk-fake-b", domain: ".e-hentai.org")]
        vault.holdNextWrite()
        let login = Task {
            try await service.completePasswordLogin(cookies: cookies, from: EHEndpoints.forumLogin, username: "fake-user-b")
        }
        #expect(await waitUntil { vault.isHolding })
        let logOut = Task { try await service.logOut() }
        try await Task.sleep(for: .milliseconds(300))
        vault.release()
        try await logOut.value
        let result = try #require(await Self.result(of: login))
        #expect(throws: CancellationError.self) { try result.get() }
        // The reset came after the login's first write, and the login wrote nothing after the reset.
        #expect(Array(vault.operations.dropFirst(earlier)) == [.write, .delete])
        #expect(await !h.cookies.isLoggedIn)
        #expect(await h.cookies.snapshot() == .empty)
        #expect(try h.vault.read() == nil)
    }

    /// A login superseded while the cookie store is still in its epoch leaves nothing of its own: signed in, it puts
    /// the store back and throws `CancellationError`; rejected, it puts the store back and throws `.rejected`. In
    /// memory and in the vault, the store is as it was before the login.
    ///
    /// The login sees a later session (logOut began one) while its own epoch is still the store's. In the case that
    /// matters, the store ran the logout's reset before the login's `beginLogin()` (an actor may run a
    /// later job first, by priority), so the login's snapshot was the empty one; that order cannot be forced from a
    /// test. A reset that fails leaves the login in the same position and can: logOut begins its session while the
    /// login's first write is held (as in `logOutDuringALoginBringsNothingBack`), and its reset changes nothing.
    @Test(arguments: [false, true])
    func supersededLoginInItsOwnEpochPutsTheStoreBack(deliversIdentity: Bool) async throws {
        let vault = ControlledVault()
        let h = try await Self.makeHarness(
            eh: Self.identity, ex: Self.identity, account: AccountInfo(method: .password, username: "fake-user-a"),
            profileSelection: .off, vault: vault
        )
        defer { h.mock.remove() }
        let service = h.service
        let before = await h.cookies.snapshot()
        let cookies = deliversIdentity
            ? [
                Self.cookie(CookieNames.memberID, "7654321", domain: ".e-hentai.org"),
                Self.cookie(CookieNames.passHash, "fedcba9876543210fedcba9876543210", domain: ".e-hentai.org"),
            ]
            : [Self.cookie("sk", "sk-fake-b", domain: ".e-hentai.org")]
        vault.refuseNextDelete()
        vault.holdNextWrite()
        let login = Task {
            try await service.completePasswordLogin(cookies: cookies, from: EHEndpoints.forumLogin, username: "fake-user-b")
        }
        #expect(await waitUntil { vault.isHolding })
        let logOut = Task { try await service.logOut() }
        try await Task.sleep(for: .milliseconds(300))
        vault.release()
        await #expect(throws: ControlledVault.Failure.self) { try await logOut.value }
        let result = try #require(await Self.result(of: login))
        if deliversIdentity {
            #expect(throws: CancellationError.self) { try result.get() }
        } else {
            #expect(throws: LoginError.rejected) { try result.get() }
        }
        // The reset reached the store and changed nothing.
        #expect(vault.operations.contains(.refusedDelete))
        let storeIsAsBefore = await h.cookies.snapshot() == before
        #expect(storeIsAsBefore)
        let vaultIsAsBefore = try Self.persisted(h.vault) == before
        #expect(vaultIsAsBefore)
        let stillA = await h.cookies.memberID == 1_234_567
        #expect(stillA)
        #expect(h.requests().isEmpty)
    }

    /// Two callers, one cancelled: the run goes on and both get its result (the cancelled one waits for it).
    @Test func cancellingOneCallerKeepsTheOther() async throws {
        let gate = GateThrottle()
        let h = try await Self.makeHarness(eh: Self.identity, throttle: gate, responder: Self.uconfig(
            get: MockResponse(body: Data(Self.withoutEros().utf8)), post: MockResponse(body: Data(Self.erosCreated().utf8))
        ))
        defer { h.mock.remove() }
        let service = h.service
        let first = Task { try await service.ensureErosProfile(site: .eh) }
        #expect(await waitUntil { await gate.isHolding })
        let second = Task { try await service.ensureErosProfile(site: .eh) }
        #expect(await waitUntil { await service.profileCallers(for: .eh) == 2 })
        first.cancel()
        #expect(await waitUntil { await service.profileCallers(for: .eh) == 1 })
        await gate.release()
        #expect(try #require(await Self.result(of: second)).get() == .created(7))
        #expect(try #require(await Self.result(of: first)).get() == .created(7))
        #expect(h.requests().filter { Self.formFields(of: $0)["profile_action"] == "create" }.count == 1)
        #expect(await service.profileDiagnostics(for: .eh)?.outcome == .created(7))
        #expect(await service.profileCallers(for: .eh) == 0)
    }

    /// A run whose only caller was cancelled is not joined: the next call starts its own run.
    @Test func cancelledRunIsNotJoined() async throws {
        let gate = GateThrottle()
        let h = try await Self.makeHarness(eh: Self.identity, throttle: gate, responder: Self.uconfig(
            get: MockResponse(body: Data(Self.withoutEros().utf8)), post: MockResponse(body: Data(Self.erosCreated().utf8))
        ))
        defer { h.mock.remove() }
        let service = h.service
        let cancelled = Task { try await service.ensureErosProfile(site: .eh) }
        #expect(await waitUntil { await gate.isHolding })
        cancelled.cancel()
        #expect(await waitUntil { await service.profileCallers(for: .eh) == 0 })
        // The cancelled run is still held at the throttle; a new call does not wait for it.
        let next = Task { try await service.ensureErosProfile(site: .eh) }
        #expect(try #require(await Self.result(of: next)).get() == .created(7))
        await gate.release()
        let result = try #require(await Self.result(of: cancelled))
        #expect(throws: EHNetworkError.cancelled) { try result.get() }
        let get = "GET \(Self.ehUConfig.absoluteString)", post = "POST \(Self.ehUConfig.absoluteString)"
        #expect(Self.methodsAndURLs(h.requests()) == [get, post])
        #expect(await service.profileCallers(for: .eh) == 0)
    }

    /// EH's run waiting at the throttle does not hold up or change EX's; cancelling it leaves EX as it is.
    @Test func sitesRunIndependently() async throws {
        let gate = GateThrottle()
        let created = try Self.erosCreated(), without = try Self.withoutEros()
        let h = try await Self.makeHarness(eh: Self.identity, ex: Self.identity, throttle: gate) { request in
            if request.httpMethod == "POST" {
                let domain = request.url == Self.exUConfig ? ".exhentai.org" : ".e-hentai.org"
                return MockResponse(headers: ["Set-Cookie": "sp=7; path=/; domain=\(domain)"], body: Data(created.utf8))
            }
            return MockResponse(body: Data(without.utf8))
        }
        defer { h.mock.remove() }
        let service = h.service
        let eh = Task { try await service.ensureErosProfile(site: .eh) }
        #expect(await waitUntil { await gate.isHolding })
        let ex = Task { try await service.ensureErosProfile(site: .ex) }
        #expect(try #require(await Self.result(of: ex)).get() == .created(7))
        #expect(await service.profileCallers(for: .eh) == 1)
        #expect(await service.profileCallers(for: .ex) == 0)
        eh.cancel()
        #expect(await waitUntil { await service.profileCallers(for: .eh) == 0 })
        await gate.release()
        let result = try #require(await Self.result(of: eh))
        #expect(throws: EHNetworkError.cancelled) { try result.get() }
        #expect(await h.jar(.ex)[CookieNames.profile] == "7")
        #expect(await h.jar(.eh)[CookieNames.profile] == nil)
        #expect(await service.profileDiagnostics(for: .ex)?.outcome == .created(7))
        #expect(await service.profileDiagnostics(for: .eh) == nil)
        #expect(h.requests().allSatisfy { $0.url?.host() == EHSite.ex.host })
    }

    /// The profile run and the EX check always ask the site, whatever the cache holds.
    @Test func checksNeverUseTheCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "eros-account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unselected = try Self.erosUnselected()
        let h = try await Self.makeHarness(
            eh: Self.identity, ex: Self.identity, profileSelection: .off, cache: ResponseCache(directory: directory)
        ) { request in
            if request.url == Self.exUConfig {
                return MockResponse(headers: ["Set-Cookie": "igneous=\(Self.igneous); path=/; domain=.exhentai.org"], body: Data(unselected.utf8))
            }
            return MockResponse(body: Self.notASettingsPage)
        }
        defer { h.mock.remove() }
        // Stale pages that would answer both checks from the cache.
        let client = EHClient(
            configuration: try EHClientConfiguration(sessionConfigurator: h.mock.configurator), cookies: h.cookies,
            userAgents: h.userAgents, throttle: RecordingThrottle(), cache: ResponseCache(directory: directory)
        )
        for site in EHSite.allCases {
            let stale = EHResponse(
                status: 200, url: EHEndpoints.uconfig(site: site), headers: [:], body: Data(try Self.erosSelected().utf8),
                source: .network
            )
            await client.storeInCache(stale, for: EHRequests.page(EHEndpoints.uconfig(site: site), site: site))
        }
        #expect(try await h.service.activateExHentai() == .granted)
        #expect(try await h.service.ensureErosProfile(site: .eh) == .failed)
        #expect(h.requests().count == 4)
    }

    /// A 503 or 403 is never answered by a cached settings page: no create from an old page, no EX access from one.
    @Test func staleCacheNeverAnswersTheChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "eros-account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = try Self.erosCreated()
        let h = try await Self.makeHarness(
            eh: Self.identity, ex: Self.identity.merging([CookieNames.igneous: Self.igneous]) { $1 }, profileSelection: .off,
            cache: ResponseCache(directory: directory)
        ) { request in
            if request.url == Self.exUConfig { return MockResponse(status: 403) }
            if request.httpMethod == "POST" { return MockResponse(body: Data(created.utf8)) }
            return MockResponse(status: 503)
        }
        defer { h.mock.remove() }
        // Old pages, under the account and profile now in the cookie store.
        for (site, page) in [(EHSite.eh, try Self.withoutEros()), (.ex, try Self.erosSelected())] {
            let url = EHEndpoints.uconfig(site: site)
            let stale = EHResponse(status: 200, url: url, headers: [:], body: Data(page.utf8), source: .network)
            await h.client.storeInCache(stale, for: EHRequests.page(url, site: site))
        }
        await #expect(throws: EHNetworkError.httpStatus(503)) { try await h.service.ensureErosProfile(site: .eh) }
        await #expect(throws: EHNetworkError.httpStatus(403)) { try await h.service.activateExHentai() }
        #expect(Self.methodsAndURLs(h.requests()) == ["GET \(Self.ehUConfig.absoluteString)", "GET \(Self.exUConfig.absoluteString)"])
        #expect(await h.jar(.eh)[CookieNames.profile] == nil)
    }

    // MARK: - ExHentai

    /// A ban in the EX profile run after access was granted: the activation throws it; the igneous tells the access.
    @Test func exProfileNoticeStopsTheActivation() async throws {
        let banned = try Fixtures.data("constructed/eh/banned.txt")
        let requests = Counter()
        let h = try await Self.makeHarness(eh: Self.identity, ex: Self.identity) { request in
            guard request.url == Self.exUConfig else { throw URLError(.badURL) }
            if requests.next() == 1 {
                return MockResponse(
                    headers: ["Set-Cookie": "igneous=\(Self.igneous); path=/; domain=.exhentai.org"],
                    body: Data("<html>Fake</html>".utf8)
                )
            }
            return MockResponse(body: banned)
        }
        defer { h.mock.remove() }
        let error = await #expect(throws: EHNetworkError.self) { try await h.service.activateExHentai() }
        let isBan = if case .issue(.banned)? = error { true } else { false }
        #expect(isBan)
        #expect(await h.jar(.ex)[CookieNames.igneous] == Self.igneous)
        #expect(h.requests().count == 2)
        let diagnosed = await h.service.profileDiagnostics(for: .ex)?.outcome
        let isStoppedByBan = if case .stopped(.banned)? = diagnosed { true } else { false }
        #expect(isStoppedByBan)
    }

    @Test func exActivationCapturesIgneous() async throws {
        let captured = try Fixtures.data("ex/account/uconfig.html")
        let h = try await Self.makeHarness(eh: Self.identity, ex: Self.identity, profileSelection: .off, responder: Self.uconfig(
            site: .ex,
            get: MockResponse(headers: ["Set-Cookie": "igneous=\(Self.igneous); path=/; domain=.exhentai.org"], body: captured)
        ))
        defer { h.mock.remove() }
        #expect(try await h.service.activateExHentai() == .granted)
        #expect(await h.jar(.ex)[CookieNames.igneous] == Self.igneous)
        #expect(await h.jar(.eh)[CookieNames.igneous] == nil)
        let requests = h.requests()
        #expect(Self.methodsAndURLs(requests) == ["GET \(Self.exUConfig.absoluteString)"])
        #expect(requests[0].value(forHTTPHeaderField: "Cookie")?.contains(Self.passHash) == true)
    }

    @Test func exActivationSelectsTheEXProfile() async throws {
        let selected = try Self.erosSelected()
        let h = try await Self.makeHarness(eh: Self.identity, ex: Self.identity, responder: Self.uconfig(
            site: .ex,
            get: MockResponse(headers: ["Set-Cookie": "igneous=\(Self.igneous); path=/; domain=.exhentai.org"], body: Data(selected.utf8))
        ))
        defer { h.mock.remove() }
        #expect(try await h.service.activateExHentai() == .granted)
        #expect(Self.methodsAndURLs(h.requests()) == Array(repeating: "GET \(Self.exUConfig.absoluteString)", count: 2))
        #expect(await h.jar(.ex)[CookieNames.profile] == "5")
        #expect(await h.jar(.eh)[CookieNames.profile] == nil)
        #expect(await h.service.profileDiagnostics(for: .ex)?.outcome == .alreadySelected(5))
    }

    @Test func mysteryIgneousMeansDenied() async throws {
        let h = try await Self.makeHarness(eh: Self.identity, ex: Self.identity, responder: Self.uconfig(
            site: .ex,
            get: MockResponse(headers: ["Set-Cookie": "igneous=mystery; path=/; domain=.exhentai.org"], body: Data("<html>Fake</html>".utf8))
        ))
        defer { h.mock.remove() }
        #expect(try await h.service.activateExHentai() == .denied)
        #expect(await h.jar(.ex)[CookieNames.igneous] == nil)
        // Denied: no profile run on EX.
        #expect(h.requests().count == 1)

        // "mystery" already in the jar (set by hand) is no access either.
        let stored = try await Self.makeHarness(
            eh: Self.identity, ex: Self.identity.merging([CookieNames.igneous: "mystery"]) { $1 },
            responder: Self.uconfig(site: .ex, get: MockResponse(body: Data("<html>Fake</html>".utf8)))
        )
        defer { stored.mock.remove() }
        #expect(try await stored.service.activateExHentai() == .denied)
    }

    @Test func emptyEXPageMeansDenied() async throws {
        let h = try await Self.makeHarness(eh: Self.identity, ex: Self.identity, responder: Self.uconfig(site: .ex, get: MockResponse()))
        defer { h.mock.remove() }
        #expect(try await h.service.activateExHentai() == .denied)
        #expect(h.requests().count == 1)
    }

    @Test func refreshIgneousClearsFirst() async throws {
        let h = try await Self.makeHarness(
            eh: Self.identity, ex: Self.identity.merging([CookieNames.igneous: "igneous-fake-old"]) { $1 },
            profileSelection: .off,
            responder: Self.uconfig(
                site: .ex,
                get: MockResponse(headers: ["Set-Cookie": "igneous=\(Self.igneous); path=/; domain=.exhentai.org"], body: Data("<html>Fake</html>".utf8))
            )
        )
        defer { h.mock.remove() }
        #expect(try await h.service.refreshIgneous() == .granted)
        let cookie = h.requests().first?.value(forHTTPHeaderField: "Cookie") ?? ""
        #expect(!cookie.contains("igneous="))
        #expect(cookie.contains(Self.passHash))
        #expect(await h.jar(.ex)[CookieNames.igneous] == Self.igneous)
    }

    // MARK: - Forum profile, logout, unloaded store

    @Test func forumProfileIsKeptWithTheAccount() async throws {
        let h = try await Self.makeHarness(profileSelection: .off)
        defer { h.mock.remove() }
        // No account yet: nothing is written.
        try await h.service.updateForumProfile(ForumProfile(displayName: "Fake Nickname", avatarURL: nil), memberID: 1_234_567)
        #expect(await h.cookies.snapshot() == .empty)

        _ = try await h.service.logIn(with: CookieCredentials(memberID: Self.memberID, passHash: Self.passHash))
        let avatar = URL(string: "https://forums.e-hentai.org/uploads/fake-avatar.png")!
        // A page read for another member (logged out and replaced meanwhile) is dropped.
        try await h.service.updateForumProfile(ForumProfile(displayName: "Fake Other", avatarURL: nil), memberID: 7_654_321)
        #expect(await h.cookies.snapshot().account == AccountInfo(method: .cookie))
        let before = Date()
        try await h.service.updateForumProfile(ForumProfile(displayName: "Fake Nickname", avatarURL: avatar), memberID: 1_234_567)
        let after = Date()
        let account = try #require(await h.cookies.snapshot().account)
        #expect(account.method == .cookie)
        #expect(account.displayName == "Fake Nickname")
        #expect(account.avatarURL == avatar)
        let fetchedAt = try #require(account.profileFetchedAt)
        #expect(fetchedAt >= before && fetchedAt <= after)

        // nil forgets what was read.
        try await h.service.updateForumProfile(nil, memberID: 1_234_567)
        #expect(await h.cookies.snapshot().account == AccountInfo(method: .cookie))
    }

    @Test func logoutClearsEverything() async throws {
        let h = try await Self.makeHarness(eh: ["cf_clearance": "clearance-fake-0001"], responder: Self.uconfig(
            get: MockResponse(body: Data(Self.erosSelected().utf8))
        ))
        defer { h.mock.remove() }
        _ = try await h.service.logIn(with: CookieCredentials(memberID: Self.memberID, passHash: Self.passHash))
        #expect(await h.service.profileDiagnostics(for: .eh) != nil)
        try await h.service.logOut()
        #expect(await !h.cookies.isLoggedIn)
        #expect(await h.cookies.snapshot().cookies.isEmpty)
        #expect(await h.cookies.snapshot().account == nil)
        #expect(try h.vault.read() == nil)
        #expect(await h.service.profileDiagnostics(for: .eh) == nil)
    }

    /// Before the cookie store has loaded, every account action but logging out throws `.notLoaded` and sends nothing.
    @Test func unloadedStoreSendsNothing() async throws {
        let h = try await Self.makeHarness(loaded: false) { _ in MockResponse(body: Data("<html>Fake</html>".utf8)) }
        defer { h.mock.remove() }
        let credentials = CookieCredentials(memberID: Self.memberID, passHash: Self.passHash)
        let webCookies = [
            Self.cookie(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org"),
            Self.cookie(CookieNames.passHash, Self.passHash, domain: ".e-hentai.org"),
        ]
        await #expect(throws: CookieStoreError.notLoaded) {
            try await h.service.completePasswordLogin(cookies: webCookies, from: EHEndpoints.forumLogin, username: "fake-user")
        }
        await #expect(throws: CookieStoreError.notLoaded) { try await h.service.logIn(with: credentials) }
        await #expect(throws: CookieStoreError.notLoaded) {
            try await h.service.completeWebLogin(cookies: webCookies, from: EHEndpoints.webLoginStart)
        }
        await #expect(throws: CookieStoreError.notLoaded) { try await h.service.activateExHentai() }
        await #expect(throws: CookieStoreError.notLoaded) { try await h.service.refreshIgneous() }
        await #expect(throws: CookieStoreError.notLoaded) { try await h.service.ensureErosProfile(site: .eh) }
        await #expect(throws: CookieStoreError.notLoaded) {
            try await h.service.updateForumProfile(ForumProfile(displayName: "Fake Nickname", avatarURL: nil), memberID: 1_234_567)
        }
        #expect(h.requests().isEmpty)
        #expect(await h.cookies.snapshot() == .empty)
        // Logging out always works.
        try await h.service.logOut()
        #expect(await h.cookies.isLoaded)
    }
}

/// Holds the `target`-th `acquire(for:)` (the first by default) until `release()`; lets every other one through at
/// once. The hold ignores cancellation, as a request already past the throttle's own checks would.
private actor GateThrottle: RequestThrottle {
    private let target: Int
    private var count = 0
    private(set) var isHolding = false
    private var isOpen = false
    private var held: CheckedContinuation<Void, Never>?

    init(holding target: Int = 1) {
        self.target = target
    }

    func acquire(for url: URL) async throws {
        count += 1
        guard count == target, !isOpen else { return }
        isHolding = true
        await withCheckedContinuation { held = $0 }
    }

    func release() {
        isOpen = true
        held?.resume()
        held = nil
    }
}

/// A thread-safe counter for mock responders: `next()` gives 1, 2, 3, ….
private final class Counter: Sendable {
    private let value = Mutex(0)

    func next() -> Int {
        value.withLock { count in
            count += 1
            return count
        }
    }
}

/// A vault over an `InMemoryVault` that can refuse its next write or hold it until `release()`, and refuse its next
/// delete; it records the writes and deletes it carried out, and the deletes it refused. A held write blocks the
/// cookie store's actor, as a slow Keychain would.
private final class ControlledVault: CredentialVault {
    struct Failure: Error {}

    enum Operation: Equatable, Sendable {
        case write, delete, refusedDelete
    }

    private struct State {
        var failsNext = false
        var holdsNext = false
        var refusesNextDelete = false
        var isHolding = false
        var operations: [Operation] = []
    }

    let inner = InMemoryVault()
    private let state = Mutex(State())
    private let gate = DispatchSemaphore(value: 0)

    var isHolding: Bool { state.withLock { $0.isHolding } }
    var operations: [Operation] { state.withLock { $0.operations } }

    func failNextWrite() { state.withLock { $0.failsNext = true } }
    func holdNextWrite() { state.withLock { $0.holdsNext = true } }
    func refuseNextDelete() { state.withLock { $0.refusesNextDelete = true } }

    func release() {
        state.withLock { $0.isHolding = false }
        gate.signal()
    }

    func read() throws -> Data? { try inner.read() }

    func write(_ data: Data) throws {
        let (fails, holds) = state.withLock { state in
            defer { state.failsNext = false; state.holdsNext = false }
            if state.holdsNext { state.isHolding = true }
            return (state.failsNext, state.holdsNext)
        }
        if holds { gate.wait() }
        if fails { throw Failure() }
        try inner.write(data)
        state.withLock { $0.operations.append(.write) }
    }

    func delete() throws {
        let refuses = state.withLock { state in
            defer { state.refusesNextDelete = false }
            if state.refusesNextDelete { state.operations.append(.refusedDelete) }
            return state.refusesNextDelete
        }
        if refuses { throw Failure() }
        try inner.delete()
        state.withLock { $0.operations.append(.delete) }
    }
}
