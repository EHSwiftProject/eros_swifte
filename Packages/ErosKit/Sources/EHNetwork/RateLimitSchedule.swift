/// A booked slot: a request to `host` (normalized) may start at `start`, an offset from the limiter's origin.
public struct RateLimitReservation: Sendable, Equatable {
    public let host: String
    public let start: Duration

    public init(host: String, start: Duration) {
        self.host = host
        self.start = start
    }
}

/// Deterministic token bucket scheduler. Time is an offset from the owner's origin, so it needs no clock.
public struct RateLimitSchedule: Sendable {
    private struct BucketState {
        var tokens: Int
        var refilledAt: Duration
        var lastStart: Duration
    }

    /// What `cancel(_:)` needs to put the bucket and the host interval back to before `reservation`.
    private struct Undo {
        let reservation: RateLimitReservation
        /// nil when the reservation created the bucket.
        let previousState: BucketState?
        let previousNextAllowed: Duration?
    }

    private struct Bucket {
        let rule: TokenBucketRule
        var state: BucketState
        /// The bucket's most recent reservation; nil once it has been cancelled.
        var latest: Undo?
    }

    private let policy: RateLimitPolicy
    private var buckets: [String: Bucket] = [:]
    /// Per normalized host: the earliest offset at which its next request may start.
    private var nextAllowed: [String: Duration] = [:]

    public init(policy: RateLimitPolicy) {
        self.policy = policy
    }

    /// Books a slot for `host` and returns when the request may start.
    /// `now` and the returned start time are offsets from the limiter's origin.
    public mutating func reserve(host: String, at now: Duration) -> Duration {
        reserveUndoable(host: host, at: now).start
    }

    /// Like `reserve(host:at:)`, but returns a reservation that `cancel(_:)` can take back
    /// while it is still the latest one of its bucket.
    public mutating func reserveUndoable(host: String, at now: Duration) -> RateLimitReservation {
        let h = RateLimitPolicy.normalizedHost(host)
        let assignment = policy.bucket(forNormalizedHost: h)
        let key = assignment.key, rule = assignment.rule
        let previous = buckets[key]
        let previousNextAllowed = nextAllowed[h]
        var t = max(now, previousNextAllowed ?? .zero, previous?.state.lastStart ?? .zero)
        // A new bucket starts full; its refill clock runs from first use.
        var b = previous?.state ?? BucketState(tokens: rule.capacity, refilledAt: t, lastStart: t)
        Self.refill(&b, rule: rule, to: t)
        if b.tokens == 0 {
            t = b.refilledAt + rule.refillInterval
            Self.refill(&b, rule: rule, to: t)
        }
        b.tokens -= 1
        b.lastStart = t
        let reservation = RateLimitReservation(host: h, start: t)
        let undo = Undo(reservation: reservation, previousState: previous?.state, previousNextAllowed: previousNextAllowed)
        buckets[key] = Bucket(rule: rule, state: b, latest: undo)
        nextAllowed[h] = t + policy.minimumHostInterval
        return reservation
    }

    /// Rolls the bucket and the host interval back to before `reservation` when it is still the latest one of its bucket.
    ///
    /// Returns false, changing nothing, once a later reservation of the same bucket exists, once the reservation
    /// has been cancelled, or once `pruneIdle(at:)` dropped its bucket. Only one step is kept: after a cancel,
    /// earlier reservations of that bucket cannot be cancelled.
    ///
    /// `reservation.host` is taken as it is (the normalized host `reserveUndoable` recorded), never normalized again.
    public mutating func cancel(_ reservation: RateLimitReservation) -> Bool {
        let h = reservation.host
        let key = policy.bucket(forNormalizedHost: h).key
        guard let bucket = buckets[key], let undo = bucket.latest,
              undo.reservation.host == h, undo.reservation.start == reservation.start else {
            return false
        }
        // Every reservation of `h` goes through this bucket, so no other reservation has moved its host interval
        // since. If `pruneIdle` dropped that interval, the restored value is no later than `reservation.start`,
        // which had already passed, so restoring it changes nothing.
        if let state = undo.previousState {
            buckets[key] = Bucket(rule: bucket.rule, state: state, latest: nil)
        } else {
            buckets[key] = nil
        }
        nextAllowed[h] = undo.previousNextAllowed
        return true
    }

    /// Drops buckets that would be full again by `now` and host intervals that have passed.
    ///
    /// A dropped host interval changes nothing later. A dropped bucket comes back full on its next use with its
    /// refill clock restarted there, which can only delay later refills, never bring them forward. A bucket
    /// whose latest reservation starts after `now` is never full, so a pending reservation stays cancellable.
    public mutating func pruneIdle(at now: Duration) {
        buckets = buckets.filter { _, bucket in
            var state = bucket.state
            Self.refill(&state, rule: bucket.rule, to: now)
            return state.tokens < bucket.rule.capacity
        }
        nextAllowed = nextAllowed.filter { _, allowed in allowed > now }
    }

    /// Buckets plus host intervals currently held; `pruneIdle(at:)` keeps it bounded.
    public var trackedEntryCount: Int {
        buckets.count + nextAllowed.count
    }

    private static func refill(_ b: inout BucketState, rule: TokenBucketRule, to t: Duration) {
        let n = Int(((t - b.refilledAt) / rule.refillInterval).rounded(.down))
        guard n > 0 else { return }
        b.tokens = min(rule.capacity, b.tokens + n)
        b.refilledAt += rule.refillInterval * n
    }
}
