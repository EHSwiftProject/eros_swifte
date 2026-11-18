import EHParsing
import Foundation

/// Why both sites are paused.
public enum PauseReason: Sendable, Equatable { case banned, tooManyRequests }

/// A pause of every request to both sites (`SiteBreaker.isGuarded(host:)`) until `until`.
public struct SitePause: Sendable, Equatable {
    public let reason: PauseReason
    public let until: Date

    public init(reason: PauseReason, until: Date) {
        self.reason = reason
        self.until = until
    }
}

/// The app's site-wide circuit breaker (user decision 2026-11-08): an IP ban stops every request to E-Hentai and
/// ExHentai (API and thumbnails included) until the end the ban notice gives, or for an hour when it gives none; a 429
/// stops them for 60 seconds. Both resume by themselves. A 509 is the image quota's (M4) and stops nothing; H@H nodes
/// (`*.hath.network`) are never paused.
///
/// `EHClient` (and the password login) report the notices they meet with `record(_:at:)`; `BreakerThrottle` refuses
/// what would go out during a pause. The time comes from `now`; a pause's end is announced on `updates()` by a timer
/// on real time.
public actor SiteBreaker {
    /// The ban's length when its notice gives none.
    static let defaultBanLength: TimeInterval = 3_600
    /// A 429's pause.
    static let tooManyRequestsLength: TimeInterval = 60

    /// Both sites' hosts and those of their images; each counts with its subdomains.
    private static let guardedDomains = ["e-hentai.org", "exhentai.org", "ehgt.org"]

    private let now: @Sendable () -> Date
    /// The pause as last set; it may have ended (see `current()`).
    private var pause: SitePause?
    private var subscribers: [Int: AsyncStream<SitePause?>.Continuation] = [:]
    private var nextSubscriber = 0
    /// Announces the end of `pause` on `updates()`; rescheduled whenever `pause` changes.
    private var expiry: Task<Void, Never>?

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    deinit {
        expiry?.cancel()
        for continuation in subscribers.values { continuation.finish() }
    }

    /// Whether requests to `host` stop during a pause: `e-hentai.org`, `exhentai.org`, `ehgt.org` and their subdomains,
    /// compared after `RateLimitPolicy.normalizedHost(_:)`. `*.hath.network` and every other host are not.
    public static func isGuarded(host: String) -> Bool {
        let host = RateLimitPolicy.normalizedHost(host)
        return guardedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The pause in force for a request to `url`: `current()` for a guarded host, nil for any other.
    public func pause(for url: URL) -> SitePause? {
        guard Self.isGuarded(url) else { return nil }
        return current()
    }

    /// Records a site notice met at `url` (the response's URL) and returns the pause now in force, or nil when the
    /// notice pauses nothing.
    ///
    /// `.banned(remaining)` pauses until now + `remaining` (an hour when nil), `.tooManyRequests` until now + 60
    /// seconds; any other notice, and any notice from a host that is not guarded, changes nothing (nil). A pause that
    /// has not ended yet is merged: the later end wins, and a ban on either side makes the reason `.banned`. One that
    /// has ended is replaced: `updates()` gets the new pause, without the end in between.
    public func record(_ issue: ResponseIssue, at url: URL) -> SitePause? {
        guard Self.isGuarded(url) else { return nil }
        let start = now()
        let incoming: SitePause
        switch issue {
        case .banned(let remaining):
            let length = remaining.map(Self.seconds(of:)) ?? Self.defaultBanLength
            incoming = SitePause(reason: .banned, until: start.addingTimeInterval(length))
        case .tooManyRequests:
            incoming = SitePause(reason: .tooManyRequests, until: start.addingTimeInterval(Self.tooManyRequestsLength))
        case .bandwidthExceeded, .exAccessDenied, .keyMismatch:
            return nil
        }
        // The pause in force, read without clearing one that has ended: replacing it announces the new pause only,
        // never the end in between (a banner would flicker).
        let active = pause.flatMap { start < $0.until ? $0 : nil }
        let merged = active.map { Self.merge($0, incoming) } ?? incoming
        if merged != pause { set(merged) }
        return merged
    }

    /// The pause in force: nil once its end has come (`now() < until` no longer holds), which also clears it.
    public func current() -> SitePause? {
        guard let pause else { return nil }
        if now() < pause.until { return pause }
        set(nil)
        return nil
    }

    /// The pause in force at once, then every change: a pause beginning or extended, and nil when it ends. The stream
    /// lasts until its subscriber stops listening (or the breaker goes away).
    public func updates() -> AsyncStream<SitePause?> {
        let value = current()
        let (stream, continuation) = AsyncStream.makeStream(of: SitePause?.self)
        let id = nextSubscriber
        nextSubscriber += 1
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        continuation.yield(value)
        return stream
    }

    /// How many `updates()` streams are still open (tests).
    var subscriberCount: Int { subscribers.count }

    // MARK: - Private

    /// Whether `url`'s host is guarded; a URL without a host is not.
    private static func isGuarded(_ url: URL) -> Bool {
        guard let host = url.host() else { return false }
        return isGuarded(host: host)
    }

    private static func merge(_ old: SitePause, _ new: SitePause) -> SitePause {
        let reason: PauseReason = old.reason == .banned || new.reason == .banned ? .banned : .tooManyRequests
        return SitePause(reason: reason, until: max(old.until, new.until))
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    /// Makes `value` the pause, tells every subscriber and schedules the announcement of its end.
    private func set(_ value: SitePause?) {
        pause = value
        for continuation in subscribers.values { continuation.yield(value) }
        scheduleExpiry()
    }

    /// Sleeps (real time) until the pause's end by `now`, then lets `current()` clear it; a pause still in force by
    /// then (the clock moved back, or it was extended meanwhile) is waited for again.
    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = nil
        guard let pause else { return }
        let delay = max(0, pause.until.timeIntervalSince(now()))
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.expire()
        }
    }

    private func expire() {
        if current() != nil { scheduleExpiry() }
    }

    private func unsubscribe(_ id: Int) {
        subscribers[id] = nil
    }
}

/// The throttle every request of the app waits for (`AppEnvironment.throttle`): `base` (the rate limiter), behind the
/// breaker. A request to a guarded host (`SiteBreaker.isGuarded(host:)`) is refused with `EHNetworkError.paused` when a
/// pause is in force before it waits for `base`, and again after: a pause that began while it waited in the queue
/// (scrolling a list queues many thumbnails and the next page) stops it as well. Other hosts only wait for `base`.
public struct BreakerThrottle: RequestThrottle {
    private let base: any RequestThrottle
    private let breaker: SiteBreaker

    public init(base: any RequestThrottle, breaker: SiteBreaker) {
        self.base = base
        self.breaker = breaker
    }

    public func acquire(for url: URL) async throws {
        guard let host = url.host(), SiteBreaker.isGuarded(host: host) else {
            try await base.acquire(for: url)
            return
        }
        if let pause = await breaker.pause(for: url) { throw EHNetworkError.paused(pause) }
        try await base.acquire(for: url)
        if let pause = await breaker.pause(for: url) { throw EHNetworkError.paused(pause) }
    }
}
