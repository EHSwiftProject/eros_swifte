import Foundation

/// Throttles requests per host using a `RateLimitSchedule`.
///
/// Requests of one bucket wait in a FIFO queue. Only the head of a queue holds a reservation, so when a
/// waiting request is cancelled its slot goes back to the bucket: a queued waiter never booked one, and the
/// head's reservation is the latest of its bucket, which `RateLimitSchedule.cancel(_:)` rolls back. (Pruning
/// keeps that reservation while its start is ahead; it can drop it only once the bucket is full again.)
public actor RateLimiter {
    /// Queues of the buckets that have requests in flight; a bucket leaves this map when its queue empties.
    private struct BucketQueue {
        /// The request that holds (or is about to book) the bucket's reservation.
        var headID: UInt64
        /// Requests behind the head, each suspended on its continuation.
        var waiting: [Waiter]
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// `trackedEntryCount` above which idle schedule entries are pruned after a reservation.
    private static let pruneThreshold = 256

    private var schedule: RateLimitSchedule
    private let policy: RateLimitPolicy
    private let origin = ContinuousClock.now
    private var queues: [String: BucketQueue] = [:]
    private var nextID: UInt64 = 0

    public init(policy: RateLimitPolicy = .flutterParity) {
        self.policy = policy
        schedule = RateLimitSchedule(policy: policy)
    }

    /// Suspends until a request to `host` may start; throws `CancellationError` if the task is cancelled first.
    ///
    /// A request cancelled while waiting gives its slot back. The longest wait is therefore set by the
    /// uncancelled requests ahead of it in the same bucket: roughly their count × the bucket's refill interval
    /// once its tokens run out, plus up to `minimumHostInterval` (200 ms) for the same host.
    public func acquire(host: String) async throws {
        try Task.checkCancellation()
        let host = RateLimitPolicy.normalizedHost(host)
        // The schedule's bucket for this host: the queue a request waits in and the bucket it books never part.
        let key = policy.bucket(forNormalizedHost: host).key
        let id = nextID
        nextID &+= 1

        if queues[key] == nil {
            queues[key] = BucketQueue(headID: id, waiting: [])
        } else {
            // Throws only when cancelled while still queued; that waiter has then already left the queue.
            try await waitForTurn(key: key, id: id)
            if Task.isCancelled {
                leaveHead(key: key, id: id)
                throw CancellationError()
            }
        }

        // This request is the head of its bucket from here until `leaveHead`, so its reservation stays the
        // bucket's latest one: no other request of this bucket reserves meanwhile.
        let reservation = schedule.reserveUndoable(host: host, at: elapsed())
        if schedule.trackedEntryCount > Self.pruneThreshold {
            schedule.pruneIdle(at: elapsed())
        }
        do {
            let start = origin + reservation.start
            if start > ContinuousClock.now {
                try await Task.sleep(until: start, clock: .continuous)
            }
            try Task.checkCancellation()
        } catch {
            _ = schedule.cancel(reservation)
            leaveHead(key: key, id: id)
            throw error
        }
        leaveHead(key: key, id: id)
    }

    /// Suspends until a request to `url.host()` may start. The port never matters.
    public func acquire(for url: URL) async throws {
        var host = url.host() ?? ""
        // `URL.host()` drops the brackets of an IPv6 literal; put them back so it shares the bucket of `acquire(host:)`.
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        try await acquire(host: host)
    }

    private func elapsed() -> Duration {
        ContinuousClock.now - origin
    }

    /// Appends the caller to the queue of `key` and suspends until `leaveHead` makes it the head.
    private func waitForTurn(key: String, id: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Runs on this actor before the task suspends, so the queue cannot change under it.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if queues[key] == nil {
                    // Defensive: the queue emptied since `acquire` looked; take the head at once.
                    queues[key] = BucketQueue(headID: id, waiting: [])
                    continuation.resume()
                } else {
                    queues[key]!.waiting.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            // Not on the actor here: hop over. Whatever state the waiter has reached by then, `dropWaiter` is safe.
            Task { await self.dropWaiter(key: key, id: id) }
        }
    }

    /// Removes a cancelled request that is still queued behind the head and fails it with `CancellationError`.
    /// Does nothing if it is the head (its own task handles that) or has already gone.
    private func dropWaiter(key: String, id: UInt64) {
        guard let index = queues[key]?.waiting.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queues[key]!.waiting.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Ends the head's turn and hands the bucket to the next queued request, or drops the empty queue.
    private func leaveHead(key: String, id: UInt64) {
        guard queues[key]?.headID == id else {
            assertionFailure("leaveHead called by a request that is not the head")
            return
        }
        if queues[key]!.waiting.isEmpty {
            queues[key] = nil
            return
        }
        let next = queues[key]!.waiting.removeFirst()
        queues[key]!.headID = next.id
        next.continuation.resume()
    }
}
