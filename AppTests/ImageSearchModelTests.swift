import EHModels
import EHNetwork
import Foundation
import Testing
import UIKit

@testable import Eros

/// `ImageSearchModel`, `ImageLookupFeed` and the image search's route values (search Q5). Every image is made here; the
/// lookups are closures, the feed's requests go to a `StubURLProtocol` answering with a page of the Debug bundle's
/// fixtures, and the result address is made up: nothing reaches the network.
///
/// Each test has a minute (`.timeLimit`): some hold a request, a page or a feed's answer until they let it go (a
/// gate, a throttle: neither heeds cancellation), and one that never lets go must fail at the limit, not hang the
/// run (the test process is then ended and started again for the tests after it).
@MainActor @Suite(.timeLimit(.minutes(1))) struct ImageSearchModelTests {
    static let notAnImage = "This file is not an image Eros-SE can read."
    static let tooLarge = "The image is too large to upload, even after making it smaller."
    static let noResults = "The site did not return search results."

    /// A made-up result address in the shape of the site's.
    static let resultURL = URL(
        string: "https://e-hentai.org/?f_shash=0123456789abcdef0123456789abcdef01234567&fs_from=a.png"
    )!
    static let emptyPage = GalleryListPage(
        items: [], skippedRowCount: 0, displayMode: nil, previousCursor: nil, nextCursor: "123", pageIndex: nil,
        pageCount: nil, resultSummary: nil, filteredCount: nil, similarityScanDisabled: true, favoriteFolders: [],
        favoritesOrder: nil
    )
    static let result = ImageLookupResult(resultURL: resultURL, page: emptyPage)

    /// A `side` × `side` PNG of one colour.
    static func png(side: CGFloat = 16) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// Bytes that start like no image format.
    static let garbage = Data((0..<64).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

    /// The calls a lookup closure received.
    final class LookupLog {
        var calls: [(data: Data, format: ImageFormat, options: ImageLookupOptions)] = []
    }

    /// A model on E-Hentai whose lookup records its calls in `log` and then does `answer`.
    static func model(
        log: LookupLog = LookupLog(),
        answer: @escaping @MainActor () async throws -> ImageLookupResult = { ImageSearchModelTests.result }
    ) -> ImageSearchModel {
        ImageSearchModel(site: .eh) { data, format, options in
            log.calls.append((data, format, options))
            return try await answer()
        }
    }

    // MARK: - Options and choosing

    /// Similarity Scan on, covers only and expunged off (field by field).
    @Test func optionsDefaultToSimilarityOnly() {
        let model = Self.model()
        #expect(model.options.similar == true)
        #expect(model.options.coversOnly == false)
        #expect(model.options.includeExpunged == false)
        #expect(model.image == nil)
        #expect(!model.isSearching && !model.isPreparing)
    }

    /// A PNG under the limit is kept byte for byte, picked from Photos or from Files.
    @Test func chosenPNGKeepsItsBytes() async throws {
        let png = Self.png()
        let model = Self.model()
        await model.choose(png)
        #expect(model.image == PreparedImage(data: png, format: .png, wasReencoded: false))
        #expect(model.preview != nil)
        #expect(!model.isPreparing)
        #expect(model.failureMessage == nil)

        let other = Self.png(side: 24)
        let url = FileManager.default.temporaryDirectory.appending(path: "image-search-test-\(UUID().uuidString).png")
        try other.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await model.chooseFile(at: url)
        #expect(model.image == PreparedImage(data: other, format: .png, wasReencoded: false))
        #expect(!model.isPreparing)
    }

    @Test func notAnImageSendsNothing() async {
        let log = LookupLog()
        let model = Self.model(log: log)
        await model.choose(Self.garbage)
        #expect(model.image == nil)
        #expect(model.failureMessage == Self.notAnImage)
        await model.search()
        #expect(log.calls.isEmpty)
        #expect(model.result == nil)
    }

    /// A file over `ImageLookupUpload.maximumInputBytes` is refused by its size. It is a sparse file nobody may read:
    /// had the model read it, the read would fail and say "not an image" instead.
    @Test func hugeFileIsRefusedBeforeReading() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "image-search-test-\(UUID().uuidString).jpg")
        #expect(FileManager.default.createFile(atPath: url.path(), contents: Data([0xFF, 0xD8, 0xFF, 0xE0])))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ImageLookupUpload.maximumInputBytes + 1))
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path())
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path())
            try? FileManager.default.removeItem(at: url)
        }
        #expect((try? Data(contentsOf: url)) == nil, "The file can be read")

        let log = LookupLog()
        let model = Self.model(log: log)
        await model.chooseFile(at: url)
        #expect(model.failureMessage == Self.tooLarge)
        #expect(model.image == nil)
        #expect(!model.isPreparing)
        await model.search()
        #expect(log.calls.isEmpty)
    }

    /// A photo that cannot be loaded says it is not an image; a cancelled load says nothing.
    @Test func photoThatCannotBeLoadedIsNotAnImage() async {
        struct Unreadable: Error {}
        let model = Self.model()
        await model.choose { nil }
        #expect(model.failureMessage == Self.notAnImage)
        model.failureMessage = nil
        await model.choose { throw Unreadable() }
        #expect(model.failureMessage == Self.notAnImage)
        model.failureMessage = nil
        await model.choose { throw CancellationError() }
        #expect(model.failureMessage == nil)
        #expect(model.image == nil)
        let png = Self.png()
        await model.choose { png }
        #expect(model.image?.data == png)
    }

    /// Two choices overlap: the one made later is kept, even when the earlier one ends after it. Meanwhile Search does
    /// nothing. The earlier preparation is held by a gate until the later one is done, so the order does not depend on
    /// timing.
    @Test func theLaterChoiceWins() async {
        let gate = Gate()
        let kept = Data("fake-kept".utf8), earlier = Data("fake-earlier".utf8), later = Data("fake-later".utf8)
        let log = LookupLog()
        let model = ImageSearchModel(
            site: .eh,
            lookup: { data, format, options in
                log.calls.append((data, format, options))
                return Self.result
            },
            prepare: { data in
                if data == earlier { await gate.wait() }
                return PreparedImage(data: data, format: .png, wasReencoded: false)
            }
        )
        await model.choose(kept)
        #expect(model.image?.data == kept)

        let first = Task.immediate { await model.choose(earlier) }
        #expect(model.isPreparing)
        await model.search()
        #expect(log.calls.isEmpty, "Search ran while an image was being prepared")

        await model.choose(later)
        #expect(model.image?.data == later)
        #expect(!model.isPreparing)
        gate.open()
        await first.value
        #expect(model.image?.data == later)
        #expect(!model.isPreparing)
    }

    // MARK: - Searching

    @Test func searchPassesBytesAndOptions() async {
        let png = Self.png()
        let log = LookupLog()
        let model = Self.model(log: log)
        await model.choose(png)
        model.options.coversOnly = true
        await model.search()
        #expect(log.calls.count == 1)
        #expect(log.calls.first?.data == png)
        #expect(log.calls.first?.format == .png)
        var expected = ImageLookupOptions()
        expected.coversOnly = true
        #expect(log.calls.first?.options == expected)
        #expect(model.result == Self.result)
        #expect(model.failureMessage == nil)
        #expect(!model.isSearching)
    }

    @Test(arguments: [
        ImageLookupError.noRedirect(status: 200), .missingLocation, .unexpectedLocation,
    ])
    func lookupFailuresShowOneMessage(error: ImageLookupError) async {
        let model = Self.model { throw error }
        await model.choose(Self.png())
        await model.search()
        #expect(model.failureMessage == Self.noResults)
        #expect(model.result == nil)
        #expect(!model.isSearching)
    }

    /// A cancelled search, and one whose session ended, say nothing (`ListFailure(_:)` drops them); any other failure
    /// is worded as a list's.
    @Test func cancelledLookupShowsNothing() async {
        for error: any Error in [CancellationError(), EHNetworkError.cancelled, EHNetworkError.sessionEnded] {
            let model = Self.model { throw error }
            await model.choose(Self.png())
            await model.search()
            #expect(model.failureMessage == nil, Comment(rawValue: String(describing: type(of: error))))
            #expect(model.result == nil)
        }
        let model = Self.model { throw EHNetworkError.transport(.notConnectedToInternet) }
        await model.choose(Self.png())
        await model.search()
        #expect(model.failureMessage == ListFailure.network.message)
    }

    @Test func searchingTwiceAtOnceSendsOne() async {
        let gate = Gate()
        let log = LookupLog()
        let model = Self.model(log: log) {
            await gate.wait()
            return Self.result
        }
        await model.choose(Self.png())
        let first = Task.immediate { await model.search() }
        #expect(model.isSearching)
        await model.search()
        gate.open()
        await first.value
        #expect(log.calls.count == 1)
        #expect(!model.isSearching)
        #expect(model.result == Self.result)
    }

    // MARK: - The results' feed

    /// An environment (in-memory stores) whose requests go to a stub answering every one with `answer`; started.
    static func makeEnvironment(answer: Data) async -> (environment: AppEnvironment, stub: StubSession) {
        let stub = StubURLProtocol.install { _ in StubResponse(body: answer) }
        let environment = AppEnvironment(
            uiTesting: true, sessionConfigurator: stub.configurator, userAgentProbe: { "FakeWebKit/1" }
        )
        await environment.start()
        return (environment, stub)
    }

    /// The first page is the one the lookup read: nothing is asked, and it is not from the cache, so the list does
    /// not refresh it in the background.
    @Test func feedFirstPageReusesTheLookupPage() async throws {
        let (environment, stub) = await Self.makeEnvironment(answer: SearchFeedsTests.fixture("eh/list/front.html"))
        defer { stub.remove() }
        let feed = ImageLookupFeed(result: Self.result, service: environment.service, site: .eh)
        let first = try await feed.page(at: .first, refresh: false)
        #expect(first == ListPageResult(page: Self.emptyPage, isFromCache: false))
        #expect(stub.requests().isEmpty)
    }

    @Test func feedNextPageAsksForTheCursor() async throws {
        let (environment, stub) = await Self.makeEnvironment(answer: SearchFeedsTests.fixture("eh/list/front.html"))
        defer { stub.remove() }
        let feed = ImageLookupFeed(result: Self.result, service: environment.service, site: .eh)
        let next = try await feed.page(at: .next("123"), refresh: false)
        #expect(next.page.items.count == 25)
        #expect(stub.requests().map(\.httpMethod) == ["GET"])
        #expect(stub.requests().compactMap(\.url) == [URL(string: Self.resultURL.absoluteString + "&next=123")!])
    }

    /// Pulling to refresh asks for the result address again (Flutter uploads again); numbered pages and jumps are not
    /// offered and fail without a request.
    @Test func feedRefreshAsksForTheResultsAgain() async throws {
        let (environment, stub) = await Self.makeEnvironment(answer: SearchFeedsTests.fixture("eh/list/front.html"))
        defer { stub.remove() }
        let feed = ImageLookupFeed(result: Self.result, service: environment.service, site: .eh)
        let refreshed = try await feed.page(at: .first, refresh: true)
        #expect(refreshed.page.items.count == 25)
        #expect(stub.requests().compactMap(\.url) == [Self.resultURL])
        for position in [ListPosition.page(2), .jump("1d"), .seek("2026-01-01")] {
            await #expect(throws: (any Error).self) { try await feed.page(at: position, refresh: false) }
        }
        #expect(stub.requests().count == 1)
    }

    // MARK: - Routes

    /// A results route is one push: two of the same result are different routes, a route equals only itself.
    @Test func resultsRoutesCompareByTheirID() {
        let one = ImageSearchResults(result: Self.result, site: .eh)
        let two = ImageSearchResults(result: Self.result, site: .eh)
        #expect(one != two)
        #expect(one == one)
        #expect(ImageSearchRoute.results(one) == .results(one))
        #expect(ImageSearchRoute.results(one) != .results(two))
        #expect(Set([ImageSearchRoute.results(one), .results(one), .results(two)]).count == 2)
        #expect(ImageSearchRoute.search(.eh) == .search(.eh))
        #expect(ImageSearchRoute.search(.eh) != .search(.ex))
    }
}
