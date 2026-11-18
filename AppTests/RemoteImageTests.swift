import EHNetwork
import EHParsing
import Foundation
import Nuke
import SwiftUI
import Synchronization
import Testing
import UIKit
import WebKit

@testable import Eros

/// `RemoteImage` and the image pipelines of `AppEnvironment`: the disk cache, and what logging out and a login clear.
/// Requests are answered by `StubURLProtocol` (`ImageHarness`); nothing reaches the network.
///
/// Each test has a minute (`.timeLimit`): some hold a request, a page or a feed's answer until they let it go (a
/// gate, a throttle: neither heeds cancellation), and one that never lets go must fail at the limit, not hang the
/// run (the test process is then ended and started again for the tests after it).
@MainActor @Suite(.timeLimit(.minutes(1))) struct RemoteImageTests {
    private static let cover = URL(string: "https://ehgt.org/t/00/00/fake-cover-0002.jpg")!
    private static let avatar = URL(string: "https://forums.e-hentai.org/uploads/av-fake-0002.jpg")!

    /// The phases a `RemoteImage` showed, oldest first.
    @MainActor private final class PhaseLog {
        var phases: [RemoteImagePhase] = []

        var successSize: CGSize? {
            for case .success(_, let size) in phases.reversed() { return size }
            return nil
        }

        func record(_ phase: RemoteImagePhase) {
            phases.append(phase)
        }
    }

    @Test func remoteImageShowsTheLoadedImage() async throws {
        let h = await ImageHarness.make(
            responder: ImageHarness.serving([Self.cover], png: ImageHarness.png(width: 3, height: 2))
        )
        let log = PhaseLog()

        let window = try Self.show(RemoteImage(url: Self.cover) { phase in
            let _ = log.record(phase)
            Color.clear
        }.environment(h.environment))
        defer { Self.hide(window) }
        #expect(await eventually { log.successSize != nil })
        #expect(log.successSize == CGSize(width: 3, height: 2))
        if case .empty? = log.phases.first {} else { Issue.record("first phase: \(String(describing: log.phases.first))") }
        #expect(h.stub.requests().compactMap(\.url) == [Self.cover])
    }

    @Test func remoteImageShowsAFailureWithoutRetrying() async throws {
        let h = await ImageHarness.make(responder: ImageHarness.answering(StubResponse(status: 404)))
        let log = PhaseLog()

        let window = try Self.show(RemoteImage(url: Self.cover) { phase in
            let _ = log.record(phase)
            Color.clear
        }.environment(h.environment))
        defer { Self.hide(window) }
        #expect(await eventually {
            if case .failure? = log.phases.last { return true }
            return false
        })
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.stub.requests().count == 1)
    }

    /// A thumbnail shown while both sites are paused (a 429: 60 seconds) is refused before it goes out; that is not a
    /// failure but a wait (A-M2). Once the pause ends, the same view loads it, with no new view and no pull to refresh.
    @Test func aThumbnailRefusedDuringAPauseLoadsWhenItEnds() async throws {
        let clock = MovableClock()
        let h = await ImageHarness.make(
            breaker: SiteBreaker(now: { clock.now }), responder: ImageHarness.serving([Self.cover])
        )
        _ = try #require(await h.environment.breaker.record(.tooManyRequests, at: URL(string: "https://e-hentai.org/")!))
        #expect(await eventually { h.environment.sitePause != nil })
        let asked = clock.reads
        let log = PhaseLog()

        let window = try Self.show(RemoteImage(url: Self.cover) { phase in
            let _ = log.record(phase)
            Color.clear
        }.environment(h.environment))
        defer { Self.hide(window) }
        // The load has asked the breaker (every question reads its clock; nothing else asks it meanwhile) and was
        // refused: the clock does not move before that (M2 re-review F3 M-9c).
        #expect(await eventually { clock.reads > asked })
        #expect(h.stub.requests().isEmpty)
        #expect(!log.phases.isEmpty)
        // The refusal has had time to reach the view (a wait anchored on the attempt, not on the clock), before the
        // pause ends and a new load could hide it (M2 re-review F5 N-7).
        let failed = await eventually(within: .milliseconds(300)) {
            log.phases.contains { if case .failure = $0 { true } else { false } }
        }
        #expect(!failed, "The refusal showed as a failure")

        // The pause's end has come: the breaker clears it, and the thumbnail loads.
        clock.advance(by: 61)
        #expect(await h.environment.breaker.current() == nil)
        #expect(await eventually { log.successSize != nil })
        #expect(h.stub.requests().compactMap(\.url) == [Self.cover])
    }

    /// A thumbnail whose own answer began the pause (a 429 from the image host) loads once the pause ends, on the same
    /// view (M2 re-review F3 M-1). On the simulator the pause usually reaches the view first, and the key's change
    /// cancels the load before its error is looked at, so this passes without M-1 as well (measured): whether such an
    /// answer is a wait is pinned by `whatAFailedLoadWaitsFor`.
    @Test func aThumbnailWhoseAnswerBeganThePauseLoadsWhenItEnds() async throws {
        let clock = MovableClock()
        let calls = CallCounter()
        let png = ImageHarness.png()
        let cover = Self.cover
        let h = await ImageHarness.make(breaker: SiteBreaker(now: { clock.now })) { request in
            guard request.url == cover else { throw URLError(.badURL) }
            if calls.next() == 1 { return StubResponse(status: 429) }
            return StubResponse(headers: ["Content-Type": "image/png"], body: png)
        }
        let log = PhaseLog()

        let window = try Self.show(RemoteImage(url: Self.cover) { phase in
            let _ = log.record(phase)
            Color.clear
        }.environment(h.environment))
        defer { Self.hide(window) }
        #expect(await eventually { h.stub.requests().count == 1 })
        #expect(await eventually { h.environment.sitePause != nil })
        #expect(!log.phases.contains { if case .failure = $0 { true } else { false } }, "The 429 showed as a failure")

        clock.advance(by: 61)
        #expect(await h.environment.breaker.current() == nil)
        #expect(await eventually { log.successSize != nil })
        #expect(h.stub.requests().compactMap(\.url) == [Self.cover, Self.cover])
        #expect(!log.phases.contains { if case .failure = $0 { true } else { false } })
    }

    /// What a failed load waits for instead of showing a failure (A-M2, M2 re-review F3 M-1): a session boundary, a
    /// pause, and an answer that began the pause (a ban or a 429, `SiteBreaker.record(_:at:)`'s), from a guarded host
    /// only; anything else is a failure.
    @Test func whatAFailedLoadWaitsFor() {
        typealias Image = RemoteImage<EmptyView>
        let pause = SitePause(reason: .tooManyRequests, until: .distantFuture)
        let hath = URL(string: "https://abc.hath.network/h/fake-0002/fake-thumb-0002.jpg")!
        #expect(Image.waits(after: ImageLoadError.superseded, loading: Self.cover))
        #expect(Image.waits(after: EHNetworkError.paused(pause), loading: Self.cover))
        #expect(Image.waits(after: EHNetworkError.issue(.tooManyRequests), loading: Self.cover))
        #expect(Image.waits(after: EHNetworkError.issue(.banned(remaining: nil)), loading: Self.cover))
        #expect(!Image.waits(after: EHNetworkError.issue(.tooManyRequests), loading: hath))
        #expect(!Image.waits(after: EHNetworkError.issue(.bandwidthExceeded), loading: Self.cover))
        #expect(!Image.waits(after: ImageLoadError.status(404), loading: Self.cover))
        #expect(!Image.waits(after: URLError(.notConnectedToInternet), loading: Self.cover))
        #expect(!Image.waits(after: nil, loading: Self.cover))
        #expect(!Image.pausesBothSites(.exAccessDenied))
        #expect(!Image.pausesBothSites(.keyMismatch))
    }

    @Test func thumbnailsUseADiskCacheUnderCaches() async throws {
        let h = await ImageHarness.make(responder: ImageHarness.serving([]))
        let loader = try #require(h.images.configuration.dataLoader as? EHImageDataLoader)
        let name = "eros-tests-thumbnails-\(UUID().uuidString)"

        let pipeline = ImagePipelines.thumbnails(dataLoader: loader, diskCacheName: name)
        let cache = try #require(pipeline.configuration.dataCache as? DataCache)
        defer { try? FileManager.default.removeItem(at: cache.path) }
        let expected = URL.cachesDirectory.appending(path: name, directoryHint: .isDirectory)
        #expect(cache.path.resolvingSymlinksInPath().path() == expected.resolvingSymlinksInPath().path())
        #expect(cache.sizeLimit == 300 * 1024 * 1024)

        // UI testing (the hosted tests' environments too): no disk cache; avatars never have one.
        #expect(h.images.configuration.dataCache == nil)
        #expect(ImagePipelines.thumbnails(dataLoader: loader, diskCacheName: nil).configuration.dataCache == nil)
        #expect(h.environment.avatars.pipeline.configuration.dataCache == nil)
        // Each pipeline has a memory cache of its own, not Nuke's shared one.
        let thumbnails = try #require(h.images.configuration.imageCache as? ImageCache)
        let avatars = try #require(h.environment.avatars.pipeline.configuration.imageCache as? ImageCache)
        #expect(thumbnails !== ImageCache.shared)
        #expect(avatars !== ImageCache.shared)
        #expect(thumbnails !== avatars)
    }

    @Test func logOutClearsThumbnailsAndAvatars() async throws {
        let h = await Self.loadedHarness()
        let cache = try #require(h.images.configuration.dataCache as? DataCache)
        defer { try? FileManager.default.removeItem(at: cache.path) }

        try await h.environment.logOut()
        Self.expectCleared(h, disk: cache)
    }

    /// A login may change the account: what the earlier one loaded goes first (EX thumbnails need its cookies).
    @Test func aLoginStartClearsThumbnailsAndAvatars() async throws {
        let h = await Self.loadedHarness()
        let cache = try #require(h.images.configuration.dataCache as? DataCache)
        defer { try? FileManager.default.removeItem(at: cache.path) }

        try await h.environment.prepareLogin()
        Self.expectCleared(h, disk: cache)
    }

    /// A thumbnail whose request went out before a logout (or the start of a login) and whose answer comes back after
    /// it is dropped: neither cache keeps what the ended session's cookies fetched. Asked for again, it is kept.
    @Test(arguments: ImageHarness.SessionBoundary.allCases)
    func loadsAcrossASessionBoundaryAreDropped(_ boundary: ImageHarness.SessionBoundary) async throws {
        let gate = ResponderGate()
        let png = ImageHarness.png()
        let cover = Self.cover
        let h = await ImageHarness.make(thumbnailCacheName: "eros-tests-thumbnails-\(UUID().uuidString)") { request in
            guard request.url == cover else { throw URLError(.badURL) }
            gate.wait()
            return StubResponse(headers: ["Content-Type": "image/png"], body: png)
        }
        let cache = try #require(h.images.configuration.dataCache as? DataCache)
        defer { try? FileManager.default.removeItem(at: cache.path) }

        let load = h.images.imageTask(with: cover)
        // The request is out (the stub records it before it answers) and its answer is held.
        #expect(await eventually { h.stub.requests().count == 1 })
        try await boundary.cross(in: h.environment)
        gate.open()

        do {
            _ = try await load.image
            Issue.record("an image of the ended session loaded")
        } catch {
            #expect(error.dataLoadingError as? ImageLoadError == .superseded)
        }
        let request = ImageRequest(url: cover)
        #expect(!h.images.cache.containsCachedImage(for: request, caches: .memory))
        cache.flush()
        #expect(!cache.containsData(for: h.images.cache.makeDataCacheKey(for: request)))

        _ = try await h.images.image(for: cover)
        #expect(h.images.cache.containsCachedImage(for: request, caches: .memory))
        #expect(h.stub.requests().count == 2)
    }

    /// Between the start of a login (`prepareLogin()`, which empties the caches) and its end the earlier account's
    /// cookies are still in the jars, for as long as the web login's sheet (or the password login's WebView run) is
    /// open: a thumbnail asked for meanwhile goes out with them. Once the login has written the new account, what
    /// comes back for it is dropped as well (B1 transfer), and asked for again it loads under the new account.
    ///
    /// A login that throws is handled the same way: the account step can throw after it has written the new account
    /// (`AccountService`'s profile run rethrows a `CookieStoreError`), which a hosted test cannot bring about, so a
    /// rejected login stands in for that path here (the earlier account is put back and its thumbnail loads again).
    ///
    /// The stub answers on one loading thread, which the held thumbnail blocks: the login's profile run would wait
    /// behind it. Both sites are paused meanwhile, so that run's request is refused before it goes out and the login
    /// ends at once (the injected breaker's clock then ends the pause).
    @Test(arguments: [true, false])
    func loadsStartedDuringALoginAreDroppedOnceTheAccountChanges(signsIn: Bool) async throws {
        let gate = ResponderGate()
        let png = ImageHarness.png()
        let thumbnail = URL(string: "https://s.exhentai.org/t/00/00/fake-thumb-0003.jpg")!
        let calls = CallCounter()
        let stub = StubURLProtocol.install { request in
            guard request.url == thumbnail else { throw URLError(.badURL) }
            if calls.next() == 1 { gate.wait() }
            return StubResponse(headers: ["Content-Type": "image/png"], body: png)
        }
        defer { stub.remove() }
        let clock = MovableClock()
        let environment = AppEnvironment(
            uiTesting: true, sessionConfigurator: stub.configurator, userAgentProbe: { ImageHarness.userAgent },
            breaker: SiteBreaker(now: { clock.now }), thumbnailCacheName: "eros-tests-thumbnails-\(UUID().uuidString)"
        )
        await environment.start()
        let images = environment.images
        let cache = try #require(images.configuration.dataCache as? DataCache)
        defer { try? FileManager.default.removeItem(at: cache.path) }
        try await environment.cookies.set(
            ImageHarness.identity.merging(["igneous": "igneous-fake-0003"]) { $1 }, for: [.ex]
        )
        try await environment.prepareLogin()

        let load = images.imageTask(with: thumbnail)
        // The request is out with the earlier account's cookies and its answer is held.
        #expect(await eventually { stub.requests().count == 1 })
        #expect(stub.requests().first?.value(forHTTPHeaderField: "Cookie")?.contains("igneous=igneous-fake-0003") == true)
        _ = try #require(await environment.breaker.record(.tooManyRequests, at: URL(string: "https://e-hentai.org/")!))
        // Another account signs in through the web login, or the login is rejected (no identity in the WebView).
        if signsIn {
            let store = environment.bridge.dataStore.httpCookieStore
            await store.setCookie(fakeCookie(CookieNames.memberID, "7654321"))
            await store.setCookie(fakeCookie(CookieNames.passHash, "fedcba9876543210fedcba9876543210"))
            try await environment.completeWebLogin(from: WKWebView())
        } else {
            await #expect(throws: LoginError.rejected) { try await environment.completeWebLogin(from: WKWebView()) }
        }
        #expect(environment.isLoggedIn == signsIn)
        #expect(stub.requests().count == 1)
        gate.open()

        do {
            _ = try await load.image
            Issue.record("an image of the earlier account loaded after the account changed")
        } catch {
            #expect(error.dataLoadingError as? ImageLoadError == .superseded)
        }
        let request = ImageRequest(url: thumbnail)
        #expect(!images.cache.containsCachedImage(for: request, caches: .memory))
        cache.flush()
        #expect(!cache.containsData(for: images.cache.makeDataCacheKey(for: request)))

        clock.advance(by: 61)
        _ = try await images.image(for: thumbnail)
        #expect(images.cache.containsCachedImage(for: request, caches: .memory))
        #expect(stub.requests().count == 2)
        let again = stub.requests().last?.value(forHTTPHeaderField: "Cookie") ?? ""
        if signsIn {
            #expect(again.contains("\(CookieNames.memberID)=7654321"))
            #expect(!again.contains("igneous-fake-0003"))
        } else {
            #expect(again.contains("igneous=igneous-fake-0003"))
        }
    }

    // MARK: - Helpers

    /// An environment with a thumbnail disk cache, the cover and the avatar loaded and kept.
    private static func loadedHarness() async -> ImageHarness.Harness {
        let h = await ImageHarness.make(
            thumbnailCacheName: "eros-tests-thumbnails-\(UUID().uuidString)",
            responder: ImageHarness.serving([cover, avatar])
        )
        let request = ImageRequest(url: cover)
        _ = try? await h.images.image(for: request)
        #expect(await h.environment.avatars.image(for: avatar) != nil)
        #expect(h.images.cache.containsCachedImage(for: request, caches: .memory))
        #expect(h.images.cache.containsData(for: request))
        #expect(h.environment.avatars.pipeline.cache.containsCachedImage(for: ImageRequest(url: avatar), caches: .memory))
        return h
    }

    private static func expectCleared(_ h: ImageHarness.Harness, disk cache: DataCache) {
        let request = ImageRequest(url: cover)
        #expect(!h.images.cache.containsCachedImage(for: request, caches: .memory))
        #expect(!h.images.cache.containsData(for: request))
        cache.flush()
        #expect(!cache.containsData(for: h.images.cache.makeDataCacheKey(for: request)))
        #expect(!h.environment.avatars.pipeline.cache.containsCachedImage(for: ImageRequest(url: avatar), caches: .memory))
        #expect(!h.environment.avatars.hasImage(for: avatar))
    }

    /// `view` in a window of its own on the host app's scene, so its tasks run as on screen.
    private static func show(_ view: some View) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        return window
    }

    private static func hide(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// A clock for a breaker that the test moves by hand; starts at 1_800_000_000. It counts how often it was read: the
/// breaker reads it for every question (`pause(for:)`, `current()`).
private final class MovableClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    private let readCount = Mutex(0)

    var now: Date {
        readCount.withLock { $0 += 1 }
        return date.withLock { $0 }
    }

    /// How often `now` was read.
    var reads: Int { readCount.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}
