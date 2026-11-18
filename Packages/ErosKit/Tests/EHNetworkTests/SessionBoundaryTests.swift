import EHFixtures
import EHModels
import EHNetwork
import EHNetworkTesting
import EHParsing
import Foundation
import Synchronization
import Testing

/// Where one session ends and the next begins: logging out, a login, and the
/// requests in flight across them. Every request goes to `MockURLProtocol`; every value is made up.
@Suite struct SessionBoundaryTests {
    private static let memberA = "1234567", passHashA = "0123456789abcdef0123456789abcdef"
    private static let memberB = "7654321", passHashB = "fedcba9876543210fedcba9876543210"
    private static let identityA = [CookieNames.memberID: memberA, CookieNames.passHash: passHashA]
    private static let identityB = [CookieNames.memberID: memberB, CookieNames.passHash: passHashB]
    private static let webKitUserAgent = "FakeWebKit/1"

    private static let ehPage = URL(string: "https://e-hentai.org/g/1234/0123456789/")!
    private static let exPage = URL(string: "https://exhentai.org/g/1234/0123456789/")!
    private static let redirecting = URL(string: "https://e-hentai.org/r/1")!
    private static let accountPage = Data("<html><body>fake account page</body></html>".utf8)
    private static let anonymousPage = Data("<html><body>fake anonymous page</body></html>".utf8)

    private struct Harness {
        let service: AccountService
        let client: EHClient
        let cookies: CookieStore
        let vault: any CredentialVault
        let cache: ResponseCache
        let directory: URL
        let mock: MockSession

        func jar(_ site: EHSite) async -> [String: String] {
            await cookies.snapshot().cookies[site] ?? [:]
        }

        /// The names of the files in the cache directory.
        func files() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
        }

