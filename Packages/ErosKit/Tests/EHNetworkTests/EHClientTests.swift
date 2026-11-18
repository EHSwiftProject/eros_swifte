import EHFixtures
import EHModels
import EHNetwork
import EHNetworkTesting
import EHParsing
import Foundation
import Testing

/// Every request in this suite goes to `MockURLProtocol`; none reaches the network.
@Suite struct EHClientTests {
    private static let memberID = "1234567"
    private static let passHash = "0123456789abcdef0123456789abcdef"
    /// Made-up values for the ten injected cookies; every value is unique so a leak is easy to spot.
    private static let ehJar: [String: String] = [
        "ipb_member_id": memberID,
        "ipb_pass_hash": passHash,
        "igneous": "igneous-fake-eh",
        "hath_perks": "perks-fake-0002",
        "sk": "sk-fake-eh",
        "star": "star-fake-0004",
        "yay": "yay-fake-0005",
        "iq": "iq-fake-0006",
        "cf_clearance": "clearance-fake-eh",
        "cf_duid": "duid-fake-eh",
    ]
    private static let exJar: [String: String] = [
        "ipb_member_id": memberID,
        "ipb_pass_hash": passHash,
        "igneous": "igneous-fake-ex",
        "cf_clearance": "clearance-fake-ex",
    ]
    private static let webKitUserAgent = "FakeWebKit/1"
    private static let page = Data("<html><body>page</body></html>".utf8)

    private static let ehPage = URL(string: "https://e-hentai.org/g/1234/0123456789/")!
    private static let exPage = URL(string: "https://exhentai.org/g/1234/0123456789/")!
    private static let thumbnail = URL(string: "https://ehgt.org/t/01/23/0123456789abcdef-1000-1400-jpg_l.jpg")!
    private static let hathImage = URL(string: "https://abcdefg.hath.network/h/0123456789abcdef/keystamp=1;fileindex=1;xres=1280/1.jpg")!
    private static let forumsLogin = URL(string: "https://forums.e-hentai.org/index.php?act=Login&CODE=01")!

    private static let loginForm: EHRequest.Body = .form([
        URLQueryItem(name: "UserName", value: "fake-user"),
        URLQueryItem(name: "PassWord", value: "fake-password-0001"),
        URLQueryItem(name: "CookieDate", value: "1"),
    ])

    /// A client whose sessions go to a fresh `MockURLProtocol` registration, with its stores and throttle.
    private struct Harness {
        let client: EHClient
        let cookies: CookieStore
        let userAgents: UserAgentStore
        let throttle: RecordingThrottle
        let mock: MockSession

        /// The first request the mock received for `url`.
        func request(to url: URL) -> URLRequest? {
            mock.requests().first { $0.url == url }
        }
    }

    /// Loaded stores (the jars as given, the WebKit UA adopted when given) and a client on a new mock registration.
    /// The default responder answers every request with a small HTML page.
    private static func makeHarness(
        eh: [String: String] = [:], ex: [String: String] = [:], userAgent: String? = nil,
        responder: @escaping @Sendable (URLRequest) throws -> MockResponse = { _ in MockResponse(body: page) }
    ) async throws -> Harness {
        let mock = MockURLProtocol.install(responder)
        let cookies = CookieStore(vault: InMemoryVault())
        try await cookies.load()
        if !eh.isEmpty { try await cookies.set(eh, for: [.eh]) }
        if !ex.isEmpty { try await cookies.set(ex, for: [.ex]) }
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        await userAgents.load()
        if let userAgent { _ = await userAgents.adopt(userAgent) }
        let throttle = RecordingThrottle()
        let configuration = try EHClientConfiguration(sessionConfigurator: mock.configurator)
        let client = EHClient(configuration: configuration, cookies: cookies, userAgents: userAgents, throttle: throttle)
        return Harness(client: client, cookies: cookies, userAgents: userAgents, throttle: throttle, mock: mock)
    }

    /// A client on `throttle` with empty stores (the cookie store on `vault`) that reports site notices to `breaker`;
    /// for the cancellation, vault and breaker tests.
    private static func makeClient(
        throttle: any RequestThrottle, mock: MockSession, vault: any CredentialVault = InMemoryVault(),
        breaker: SiteBreaker? = nil
    ) async throws -> EHClient {
        let cookies = CookieStore(vault: vault)
        try await cookies.load()
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        await userAgents.load()
        let configuration = try EHClientConfiguration(sessionConfigurator: mock.configurator)
        return EHClient(
            configuration: configuration, cookies: cookies, userAgents: userAgents, throttle: throttle, breaker: breaker
        )
    }

    /// The breaker's fixed time in the breaker tests (T).
    private static let breakerTime = Date(timeIntervalSince1970: 1_800_000_000)

    /// A breaker at `breakerTime`, and a client that waits for it (`BreakerThrottle` over `base`) and reports to it.
    private static func makeGuardedClient(
        base: any RequestThrottle = RecordingThrottle(), mock: MockSession
    ) async throws -> (EHClient, SiteBreaker) {
        let breaker = SiteBreaker(now: { breakerTime })
        let client = try await makeClient(
            throttle: BreakerThrottle(base: base, breaker: breaker), mock: mock, breaker: breaker
        )
        return (client, breaker)
    }

    /// Waits up to about two seconds for `condition`.
    private static func eventually(_ condition: () async -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // MARK: - Throttle

    @Test func everyRequestPassesTheThrottle() async throws {
        let h = try await Self.makeHarness()
        defer { h.mock.remove() }
        _ = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        _ = try await h.client.send(EHRequest(url: Self.exPage, site: .ex))
        _ = try await h.client.send(EHRequest(url: Self.thumbnail, site: .eh))
        _ = try await h.client.send(EHRequest(method: .post, url: Self.forumsLogin, site: .eh, body: Self.loginForm))
        let urls = [Self.ehPage, Self.exPage, Self.thumbnail, Self.forumsLogin]
        #expect(await h.throttle.acquiredURLs == urls)
        #expect(h.mock.requests().map(\.url) == urls)
        #expect(h.mock.requests().map(\.httpMethod) == ["GET", "GET", "GET", "POST"])
    }

    @Test func rateLimiterIsARequestThrottle() async throws {
        let mock = MockURLProtocol.install { _ in MockResponse(body: Self.page) }
        defer { mock.remove() }
        let client = try await Self.makeClient(throttle: RateLimiter(), mock: mock)
        let response = try await client.send(EHRequest(url: Self.ehPage, site: .eh))
        #expect(response.status == 200)
        #expect(mock.requests().count == 1)
    }

    // MARK: - Headers and cookies

    @Test func siteRequestsCarryNWAndTheCookies() async throws {
        let h = try await Self.makeHarness(eh: Self.ehJar, userAgent: Self.webKitUserAgent)
        defer { h.mock.remove() }
        let twoLevelHath = URL(string: "https://a1b2c3.d4e5f6.hath.network:8443/h/0123456789abcdef/1.jpg")!
        for url in [Self.ehPage, Self.thumbnail, Self.hathImage, twoLevelHath] {
            _ = try await h.client.send(EHRequest(url: url, site: .eh))
        }
        let expected = try #require(await h.cookies.cookieHeader(for: Self.ehPage))
        #expect(expected.hasPrefix("nw=1; "))
        for name in CookieNames.injected {
            #expect(expected.contains("\(name)=\(Self.ehJar[name]!)"))
        }
        #expect(h.request(to: Self.ehPage)?.value(forHTTPHeaderField: "Cookie") == expected)
        for url in [Self.thumbnail, Self.hathImage, twoLevelHath] {
            let request = try #require(h.request(to: url))
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil, "\(url)")
        }
    }

