import EHModels
import EHNetwork
import Foundation
import Nuke
import Synchronization
import SwiftUI
import Testing
import UIKit

@testable import Eros

/// What the image tests share: a UI testing `AppEnvironment` whose URLSession requests `StubURLProtocol` answers (made-up
/// PNGs, nothing reaches the network), with a stub UA probe. Every cookie value and file name is made up.
@MainActor enum ImageHarness {
    @MainActor struct Harness {
        let environment: AppEnvironment
        let stub: StubSession

        /// The thumbnail pipeline (`AppEnvironment.images`).
        var images: ImagePipeline { environment.images }
    }

    static let userAgent =
        "Mozilla/5.0 (FakePhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    static let identity = [CookieNames.memberID: "1234567", CookieNames.passHash: "0123456789abcdef0123456789abcdef"]
    /// A made-up ban notice, as the site sends it (plain text, no HTML).
    static let banNotice = Data((
        "Your IP address has been temporarily banned for excessive pageloads which indicates that you are using "
            + "automated mirroring/harvesting software. The ban expires in 59 minutes and 47 seconds"
    ).utf8)

    /// A started environment (`start()`: the stub UA is current). `thumbnailCacheName` gives the thumbnails a disk
    /// cache of that name.
    static func make(
        throttle: (any RequestThrottle)? = nil, breaker: SiteBreaker? = nil, thumbnailCacheName: String? = nil,
        responder: @escaping @Sendable (URLRequest) throws -> StubResponse
    ) async -> Harness {
        let stub = StubURLProtocol.install(responder)
        let environment = AppEnvironment(
            uiTesting: true, sessionConfigurator: stub.configurator, userAgentProbe: { userAgent }, throttle: throttle,
            breaker: breaker, thumbnailCacheName: thumbnailCacheName
        )
        await environment.start()
        return Harness(environment: environment, stub: stub)
    }

    /// A PNG of `width` × `height` pixels.
    static func png(width: Int = 2, height: Int = 2) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Answers each of `urls` with `png` (`image/png`); any other URL fails.
    static func serving(_ urls: [URL], png: Data = png()) -> @Sendable (URLRequest) throws -> StubResponse {
        let served = Set(urls)
        return { request in
            guard let url = request.url, served.contains(url) else { throw URLError(.badURL) }
            return StubResponse(headers: ["Content-Type": "image/png"], body: png)
        }
    }

    /// Answers every request with `response`.
    static func answering(_ response: StubResponse) -> @Sendable (URLRequest) throws -> StubResponse {
        { _ in response }
    }

    /// The two session boundaries that end the image loads in flight and empty the image caches.
    enum SessionBoundary: CaseIterable, Sendable {
        case logOut
        case loginStart

        @MainActor func cross(in environment: AppEnvironment) async throws {
            switch self {
            case .logOut: try await environment.logOut()
            case .loginStart: try await environment.prepareLogin()
            }
        }
    }
}

/// Holds a stub's answers (the URL protocol's loading thread waits in the responder) until `open()`; for at most 10 s,
/// so a broken test does not hang the run.
final class ResponderGate: Sendable {
    private let isOpen = Mutex(false)
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        guard !isOpen.withLock({ $0 }) else { return }
        _ = semaphore.wait(timeout: .now() + 10)
    }

    func open() {
        isOpen.withLock { $0 = true }
        semaphore.signal()
    }
}

/// A throttle that lets every request through at once, except those to `host`, which wait until `open()`.
actor HoldingThrottle: RequestThrottle {
    private let host: String
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Whether a request to `host` is waiting now.
    var holds: Bool { !waiting.isEmpty }

    init(host: String) {
        self.host = host
    }

    func acquire(for url: URL) async throws {
        if url.host() == host, !isOpen {
            await withCheckedContinuation { waiting.append($0) }
        }
        try Task.checkCancellation()
    }

    func open() {
        isOpen = true
        let held = waiting
        waiting = []
        for continuation in held { continuation.resume() }
    }
}

/// A count that any thread may add to.
final class Tally: Sendable {
    private let value = Mutex(0)

    var count: Int { value.withLock { $0 } }

    func add() {
        value.withLock { $0 += 1 }
    }
}

/// `GatedThrottle` that also counts the calls whose task was cancelled while they waited (the gate itself only notices
/// a cancellation once it opens).
struct CountingCancellations: RequestThrottle {
    let base: GatedThrottle
    let cancellations: Tally

    func acquire(for url: URL) async throws {
        try await withTaskCancellationHandler {
            try await base.acquire(for: url)
        } onCancel: {
            cancellations.add()
        }
    }
}

