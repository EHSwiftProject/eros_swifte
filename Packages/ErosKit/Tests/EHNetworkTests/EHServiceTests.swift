import EHFixtures
import EHModels
import EHNetwork
import EHNetworkTesting
import EHParsing
import Foundation
import Synchronization
import Testing

/// Every request in this suite goes to `MockURLProtocol`; none reaches the network.
@Suite struct EHServiceTests {
    private static let compact = Data(try! Fixtures.data("eh/list/front.html"))
    private static let nonCompact = Data(try! Fixtures.data("constructed/eh/list-non-compact.html"))
    private static let empty = Data(try! Fixtures.data("eh/list/search-empty.html"))
    private static let query = ListQuery(source: .front)

    /// A made-up account; the jars of both sites hold it in the harness unless told otherwise.
    private static let memberID = 1234567
    private static let passHash = "0123456789abcdef0123456789abcdef"

    private static func scope(
        _ kind: NoticeScope.Kind = .compactView, _ site: EHSite = .eh, member: Int? = memberID
    ) -> NoticeScope {
        NoticeScope(kind: kind, site: site, memberID: member)
    }

    /// Writes the identity of `member` into the jars of both sites.
    private static func logIn(_ cookies: CookieStore, member: Int) async throws {
        try await cookies.set(
            ["ipb_member_id": String(member), "ipb_pass_hash": passHash], for: [.eh, .ex]
        )
    }

    /// The result of `task`, or nil after 5 seconds. The waiting is done by a separate task, so a task that never
    /// finishes costs only the timeout.
    private static func result(
        of task: Task<GalleryListPage, any Error>
    ) async -> Result<GalleryListPage, any Error>? {
        let box = Mutex<Result<GalleryListPage, any Error>?>(nil)
        let watcher = Task { let outcome = await task.result; box.withLock { $0 = outcome } }
        defer { watcher.cancel() }
        _ = await waitUntil { box.withLock { $0 != nil } }
        return box.withLock { $0 }
    }

    /// A service whose presenter is a `GatedPresenter`. A request without `inline_set` gets the non-Compact page.
    private static func makeGatedHarness(
        presenter: GatedPresenter = GatedPresenter(), ledger: any NoticeLedger = InMemoryNoticeLedger()
    ) async throws -> (
        service: EHService, presenter: GatedPresenter, mock: MockSession, directory: URL, cookies: CookieStore,
        client: EHClient
    ) {
        let base = try await makeHarness { request, _ in
            let resent = request.url?.absoluteString.contains("inline_set") == true
            return MockResponse(body: resent ? compact : nonCompact)
        }
        let service = EHService(client: base.client, presenter: presenter, ledger: ledger)
        return (service, presenter, base.mock, base.directory, base.cookies, base.client)
    }

    private struct Harness {
        let service: EHService
        let client: EHClient
        let presenter: RecordingPresenter
        let ledger: InMemoryNoticeLedger
        let cookies: CookieStore
        let mock: MockSession
        let directory: URL

        /// The URLs the mock received, oldest first.
        func urls() -> [URL] { mock.requests().compactMap(\.url) }

