import EHNetwork
import Foundation
import Testing

/// Timing checks use a wide margin instead of a tolerance around the expected time: every wrong outcome these
/// tests guard against lands at least one `slot` (2 s) away from the right one. Lateness only ever delays a start
/// (the schedule never lets a request start early), so the checks lean late: a start counts for slot n from a
/// quarter of a slot before n slots to three quarters of a slot (`allowedLateness`, 1.5 s) after. So a correct
/// limiter fails only when a start is 1.5 s late; a start one slot early is caught unless it is itself that late;
/// a start one slot late is caught whatever the load. (In the full test run, where the other suites keep the
/// threads busy, every timed start here was once 0.6 s late: past the half slot of room that 1 s slots and checks
/// at the midpoint left.) The suite takes about 6 s.
struct RateLimiterTests {
    /// One token per slot and no per-host gap, so the n-th request of the bucket starts n slots after the first.
    private static let slot = Duration.seconds(2)
    /// How late a start may be before a check fails: three quarters of a slot.
    private static let allowedLateness = slot * 0.75
    private static let oneToken = RateLimitPolicy(
        minimumHostInterval: .zero,
        groups: [],
        defaultRule: TokenBucketRule(capacity: 1, refillInterval: slot)
    )
    /// When queued requests are cancelled: late enough that they are usually queued, and far ahead of slot 1.
    private static let cancelAt = Duration.milliseconds(100)