        func cleanUp() {
            mock.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A loaded cookie store with the given jars and account, the WebKit UA, a response cache in a new temporary
    /// directory, and an account service that never chooses a profile (it sends nothing of its own).
    private static func makeHarness(
        eh: [String: String] = [:], ex: [String: String] = [:], account: AccountInfo? = nil,
        vault: any CredentialVault = InMemoryVault(), throttle: any RequestThrottle = RecordingThrottle(),
        responder: @escaping @Sendable (URLRequest) throws -> MockResponse = { _ in MockResponse(body: accountPage) }
    ) async throws -> Harness {
        let mock = MockURLProtocol.install(responder)
        let cookies = CookieStore(vault: vault)
        try await cookies.load()
        if !eh.isEmpty { try await cookies.set(eh, for: [.eh]) }
        if !ex.isEmpty { try await cookies.set(ex, for: [.ex]) }
        if let account { try await cookies.setAccount(account) }
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        await userAgents.load()
        _ = await userAgents.adopt(webKitUserAgent)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "eros-session-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = ResponseCache(directory: directory)
        let client = EHClient(
            configuration: try EHClientConfiguration(sessionConfigurator: mock.configurator), cookies: cookies,
            userAgents: userAgents, throttle: throttle, cache: cache
        )
        let service = AccountService(client: client, cookies: cookies, profileSelection: .off, retryDelay: .zero)
        return Harness(
            service: service, client: client, cookies: cookies, vault: vault, cache: cache, directory: directory,
            mock: mock
        )
    }

    private static func cookie(_ name: String, _ value: String, domain: String?) -> ParsedCookie {
        ParsedCookie(name: name, value: value, domain: domain, expiresAt: nil, isDeletion: false)
    }

    // MARK: - Pages of an ended session are not handed on (C5)

    private static let frontList = Data(try! Fixtures.data("eh/list/front.html"))
    private static let nonCompactList = Data(try! Fixtures.data("constructed/eh/list-non-compact.html"))

    private static func makeService(_ h: Harness) -> EHService {
        EHService(client: h.client, presenter: AlwaysAgree(), ledger: InMemoryNoticeLedger())
    }

    /// A list requested before the logout is dropped with `.sessionEnded`, while `EHClient.send` itself still hands
    /// the login flows their answer (the control: a page request in flight across the same logout returns 200).
    @Test func listOfAnEndedSessionIsDropped() async throws {
        // One at a time: the mock's loading thread is blocked while a gate holds a response.
        let listGate = ResponseGate(), controlGate = ResponseGate()
        let h = try await Self.makeHarness(eh: Self.identityA) { request in
            if request.url == Self.ehPage {
                controlGate.pass()
                return MockResponse(body: Self.accountPage)
            }
            listGate.pass()
            return MockResponse(body: Self.frontList)
        }
        defer { h.cleanUp() }
        let service = Self.makeService(h), client = h.client
        let list = Task { try await service.galleryList(ListQuery(source: .front), site: .eh) }
        defer { list.cancel() }
        #expect(await waitUntil { listGate.hasArrived })
        try await h.service.logOut()
        listGate.open()
        await #expect(throws: EHNetworkError.sessionEnded) { try await list.value }
        // The control: `send` itself still returns the answer of a request in flight across a logout.
        let control = Task { try await client.send(EHRequest(url: Self.ehPage, site: .eh)) }
        defer { control.cancel() }
        #expect(await waitUntil { controlGate.hasArrived })
        try await h.service.logOut()
        controlGate.open()
        #expect(try await control.value.status == 200)
    }

    /// `galleryListResult` drops a list of an ended session the same way: its `- Throws` names `.sessionEnded`, which
    /// the callers drop silently.
    @Test func listResultOfAnEndedSessionIsDropped() async throws {
        let gate = ResponseGate()
        let h = try await Self.makeHarness(eh: Self.identityA) { _ in
            gate.pass()
            return MockResponse(body: Self.frontList)
        }
        defer { h.cleanUp() }
        let service = Self.makeService(h)
        let list = Task { try await service.galleryListResult(ListQuery(source: .front), site: .eh, refresh: false) }
        defer { list.cancel() }
        #expect(await waitUntil { gate.hasArrived })
        try await h.service.logOut()
        gate.open()
        await #expect(throws: EHNetworkError.sessionEnded) { try await list.value }
    }

    @Test func pageOfAnEndedSessionIsDropped() async throws {
        let gate = ResponseGate()
        let h = try await Self.makeHarness(eh: Self.identityA) { _ in
            gate.pass()
            return MockResponse(body: Self.accountPage)
        }
        defer { h.cleanUp() }
        let service = Self.makeService(h)
        let parsed = Mutex(false)
        let page = Task {
            try await service.page(Self.ehPage, site: .eh) { _ in parsed.withLock { $0 = true } }
        }
        defer { page.cancel() }
        #expect(await waitUntil { gate.hasArrived })
        try await h.service.logOut()
        gate.open()
        await #expect(throws: EHNetworkError.sessionEnded) { try await page.value }
        #expect(!parsed.withLock { $0 })
    }

    @Test func apiAnswerOfAnEndedSessionIsDropped() async throws {
        let gate = ResponseGate()
        let h = try await Self.makeHarness(eh: Self.identityA) { _ in
            gate.pass()
            return MockResponse(body: Data("{}".utf8))
        }
        defer { h.cleanUp() }
        let service = Self.makeService(h)
        let parsed = Mutex(false)
        let call = Task {
            try await service.api(EHAPI.tagsuggest("fake", site: .eh)) { _ in parsed.withLock { $0 = true } }
        }
        defer { call.cancel() }
        #expect(await waitUntil { gate.hasArrived })
        try await h.service.logOut()
        gate.open()
        await #expect(throws: EHNetworkError.sessionEnded) { try await call.value }
        #expect(!parsed.withLock { $0 })
    }

    /// A page from the cache belongs to the session its scope was read in: with no change since, it is current.
    @Test func cachedPagesAreCurrent() async throws {
        let h = try await Self.makeHarness(eh: Self.identityA) { _ in MockResponse(body: Self.frontList) }
        defer { h.cleanUp() }
        let service = Self.makeService(h)
        #expect(try await service.galleryList(ListQuery(source: .front), site: .eh).items.count == 25)
        #expect(try await service.galleryList(ListQuery(source: .front), site: .eh).items.count == 25)
        #expect(h.mock.requests().count == 1)
    }

    // MARK: - The Compact resend across a session change

    /// The Compact resend (`inline_set=dm_l` changes the account's setting on the site) waits at the throttle while
    /// another account signs in: it is not sent with that account's cookies, and the list ends with `.sessionEnded`.
    @Test func resendOfAnEndedSessionIsNotSent() async throws {
        let throttle = HoldingThrottle(holding: 2)
        let h = try await Self.makeHarness(eh: Self.identityA, throttle: throttle) { request in
            let resent = request.url?.absoluteString.contains("inline_set") == true
            return MockResponse(body: resent ? Self.frontList : Self.nonCompactList)
        }
        defer { h.cleanUp() }
        let service = Self.makeService(h)
        let list = Task { try await service.galleryList(ListQuery(source: .front), site: .eh) }
        defer { list.cancel() }
        #expect(await waitUntil { await throttle.isHolding })
        try await h.service.logOut()
        _ = try await h.service.logIn(with: CookieCredentials(memberID: Self.memberB, passHash: Self.passHashB))
        await throttle.release()
        await #expect(throws: EHNetworkError.sessionEnded) { try await list.value }
        #expect(h.mock.requests().count == 1)
        #expect(h.mock.requests().allSatisfy { $0.url?.absoluteString.contains("inline_set") == false })
    }

    /// The session ends while the resend is in flight: whatever comes back (still not Compact, or the list) is
    /// dropped with `.sessionEnded`, never reported as a display mode problem, and not cached.
    @Test(arguments: [false, true])
    func resendAnsweredAfterTheSessionEndedIsDropped(resendIsCompact: Bool) async throws {
        let gate = ResponseGate()
        let resent = resendIsCompact ? Self.frontList : Self.nonCompactList
        let h = try await Self.makeHarness(eh: Self.identityA) { request in
            guard request.url?.absoluteString.contains("inline_set") == true else {
                return MockResponse(body: Self.nonCompactList)
            }
            gate.pass()
            return MockResponse(body: resent)
        }
        defer { h.cleanUp() }
        let service = Self.makeService(h)
        let list = Task { try await service.galleryList(ListQuery(source: .front), site: .eh) }
        defer { list.cancel() }
        #expect(await waitUntil { gate.hasArrived })
        // Not through logging out, which would clear the cache: only the session changes.
        try await h.cookies.reset()
        gate.open()
        await #expect(throws: EHNetworkError.sessionEnded) { try await list.value }
        #expect(h.mock.requests().count == 2)
        #expect(try h.files().isEmpty)
    }

    // MARK: - Requests in flight when the session ends

    /// PROBE-A: a response that comes back after logging out writes no cookie, neither into the jars nor into the
    /// vault, and its page does not land in the cache the logout cleared.
    @Test func responseAfterLogoutWritesNothing() async throws {
        let gate = ResponseGate()
        let h = try await Self.makeHarness(eh: Self.identityA, ex: Self.identityA) { _ in
            gate.pass()
            return MockResponse(
                headers: [
                    "Set-Cookie": "sk=sk-fake-late; path=/; domain=.e-hentai.org, "
                        + "hath_perks=perks-fake-late; path=/; domain=.e-hentai.org",
                ],
                body: Self.accountPage
            )
        }
        defer { h.cleanUp() }
        let client = h.client
        let send = Task { try await client.send(EHRequest(url: Self.ehPage, site: .eh)) }
        #expect(await waitUntil { gate.hasArrived })
        try await h.service.logOut()
        gate.open()
        let response = try await send.value
        #expect(response.source == .network)
        #expect(await h.cookies.snapshot() == .empty)
        #expect(try h.vault.read() == nil)
        #expect(await !h.cookies.isLoggedIn)
        #expect(try h.files().isEmpty)
    }

    /// A redirect that comes back after logging out: its Set-Cookie is dropped and the hop is refused, so nothing
    /// goes out under the ended session's request.
    @Test func redirectAfterLogoutIsRefused() async throws {
        let gate = ResponseGate()
        let target = URL(string: "https://e-hentai.org/r/2")!
        let h = try await Self.makeHarness(eh: Self.identityA) { request in
            guard request.url == Self.redirecting else { return MockResponse(body: Self.accountPage) }
            gate.pass()
            return MockResponse(
                status: 302, headers: ["Set-Cookie": "sk=sk-fake-hop; path=/; domain=.e-hentai.org"], redirectTo: target
            )
        }
        defer { h.cleanUp() }
        let client = h.client
        let send = Task { try await client.send(EHRequest(url: Self.redirecting, site: .eh)) }
        #expect(await waitUntil { gate.hasArrived })
        try await h.service.logOut()
        gate.open()
        await #expect(throws: EHNetworkError.cancelled) { try await send.value }
        #expect(h.mock.requests().map(\.url) == [Self.redirecting])
        #expect(await h.cookies.snapshot() == .empty)
        #expect(try h.vault.read() == nil)
    }

    /// A hop waiting at the throttle while a login signs in is refused: it would go out with the new account's
    /// cookies as part of a request sent signed out, and its page would be cached under the anonymous scope.
    @Test func hopWaitingAtTheThrottleIsRefusedAfterALogin() async throws {
        let throttle = HoldingThrottle(holding: 2)
        let h = try await Self.makeHarness(throttle: throttle) { request in
            request.url == Self.redirecting
                ? MockResponse(status: 302, redirectTo: Self.exPage) : MockResponse(body: Self.accountPage)
        }
        defer { h.cleanUp() }
        let client = h.client
        let send = Task { try await client.send(EHRequest(url: Self.redirecting, site: .eh)) }
        #expect(await waitUntil { await throttle.isHolding })
        _ = try await h.service.logIn(with: CookieCredentials(memberID: Self.memberB, passHash: Self.passHashB))
        await throttle.release()
        await #expect(throws: EHNetworkError.cancelled) { try await send.value }
        #expect(h.mock.requests().map(\.url) == [Self.redirecting])
        #expect(try h.files().isEmpty)
        #expect(await h.cookies.isLoggedIn)
    }

    /// PROBE-B (m1): the cache scope is read with the Cookie header, after the throttle. A request that waited while
    /// the session ended is sent signed out, so its page is stored as the anonymous one, never under the account
    /// and profile from before the wait.
    @Test func cacheScopeIsReadWithTheCookieHeader() async throws {
        let throttle = HoldingThrottle(holding: 1)
        let signedIn = Self.identityA.merging([CookieNames.profile: "4"]) { $1 }
        let h = try await Self.makeHarness(eh: signedIn, throttle: throttle) { request in
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            return MockResponse(body: cookie.contains("\(CookieNames.memberID)=") ? Self.accountPage : Self.anonymousPage)
        }
        defer { h.cleanUp() }
        let client = h.client
        let send = Task { try await client.send(EHRequest(url: Self.ehPage, site: .eh)) }
        #expect(await waitUntil { await throttle.isHolding })
        try await h.cookies.reset()
        await throttle.release()
        #expect(try await send.value.body == Self.anonymousPage)
        #expect(await h.cache.lookup(CacheKey(url: Self.ehPage, scope: "anonymous|-"))?.body == Self.anonymousPage)
        #expect(await h.cache.lookup(CacheKey(url: Self.ehPage, scope: "1234567|4")) == nil)

        // The same account and profile again: its own page, from the site.
        try await h.cookies.set(signedIn, for: [.eh])
        let again = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        #expect(again.source == .network)
        #expect(again.body == Self.accountPage)
        #expect(h.mock.requests().count == 2)
    }

    // MARK: - Storing a response later (EHService's Compact resend)

    /// The page is stored under the account and profile its request went out with, not the ones current when
    /// `storeInCache` runs (here the profile changed in between).
    @Test func storeInCacheKeepsTheScopeTheRequestWentOutWith() async throws {
        let h = try await Self.makeHarness(eh: Self.identityA.merging([CookieNames.profile: "4"]) { $1 })
        defer { h.cleanUp() }
        let resend = URL(string: "https://e-hentai.org/?inline_set=dm_l")!
        let resent = try await h.client.send(EHRequest(url: resend, site: .eh, cachePolicy: .none))
        try await h.cookies.set([CookieNames.profile: "5"], for: [.eh])
        let first = EHRequest(url: Self.ehPage, site: .eh)
        await h.client.storeInCache(resent, for: first)
        #expect(await h.cache.lookup(CacheKey(url: Self.ehPage, scope: "1234567|4"))?.body == Self.accountPage)
        #expect(await h.cache.lookup(CacheKey(url: Self.ehPage, scope: "1234567|5")) == nil)
        #expect(try h.files().count == 1)
        // A request on the other site is not this response's: nothing is stored for it.
        await h.client.storeInCache(resent, for: EHRequest(url: Self.exPage, site: .ex))
        #expect(try h.files().count == 1)
    }

    /// Sent as A, then the session changed before `storeInCache`: nothing is stored, under B's key or any other.
    /// Logging out also clears the cache; a reset outside the account service (another login path) changes only
    /// the epoch, which is checked on its own.
    @Test(arguments: [true, false])
    func storeInCacheAfterTheSessionChangedStoresNothing(throughLogOut: Bool) async throws {
        let h = try await Self.makeHarness(eh: Self.identityA)
        defer { h.cleanUp() }
        let resend = URL(string: "https://e-hentai.org/?inline_set=dm_l")!
        let resent = try await h.client.send(EHRequest(url: resend, site: .eh, cachePolicy: .none))
        if throughLogOut {
            try await h.service.logOut()
            _ = try await h.service.logIn(with: CookieCredentials(memberID: Self.memberB, passHash: Self.passHashB))
        } else {
            try await h.cookies.reset()
            try await h.cookies.set(Self.identityB, for: Set(EHSite.allCases))
        }
        await h.client.storeInCache(resent, for: EHRequest(url: Self.ehPage, site: .eh))
        #expect(await h.cache.lookup(CacheKey(url: Self.ehPage, scope: "7654321|-")) == nil)
        #expect(await h.cache.lookup(CacheKey(url: Self.ehPage, scope: "1234567|-")) == nil)
        #expect(try h.files().isEmpty)
        // B's own request does not get A's page.
        let page = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        #expect(page.source == .network)
    }

    // MARK: - Logging out

    /// The cache's own gate: a page in flight while the cache is cleared is not stored,
    /// although the cookie store's session has not changed. Only the cache generation moves here, so the epoch check
    /// that stops it on a logout is not what stops it: checking the epoch and writing the page are two steps, and a
    /// logout's reset and clear may come between them.
    @Test func pageInFlightWhenTheCacheIsClearedIsNotStored() async throws {
        let gate = ResponseGate()
        let h = try await Self.makeHarness(eh: Self.identityA) { _ in
            gate.pass()
            return MockResponse(body: Self.accountPage)
        }
        defer { h.cleanUp() }
        let epoch = await h.cookies.epoch
        let client = h.client
        let send = Task { try await client.send(EHRequest(url: Self.ehPage, site: .eh)) }
        #expect(await waitUntil { gate.hasArrived })
        await client.removeAllCachedResponses()
        gate.open()
        #expect(try await send.value.source == .network)
        #expect(await h.cookies.epoch == epoch)
        #expect(try h.files().isEmpty)
        // A page asked for after the clear is stored as usual: the cache itself works.
        gate.open()
        #expect(try await client.send(EHRequest(url: Self.ehPage, site: .eh)).source == .network)
        #expect(try h.files().count == 1)
    }

    /// Logging out deletes every cached page (the account's favorites must not stay on disk for three days), also
    /// when the vault cannot be deleted.
    @Test func logOutClearsTheResponseCache() async throws {
        let h = try await Self.makeHarness(eh: Self.identityA)
        defer { h.cleanUp() }
        _ = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        _ = try await h.client.send(EHRequest(url: Self.exPage, site: .ex))
        #expect(try h.files().count == 2)
        try await h.service.logOut()
        #expect(try h.files().isEmpty)
        #expect(try await h.client.send(EHRequest(url: Self.ehPage, site: .eh)).source == .network)

        let failing = try await Self.makeHarness(vault: FailingVault(stored: nil))
        defer { failing.cleanUp() }
        _ = try await failing.client.send(EHRequest(url: Self.ehPage, site: .eh))
        #expect(try failing.files().count == 1)
        await #expect(throws: FailingVault.Failure.self) { try await failing.service.logOut() }
        #expect(try failing.files().isEmpty)
    }

    // MARK: - Logins

    /// N7 m7: signed out, the jars may still hold what an earlier account left (a response after logging out in an
    /// older build, a cookie the site set while signed out). A login starts from the UA-bound Cloudflare cookies
    /// only: none of it goes out with the new identity.
    @Test(arguments: [LoginMethod.cookie, .password])
    func loginTakesNothingAnEarlierAccountLeft(method: LoginMethod) async throws {
        let h = try await Self.makeHarness(
            eh: [
                "hath_perks": "perks-fake-a", "sk": "sk-fake-a", CookieNames.profile: "4",
                CookieNames.clearance: "clearance-fake-0001",
            ],
            ex: [CookieNames.igneous: "igneous-fake-a", CookieNames.profile: "2", "sk": "sk-fake-a", "__cf_bm": "bm-fake-0002"],
            account: AccountInfo(method: .password, username: "fake-user-a")
        )
        defer { h.cleanUp() }
        switch method {
        case .cookie:
            _ = try await h.service.logIn(with: CookieCredentials(memberID: Self.memberB, passHash: Self.passHashB))
        default:
            let cookies = Self.identityB.map { Self.cookie($0.key, $0.value, domain: ".e-hentai.org") }
            _ = try await h.service.completePasswordLogin(cookies: cookies, from: EHEndpoints.forumLogin, username: "fake-user-b")
        }
        #expect(await h.jar(.eh) == Self.identityB.merging([CookieNames.clearance: "clearance-fake-0001"]) { $1 })
        #expect(await h.jar(.ex) == Self.identityB.merging(["__cf_bm": "bm-fake-0002"]) { $1 })
        let account = await h.cookies.snapshot().account
        #expect(account?.method == method && account?.username != "fake-user-a")
        let persisted = try h.vault.read().map { try JSONDecoder().decode(SessionSnapshot.self, from: $0) }
        #expect(persisted == (await h.cookies.snapshot()))

        _ = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        _ = try await h.client.send(EHRequest(url: Self.exPage, site: .ex))
        let headers = h.mock.requests().map { $0.value(forHTTPHeaderField: "Cookie") ?? "" }
        #expect(headers.count == 2)
        for header in headers {
            #expect(header.contains("\(CookieNames.memberID)=\(Self.memberB)"))
            #expect(!header.contains("fake-a"))
            #expect(!header.contains("\(CookieNames.profile)="))
        }
    }

    /// Signed in as A, a login as B (no logout between: an account switch) takes none of A's cookies; a login as B
    /// that fails puts A's session back whole (every login clears both jars).
    @Test func loginWhileSignedInTakesNothingOfTheSignedInAccount() async throws {
        let ehA = Self.identityA.merging([
            "hath_perks": "perks-fake-a", "sk": "sk-fake-a", CookieNames.profile: "4",
            CookieNames.clearance: "clearance-fake-0001",
        ]) { $1 }
        let exA = Self.identityA.merging([CookieNames.igneous: "igneous-fake-a", CookieNames.profile: "2"]) { $1 }
        let accountA = AccountInfo(method: .password, username: "fake-user-a")
        let h = try await Self.makeHarness(eh: ehA, ex: exA, account: accountA)
        defer { h.cleanUp() }
        _ = try await h.service.logIn(with: CookieCredentials(memberID: Self.memberB, passHash: Self.passHashB))
        #expect(await h.jar(.eh) == Self.identityB.merging([CookieNames.clearance: "clearance-fake-0001"]) { $1 })
        #expect(await h.jar(.ex) == Self.identityB)
        #expect(await h.cookies.snapshot().account == AccountInfo(method: .cookie))
        _ = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        _ = try await h.client.send(EHRequest(url: Self.exPage, site: .ex))
        let headers = h.mock.requests().map { $0.value(forHTTPHeaderField: "Cookie") ?? "" }
        #expect(headers.count == 2)
        for header in headers {
            #expect(header.contains("\(CookieNames.memberID)=\(Self.memberB)"))
            #expect(!header.contains(Self.memberA))
            #expect(!header.contains("fake-a"))
            #expect(!header.contains("\(CookieNames.profile)="))
        }

        // Rejected: A is signed in again, exactly as before, in memory and in the vault.
        let failed = try await Self.makeHarness(eh: ehA, ex: exA, account: accountA)
        defer { failed.cleanUp() }
        let before = await failed.cookies.snapshot()
        await #expect(throws: LoginError.rejected) {
            try await failed.service.completePasswordLogin(
                cookies: [Self.cookie("sk", "sk-fake-b", domain: ".e-hentai.org")], from: EHEndpoints.forumLogin,
                username: "fake-user-b"
            )
        }
        #expect(await failed.cookies.snapshot() == before)
        let persisted = try failed.vault.read().map { try JSONDecoder().decode(SessionSnapshot.self, from: $0) }
        #expect(persisted == before)
        #expect(await failed.cookies.memberID == 1_234_567)
    }