        func cleanUp() {
            mock.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A service on a new mock registration with a cache in a temporary directory. The responder gets the 1-based
    /// number of the request.
    private static func makeHarness(
        answer: Bool = true, acknowledged: Set<NoticeScope> = [], loggedIn: Bool = true,
        responder: @escaping @Sendable (URLRequest, Int) throws -> MockResponse
    ) async throws -> Harness {
        let count = Mutex(0)
        let mock = MockURLProtocol.install { request in
            let number = count.withLock { value -> Int in
                value += 1
                return value
            }
            return try responder(request, number)
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "eros-service-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cookies = CookieStore(vault: InMemoryVault())
        try await cookies.load()
        if loggedIn { try await logIn(cookies, member: memberID) }
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        await userAgents.load()
        let configuration = try EHClientConfiguration(sessionConfigurator: mock.configurator)
        let client = EHClient(
            configuration: configuration, cookies: cookies, userAgents: userAgents, throttle: RecordingThrottle(),
            cache: ResponseCache(directory: directory)
        )
        let presenter = RecordingPresenter(answer: answer)
        let ledger = InMemoryNoticeLedger(acknowledged: acknowledged)
        return Harness(
            service: EHService(client: client, presenter: presenter, ledger: ledger), client: client,
            presenter: presenter, ledger: ledger, cookies: cookies, mock: mock, directory: directory
        )
    }

    @Test func compactPageIsParsedWithoutResend() async throws {
        let h = try await Self.makeHarness { _, _ in MockResponse(body: Self.compact) }
        defer { h.cleanUp() }
        let page = try await h.service.galleryList(Self.query, site: .eh)
        #expect(h.urls().count == 1)
        #expect(page.items.count == 25)
        #expect(await h.presenter.calls.isEmpty)
    }

    @Test func nonHTMLBodyIsAnError() async throws {
        let h = try await Self.makeHarness { _, _ in MockResponse(body: Data([0x00, 0xFF, 0xFE])) }
        defer { h.cleanUp() }
        await #expect(throws: ParseError.missing("list page")) {
            try await h.service.galleryList(Self.query, site: .eh)
        }
    }

    @Test func nilDisplayModeIsTreatedAsCompact() async throws {
        let h = try await Self.makeHarness { _, _ in MockResponse(body: Self.empty) }
        defer { h.cleanUp() }
        let page = try await h.service.galleryList(Self.query, site: .eh)
        #expect(h.urls().count == 1)
        #expect(page.items.isEmpty)
        #expect(await h.presenter.calls.isEmpty)
        #expect(h.urls().allSatisfy { !$0.absoluteString.contains("inline_set") })
    }

    @Test func firstNonCompactAsksOnceThenResends() async throws {
        let h = try await Self.makeHarness { _, number in
            MockResponse(body: number == 1 ? Self.nonCompact : Self.compact)
        }
        defer { h.cleanUp() }
        let page = try await h.service.galleryList(Self.query, site: .eh)
        let urls = h.urls()
        #expect(urls.count == 2)
        #expect(!urls[0].absoluteString.contains("inline_set"))
        #expect(urls[1].absoluteString.contains("inline_set=dm_l"))
        #expect(page.items.count == 25)
        #expect(await h.ledger.isAcknowledged(Self.scope()))
        let calls = await h.presenter.calls
        #expect(calls.count == 1)
        #expect(calls.first?.site == .eh)
        #expect(calls.first?.change == .compactView(current: .thumbnail))
    }

    @Test func declinedNoticeSendsNothing() async throws {
        let h = try await Self.makeHarness(answer: false) { _, _ in MockResponse(body: Self.nonCompact) }
        defer { h.cleanUp() }
        await #expect(throws: ListServiceError.displayModeNotCompact(.thumbnail)) {
            try await h.service.galleryList(Self.query, site: .eh)
        }
        #expect(h.urls().count == 1)
        #expect(await !h.ledger.isAcknowledged(Self.scope()))
        #expect(await h.presenter.calls.count == 1)
    }

    @Test func acknowledgedNoticeResendsSilently() async throws {
        let h = try await Self.makeHarness(acknowledged: [Self.scope()]) { _, number in
            MockResponse(body: number == 1 ? Self.nonCompact : Self.compact)
        }
        defer { h.cleanUp() }
        let page = try await h.service.galleryList(Self.query, site: .eh)
        #expect(page.items.count == 25)
        #expect(h.urls().count == 2)
        #expect(await h.presenter.calls.isEmpty)
    }

    @Test func stillNotCompactAfterResendStops() async throws {
        let h = try await Self.makeHarness { _, _ in MockResponse(body: Self.nonCompact) }
        defer { h.cleanUp() }
        await #expect(throws: ListServiceError.displayModeStillNotCompact(.thumbnail)) {
            try await h.service.galleryList(Self.query, site: .eh)
        }
        #expect(h.urls().count == 2)
    }

