import EHNetwork
import EHNetworkTesting
import EHParsing
import Foundation
import Synchronization
import Testing

/// The breaker's clock is a `ManualClock` that starts at `start` (T) unless a test says otherwise. Nothing here sends a
/// request: `BreakerThrottle` runs over `RecordingThrottle` or a gate of this file.
@Suite struct SiteBreakerTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let ehHome = URL(string: "https://e-hentai.org/")!
    private static let exHome = URL(string: "https://exhentai.org/")!
    private static let ehThumbnail = URL(string: "https://ehgt.org/t/01/23/0123456789abcdef-1000-1400-jpg_l.jpg")!
    private static let exThumbnail = URL(string: "https://s.exhentai.org/t/01/23/0123456789abcdef-1000-1400-jpg_l.jpg")!
    private static let hathImage = URL(string: "https://abc.hath.network/h/fake")!
    private static let otherSite = URL(string: "https://api.github.com/fake")!

    /// A clock the test moves by hand.
    private final class ManualClock: Sendable {
        private let date = Mutex(SiteBreakerTests.start)

        var now: Date { date.withLock { $0 } }

        /// Sets the time to `seconds` after T.
        func set(secondsAfterStart seconds: TimeInterval) {
            date.withLock { $0 = SiteBreakerTests.start.addingTimeInterval(seconds) }
        }
    }

    private static func makeBreaker() -> (SiteBreaker, ManualClock) {
        let clock = ManualClock()
        return (SiteBreaker(now: { clock.now }), clock)
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    // MARK: - Hosts

    @Test(arguments: [
        ("e-hentai.org", true), ("forums.e-hentai.org", true), ("upld.e-hentai.org", true), ("exhentai.org", true),
        ("s.exhentai.org", true), ("ehgt.org", true), ("gt1.ehgt.org", true), ("E-HENTAI.ORG.", true),
        ("abc.hath.network", false), ("ab.cd.hath.network", false), ("e-hentai.org.example.com", false),
        ("notexhentai.org", false), ("api.github.com", false),
    ])
    func guardedHosts(host: String, guarded: Bool) {
        #expect(SiteBreaker.isGuarded(host: host) == guarded)
    }

    // MARK: - Recording

    @Test func banLastsAsLongAsThePageSays() async {
        let (breaker, _) = Self.makeBreaker()
        let pause = await breaker.record(.banned(remaining: .seconds(7_260)), at: Self.ehHome)
        let expected = SitePause(reason: .banned, until: Self.at(7_260))
        #expect(pause == expected)
        #expect(await breaker.current() == expected)
    }

    @Test func banWithoutATimeLastsAnHour() async {
        let (breaker, _) = Self.makeBreaker()
        let pause = await breaker.record(.banned(remaining: nil), at: Self.ehHome)
        #expect(pause == SitePause(reason: .banned, until: Self.at(3_600)))
    }

    @Test func tooManyRequestsLastsSixtySeconds() async {
        let (breaker, _) = Self.makeBreaker()
        let pause = await breaker.record(.tooManyRequests, at: Self.ehHome)
        #expect(pause == SitePause(reason: .tooManyRequests, until: Self.at(60)))
    }

    /// 509 belongs to the image quota (M4); the other notices are about one account or one key.
    @Test func otherIssuesDoNotPause() async {
        let (breaker, _) = Self.makeBreaker()
        for issue in [ResponseIssue.bandwidthExceeded, .exAccessDenied, .keyMismatch] {
            #expect(await breaker.record(issue, at: Self.ehHome) == nil, Comment(rawValue: "\(issue)"))
            #expect(await breaker.record(issue, at: Self.exHome) == nil, Comment(rawValue: "\(issue)"))
        }
        #expect(await breaker.current() == nil)
    }

    @Test func unguardedHostsDoNotPause() async {
        let (breaker, _) = Self.makeBreaker()
        #expect(await breaker.record(.tooManyRequests, at: Self.hathImage) == nil)
        #expect(await breaker.record(.banned(remaining: nil), at: Self.otherSite) == nil)
        #expect(await breaker.current() == nil)
    }

    @Test func aPauseCoversBothSites() async throws {
        let (breaker, _) = Self.makeBreaker()
        let pause = try #require(await breaker.record(.tooManyRequests, at: Self.ehHome))
        for url in [Self.ehHome, Self.exHome, Self.ehThumbnail, Self.exThumbnail] {
            #expect(await breaker.pause(for: url) == pause, Comment(rawValue: url.absoluteString))
        }
        for url in [Self.hathImage, Self.otherSite] {
            #expect(await breaker.pause(for: url) == nil, Comment(rawValue: url.absoluteString))
        }
    }

    @Test func pauseEndsAtItsTime() async throws {
        let (breaker, clock) = Self.makeBreaker()
        let pause = try #require(await breaker.record(.tooManyRequests, at: Self.ehHome))
        clock.set(secondsAfterStart: 59)
        #expect(await breaker.current() == pause)
        #expect(await breaker.pause(for: Self.exHome) == pause)
        clock.set(secondsAfterStart: 60)
        #expect(await breaker.current() == nil)
        #expect(await breaker.pause(for: Self.exHome) == nil)
    }

    @Test func laterPausesExtendAndBanWins() async {
        let (breaker, clock) = Self.makeBreaker()
        let first = SitePause(reason: .tooManyRequests, until: Self.at(60))
        #expect(await breaker.record(.tooManyRequests, at: Self.ehHome) == first)
        clock.set(secondsAfterStart: 10)
        // A shorter ban: the end stays, the reason becomes the ban.
        let banned = SitePause(reason: .banned, until: Self.at(60))
        #expect(await breaker.record(.banned(remaining: .seconds(30)), at: Self.exHome) == banned)
        #expect(await breaker.current() == banned)
        clock.set(secondsAfterStart: 20)
        // A later 429 pushes the end on; the ban stays the reason.
        let extended = SitePause(reason: .banned, until: Self.at(80))
        #expect(await breaker.record(.tooManyRequests, at: Self.ehHome) == extended)
        #expect(await breaker.current() == extended)
    }

    /// Real time: a subscriber gets the state at once, then the start and, once its time has passed, the end.
    @Test func updatesReportStartAndEnd() async throws {
        let breaker = SiteBreaker()
        let updates = await breaker.updates()
        let collector = Task { () -> [SitePause?] in
            var values: [SitePause?] = []
            for await value in updates {
                values.append(value)
                if values.count == 3 { break }
            }
            return values
        }
        let pause = try #require(await breaker.record(.banned(remaining: .milliseconds(300)), at: Self.ehHome))
        let timeout = Task {
            try await Task.sleep(for: .seconds(2))
            collector.cancel()
        }
        let values = await collector.value
        timeout.cancel()
        #expect(values == [nil, pause, nil])
        #expect(await breaker.current() == nil)
    }

    /// A pause recorded once the last one has ended, before anything cleared it (no one asked, the end's timer had not
    /// fired), is announced as it is: subscribers never see the end in between, so a banner does not flicker.
    @Test func replacingAnEndedPauseSkipsTheEnd() async throws {
        let (breaker, clock) = Self.makeBreaker()
        let updates = await breaker.updates()
        let first = try #require(await breaker.record(.tooManyRequests, at: Self.ehHome))
        clock.set(secondsAfterStart: 61)
        let second = try #require(await breaker.record(.tooManyRequests, at: Self.exHome))
        #expect(second == SitePause(reason: .tooManyRequests, until: Self.at(121)))
        let collector = Task { () -> [SitePause?] in
            var values: [SitePause?] = []
            for await value in updates {
                values.append(value)
                if values.count == 3 { break }
            }
            return values
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(2))
            collector.cancel()
        }
        let values = await collector.value
        timeout.cancel()
        #expect(values == [nil, first, second])
        #expect(await breaker.current() == second)
    }

    // MARK: - BreakerThrottle

    @Test func pausedGuardedRequestIsRefusedAtOnce() async throws {
        let (breaker, _) = Self.makeBreaker()
        let base = RecordingThrottle()
        let throttle = BreakerThrottle(base: base, breaker: breaker)
        let pause = try #require(await breaker.record(.tooManyRequests, at: Self.ehHome))
        for url in [Self.ehHome, Self.exHome, Self.ehThumbnail] {
            await #expect(throws: EHNetworkError.paused(pause), Comment(rawValue: url.absoluteString)) {
                try await throttle.acquire(for: url)
            }
        }
        #expect(await base.acquiredURLs.isEmpty)
    }

    @Test func unguardedHostsPassDuringAPause() async throws {
        let (breaker, _) = Self.makeBreaker()
        let base = RecordingThrottle()
        let throttle = BreakerThrottle(base: base, breaker: breaker)
        _ = try #require(await breaker.record(.tooManyRequests, at: Self.ehHome))
        try await throttle.acquire(for: Self.hathImage)
        try await throttle.acquire(for: Self.otherSite)
        #expect(await base.acquiredURLs == [Self.hathImage, Self.otherSite])
    }

    /// A request already waiting in the rate limiter when the pause begins does not go out once its turn comes.
    @Test func pauseThatBeginsDuringTheWaitRefuses() async throws {
        let (breaker, _) = Self.makeBreaker()
        let gate = HoldingThrottle()
        let throttle = BreakerThrottle(base: gate, breaker: breaker)
        let waiting = Task { try await throttle.acquire(for: Self.exHome) }
        await gate.waitUntilHolding(1)
        let pause = try #require(await breaker.record(.tooManyRequests, at: Self.ehHome))
        await gate.open()
        await #expect(throws: EHNetworkError.paused(pause)) { try await waiting.value }
        #expect(await gate.acquiredURLs == [Self.exHome])
    }
}

/// Holds every request until `open()`, then lets them and every later one through at once; records every URL.
private actor HoldingThrottle: RequestThrottle {
    private(set) var acquiredURLs: [URL] = []
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func acquire(for url: URL) async throws {
        acquiredURLs.append(url)
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

    func open() {
        isOpen = true
        let released = held
        held = []
        released.forEach { $0.resume() }
    }
}