    /// An igneous an earlier account left in the EX jar does not make ExHentai access for the new one.
    @Test func leftoverIgneousGrantsNothing() async throws {
        let h = try await Self.makeHarness(ex: [CookieNames.igneous: "igneous-fake-a"]) { _ in
            // ExHentai answers B's settings page without an igneous.
            MockResponse(body: Data("<html>Fake</html>".utf8))
        }
        defer { h.cleanUp() }
        _ = try await h.service.logIn(with: CookieCredentials(memberID: Self.memberB, passHash: Self.passHashB))
        #expect(try await h.service.activateExHentai() == .denied)
        let cookie = h.mock.requests().first?.value(forHTTPHeaderField: "Cookie") ?? ""
        #expect(!cookie.contains(CookieNames.igneous))
    }

    /// A rejected login from a signed-out store puts back what it cleared: the store is exactly as before.
    @Test func rejectedLoginPutsTheJarsBack() async throws {
        let h = try await Self.makeHarness(
            eh: ["sk": "sk-fake-a", CookieNames.clearance: "clearance-fake-0001"], ex: [CookieNames.igneous: "igneous-fake-a"]
        )
        defer { h.cleanUp() }
        let before = await h.cookies.snapshot()
        let epoch = await h.cookies.epoch
        await #expect(throws: LoginError.rejected) {
            try await h.service.completeWebLogin(
                cookies: [Self.cookie("sk", "sk-fake-b", domain: ".e-hentai.org")], from: EHEndpoints.webLoginStart
            )
        }
        #expect(await h.cookies.snapshot() == before)
        let persisted = try h.vault.read().map { try JSONDecoder().decode(SessionSnapshot.self, from: $0) }
        #expect(persisted == before)
        // The attempt and the restore are sessions of their own.
        #expect(await h.cookies.epoch == epoch + 2)
    }
}

/// Holds a mock response until `open()`: the responder calls `pass()`, which records the arrival and blocks the
/// loading thread (at most 5 seconds, so a broken test fails instead of hanging).
private final class ResponseGate: Sendable {
    private let arrived = Mutex(false)
    private let semaphore = DispatchSemaphore(value: 0)

    var hasArrived: Bool { arrived.withLock { $0 } }

    func pass() {
        arrived.withLock { $0 = true }
        _ = semaphore.wait(timeout: .now() + 5)
    }

    func open() {
        semaphore.signal()
    }
}

/// Holds the `target`-th `acquire(for:)` until `release()`; lets every other one through at once. The hold ignores
/// cancellation, as a request already past the throttle's own checks would.
private actor HoldingThrottle: RequestThrottle {
    private let target: Int
    private var count = 0
    private(set) var isHolding = false
    private var isOpen = false
    private var held: CheckedContinuation<Void, Never>?

    init(holding target: Int) {
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