    @Test func headersMatchTheDefaults() async throws {
        let h = try await Self.makeHarness(eh: Self.ehJar)
        defer { h.mock.remove() }
        #expect(await h.userAgents.isWebKit == false)
        _ = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        _ = try await h.client.send(EHRequest(url: Self.thumbnail, site: .eh))
        for request in h.mock.requests() {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == RequestDefaults.chromeUserAgent)
            #expect(request.value(forHTTPHeaderField: "Accept") == RequestDefaults.accept)
            #expect(request.value(forHTTPHeaderField: "Accept-Language") == RequestDefaults.acceptLanguage)
        }
        #expect(h.mock.requests().count == 2)
    }

    @Test func webKitUserAgentIsSentEverywhere() async throws {
        let redirecting = URL(string: "https://e-hentai.org/r/1")!
        let target = URL(string: "https://e-hentai.org/r/2")!
        let h = try await Self.makeHarness(userAgent: Self.webKitUserAgent) { request in
            request.url == redirecting ? MockResponse(status: 302, redirectTo: target) : MockResponse(body: Self.page)
        }
        defer { h.mock.remove() }
        _ = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))      // logged out
        _ = try await h.client.send(EHRequest(url: Self.exPage, site: .ex))
        _ = try await h.client.send(EHRequest(url: Self.thumbnail, site: .eh))
        _ = try await h.client.send(EHRequest(method: .post, url: Self.forumsLogin, site: .eh, body: Self.loginForm))
        _ = try await h.client.send(EHRequest(url: redirecting, site: .eh))
        let requests = h.mock.requests()
        #expect(requests.map(\.url) == [Self.ehPage, Self.exPage, Self.thumbnail, Self.forumsLogin, redirecting, target])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == Self.webKitUserAgent, "\(request.url!)")
        }
        let image = await h.client.authorizedURLRequest(for: Self.hathImage, site: .eh)
        #expect(image.value(forHTTPHeaderField: "User-Agent") == Self.webKitUserAgent)
    }

    @Test func setCookieIsWrittenBack() async throws {
        let h = try await Self.makeHarness(ex: ["igneous": "igneous-fake-ex"]) { request in
            switch request.url?.host() {
            case "e-hentai.org":
                MockResponse(headers: ["Set-Cookie": "sk=sk-fake-new; path=/; domain=.e-hentai.org"], body: Self.page)
            default:
                MockResponse(headers: ["Set-Cookie": "igneous=mystery; path=/; domain=.exhentai.org"], body: Self.page)
            }
        }
        defer { h.mock.remove() }
        _ = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        _ = try await h.client.send(EHRequest(url: Self.exPage, site: .ex))
        let snapshot = await h.cookies.snapshot()
        #expect(snapshot.cookies[.eh]?["sk"] == "sk-fake-new")
        #expect(snapshot.cookies[.ex]?["igneous"] == "igneous-fake-ex")
    }

    @Test func clearanceCookiesAreNotSentWithTheFallbackUA() async throws {
        let h = try await Self.makeHarness(eh: Self.ehJar)
        defer { h.mock.remove() }
        _ = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        let fallback = try #require(h.mock.requests().last?.value(forHTTPHeaderField: "Cookie"))
        #expect(!fallback.contains("cf_clearance"))
        #expect(!fallback.contains("cf_duid"))
        #expect(fallback.contains("ipb_member_id=\(Self.memberID)"))
        #expect(fallback == (await h.cookies.cookieHeader(for: Self.ehPage, excluding: ["cf_clearance", "cf_duid"])))
        let fallbackImage = await h.client.authorizedURLRequest(for: Self.ehPage, site: .eh)
        #expect(fallbackImage.value(forHTTPHeaderField: "Cookie") == fallback)

        _ = await h.userAgents.adopt(Self.webKitUserAgent)
        _ = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        let webKit = try #require(h.mock.requests().last?.value(forHTTPHeaderField: "Cookie"))
        #expect(webKit.contains("cf_clearance=clearance-fake-eh"))
        #expect(webKit.contains("cf_duid=duid-fake-eh"))
        #expect(webKit == (await h.cookies.cookieHeader(for: Self.ehPage)))
        let webKitImage = await h.client.authorizedURLRequest(for: Self.ehPage, site: .eh)
        #expect(webKitImage.value(forHTTPHeaderField: "Cookie") == webKit)
    }

    @Test func otherCloudflareCookiesFollowTheClearanceCookie() async throws {
        let bound = ["__cf_bm": "bm-fake-0001", "_cfuvid": "uvid-fake-0002", "cf_chl_prog": "chl-fake-0003"]
        let jar = Self.ehJar.merging(bound) { $1 }.merging(["ipb_session_id": "session-fake-0004"]) { $1 }
        let h = try await Self.makeHarness(eh: jar)
        defer { h.mock.remove() }
        _ = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        let fallback = try #require(h.mock.requests().last?.value(forHTTPHeaderField: "Cookie"))
        for name in bound.keys + ["cf_clearance", "cf_duid"] { #expect(!fallback.contains("\(name)="), Comment(rawValue: name)) }
        #expect(fallback.contains("ipb_session_id=session-fake-0004"))
        // The hop of a redirect and the image request take the same decision.
        let image = await h.client.authorizedURLRequest(for: Self.ehPage, site: .eh)
        #expect(image.value(forHTTPHeaderField: "Cookie") == fallback)
        let hop = await h.client.redirectedRequest(URLRequest(url: Self.ehPage), site: .eh)
        #expect(hop.value(forHTTPHeaderField: "Cookie") == fallback)

        _ = await h.userAgents.adopt(Self.webKitUserAgent)
        let webKit = await h.client.authorizedURLRequest(for: Self.ehPage, site: .eh).value(forHTTPHeaderField: "Cookie")
        for (name, value) in bound { #expect(webKit?.contains("\(name)=\(value)") == true, Comment(rawValue: name)) }
    }

    /// Network m2 (PROBE-C): on the Chrome fallback a response's UA-bound Cloudflare cookies are not written: they
    /// were issued for the Chrome UA, and once the WebKit UA is read again with an unchanged string (WebKit freezes
    /// its version, so an OS update often keeps it) adopting it removes nothing, and they would go out with it.
    @Test func fallbackResponsesWriteNoUserAgentBoundCookie() async throws {
        let next = URL(string: "https://e-hentai.org/next")!
        let mock = MockURLProtocol.install { request in
            guard request.url == Self.ehPage else {
                return MockResponse(headers: ["Set-Cookie": "__cf_bm=bm-fake-webkit; path=/; domain=.e-hentai.org"], body: Self.page)
            }
            return MockResponse(
                headers: [
                    "Set-Cookie": "__cf_bm=bm-fake-chrome; path=/; domain=.e-hentai.org, "
                        + "cf_clearance=clearance-fake-chrome; path=/; domain=.e-hentai.org, "
                        + "sk=sk-fake-0001; path=/; domain=.e-hentai.org",
                ],
                body: Self.page
            )
        }
        defer { mock.remove() }
        let cookies = CookieStore(vault: InMemoryVault())
        try await cookies.load()
        // Issued for the WebKit UA before the OS update.
        try await cookies.set(["cf_clearance": "clearance-fake-webkit"], for: [.eh])
        // The UA was read on 27.1; the system is 27.2 and reading it again has not worked yet: the fallback.
        let cached = WebKitUserAgent(
            value: Self.webKitUserAgent, systemVersion: "27.1", capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(cached), systemVersion: "27.2")
        await userAgents.load()
        #expect(await !userAgents.isWebKit)
        let client = EHClient(
            configuration: try EHClientConfiguration(sessionConfigurator: mock.configurator), cookies: cookies,
            userAgents: userAgents, throttle: RecordingThrottle()
        )
        _ = try await client.send(EHRequest(url: Self.ehPage, site: .eh))
        #expect(await cookies.snapshot().cookies[.eh] == ["cf_clearance": "clearance-fake-webkit", "sk": "sk-fake-0001"])

        // Read again with the same string: nothing to remove, and nothing issued for Chrome goes out with it.
        #expect(try await adoptWebKitUserAgent(Self.webKitUserAgent, userAgents: userAgents, cookies: cookies) == false)
        #expect(await userAgents.isWebKit)
        _ = try await client.send(EHRequest(url: next, site: .eh))
        let request = try #require(mock.requests().last)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == Self.webKitUserAgent)
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        #expect(cookie.contains("cf_clearance=clearance-fake-webkit"))
        #expect(!cookie.contains("__cf_bm"))
        #expect(!cookie.contains("clearance-fake-chrome"))
        // With the WebKit UA a response's Cloudflare cookies are written as before.
        #expect(await cookies.snapshot().cookies[.eh]?["__cf_bm"] == "bm-fake-webkit")
    }

    @Test func callerHeadersComeLastButCannotReplaceCookieOrUserAgent() async throws {
        let h = try await Self.makeHarness(eh: Self.ehJar, userAgent: Self.webKitUserAgent)
        defer { h.mock.remove() }
        let headers = [
            "Referer": "https://e-hentai.org/",
            "Accept": "application/json",
            "cookie": "ipb_member_id=7654321",
            "User-Agent": "Forged/1",
        ]
        _ = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh, headers: headers))
        let request = try #require(h.mock.requests().first)
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://e-hentai.org/")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Cookie") == (await h.cookies.cookieHeader(for: Self.ehPage)))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == Self.webKitUserAgent)
    }

    @Test func authorizedURLRequestIsScopedAndNotThrottled() async throws {
        let h = try await Self.makeHarness(eh: Self.ehJar, userAgent: Self.webKitUserAgent)
        defer { h.mock.remove() }
        let page = await h.client.authorizedURLRequest(for: Self.ehPage, site: .eh)
        #expect(page.url == Self.ehPage)
        #expect(page.value(forHTTPHeaderField: "Cookie") == (await h.cookies.cookieHeader(for: Self.ehPage)))
        #expect(page.value(forHTTPHeaderField: "Accept") == RequestDefaults.accept)
        #expect(page.value(forHTTPHeaderField: "Accept-Language") == RequestDefaults.acceptLanguage)
        #expect(page.timeoutInterval == 20)
        #expect(page.httpShouldHandleCookies == false)
        let image = await h.client.authorizedURLRequest(for: Self.hathImage, site: .ex)
        #expect(image.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(image.timeoutInterval == 25)
        #expect(await h.throttle.acquiredURLs.isEmpty)
        #expect(h.mock.requests().isEmpty)
    }

    // MARK: - Redirects of authorized requests

    @Test func redirectedRequestRescopesCookieAndUserAgent() async throws {
        let h = try await Self.makeHarness(eh: Self.ehJar, ex: Self.exJar, userAgent: Self.webKitUserAgent)
        defer { h.mock.remove() }
        // What URLSession copies when a request to e-hentai.org redirects to an H@H node: every header, Cookie included.
        var copied = await h.client.authorizedURLRequest(for: Self.ehPage, site: .eh)
        copied.setValue("https://e-hentai.org/", forHTTPHeaderField: "Referer")
        copied.url = Self.hathImage
        try #require(copied.value(forHTTPHeaderField: "Cookie") != nil)
        let hath = await h.client.redirectedRequest(copied, site: .eh)
        #expect(hath.url == Self.hathImage)
        #expect(hath.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(hath.allHTTPHeaderFields?.keys.contains { $0.lowercased() == "cookie" } == false)
        #expect(hath.value(forHTTPHeaderField: "User-Agent") == Self.webKitUserAgent)
        #expect(hath.value(forHTTPHeaderField: "Referer") == "https://e-hentai.org/")
        #expect(hath.value(forHTTPHeaderField: "Accept") == RequestDefaults.accept)
        #expect(hath.timeoutInterval == 20)
        #expect(hath.httpShouldHandleCookies == false)

        // Headers in any case are replaced, not left beside the new ones.
        var forged = URLRequest(url: Self.exPage)
        forged.setValue("ipb_pass_hash=forged-0001", forHTTPHeaderField: "cookie")
        forged.setValue("Forged/1", forHTTPHeaderField: "user-agent")
        let ex = await h.client.redirectedRequest(forged, site: .ex)
        let exCookie = try #require(ex.value(forHTTPHeaderField: "Cookie"))
        #expect(exCookie == (await h.cookies.cookieHeader(for: Self.exPage)))
        #expect(exCookie.contains("igneous=igneous-fake-ex"))
        #expect(!exCookie.contains("forged-0001"))
        #expect(!exCookie.contains("sk-fake-eh"))
        #expect(ex.allHTTPHeaderFields?.keys.filter { $0.lowercased() == "cookie" }.count == 1)
        #expect(ex.allHTTPHeaderFields?.keys.filter { $0.lowercased() == "user-agent" }.count == 1)
        #expect(ex.value(forHTTPHeaderField: "User-Agent") == Self.webKitUserAgent)
        #expect(ex.timeoutInterval == 25)
        #expect(await h.throttle.acquiredURLs.isEmpty)
        #expect(h.mock.requests().isEmpty)
    }

    @Test func redirectedRequestUsesTheFallbackScope() async throws {
        let h = try await Self.makeHarness(ex: Self.exJar)
        defer { h.mock.remove() }
        var copied = URLRequest(url: Self.ehPage)
        copied.setValue("cf_clearance=clearance-fake-eh", forHTTPHeaderField: "Cookie")
        copied.url = Self.exPage
        let ex = await h.client.redirectedRequest(copied, site: .ex)
        let cookie = try #require(ex.value(forHTTPHeaderField: "Cookie"))
        #expect(!cookie.contains("cf_clearance"))
        #expect(cookie == (await h.cookies.cookieHeader(for: Self.exPage, excluding: ["cf_clearance", "cf_duid"])))
        #expect(ex.value(forHTTPHeaderField: "User-Agent") == RequestDefaults.chromeUserAgent)
    }

    @Test func imageSessionFollowsRedirectsByTheContract() async throws {
        let fullImage = URL(string: "https://e-hentai.org/fullimg/1234/1/0123456789/01.jpg")!
        let h = try await Self.makeHarness(eh: Self.ehJar, userAgent: Self.webKitUserAgent) { request in
            request.url == fullImage ? MockResponse(status: 302, redirectTo: Self.hathImage) : MockResponse(body: Data([0xFF, 0xD8]))
        }
        defer { h.mock.remove() }
        let configuration = try EHClientConfiguration(sessionConfigurator: h.mock.configurator)
        let session = URLSession(configuration: EHClient.makeSessionConfiguration(for: .eh, configuration: configuration))
        defer { session.finishTasksAndInvalidate() }
        // As authorizedURLRequest(for:site:) asks: the caller acquires, and its task delegate handles the redirect.
        try await h.throttle.acquire(for: fullImage)
        let request = await h.client.authorizedURLRequest(for: fullImage, site: .eh)
        let delegate = ContractRedirectDelegate(client: h.client, throttle: h.throttle, site: .eh)
        let (_, response) = try await session.data(for: request, delegate: delegate)
        #expect((response as? HTTPURLResponse)?.url == Self.hathImage)
        #expect(await h.throttle.acquiredURLs == [fullImage, Self.hathImage])
        let requests = h.mock.requests()
        #expect(requests.map(\.url) == [fullImage, Self.hathImage])
        #expect(requests.first?.value(forHTTPHeaderField: "Cookie") == (await h.cookies.cookieHeader(for: fullImage)))
        #expect(requests.last?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "User-Agent") == Self.webKitUserAgent)
    }

    // MARK: - Bodies and responses

    @Test func bodiesAreEncodedWithTheirContentType() async throws {
        let h = try await Self.makeHarness()
        defer { h.mock.remove() }
        let api = URL(string: "https://api.e-hentai.org/api.php")!
        let json = Data(#"{"method":"gdata","gidlist":[[1234,"0123456789"]]}"#.utf8)
        _ = try await h.client.send(EHRequest(method: .post, url: api, site: .eh, body: .json(json), expectsJSON: true))
        let form: [URLQueryItem] = [
            URLQueryItem(name: "UserName", value: "fake user"),
            URLQueryItem(name: "PassWord", value: "p@ss&w=rd+1/é"),
            URLQueryItem(name: "empty", value: nil),
        ]
        _ = try await h.client.send(EHRequest(method: .post, url: Self.forumsLogin, site: .eh, body: .form(form)))
        let lookup = URL(string: "https://upld.e-hentai.org/image_lookup.php")!
        let multipart = MultipartBody(boundary: "Eros-test", parts: [
            MultipartBody.Part(name: "sfile", fileName: "a\"b.jpg", contentType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF])),
            MultipartBody.Part(name: "fs_similar", data: Data("on".utf8)),
        ])
        _ = try await h.client.send(EHRequest(method: .post, url: lookup, site: .eh, body: .multipart(multipart)))

        let requests = h.mock.requests()
        try #require(requests.count == 3)
        #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(requests[0].httpBody == json)
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(requests[1].httpBody.map { String(decoding: $0, as: UTF8.self) }
            == "UserName=fake+user&PassWord=p%40ss%26w%3Drd%2B1%2F%C3%A9&empty=")
        #expect(requests[2].value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=Eros-test")
        var expected = Data()
        expected.append(Data("--Eros-test\r\nContent-Disposition: form-data; name=\"sfile\"; filename=\"a%22b.jpg\"\r\n".utf8))
        expected.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        expected.append(Data([0xFF, 0xD8, 0xFF]))
        expected.append(Data("\r\n--Eros-test\r\nContent-Disposition: form-data; name=\"fs_similar\"\r\n\r\non\r\n".utf8))
        expected.append(Data("--Eros-test--\r\n".utf8))
        #expect(requests[2].httpBody == expected)
    }

    @Test func responsesHaveLowercasedHeadersAndReplacedInvalidText() async throws {
        let h = try await Self.makeHarness { _ in
            MockResponse(headers: ["Content-Type": "text/html; charset=UTF-8", "X-Fake-Header": "1"], body: Data([0x61, 0xFF, 0x62]))
        }
        defer { h.mock.remove() }
        let response = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        #expect(response.status == 200)
        #expect(response.url == Self.ehPage)
        #expect(response.source == .network)
        #expect(response.headers["content-type"] == "text/html; charset=UTF-8")
        #expect(response.headers["x-fake-header"] == "1")
        #expect(response.headers.keys.allSatisfy { $0 == $0.lowercased() })
        #expect(response.text == "a\u{FFFD}b")
        let built = EHResponse(status: 200, url: Self.ehPage, headers: ["Set-Cookie": "a=1", "set-cookie": "b=2"], body: Data(), source: .cache)
        #expect(built.headers == ["set-cookie": "a=1, b=2"])
    }

    // MARK: - Redirects

    @Test func redirectsAreThrottledAndCarryCookies() async throws {
        let target = Self.exPage
        // The first hop sets a Domain cookie and a host-only one: both belong to the hop's own host (e-hentai.org).
        let h = try await Self.makeHarness(
            eh: ["ipb_member_id": Self.memberID, "ipb_pass_hash": Self.passHash, "sk": "sk-fake-eh"],
            ex: Self.exJar, userAgent: Self.webKitUserAgent
        ) { request in
            guard request.url == Self.ehPage else { return MockResponse(body: Self.page) }
            return MockResponse(
                status: 302,
                headers: ["Set-Cookie": "sk=sk-fake-hop; path=/; domain=.e-hentai.org, hop=hop-fake-0001; path=/"],
                redirectTo: target
            )
        }
        defer { h.mock.remove() }
        let response = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        #expect(response.status == 200)
        #expect(response.url == target)
        #expect(await h.throttle.acquiredURLs == [Self.ehPage, target])

        let snapshot = await h.cookies.snapshot()
        #expect(snapshot.cookies[.eh]?["sk"] == "sk-fake-hop")
        #expect(snapshot.cookies[.eh]?["hop"] == "hop-fake-0001")
        #expect(snapshot.cookies[.ex]?["hop"] == nil)

        let requests = h.mock.requests()
        #expect(requests.map(\.url) == [Self.ehPage, target])
        let first = try #require(requests.first?.value(forHTTPHeaderField: "Cookie"))
        #expect(first.contains("sk=sk-fake-eh"))
        let second = try #require(requests.last?.value(forHTTPHeaderField: "Cookie"))
        #expect(second == (await h.cookies.cookieHeader(for: target)))
        #expect(second.contains("igneous=igneous-fake-ex"))
        #expect(!second.contains("sk="))
        #expect(!second.contains("hop="))
    }

    @Test func redirectsOffTheSitesDropTheCookies() async throws {
        let target = Self.thumbnail
        let h = try await Self.makeHarness(eh: Self.ehJar, userAgent: Self.webKitUserAgent) { request in
            request.url == Self.ehPage ? MockResponse(status: 302, redirectTo: target) : MockResponse(body: Self.page)
        }
        defer { h.mock.remove() }
        _ = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        let requests = h.mock.requests()
        #expect(requests.map(\.url) == [Self.ehPage, target])
        #expect(requests.first?.value(forHTTPHeaderField: "Cookie") != nil)
        #expect(requests.last?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "User-Agent") == Self.webKitUserAgent)
        #expect(await h.throttle.acquiredURLs == [Self.ehPage, target])
    }

    /// N3 m4: the final response's cookies are written with the final URL, not the one asked for. A Domain cookie of
    /// .exhentai.org matches only exhentai.org, and a host-only one belongs to the host that set it.
    @Test func finalResponseCookiesGoByTheFinalURL() async throws {
        let h = try await Self.makeHarness(userAgent: Self.webKitUserAgent) { request in
            guard request.url == Self.ehPage else {
                return MockResponse(
                    headers: ["Set-Cookie": "igneous=igneous-fake-final; path=/; domain=.exhentai.org, final=final-fake-0001; path=/"],
                    body: Self.page
                )
            }
            return MockResponse(status: 302, redirectTo: Self.exPage)
        }
        defer { h.mock.remove() }
        let response = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        #expect(response.url == Self.exPage)
        let snapshot = await h.cookies.snapshot()
        #expect(snapshot.cookies[.ex] == ["igneous": "igneous-fake-final", "final": "final-fake-0001"])
        #expect(snapshot.cookies[.eh] == nil)
    }

    @Test func imageLookupDoesNotFollowRedirects() async throws {
        let lookup = URL(string: "https://upld.e-hentai.org/image_lookup.php")!
        let result = URL(string: "https://e-hentai.org/?f_shash=0123456789abcdef0123456789abcdef01234567")!
        let h = try await Self.makeHarness { request in
            request.url == lookup ? MockResponse(status: 302, redirectTo: result) : MockResponse(body: Self.page)
        }
        defer { h.mock.remove() }
        let upload = MultipartBody(parts: [
            MultipartBody.Part(name: "sfile", fileName: "a.jpg", contentType: "image/jpeg", data: Data([0xFF, 0xD8])),
        ])
        let request = EHRequest(method: .post, url: lookup, site: .eh, body: .multipart(upload), followsRedirects: false)
        let response = try await h.client.send(request)
        #expect(response.status == 302)
        #expect(response.headers["location"] == result.absoluteString)
        #expect(h.mock.requests().count == 1)
        #expect(await h.throttle.acquiredURLs == [lookup])
    }

    // MARK: - Site notices and errors

    @Test func bannedBodyStopsWithoutRetry() async throws {
        let banned = try Fixtures.data("constructed/eh/banned.txt")
        let h = try await Self.makeHarness { _ in MockResponse(body: banned) }
        defer { h.mock.remove() }
        await #expect(throws: EHNetworkError.issue(.banned(remaining: .seconds(3587)))) {
            try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        }
        #expect(h.mock.requests().count == 1)
        #expect(await h.throttle.acquiredURLs.count == 1)
    }

    @Test func tooManyRequestsStops() async throws {
        let h = try await Self.makeHarness { request in
            MockResponse(status: request.url == Self.ehPage ? 429 : 509, body: Self.page)
        }
        defer { h.mock.remove() }
        await #expect(throws: EHNetworkError.issue(.tooManyRequests)) {
            try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        }
        await #expect(throws: EHNetworkError.issue(.bandwidthExceeded)) {
            try await h.client.send(EHRequest(url: Self.hathImage, site: .eh))
        }
        #expect(h.mock.requests().map(\.url) == [Self.ehPage, Self.hathImage])
    }

    // MARK: - Site pause (user decision 2026-11-08)

    @Test func tooManyRequestsPausesBothSites() async throws {
        let ehHome = URL(string: "https://e-hentai.org/")!
        let exHome = URL(string: "https://exhentai.org/")!
        let mock = MockURLProtocol.install { _ in MockResponse(status: 429, body: Self.page) }
        defer { mock.remove() }
        let (client, breaker) = try await Self.makeGuardedClient(mock: mock)
        await #expect(throws: EHNetworkError.issue(.tooManyRequests)) {
            try await client.send(EHRequest(url: ehHome, site: .eh))
        }
        let pause = SitePause(reason: .tooManyRequests, until: Self.breakerTime.addingTimeInterval(60))
        #expect(await breaker.current() == pause)
        await #expect(throws: EHNetworkError.paused(pause)) {
            try await client.send(EHRequest(url: exHome, site: .ex))
        }
        #expect(mock.requests().map(\.url) == [ehHome])
    }

    @Test func banNoticePausesUntilItsEnd() async throws {
        let banned = try Fixtures.data("constructed/eh/banned.txt")
        let mock = MockURLProtocol.install { _ in MockResponse(body: banned) }
        defer { mock.remove() }
        let (client, breaker) = try await Self.makeGuardedClient(mock: mock)
        await #expect(throws: EHNetworkError.issue(.banned(remaining: .seconds(3587)))) {
            try await client.send(EHRequest(url: Self.ehPage, site: .eh))
        }
        let expected = SitePause(reason: .banned, until: Self.breakerTime.addingTimeInterval(3587))
        #expect(await breaker.current() == expected)
        #expect(mock.requests().count == 1)
    }

    /// 509 is the image quota's (M4): the lists go on.
    @Test func bandwidthExceededDoesNotPause() async throws {
        let mock = MockURLProtocol.install { request in
            MockResponse(status: request.url == Self.thumbnail ? 509 : 200, body: Self.page)
        }
        defer { mock.remove() }
        let (client, breaker) = try await Self.makeGuardedClient(mock: mock)
        await #expect(throws: EHNetworkError.issue(.bandwidthExceeded)) {
            try await client.send(EHRequest(url: Self.thumbnail, site: .eh))
        }
        #expect(await breaker.current() == nil)
        let next = try await client.send(EHRequest(url: Self.ehPage, site: .eh))
        #expect(next.status == 200)
        #expect(mock.requests().map(\.url) == [Self.thumbnail, Self.ehPage])
    }

    /// Requests already queued in the rate limiter when a 429 comes back (scrolling a list: thumbnails and the next
    /// page) end with `.paused` once their turn comes; none goes out.
    @Test func queuedRequestsStopAfterATooManyRequests() async throws {
        let ehHome = URL(string: "https://e-hentai.org/")!
        let exThumbnail = URL(string: "https://s.exhentai.org/t/01/23/0123456789abcdef-1000-1400-jpg_l.jpg")!
        let mock = MockURLProtocol.install { request in
            MockResponse(status: request.url == ehHome ? 429 : 200, body: Self.page)
        }
        defer { mock.remove() }
        let gate = QueueThrottle()
        let (client, breaker) = try await Self.makeGuardedClient(base: gate, mock: mock)
        let first = Task { try await client.send(EHRequest(url: ehHome, site: .eh)) }
        await gate.waitUntilHolding(1)
        let queued = [(Self.ehPage, EHSite.eh), (Self.exPage, .ex), (Self.thumbnail, .eh), (exThumbnail, .ex)].map {
            (url, site) in Task { try await client.send(EHRequest(url: url, site: site)) }
        }
        await gate.waitUntilHolding(5)
        await gate.releaseFirst()
        await #expect(throws: EHNetworkError.issue(.tooManyRequests)) { try await first.value }
        let pause = try #require(await breaker.current())
        await gate.open()
        for task in queued {
            await #expect(throws: EHNetworkError.paused(pause)) { try await task.value }
        }
        #expect(mock.requests().map(\.url) == [ehHome])
    }

    /// A pause that begins while a redirect hop waits for the throttle stops the hop as it stops a new request: the
    /// request ends with `.paused` and the redirect's target is never asked for.
    @Test func redirectHopDuringAPauseThrowsPaused() async throws {
        let start = URL(string: "https://e-hentai.org/r/hop")!
        let mock = MockURLProtocol.install { request in
            request.url == start ? MockResponse(status: 302, redirectTo: Self.ehPage) : MockResponse(body: Self.page)
        }
        defer { mock.remove() }
        let breaker = SiteBreaker(now: { Self.breakerTime })
        let base = PausingThrottle(breaker: breaker, pausingAt: Self.ehPage)
        let client = try await Self.makeClient(
            throttle: BreakerThrottle(base: base, breaker: breaker), mock: mock, breaker: breaker
        )
        let pause = SitePause(reason: .tooManyRequests, until: Self.breakerTime.addingTimeInterval(60))
        await #expect(throws: EHNetworkError.paused(pause)) {
            try await client.send(EHRequest(url: start, site: .eh))
        }
        #expect(mock.requests().map(\.url) == [start])
        #expect(await base.acquiredURLs == [start, Self.ehPage])
    }

    @Test func emptyEXPageIsAccessDenied() async throws {
        let exThumbnail = URL(string: "https://s.exhentai.org/t/01/23/0123456789abcdef-1000-1400-jpg_l.jpg")!
        let h = try await Self.makeHarness(ex: Self.exJar) { _ in MockResponse(body: Data()) }
        defer { h.mock.remove() }
        await #expect(throws: EHNetworkError.issue(.exAccessDenied)) {
            try await h.client.send(EHRequest(url: Self.exPage, site: .ex))
        }
        let thumbnail = try await h.client.send(EHRequest(url: exThumbnail, site: .ex))
        #expect(thumbnail.status == 200)
        #expect(thumbnail.body.isEmpty)
    }

    /// N3 m4: a notice is told by the final host. ExHentai's empty page reached by a redirect from e-hentai.org is
    /// its access notice; an empty page on e-hentai.org reached from exhentai.org is not.
    @Test func noticesGoByTheFinalHost() async throws {
        let toEX = URL(string: "https://e-hentai.org/r/ex")!
        let toEH = URL(string: "https://exhentai.org/r/eh")!
        let h = try await Self.makeHarness(ex: Self.exJar) { request in
            switch request.url {
            case toEX: MockResponse(status: 302, redirectTo: Self.exPage)
            case toEH: MockResponse(status: 302, redirectTo: Self.ehPage)
            default: MockResponse(body: Data())
            }
        }
        defer { h.mock.remove() }
        await #expect(throws: EHNetworkError.issue(.exAccessDenied)) {
            try await h.client.send(EHRequest(url: toEX, site: .eh))
        }
        let response = try await h.client.send(EHRequest(url: toEH, site: .ex))
        #expect(response.status == 200)
        #expect(response.url == Self.ehPage)
        #expect(response.body.isEmpty)
        #expect(h.mock.requests().map(\.url) == [toEX, Self.exPage, toEH, Self.ehPage])
    }

    /// N3 m4: `expectsJSON` reaches the classifier. The API's "Key mismatch" is a notice for a JSON request only;
    /// the same body for a page request is just a body.
    @Test func keyMismatchNeedsExpectsJSON() async throws {
        let api = URL(string: "https://api.e-hentai.org/api.php")!
        let mismatch = Data(#"{"error":"Key mismatch"}"#.utf8)
        let h = try await Self.makeHarness { _ in MockResponse(body: mismatch) }
        defer { h.mock.remove() }
        let body = EHRequest.Body.json(Data(#"{"method":"gdata"}"#.utf8))
        await #expect(throws: EHNetworkError.issue(.keyMismatch)) {
            try await h.client.send(EHRequest(method: .post, url: api, site: .eh, body: body, expectsJSON: true))
        }
        let page = try await h.client.send(EHRequest(method: .post, url: api, site: .eh, body: body))
        #expect(page.body == mismatch)
        #expect(h.mock.requests().count == 2)
    }

    @Test func otherErrorsKeepTheirStatus() async throws {
        let h = try await Self.makeHarness { request in
            MockResponse(status: request.url == Self.ehPage ? 404 : 500, body: Self.page)
        }
        defer { h.mock.remove() }
        await #expect(throws: EHNetworkError.httpStatus(404)) {
            try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        }
        await #expect(throws: EHNetworkError.httpStatus(500)) {
            try await h.client.send(EHRequest(url: Self.exPage, site: .ex))
        }
    }

    @Test func transportErrorsKeepTheirCode() async throws {
        let h = try await Self.makeHarness { request in
            throw URLError(request.url == Self.ehPage ? .timedOut : .notConnectedToInternet)
        }
        defer { h.mock.remove() }
        await #expect(throws: EHNetworkError.transport(.timedOut)) {
            try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        }
        await #expect(throws: EHNetworkError.transport(.notConnectedToInternet)) {
            try await h.client.send(EHRequest(url: Self.exPage, site: .ex))
        }
    }

    @Test func siteNoticeComesBeforeAVaultFailure() async throws {
        let notice = Self.ehPage
        let mock = MockURLProtocol.install { request in
            MockResponse(
                status: request.url == notice ? 429 : 200,
                headers: ["Set-Cookie": "sk=sk-fake-new; path=/; domain=.e-hentai.org"], body: Self.page
            )
        }
        defer { mock.remove() }
        let client = try await Self.makeClient(throttle: RecordingThrottle(), mock: mock, vault: WriteFailingVault())
        await #expect(throws: EHNetworkError.issue(.tooManyRequests)) {
            try await client.send(EHRequest(url: notice, site: .eh))
        }
        // Without a notice the vault's error is thrown as it is: a login must not look successful without its cookies.
        await #expect(throws: VaultWriteError()) {
            try await client.send(EHRequest(url: URL(string: "https://e-hentai.org/")!, site: .eh))
        }
        #expect(mock.requests().count == 2)
    }

    // MARK: - Session configuration

    @Test func timeoutsMapToURLSession() async throws {
        #expect(RequestDefaults.timeouts(for: .eh).urlSession == URLSessionTimeouts(idle: .seconds(20), resource: .seconds(38)))
        #expect(RequestDefaults.timeouts(for: .ex).urlSession == URLSessionTimeouts(idle: .seconds(25), resource: .seconds(48)))
        for (site, idle, resource) in [(EHSite.eh, 20.0, 38.0), (.ex, 25.0, 48.0)] {
            let configuration = EHClient.makeSessionConfiguration(for: site, configuration: .standard)
            #expect(configuration.timeoutIntervalForRequest == idle)
            #expect(configuration.timeoutIntervalForResource == resource)
        }
        let h = try await Self.makeHarness()
        defer { h.mock.remove() }
        _ = try await h.client.send(EHRequest(url: Self.ehPage, site: .eh))
        _ = try await h.client.send(EHRequest(url: Self.exPage, site: .ex))
        #expect(h.request(to: Self.ehPage)?.timeoutInterval == 20)
        #expect(h.request(to: Self.exPage)?.timeoutInterval == 25)
    }

    @Test func sessionConfigurationDisablesSystemCookiesAndCache() {
        for site in EHSite.allCases {
            let configuration = EHClient.makeSessionConfiguration(for: site, configuration: .standard)
            #expect(configuration.httpCookieStorage == nil)
            #expect(configuration.httpShouldSetCookies == false)
            #expect(configuration.urlCache == nil)
            #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        }
    }

    @Test func sessionConfiguratorIsApplied() async throws {
        let mock = MockURLProtocol.install { _ in MockResponse(body: Self.page) }
        defer { mock.remove() }
        let custom = SessionConfigurator(usesCustomProxy: false) { configuration in
            mock.configurator.apply(to: configuration)
            var headers = configuration.httpAdditionalHeaders ?? [:]
            headers["X-Test"] = "applied"
            configuration.httpAdditionalHeaders = headers
            // Applied last: it may replace what the client set.
            configuration.timeoutIntervalForResource = 99
        }
        let configuration = try EHClientConfiguration(sessionConfigurator: custom)
        let session = EHClient.makeSessionConfiguration(for: .eh, configuration: configuration)
        #expect(session.httpAdditionalHeaders?["X-Test"] as? String == "applied")
        #expect(session.timeoutIntervalForResource == 99)

        let cookies = CookieStore(vault: InMemoryVault())
        try await cookies.load()
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        let client = EHClient(configuration: configuration, cookies: cookies, userAgents: userAgents, throttle: RecordingThrottle())
        _ = try await client.send(EHRequest(url: Self.ehPage, site: .eh))
        _ = try await client.send(EHRequest(url: Self.exPage, site: .ex))
        #expect(mock.requests().map { $0.value(forHTTPHeaderField: "X-Test") } == ["applied", "applied"])
    }

    // MARK: - Trust

    private static let otherMethods = [
        NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
        NSURLAuthenticationMethodHTMLForm, NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate,
        NSURLAuthenticationMethodClientCertificate,
    ]

    @Test func trustIsStrictByDefault() throws {
        #expect(EHClientConfiguration.standard.trustPolicy == .strict)
        #expect(EHClientConfiguration.standard.sessionConfigurator.usesCustomProxy == false)
        #expect(try EHClientConfiguration().trustPolicy == .strict)
        for method in [NSURLAuthenticationMethodServerTrust] + Self.otherMethods {
            #expect(TrustPolicy.strict.disposition(forAuthenticationMethod: method) == .performDefaultHandling, "\(method)")
        }
    }

    @Test func ignoringCertificatesRequiresCustomProxy() throws {
        #expect(throws: ConfigurationError.ignoringCertificatesRequiresCustomProxy) {
            try EHClientConfiguration(trustPolicy: .ignoreCertificateErrors)
        }
        let systemProxy = SessionConfigurator(usesCustomProxy: false) { _ in }
        #expect(throws: ConfigurationError.ignoringCertificatesRequiresCustomProxy) {
            try EHClientConfiguration(sessionConfigurator: systemProxy, trustPolicy: .ignoreCertificateErrors)
        }
        let customProxy = SessionConfigurator(usesCustomProxy: true) { _ in }
        let configuration = try EHClientConfiguration(sessionConfigurator: customProxy, trustPolicy: .ignoreCertificateErrors)
        #expect(configuration.trustPolicy == .ignoreCertificateErrors)
        #expect(configuration.sessionConfigurator.usesCustomProxy)
        #expect(try EHClientConfiguration(sessionConfigurator: customProxy).trustPolicy == .strict)
    }

    @Test func ignoringAppliesToServerTrustOnly() {
        let policy = TrustPolicy.ignoreCertificateErrors
        #expect(policy.disposition(forAuthenticationMethod: NSURLAuthenticationMethodServerTrust) == .useCredential)
        #expect(policy.disposition(forAuthenticationMethod: NSURLAuthenticationMethodHTTPBasic) == .performDefaultHandling)
        for method in Self.otherMethods {
            #expect(policy.disposition(forAuthenticationMethod: method) == .performDefaultHandling, "\(method)")
        }
    }

    // MARK: - Cancellation

    @Test func cancellationIsReported() async throws {
        let mock = MockURLProtocol.install { _ in MockResponse(body: Self.page) }
        defer { mock.remove() }
        let gate = GateThrottle(holding: Self.ehPage, until: .cancelled)
        let client = try await Self.makeClient(throttle: gate, mock: mock)
        let task = Task { try await client.send(EHRequest(url: Self.ehPage, site: .eh)) }
        await gate.waitUntilHeld()
        task.cancel()
        await #expect(throws: EHNetworkError.cancelled) { try await task.value }
        #expect(await gate.cancelledURLs == [Self.ehPage])
        #expect(mock.requests().isEmpty)
    }

    @Test func cancellationReachesTheThrottleOfARedirect() async throws {
        let target = Self.exPage
        let mock = MockURLProtocol.install { request in
            request.url == Self.ehPage ? MockResponse(status: 302, redirectTo: target) : MockResponse(body: Self.page)
        }
        defer { mock.remove() }
        let gate = GateThrottle(holding: target, until: .cancelled)
        let client = try await Self.makeClient(throttle: gate, mock: mock)
        let task = Task { try await client.send(EHRequest(url: Self.ehPage, site: .eh)) }
        await gate.waitUntilHeld()
        task.cancel()
        await #expect(throws: EHNetworkError.cancelled) { try await task.value }
        // The hop waits in a task of its own; the cancellation reaches it shortly after.
        #expect(try await Self.eventually { await gate.cancelledURLs == [target] })
        #expect(mock.requests().map(\.url) == [Self.ehPage])
    }

    @Test func cancelledRedirectIsNotFollowed() async throws {
        let target = Self.exPage
        let mock = MockURLProtocol.install { request in
            request.url == Self.ehPage ? MockResponse(status: 302, redirectTo: target) : MockResponse(body: Self.page)
        }
        defer { mock.remove() }
        // This throttle ignores cancellation, so the hop returns its request after the send was cancelled.
        let gate = GateThrottle(holding: target, until: .released)
        let client = try await Self.makeClient(throttle: gate, mock: mock)
        let task = Task { try await client.send(EHRequest(url: Self.ehPage, site: .eh)) }
        await gate.waitUntilHeld()
        task.cancel()
        await #expect(throws: EHNetworkError.cancelled) { try await task.value }
        await gate.release()
        #expect(try await Self.eventually { await gate.releasedURLs == [target] })
        try await Task.sleep(for: .milliseconds(300))
        #expect(mock.requests().map(\.url) == [Self.ehPage])
    }

    // MARK: - Privacy

    @Test func requestDescriptionHasNoCookies() {
        let request = EHRequest(
            method: .post, url: Self.forumsLogin, site: .eh, body: Self.loginForm,
            headers: ["Referer": "https://forums.e-hentai.org/", "Cookie": "ipb_pass_hash=\(Self.passHash)"]
        )
        let expected = "POST https://forums.e-hentai.org/index.php?act=Login&CODE=01"
        #expect(String(describing: request) == expected)
        #expect(String(reflecting: request) == expected)
        var dumped = ""
        dump(request, to: &dumped)
        #expect(!dumped.contains(Self.passHash))
        #expect(!dumped.contains("fake-password-0001"))
        #expect(!dumped.contains("Referer"))
    }

    @Test func responseDescriptionHasNoCookies() {
        let body = Data("pass hash \(Self.passHash)".utf8)
        let response = EHResponse(
            status: 200, url: Self.ehPage, headers: ["Set-Cookie": "ipb_pass_hash=\(Self.passHash)"], body: body,
            source: .network
        )
        #expect(String(describing: response) == "EHResponse(200, \(Self.ehPage.absoluteString), \(body.count) bytes, network)")
        var dumped = ""
        dump(response, to: &dumped)
        #expect(!dumped.contains(Self.passHash))
    }
}

