import Foundation

/// Decides when a request may start; `EHClient` asks it before every request and every redirect hop.
public protocol RequestThrottle: Sendable {
    /// Suspends until a request to `url` may start; throws `CancellationError` when the task is cancelled first.
    func acquire(for url: URL) async throws
}

extension RateLimiter: RequestThrottle {}