    @Test func resendResultIsCachedUnderTheOriginalURL() async throws {
        let h = try await Self.makeHarness { _, number in
            MockResponse(body: number == 1 ? Self.nonCompact : Self.compact)
        }
        defer { h.cleanUp() }
        _ = try await h.service.galleryList(Self.query, site: .eh)
        #expect(h.urls().count == 2)
        let again = try await h.service.galleryList(Self.query, site: .eh)
        #expect(h.urls().count == 2)
        #expect(again.items.count == 25)
    }

    @Test func nonCompactResponseIsNeverServedFromCache() async throws {
        let h = try await Self.makeHarness(answer: false) { _, _ in MockResponse(body: Self.nonCompact) }
        defer { h.cleanUp() }
        for _ in 0..<2 {
            await #expect(throws: ListServiceError.displayModeNotCompact(.thumbnail)) {
                try await h.service.galleryList(Self.query, site: .eh)
            }
        }
        #expect(h.urls().count == 2)
        #expect(await h.presenter.calls.count == 2)
    }

    @Test func metadataBatchesKeepOrder() async throws {
        let h = try await Self.makeHarness { request, _ in
            let body = try #require(request.httpBody)
            let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let list = try #require(object["gidlist"] as? [[Any]])
            let entries = list.map { pair in
                #"{"gid":\#(pair[0]),"token":"\#(pair[1])","title":"Fake Gallery \#(pair[0])"}"#
            }
            return MockResponse(body: Data(#"{"gmetadata":[\#(entries.joined(separator: ","))]}"#.utf8))
        }
        defer { h.cleanUp() }
        let ids = (0..<26).map { GalleryID(gid: 900001 + $0, token: "0f0f0f0f0f") }
        let result = try await h.service.galleryMetadata(ids, site: .eh)
        #expect(h.urls().count == 2)
        #expect(result.map(\.id) == ids)
    }

    /// Non-Compact until a request carries `inline_set`.
    private static func respondsCompactOnResend(_ request: URLRequest, _: Int) -> MockResponse {
        MockResponse(body: request.url?.absoluteString.contains("inline_set") == true ? compact : nonCompact)
    }

    @Test func consentIsKeptPerSite() async throws {
        let h = try await Self.makeHarness(responder: Self.respondsCompactOnResend)
        defer { h.cleanUp() }
        #expect(try await h.service.galleryList(Self.query, site: .eh).items.count == 25)
        #expect(h.urls().count == 2)
        #expect(try await h.service.galleryList(Self.query, site: .ex).items.count == 25)
        #expect(h.urls().count == 4)
        #expect(await h.presenter.calls.map(\.site) == [.eh, .ex])
    }

    @Test func consentIsKeptPerAccount() async throws {
        let h = try await Self.makeHarness(responder: Self.respondsCompactOnResend)
        defer { h.cleanUp() }
        _ = try await h.service.galleryList(Self.query, site: .eh)
        #expect(await h.presenter.calls.count == 1)
        try await Self.logIn(h.cookies, member: 7654321)
        _ = try await h.service.galleryList(Self.query, site: .eh)
        #expect(await h.presenter.calls.count == 2)
        try await Self.logIn(h.cookies, member: Self.memberID)
        // refresh: the first account's page is cached; without it this call would never reach the ledger.
        _ = try await h.service.galleryList(Self.query, site: .eh, refresh: true)
        #expect(await h.presenter.calls.count == 2)
        #expect(h.urls().count == 6)
        #expect(h.urls().last?.absoluteString.contains("inline_set=dm_l") == true)
    }

    @Test func anonymousConsentIsItsOwn() async throws {
        let h = try await Self.makeHarness(loggedIn: false, responder: Self.respondsCompactOnResend)
        defer { h.cleanUp() }
        _ = try await h.service.galleryList(Self.query, site: .eh)
        #expect(await h.presenter.calls.count == 1)
        #expect(await h.ledger.isAcknowledged(Self.scope(member: nil)))
        try await Self.logIn(h.cookies, member: Self.memberID)
        _ = try await h.service.galleryList(Self.query, site: .eh)
        #expect(await h.presenter.calls.count == 2)
    }

    @Test func sitesAskSeparatelyAtOnce() async throws {
        let presenter = GatedPresenter(allowsOverlap: true)
        let h = try await Self.makeGatedHarness(presenter: presenter)
        defer { h.mock.remove(); try? FileManager.default.removeItem(at: h.directory) }
        let service = h.service
        let eh = Task { try await service.galleryList(Self.query, site: .eh) }
        let ex = Task { try await service.galleryList(Self.query, site: .ex) }
        defer { eh.cancel(); ex.cancel() }
        // Both questions are open together: neither waits for the other.
        #expect(await waitUntil { await presenter.calls == 2 })
        await presenter.answer(true, site: .eh)
        await presenter.answer(false, site: .ex)
        #expect((try await Self.result(of: eh)?.get().items.count) == 25)
        var failure: ListServiceError?
        if case .failure(let error)? = await Self.result(of: ex) { failure = error as? ListServiceError }
        #expect(failure == .displayModeNotCompact(.thumbnail))
    }

    @Test func presenterGetsTheChange() async throws {
        let h = try await Self.makeHarness(responder: Self.respondsCompactOnResend)
        defer { h.cleanUp() }
        _ = try await h.service.galleryList(Self.query, site: .eh)
        let calls = await h.presenter.calls
        #expect(calls.count == 1)
        #expect(calls.first?.change == .compactView(current: .thumbnail))
        #expect(calls.first?.site == .eh)
    }

    @Test func ledgerKeepsTheScope() async throws {
        let h = try await Self.makeHarness(responder: Self.respondsCompactOnResend)
        defer { h.cleanUp() }
        _ = try await h.service.galleryList(Self.query, site: .eh)
        #expect(await h.ledger.isAcknowledged(NoticeScope(kind: .compactView, site: .eh, memberID: 1234567)))
        #expect(await !h.ledger.isAcknowledged(NoticeScope(kind: .favoritesOrder, site: .eh, memberID: 1234567)))
        #expect(await !h.ledger.isAcknowledged(NoticeScope(kind: .compactView, site: .ex, memberID: 1234567)))
        #expect(await !h.ledger.isAcknowledged(NoticeScope(kind: .compactView, site: .eh, memberID: nil)))
    }

    @Test func otherKindDoesNotCount() async throws {
        let h = try await Self.makeHarness(
            acknowledged: [Self.scope(.favoritesOrder)], responder: Self.respondsCompactOnResend
        )
        defer { h.cleanUp() }
        _ = try await h.service.galleryList(Self.query, site: .eh)
        #expect(await h.presenter.calls.count == 1)
    }

    @Test(arguments: [true, false])
    func concurrentNonCompactAsksOnce(agree: Bool) async throws {
        let ledger = CountingLedger()
        let h = try await Self.makeGatedHarness(ledger: ledger)
        defer { h.mock.remove(); try? FileManager.default.removeItem(at: h.directory) }
        let service = h.service
        let a = Task { try await service.galleryList(Self.query, site: .eh) }
        let b = Task { try await service.galleryList(Self.query, site: .eh) }
        defer { a.cancel(); b.cancel() }
        // The gate reads the ledger once on each entry and once inside the shared question: three reads, with the
        // question still open, mean both callers have passed the entry check and join the one question.
        let reached = await waitUntil {
            let waiting = await h.presenter.isWaiting
            let reads = await ledger.reads
            return waiting && reads >= 3
        }
        #expect(reached)
        for _ in 0..<50 { await Task.yield() }
        await h.presenter.answerAll(agree)
        let results = [await Self.result(of: a), await Self.result(of: b)]
        if agree {
            for result in results { #expect((try result?.get().items.count) == 25) }
            #expect(h.mock.requests().count == 4)
        } else {
            for result in results {
                var failure: ListServiceError?
                if case .failure(let error)? = result { failure = error as? ListServiceError }
                #expect(failure == .displayModeNotCompact(.thumbnail))
            }
            #expect(h.mock.requests().count == 2)
        }
        #expect(await h.presenter.calls == 1)
    }

    @Test func cancelWhileAskingSendsNoResend() async throws {
        let h = try await Self.makeGatedHarness()
        defer { h.mock.remove(); try? FileManager.default.removeItem(at: h.directory) }
        let service = h.service
        let task = Task { try await service.galleryList(Self.query, site: .eh) }
        defer { task.cancel() }
        #expect(await waitUntil { await h.presenter.isWaiting })
        task.cancel()
        let outcome = await Self.result(of: task)
        if case .failure(let error)? = outcome { #expect(error is CancellationError) } else { Issue.record("expected CancellationError") }
        #expect(h.mock.requests().count == 1)
    }

    @Test func newCallerDoesNotJoinACancelledQuestion() async throws {
        let presenter = GatedPresenter(holdOnCancel: true, allowsOverlap: true)
        let h = try await Self.makeGatedHarness(presenter: presenter)
        defer { h.mock.remove(); try? FileManager.default.removeItem(at: h.directory) }
        let service = h.service
        let a = Task { try await service.galleryList(Self.query, site: .eh) }
        defer { a.cancel() }
        #expect(await waitUntil { await presenter.calls == 1 })
        // The only waiter leaves: the gate cancels the question, which the presenter keeps open (slow withdrawal).
        a.cancel()
        #expect(await waitUntil { await presenter.cancellations == 1 })
        let c = Task { try await service.galleryList(Self.query, site: .eh) }
        defer { c.cancel() }
        // C starts a question of its own instead of joining the cancelled one.
        #expect(await waitUntil { await presenter.calls == 2 })
        await presenter.answer(false, call: 1)
        await presenter.answer(true, call: 2)
        let late = await Self.result(of: c)
        #expect((try late?.get().items.count) == 25)
        if case .failure(let error)? = await Self.result(of: a) { #expect(error is CancellationError) } else { Issue.record("expected CancellationError") }
        #expect(h.mock.requests().count == 3)
    }

    // MARK: - Session ended (C5)

    /// The session ends while the question is open: after "Continue" nothing is resent and nothing is recorded.
    @Test func sessionEndedWhileAskingSendsNoResend() async throws {
        let presenter = GatedPresenter()
        let ledger = InMemoryNoticeLedger()
        let h = try await Self.makeGatedHarness(presenter: presenter, ledger: ledger)
        defer { h.mock.remove(); try? FileManager.default.removeItem(at: h.directory) }
        let service = h.service
        let list = Task { try await service.galleryList(Self.query, site: .eh) }
        defer { list.cancel() }
        #expect(await waitUntil { await presenter.isWaiting })
        try await h.cookies.reset()
        await presenter.answerAll(true)
        var failure: EHNetworkError?
        if case .failure(let error)? = await Self.result(of: list) { failure = error as? EHNetworkError }
        #expect(failure == .sessionEnded)
        #expect(h.mock.requests().count == 1)
        #expect(h.mock.requests().allSatisfy { $0.url?.absoluteString.contains("inline_set") == false })
        #expect(await !ledger.isAcknowledged(Self.scope()))
    }

    /// Another account signs in while the question for the first is open: "Continue" records no consent for either.
    @Test func switchedAccountWhileAskingRecordsNoConsent() async throws {
        let presenter = GatedPresenter()
        let ledger = InMemoryNoticeLedger()
        let h = try await Self.makeGatedHarness(presenter: presenter, ledger: ledger)
        defer { h.mock.remove(); try? FileManager.default.removeItem(at: h.directory) }
        let service = h.service
        let list = Task { try await service.galleryList(Self.query, site: .eh) }
        defer { list.cancel() }
        #expect(await waitUntil { await presenter.isWaiting })
        try await h.cookies.reset()
        try await Self.logIn(h.cookies, member: 7654321)
        await presenter.answerAll(true)
        var failure: EHNetworkError?
        if case .failure(let error)? = await Self.result(of: list) { failure = error as? EHNetworkError }
        #expect(failure == .sessionEnded)
        #expect(await !ledger.isAcknowledged(Self.scope()))
        #expect(await !ledger.isAcknowledged(Self.scope(member: 7654321)))
    }

    /// The session ends while the question is open and the answer is "Cancel": the list of the ended session is
    /// dropped silently (`.sessionEnded`), not reported as declined.
    @Test func cancelAfterTheSessionEndedIsNotReported() async throws {
        let presenter = GatedPresenter()
        let ledger = InMemoryNoticeLedger()
        let h = try await Self.makeGatedHarness(presenter: presenter, ledger: ledger)
        defer { h.mock.remove(); try? FileManager.default.removeItem(at: h.directory) }
        let service = h.service
        let list = Task { try await service.galleryList(Self.query, site: .eh) }
        defer { list.cancel() }
        #expect(await waitUntil { await presenter.isWaiting })
        try await h.cookies.reset()
        await presenter.answerAll(false)
        var failure: (any Error)?
        if case .failure(let error)? = await Self.result(of: list) { failure = error }
        #expect(failure as? EHNetworkError == .sessionEnded, Comment(rawValue: "\(String(describing: failure))"))
        #expect(h.mock.requests().count == 1)
        #expect(await !ledger.isAcknowledged(Self.scope()))
    }

    /// A list answered from the cache belongs to the session its scope was read in: when that
    /// session ends while the Compact question is open, "Continue" resends nothing and records nothing, as for a page
    /// from the site.
    @Test func cachedPageOfAnEndedSessionIsNotResent() async throws {
        let presenter = GatedPresenter()
        let ledger = InMemoryNoticeLedger()
        let h = try await Self.makeGatedHarness(presenter: presenter, ledger: ledger)
        defer { h.mock.remove(); try? FileManager.default.removeItem(at: h.directory) }
        // Prime the cache with the non-Compact page; the service then reads it back from the cache.
        _ = try await h.client.send(EHRequests.list(Self.query, site: .eh))
        let service = h.service
        let list = Task { try await service.galleryList(Self.query, site: .eh) }
        defer { list.cancel() }
        #expect(await waitUntil { await presenter.isWaiting })
        #expect(h.mock.requests().count == 1)
        try await h.cookies.reset()
        await presenter.answerAll(true)
        var failure: (any Error)?
        if case .failure(let error)? = await Self.result(of: list) { failure = error }
        #expect(failure as? EHNetworkError == .sessionEnded, Comment(rawValue: "\(String(describing: failure))"))
        #expect(h.mock.requests().count == 1)
        #expect(await !ledger.isAcknowledged(Self.scope()))
    }

    /// A list answered from the cache belongs to the account its scope was read for, the one of the jar of its own
    /// site: an ExHentai page is recorded for the ExHentai member even when the E-Hentai jar holds another one.
    @Test func cachedExPageIsRecordedForTheExJarMember() async throws {
        let h = try await Self.makeHarness(responder: Self.respondsCompactOnResend)
        defer { h.cleanUp() }
        try await h.cookies.set(
            ["ipb_member_id": "7654321", "ipb_pass_hash": Self.passHash], for: [.ex]
        )
        // Prime the cache with the non-Compact page; the service then reads it back under the EX jar's scope.
        _ = try await h.client.send(EHRequests.list(Self.query, site: .ex))
        #expect(try await h.service.galleryList(Self.query, site: .ex).items.count == 25)
        #expect(h.urls().count == 2)
        #expect(await h.ledger.isAcknowledged(Self.scope(.compactView, .ex, member: 7654321)))
        #expect(await !h.ledger.isAcknowledged(Self.scope(.compactView, .ex, member: Self.memberID)))
    }
}