/// Lets every request through at once except those to `held`, which wait until cancelled (`.cancelled`) or until
/// `release()` whatever cancellation says (`.released`).
private actor GateThrottle: RequestThrottle {
    enum Hold { case cancelled, released }

    private let held: URL
    private let hold: Hold
    private(set) var cancelledURLs: [URL] = []
    private(set) var releasedURLs: [URL] = []
    private var isHolding = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    init(holding held: URL, until hold: Hold) {
        self.held = held
        self.hold = hold
    }

    func acquire(for url: URL) async throws {
        guard url == held else { return }
        isHolding = true
        arrivals.forEach { $0.resume() }
        arrivals = []
        switch hold {
        case .cancelled:
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                cancelledURLs.append(url)
                throw error
            }
        case .released:
            await withCheckedContinuation { releases.append($0) }
            releasedURLs.append(url)
        }
    }

    /// Returns once a request to `held` is waiting.
    func waitUntilHeld() async {
        guard !isHolding else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        releases.forEach { $0.resume() }
        releases = []
    }
}

/// Lets every request through at once, but a 429 is met (`SiteBreaker.record`) while the one to `pausingAt` waits:
/// as if another request had come back with it meanwhile.
private actor PausingThrottle: RequestThrottle {
    private let breaker: SiteBreaker
    private let pausingAt: URL
    private(set) var acquiredURLs: [URL] = []

    init(breaker: SiteBreaker, pausingAt: URL) {
        self.breaker = breaker
        self.pausingAt = pausingAt
    }

    func acquire(for url: URL) async throws {
        acquiredURLs.append(url)
        if url == pausingAt { _ = await breaker.record(.tooManyRequests, at: url) }
    }
}