    /// Expects `offset` in slot `n`: from a quarter of a slot before n slots to `allowedLateness` after.
    private func expectInSlot(_ offset: Duration, _ n: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        let low = Self.slot * (Double(n) - 0.25), high = Self.slot * Double(n) + Self.allowedLateness
        #expect(
            offset > low && offset < high,
            "\(offset) is not in slot \(n) (\(low) ..< \(high))",
            sourceLocation: sourceLocation
        )
    }

    /// Expects a cancelled request to end before `allowedLateness`, three quarters of a slot: it is cancelled about
    /// `cancelAt` after the origin, and would end at slot 1 or later if cancelling did not wake it (as the sleeping
    /// head, or when promoted behind the head).
    private func expectEndsOnCancel(
        _ offset: Duration, cancelledAt: Duration, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let limit = Self.allowedLateness
        #expect(
            offset < limit,
            "ended at \(offset); cancelled at \(cancelledAt), so it should end before \(limit)",
            sourceLocation: sourceLocation
        )
    }

    /// Runs `acquire` and reports when it returned or threw, as an offset from `origin`.
    private static func timedAcquire(
        _ limiter: RateLimiter, _ host: String, from origin: ContinuousClock.Instant
    ) async -> (offset: Duration, error: (any Error)?) {
        do {
            try await limiter.acquire(host: host)
            return (ContinuousClock.now - origin, nil)
        } catch {
            return (ContinuousClock.now - origin, error)
        }
    }

    /// Unchanged from M0. Not load sensitive: 400 ms is a hard floor (load only delays the third start, which is
    /// due 400 ms after the first), and the 2 s ceiling leaves 1.6 s for lateness.
    @Test func acquireSpacesSameHostRequests() async throws {
        let limiter = RateLimiter()
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            for _ in 0..<3 { try await limiter.acquire(host: "e-hentai.org") }
        }
        #expect(elapsed >= .milliseconds(400))
        #expect(elapsed < .seconds(2))
    }

    /// Four requests at once start in slots 0, 1, 2 and 3. Wrong outcomes: no spacing (all in slot 0) or a lost
    /// or doubled slot (a request one slot off).
    @Test(.timeLimit(.minutes(1)))
    func concurrentAcquiresAreSpacedByTheBucket() async throws {
        let limiter = RateLimiter(policy: Self.oneToken)
        let origin = ContinuousClock.now
        let offsets = try await withThrowingTaskGroup(of: Duration.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await limiter.acquire(host: "a.test")
                    return ContinuousClock.now - origin
                }
            }
            return try await group.reduce(into: [Duration]()) { $0.append($1) }.sorted()
        }
        try #require(offsets.count == 4)
        for (n, offset) in offsets.enumerated() {
            expectInSlot(offset, n)
        }
    }

    /// A starts at once; B and C queue; B is cancelled. B and C may reach the limiter in either order: either way
    /// B ends on the cancel and C keeps slot 1. Wrong outcome: B keeps its slot, so C starts in slot 2.
    @Test(.timeLimit(.minutes(1)))
    func cancelledWaiterFreesItsSlot() async throws {
        let limiter = RateLimiter(policy: Self.oneToken)
        let origin = ContinuousClock.now
        try await limiter.acquire(host: "a.test")
        expectInSlot(ContinuousClock.now - origin, 0)

        let b = Task { await Self.timedAcquire(limiter, "a.test", from: origin) }
        let c = Task { await Self.timedAcquire(limiter, "a.test", from: origin) }
        try await Task.sleep(until: origin + Self.cancelAt, clock: .continuous)
        let cancelledAt = ContinuousClock.now - origin
        b.cancel()

        let (bOffset, bError) = await b.value
        #expect(bError is CancellationError)
        expectEndsOnCancel(bOffset, cancelledAt: cancelledAt)
        let (cOffset, cError) = await c.value
        #expect(cError == nil)
        expectInSlot(cOffset, 1)
    }

    /// Wrong outcome: the cancelled request is charged a slot, so the next one starts at about one slot (2 s), 0.5 s
    /// past the top of slot 0's window (`allowedLateness`, 1.5 s).
    @Test(.timeLimit(.minutes(1)))
    func cancelledBeforeAcquireCostsNothing() async throws {
        let limiter = RateLimiter(policy: Self.oneToken)
        let cancelled = Task { () async -> (offset: Duration, error: (any Error)?) in
            withUnsafeCurrentTask { $0?.cancel() }
            return await Self.timedAcquire(limiter, "a.test", from: ContinuousClock.now)
        }
        let (offset, error) = await cancelled.value
        #expect(error is CancellationError)
        expectInSlot(offset, 0)

        let next = try await ContinuousClock().measure { try await limiter.acquire(host: "a.test") }
        expectInSlot(next, 0)
    }

    // Beyond the task brief: of three queued requests at most one is the head, so cancelling two of them
    // always removes at least one plain queued waiter. Both end on the cancel, the survivor keeps slot 1 and the
    // next request gets slot 2. Wrong outcomes: a cancelled request stays queued until slot 1, or keeps a slot
    // and pushes the survivor to slot 2 or 3 and the next request to slot 3 or 4.
    @Test(.timeLimit(.minutes(1)))
    func cancelledQueuedWaitersLeaveTheQueue() async throws {
        let limiter = RateLimiter(policy: Self.oneToken)
        let origin = ContinuousClock.now
        try await limiter.acquire(host: "a.test")

        let waiters = (0..<3).map { _ in Task { await Self.timedAcquire(limiter, "a.test", from: origin) } }
        try await Task.sleep(until: origin + Self.cancelAt, clock: .continuous)
        let cancelledAt = ContinuousClock.now - origin
        waiters[1].cancel()
        waiters[2].cancel()

        for waiter in waiters.dropFirst() {
            let (offset, error) = await waiter.value
            #expect(error is CancellationError)
            expectEndsOnCancel(offset, cancelledAt: cancelledAt)
        }
        let (survivorOffset, survivorError) = await waiters[0].value
        #expect(survivorError == nil)
        expectInSlot(survivorOffset, 1)

        try await limiter.acquire(host: "a.test")
        expectInSlot(ContinuousClock.now - origin, 2)
    }

    /// Trailing dots name the same host: one queue, one bucket and one host interval, so the second request waits
    /// for slot 1. Wrong outcome: "e-hentai.org..." waited in one queue, booked another
    /// bucket and kept its host interval for "e-hentai.org.", so the plain host started in slot 0.
    @Test(.timeLimit(.minutes(1)))
    func trailingDotsShareTheHostInterval() async throws {
        let rule = TokenBucketRule(capacity: 10, refillInterval: Self.slot)
        let policy = RateLimitPolicy(
            minimumHostInterval: Self.slot,
            groups: [HostGroup(key: "group:e-hentai.org", domain: "e-hentai.org", match: .domainAndSubdomains, rule: rule)],
            defaultRule: rule
        )
        let limiter = RateLimiter(policy: policy)
        let origin = ContinuousClock.now
        try await limiter.acquire(host: "e-hentai.org...")
        try await limiter.acquire(host: "e-hentai.org")
        expectInSlot(ContinuousClock.now - origin, 1)
    }

    /// Both URLs share one bucket, so the second request waits for slot 1. Wrong outcome: the port splits the
    /// bucket and the second request starts in slot 0.
    @Test(.timeLimit(.minutes(1)))
    func acquireForURLIgnoresThePort() async throws {
        let limiter = RateLimiter(policy: Self.oneToken)
        let withPort = try #require(URL(string: "https://x.y.hath.network:8443/a"))
        let withoutPort = try #require(URL(string: "https://x.y.hath.network/b"))
        let origin = ContinuousClock.now
        try await limiter.acquire(for: withPort)
        try await limiter.acquire(for: withoutPort)
        expectInSlot(ContinuousClock.now - origin, 1)
    }
}
