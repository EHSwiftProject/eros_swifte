import EHFixtures
import EHModels
import EHNetwork
import EHNetworkTesting
import Foundation
import Synchronization
import Testing

/// `EHService.imageLookup(image:format:options:site:)` and `galleryList(at:site:refresh:)` (search Q5). Every request
/// goes to `MockURLProtocol`; none reaches the network. The redirect and the result page are the checked-in captures
/// (`eh/list/image-lookup-redirect.html` with its `location`, `eh/list/image-lookup.html`; EX the same), the image
/// bytes are made up.
@Suite struct ImageLookupTests {
    private static let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])
    private static let nonCompact = Data(try! Fixtures.data("constructed/eh/list-non-compact.html"))
    private static let front = Data(try! Fixtures.data("eh/list/front.html"))

    /// The captured upload of `site`: its 302 body, its `location`, and the result page that location answers with.
    private struct Capture {
        let redirect: Data
        let location: URL
        let result: Data
    }

    private static func capture(_ site: EHSite) throws -> Capture {
        let directory = site == .eh ? "eh" : "ex"
        let entries = try Fixtures.manifest().entries
        let redirect = try #require(entries.first { $0.path == "\(directory)/list/image-lookup-redirect.html" })
        let location = try #require(redirect.location.flatMap(URL.init(string:)))
        return Capture(
            redirect: try Fixtures.data(redirect.path), location: location,
            result: try Fixtures.data("\(directory)/list/image-lookup.html")
        )
    }

    private struct Harness {
        let service: EHService
        let client: EHClient
        let cookies: CookieStore
        let throttle: RecordingThrottle
        let presenter: RecordingPresenter
        let mock: MockSession
        let directory: URL

        /// The requests the mock received, oldest first.
        func requests() -> [URLRequest] { mock.requests() }

        func cleanUp() {
            mock.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A logged-in service on a new mock registration, with a response cache in a temporary directory.
    private static func makeHarness(
        answer: Bool = true, responder: @escaping @Sendable (URLRequest) throws -> MockResponse
    ) async throws -> Harness {
        let mock = MockURLProtocol.install(responder)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "eros-image-lookup-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cookies = CookieStore(vault: InMemoryVault())
        try await cookies.load()
        try await cookies.set(
            ["ipb_member_id": "1234567", "ipb_pass_hash": "0123456789abcdef0123456789abcdef"], for: [.eh, .ex]
        )
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        await userAgents.load()
        let throttle = RecordingThrottle()
        let client = EHClient(
            configuration: try EHClientConfiguration(sessionConfigurator: mock.configurator), cookies: cookies,
            userAgents: userAgents, throttle: throttle, cache: ResponseCache(directory: directory)
        )
        let presenter = RecordingPresenter(answer: answer)
        return Harness(
            service: EHService(client: client, presenter: presenter, ledger: InMemoryNoticeLedger()), client: client,
            cookies: cookies, throttle: throttle, presenter: presenter, mock: mock, directory: directory
        )
    }

    /// The POST to the site's upload address answers `upload`; any other request gets `page`.
    private static func makeHarness(
        site: EHSite, upload: MockResponse, page: Data, answer: Bool = true
    ) async throws -> Harness {
        let lookup = EHEndpoints.imageLookupURL(for: site)
        return try await makeHarness(answer: answer) { request in
            request.httpMethod == "POST" && request.url == lookup ? upload : MockResponse(body: page)
        }
    }

    // MARK: - The lookup

    /// The upload is offered as a redirect, which the client does not follow; the service then asks for the location
    /// itself, once.
    @Test(arguments: [EHSite.eh, .ex]) func postsThenFetchesTheLocation(site: EHSite) async throws {
        let capture = try Self.capture(site)
        let h = try await Self.makeHarness(
            site: site, upload: MockResponse(status: 302, body: capture.redirect, redirectTo: capture.location),
            page: capture.result
        )
        defer { h.cleanUp() }
        let result = try await h.service.imageLookup(
            image: Self.image, format: .png, options: ImageLookupOptions(), site: site
        )
        let requests = h.requests()
        #expect(requests.count == 2)
        #expect(requests.first?.httpMethod == "POST")
        #expect(requests.first?.url == EHEndpoints.imageLookupURL(for: site))
        #expect(requests.last?.httpMethod == "GET")
        #expect(requests.last?.url == capture.location)
        #expect(result.resultURL == capture.location)
        #expect(result.page.items.isEmpty)
        #expect(result.page.similarityScanDisabled)
    }

    @Test func bothRequestsAreThrottled() async throws {
        let capture = try Self.capture(.eh)
        let h = try await Self.makeHarness(
            site: .eh, upload: MockResponse(status: 302, headers: ["Location": capture.location.absoluteString]),
            page: capture.result
        )
        defer { h.cleanUp() }
        _ = try await h.service.imageLookup(image: Self.image, format: .png, options: ImageLookupOptions(), site: .eh)
        #expect(await h.throttle.acquiredURLs == [EHEndpoints.imageLookupURL(for: .eh), capture.location])
    }

    @Test func nonRedirectThrows() async throws {
        let capture = try Self.capture(.eh)
        let h = try await Self.makeHarness(site: .eh, upload: MockResponse(body: capture.result), page: capture.result)
        defer { h.cleanUp() }
        await #expect(throws: ImageLookupError.noRedirect(status: 200)) {
            try await h.service.imageLookup(image: Self.image, format: .png, options: ImageLookupOptions(), site: .eh)
        }
        #expect(h.requests().count == 1)
    }

    @Test func missingLocationThrows() async throws {
        let capture = try Self.capture(.eh)
        let h = try await Self.makeHarness(
            site: .eh, upload: MockResponse(status: 302, body: capture.redirect), page: capture.result
        )
        defer { h.cleanUp() }
        await #expect(throws: ImageLookupError.missingLocation) {
            try await h.service.imageLookup(image: Self.image, format: .png, options: ImageLookupOptions(), site: .eh)
        }
        #expect(h.requests().count == 1)
    }

    /// A location off the site, on it without https, with a port other than 443, a user or password, or a fragment
    /// is never asked for. A relative one on E-Hentai is read against the upload's host, `upld.e-hentai.org`, so it
    /// is off the site too.
    @Test(arguments: [
        "https://example.com/?f_shash=x",
        "http://e-hentai.org/?f_shash=x",
        "https://exhentai.org/?f_shash=x",
        "/?f_shash=x",
        "https://e-hentai.org:8443/?f_shash=x",
        "https://u:p@e-hentai.org/?f_shash=x",
        "https://e-hentai.org/?f_shash=x#a",
    ])
    func foreignLocationIsNotFollowed(location: String) async throws {
        let capture = try Self.capture(.eh)
        let h = try await Self.makeHarness(
            site: .eh, upload: MockResponse(status: 302, headers: ["Location": location]), page: capture.result
        )
        defer { h.cleanUp() }
        await #expect(throws: ImageLookupError.unexpectedLocation) {
            try await h.service.imageLookup(image: Self.image, format: .png, options: ImageLookupOptions(), site: .eh)
        }
        #expect(h.requests().count == 1)
    }

    /// A relative `Location` is read against the upload's address. On ExHentai
    /// the upload is on the site's own host (`exhentai.org/upld/`), so a relative result address stays on the site
    /// and is asked for; on E-Hentai it lands on `upld.e-hentai.org` and is refused (`foreignLocationIsNotFollowed`).
    @Test func relativeExLocationIsAskedForOnTheSite() async throws {
        let capture = try Self.capture(.ex)
        let components = try #require(URLComponents(url: capture.location, resolvingAgainstBaseURL: false))
        let relative = components.percentEncodedPath + "?" + (components.percentEncodedQuery ?? "")
        #expect(relative.hasPrefix("/?"))
        let h = try await Self.makeHarness(
            site: .ex, upload: MockResponse(status: 302, headers: ["Location": relative]), page: capture.result
        )
        defer { h.cleanUp() }
        let result = try await h.service.imageLookup(
            image: Self.image, format: .png, options: ImageLookupOptions(), site: .ex
        )
        let requests = h.requests()
        #expect(requests.count == 2)
        #expect(requests.last?.httpMethod == "GET")
        #expect(requests.last?.url == capture.location)
        #expect(result.resultURL == capture.location)
    }

    /// The result page goes through the list's Compact flow: not Compact, the user agrees, and it is sent once more
    /// with `inline_set=dm_l`.
    @Test func nonCompactResultAsksThenResends() async throws {
        let capture = try Self.capture(.eh)
        let lookup = EHEndpoints.imageLookupURL(for: .eh)
        let h = try await Self.makeHarness { request in
            if request.httpMethod == "POST", request.url == lookup {
                return MockResponse(status: 302, headers: ["Location": capture.location.absoluteString])
            }
            let resent = request.url?.absoluteString.contains("inline_set") == true
            return MockResponse(body: resent ? Self.front : Self.nonCompact)
        }
        defer { h.cleanUp() }
        let result = try await h.service.imageLookup(
            image: Self.image, format: .png, options: ImageLookupOptions(), site: .eh
        )
        let urls = h.requests().compactMap(\.url)
        #expect(urls.count == 3)
        #expect(urls[1] == capture.location)
        #expect(urls[2].absoluteString == capture.location.absoluteString + "&inline_set=dm_l")
        #expect(result.page.items.count == 25)
        #expect(result.resultURL == capture.location)
        #expect(await h.presenter.calls.count == 1)
    }

    /// The Compact resend puts `inline_set=dm_l` in the query of a result address that has a fragment, not after
    /// the fragment (where the site would never see it).
    @Test func compactResendPutsTheSettingInTheQuery() async throws {
        let h = try await Self.makeHarness { request in
            let resent = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.contains { $0.name == "inline_set" } == true
            return MockResponse(body: resent ? Self.front : Self.nonCompact)
        }
        defer { h.cleanUp() }
        let address = try #require(URL(string: "https://e-hentai.org/?f_shash=x#a"))
        let result = try await h.service.galleryList(at: address, site: .eh, refresh: true)
        #expect(result.page.items.count == 25)
        let urls = h.requests().compactMap(\.url)
        #expect(urls.map(\.absoluteString) == [address.absoluteString, "https://e-hentai.org/?f_shash=x&inline_set=dm_l#a"])
    }

    /// The session ends while the upload is answered: the redirect is dropped as a list page of an ended session is
    /// (`EHNetworkError.sessionEnded`), and its location is never asked for.
    @Test func uploadAnsweredAfterTheSessionEndedIsDropped() async throws {
        let capture = try Self.capture(.eh)
        let gate = UploadGate()
        let lookup = EHEndpoints.imageLookupURL(for: .eh)
        let h = try await Self.makeHarness { request in
            guard request.httpMethod == "POST", request.url == lookup else { return MockResponse(body: capture.result) }
            gate.pass()
            return MockResponse(status: 302, headers: ["Location": capture.location.absoluteString])
        }
        defer { h.cleanUp() }
        let service = h.service
        let lookupTask = Task {
            try await service.imageLookup(image: Self.image, format: .png, options: ImageLookupOptions(), site: .eh)
        }
        defer { lookupTask.cancel() }
        #expect(await waitUntil { gate.hasArrived })
        try await h.cookies.reset()
        gate.open()
        await #expect(throws: EHNetworkError.sessionEnded) { try await lookupTask.value }
        #expect(h.requests().count == 1)
    }

    // MARK: - Later pages

    /// A page of the results asked without `refresh` the second time comes from the cache, without a request.
    @Test func laterPagesReportTheCache() async throws {
        let capture = try Self.capture(.eh)
        let h = try await Self.makeHarness { _ in MockResponse(body: Self.front) }
        defer { h.cleanUp() }
        let next = try #require(URL(string: capture.location.absoluteString + "&next=123"))
        let first = try await h.service.galleryList(at: next, site: .eh, refresh: false)
        #expect(!first.isFromCache)
        #expect(h.requests().count == 1)
        let again = try await h.service.galleryList(at: next, site: .eh, refresh: false)
        #expect(h.requests().count == 1)
        #expect(again.isFromCache)
        #expect(again.page.items.count == 25)
        // `refresh` asks the site again.
        let refreshed = try await h.service.galleryList(at: next, site: .eh, refresh: true)
        #expect(h.requests().count == 2)
        #expect(!refreshed.isFromCache)
    }

    @Test func cursorURLsReplaceTheCursor() throws {
        let capture = try Self.capture(.eh)
        let page = GalleryListPage(
            items: [], skippedRowCount: 0, displayMode: nil, previousCursor: nil, nextCursor: nil, pageIndex: nil,
            pageCount: nil, resultSummary: nil, filteredCount: nil, similarityScanDisabled: false, favoriteFolders: [],
            favoritesOrder: nil
        )
        let result = ImageLookupResult(resultURL: capture.location, page: page)
        let base = capture.location.absoluteString
        #expect(result.url(for: .first) == capture.location)
        #expect(result.url(for: .next("9"))?.absoluteString == base + "&next=9")
        #expect(result.url(for: .previous("8"))?.absoluteString == base + "&prev=8")

        // A cursor already in the address is replaced, whichever it was.
        let paged = ImageLookupResult(resultURL: try #require(URL(string: base + "&next=5")), page: page)
        #expect(paged.url(for: .next("9"))?.absoluteString == base + "&next=9")
        #expect(paged.url(for: .previous("8"))?.absoluteString == base + "&prev=8")
        #expect(paged.url(for: .first) == capture.location)

        let others: [ListPosition] = [
            .page(1), .jump("1d"), .seek("2026-01-01"), .offset(jump: "1d", seek: nil, from: nil),
        ]
        for position in others {
            #expect(result.url(for: position) == nil)
        }
    }
}

/// Holds the mock's answer to the upload until `open()`: the responder calls `pass()`, which records the arrival and
/// blocks the loading thread (at most 5 seconds, so a broken test fails instead of hanging).
private final class UploadGate: Sendable {
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