/// Holds every request in arrival order: `releaseFirst()` lets the earliest one through, `open()` all of them and every
/// later one.
private actor QueueThrottle: RequestThrottle {
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func acquire(for url: URL) async throws {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            held.append(continuation)
            let woken = watchers
            watchers = []
            woken.forEach { $0.resume() }
        }
    }

    /// Returns once `count` requests are held.
    func waitUntilHolding(_ count: Int) async {
        while held.count < count {
            await withCheckedContinuation { watchers.append($0) }
        }
    }

    func releaseFirst() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume()
    }

    func open() {
        isOpen = true
        let released = held
        held = []
        released.forEach { $0.resume() }
    }
}

/// What a caller of `authorizedURLRequest(for:site:)` does with a redirect: acquire the throttle for the new URL
/// (refusing the redirect when that throws), then continue with `redirectedRequest(_:site:)`.
private final class ContractRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let client: EHClient
    private let throttle: any RequestThrottle
    private let site: EHSite

    init(client: EHClient, throttle: any RequestThrottle, site: EHSite) {
        self.client = client
        self.throttle = throttle
        self.site = site
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url else { return nil }
        do {
            try await throttle.acquire(for: url)
        } catch {
            return nil
        }
        return await client.redirectedRequest(request, site: site)
    }
}

private struct VaultWriteError: Error, Equatable {}

/// Reads as empty and fails every write.
private struct WriteFailingVault: CredentialVault {
    func read() throws -> Data? { nil }
    func write(_ data: Data) throws { throw VaultWriteError() }
    func delete() throws {}
}