/// `EHImageDataLoader` behind `AppEnvironment.images`: the throttle, the WebKit UA and the image host's own cookies,
/// manual redirects, cancellation, the breaker, and only 200 image answers handed to Nuke.
///
/// Each test has a minute (`.timeLimit`): some hold a request, a page or a feed's answer until they let it go (a
/// gate, a throttle: neither heeds cancellation), and one that never lets go must fail at the limit, not hang the
/// run (the test process is then ended and started again for the tests after it).
@MainActor @Suite(.timeLimit(.minutes(1))) struct EHImageDataLoaderTests {
    private static let cover = URL(string: "https://ehgt.org/t/00/00/fake-cover-0001.jpg")!
    private static let exThumbnail = URL(string: "https://s.exhentai.org/t/00/00/fake-thumb-0001.jpg")!
    private static let hath = URL(string: "https://abc.hath.network/h/fake-0001/fake-thumb-0001.jpg")!

    @Test func imagesWaitForTheThrottle() async throws {
        let throttle = ThrottleRecorder()
        let h = await ImageHarness.make(throttle: throttle, responder: ImageHarness.serving([Self.cover]))

        let image = try await h.images.image(for: Self.cover)
        #expect(image.cgImage?.width == 2)
        #expect(await throttle.urls == [Self.cover])
        #expect(h.stub.requests().compactMap(\.url) == [Self.cover])
    }

    @Test func imagesCarryTheWebKitUserAgentAndOnlyTheirHostsCookies() async throws {
        let h = await ImageHarness.make(responder: ImageHarness.serving([Self.cover, Self.exThumbnail]))
        try await h.environment.cookies.set(ImageHarness.identity.merging(["sk": "sk-fake-0001"]) { $1 }, for: [.eh])
        try await h.environment.cookies.set(
            ImageHarness.identity.merging(["igneous": "igneous-fake-0001"]) { $1 }, for: [.ex]
        )

        _ = try await h.images.image(for: Self.cover)
        _ = try await h.images.image(for: Self.exThumbnail)
        let requests = h.stub.requests()
        let eh = try #require(requests.first { $0.url == Self.cover })
        let ex = try #require(requests.first { $0.url == Self.exThumbnail })
        let userAgent = await h.environment.userAgents.current
        #expect(userAgent == ImageHarness.userAgent)
        #expect(eh.value(forHTTPHeaderField: "User-Agent") == userAgent)
        #expect(ex.value(forHTTPHeaderField: "User-Agent") == userAgent)
        // ehgt.org is neither site's host: no cookie at all.
        #expect(eh.value(forHTTPHeaderField: "Cookie") == nil)
        let cookie = try #require(ex.value(forHTTPHeaderField: "Cookie"))
        #expect(cookie.contains("igneous=igneous-fake-0001"))
        #expect(!cookie.contains("sk-fake-0001"))
        // Each site's request timeout (design §5.2: ExHentai has more headroom): 20 s and 25 s.
        #expect(eh.timeoutInterval == 20)
        #expect(ex.timeoutInterval == 25)
    }

    /// An EX thumbnail that redirects to an H@H node: the hop waits for the throttle and carries no site cookie.
    @Test func redirectHopsAreThrottledAndRescoped() async throws {
        let throttle = ThrottleRecorder()
        let png = ImageHarness.png()
        let (thumbnail, hath) = (Self.exThumbnail, Self.hath)
        let h = await ImageHarness.make(throttle: throttle) { request in
            switch request.url {
            case thumbnail?: StubResponse(status: 302, redirectTo: hath)
            case hath?: StubResponse(headers: ["Content-Type": "image/png"], body: png)
            default: throw URLError(.badURL)
            }
        }
        try await h.environment.cookies.set(
            ImageHarness.identity.merging(["igneous": "igneous-fake-0001"]) { $1 }, for: [.ex]
        )

        _ = try await h.images.image(for: thumbnail)
        #expect(await throttle.urls == [thumbnail, hath])
        let requests = h.stub.requests()
        #expect(requests.compactMap(\.url) == [thumbnail, hath])
        #expect(requests.first?.value(forHTTPHeaderField: "Cookie")?.contains("igneous=igneous-fake-0001") == true)
        #expect(requests.last?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "User-Agent") == ImageHarness.userAgent)
    }

    /// A redirect hop prepared once the session has ended (logged out, a login began) is not sent: it would carry the
    /// next session's cookies for an image the earlier one asked for.
    @Test(arguments: ImageHarness.SessionBoundary.allCases)
    func redirectHopsAcrossASessionBoundaryAreNotSent(_ boundary: ImageHarness.SessionBoundary) async throws {
        let throttle = HoldingThrottle(host: try #require(Self.hath.host()))
        let png = ImageHarness.png()
        let (thumbnail, hath) = (Self.exThumbnail, Self.hath)
        let h = await ImageHarness.make(throttle: throttle) { request in
            switch request.url {
            case thumbnail?: StubResponse(status: 302, redirectTo: hath)
            case hath?: StubResponse(headers: ["Content-Type": "image/png"], body: png)
            default: throw URLError(.badURL)
            }
        }

        let load = h.images.imageTask(with: thumbnail)
        // The first request is out; its hop waits for the throttle.
        #expect(await eventually { await throttle.holds })
        try await boundary.cross(in: h.environment)
        await throttle.open()

        do {
            _ = try await load.image
            Issue.record("the hop went out after the session ended")
        } catch {
            #expect(error.dataLoadingError as? ImageLoadError == .superseded)
        }
        #expect(h.stub.requests().compactMap(\.url) == [thumbnail])
        #expect(!h.images.cache.containsCachedImage(for: ImageRequest(url: thumbnail), caches: .memory))
    }

    /// Scrolling past many thumbnails while they wait for the throttle: the cancelled ones never go out.
    @Test(.timeLimit(.minutes(1))) func cancelledLoadsNeverReachTheNetwork() async throws {
        let gate = GatedThrottle()
        let cancellations = Tally()
        let urls = (1...20).map { URL(string: "https://ehgt.org/t/00/00/fake-cover-\($0).jpg")! }
        let h = await ImageHarness.make(
            throttle: CountingCancellations(base: gate, cancellations: cancellations),
            responder: ImageHarness.serving(urls)
        )
        // The pipeline runs this many loads at once; the others wait in its queue.
        let running = h.images.configuration.dataLoadingQueue.maxConcurrentOperationCount
        try #require(running < urls.count)

        let tasks = urls.map { h.images.imageTask(with: $0) }
        #expect(await eventually { await gate.urls.count == running })
        try await Task.sleep(for: .milliseconds(200))
        let waiting = Set(await gate.urls)
        #expect(waiting.count == running)
        // One load still in the queue stays; every other is cancelled: the running ones while they wait for the
        // throttle, the rest in the queue.
        let kept = try #require(urls.indices.last { !waiting.contains(urls[$0]) })
        for (index, task) in tasks.enumerated() where index != kept { task.cancel() }
        #expect(await eventually { cancellations.count == running })
        await gate.open()

        let image = try await tasks[kept].image
        #expect(image.cgImage?.width == 2)
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.stub.requests().compactMap(\.url) == [urls[kept]])
        #expect(await h.environment.breaker.current() == nil)
    }

    /// A cancelled load records nothing: the same URL loads again later (scrolling back), from the site.
    @Test func cancelledLoadsAreNotRemembered() async throws {
        let gate = GatedThrottle()
        let cancellations = Tally()
        let h = await ImageHarness.make(
            throttle: CountingCancellations(base: gate, cancellations: cancellations),
            responder: ImageHarness.serving([Self.cover])
        )

        let first = h.images.imageTask(with: Self.cover)
        #expect(await eventually { await gate.urls.count == 1 })
        first.cancel()
        #expect(await eventually { cancellations.count == 1 })
        await gate.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.stub.requests().isEmpty)

        let image = try await h.images.image(for: Self.cover)
        #expect(image.cgImage?.width == 2)
        #expect(h.stub.requests().compactMap(\.url) == [Self.cover])
        #expect(await gate.urls == [Self.cover, Self.cover])
        #expect(await h.environment.breaker.current() == nil)
    }

    /// An image asked for over plain http is refused before the throttle, and nothing goes out: a cookie never
    /// travels unencrypted (L056).
    @Test func plainHTTPImagesAreRefusedUnsent() async throws {
        let throttle = ThrottleRecorder()
        let url = URL(string: "http://ehgt.org/t/00/00/fake-cover-0001.jpg")!
        let h = await ImageHarness.make(throttle: throttle, responder: ImageHarness.serving([url]))

        do {
            _ = try await h.images.image(for: url)
            Issue.record("a plain http image loaded")
        } catch {
            #expect((error.dataLoadingError as? URLError)?.code == .unsupportedURL)
        }
        #expect(await throttle.urls.isEmpty)
        #expect(h.stub.requests().isEmpty)
    }

    /// A redirect hop to plain http is refused: the first answer stays the only request (L056).
    @Test func redirectsToPlainHTTPAreRefused() async throws {
        let throttle = ThrottleRecorder()
        let png = ImageHarness.png()
        let thumbnail = Self.exThumbnail
        let plain = URL(string: "http://abc.hath.network/h/fake-0001/fake-thumb-0001.jpg")!
        let h = await ImageHarness.make(throttle: throttle) { request in
            switch request.url {
            case thumbnail?: StubResponse(status: 302, redirectTo: plain)
            case plain?: StubResponse(headers: ["Content-Type": "image/png"], body: png)
            default: throw URLError(.badURL)
            }
        }

        do {
            _ = try await h.images.image(for: thumbnail)
            Issue.record("the image loaded over a plain http hop")
        } catch {
            #expect((error.dataLoadingError as? URLError)?.code == .unsupportedURL)
        }
        #expect(await throttle.urls == [thumbnail])
        #expect(h.stub.requests().compactMap(\.url) == [thumbnail])
        #expect(!h.images.cache.containsCachedImage(for: ImageRequest(url: thumbnail), caches: .memory))
    }

    /// The session (and the timeout) of an image follows its host: ExHentai's for exhentai.org and its subdomains,
    /// E-Hentai's for any other host, ehgt.org and the H@H nodes included (L056).
    @Test func imagesUseTheSessionOfTheirHost() {
        #expect(EHImageDataLoader.site(for: URL(string: "https://s.exhentai.org/t/00/00/fake.jpg")!) == .ex)
        #expect(EHImageDataLoader.site(for: URL(string: "https://exhentai.org/fake.jpg")!) == .ex)
        #expect(EHImageDataLoader.site(for: URL(string: "https://ehgt.org/t/00/00/fake.jpg")!) == .eh)
        #expect(EHImageDataLoader.site(for: Self.hath) == .eh)
        #expect(EHImageDataLoader.site(for: URL(string: "https://e-hentai.org/fake.jpg")!) == .eh)
        #expect(EHImageDataLoader.site(for: URL(string: "https://forums.e-hentai.org/uploads/fake.jpg")!) == .eh)
    }

    @Test func pausedSitesSendNoImageRequest() async throws {
        let h = await ImageHarness.make(responder: ImageHarness.serving([Self.cover]))
        let pause = try #require(await h.environment.breaker.record(.banned(remaining: nil), at: Self.cover))

        do {
            _ = try await h.images.image(for: Self.cover)
            Issue.record("loaded during a pause")
        } catch {
            #expect(error.dataLoadingError as? EHNetworkError == .paused(pause))
        }
        #expect(h.stub.requests().isEmpty)
    }

    /// The ban notice comes as a 200 text answer instead of the image: both sites pause.
    @Test func bannedImageAnswersTripTheBreaker() async throws {
        let h = await ImageHarness.make(responder: ImageHarness.answering(StubResponse(
            headers: ["Content-Type": "text/html; charset=UTF-8"], body: ImageHarness.banNotice
        )))

        await Self.expectBanned(loading: Self.cover, in: h)
    }

    /// The ban notice as a 403: both sites pause as well.
    @Test func forbiddenBanNoticesTripTheBreaker() async throws {
        let h = await ImageHarness.make(responder: ImageHarness.answering(StubResponse(
            status: 403, headers: ["Content-Type": "text/html; charset=UTF-8"], body: ImageHarness.banNotice
        )))

        await Self.expectBanned(loading: Self.cover, in: h)
    }

    /// An answer that says it is an image is not searched for a notice, whatever its bytes hold.
    @Test func imageAnswersAreNotScannedForNotices() async throws {
        let h = await ImageHarness.make(responder: ImageHarness.answering(StubResponse(
            headers: ["Content-Type": "image/jpeg"], body: ImageHarness.banNotice
        )))

        _ = try? await h.images.image(for: Self.cover)
        #expect(h.stub.requests().count == 1)
        #expect(await h.environment.breaker.current() == nil)
    }

    @Test func non200IsAFailure() async throws {
        let h = await ImageHarness.make(responder: ImageHarness.answering(StubResponse(
            status: 404, headers: ["Content-Type": "text/html"], body: Data("<html><body>Fake 404</body></html>".utf8)
        )))

        for attempt in 1...2 {
            do {
                _ = try await h.images.image(for: Self.cover)
                Issue.record("a 404 loaded")
            } catch {
                #expect(error.dataLoadingError != nil)
            }
            // Nothing is kept: the next load asks the site again.
            #expect(!h.images.cache.containsCachedImage(for: ImageRequest(url: Self.cover)))
            #expect(h.stub.requests().count == attempt)
        }
        #expect(await h.environment.breaker.current() == nil)
    }

    // MARK: - Helpers

    /// Loading `url` fails with the ban notice, and both sites are paused for a ban.
    private static func expectBanned(loading url: URL, in h: ImageHarness.Harness) async {
        do {
            _ = try await h.images.image(for: url)
            Issue.record("the ban notice loaded as an image")
        } catch {
            guard case .issue(.banned)? = error.dataLoadingError as? EHNetworkError else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        #expect(h.stub.requests().count == 1)
        #expect(await h.environment.breaker.current()?.reason == .banned)
    }
}
