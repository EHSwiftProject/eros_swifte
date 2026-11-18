import EHNetwork
import Foundation

/// A `RequestThrottle` that never waits and records the URL of every request it lets through, in order.
///
/// Like `RateLimiter`, a request whose task is already cancelled throws `CancellationError` and is not recorded.
public actor RecordingThrottle: RequestThrottle {
    /// The URLs passed to `acquire(for:)`, oldest first, redirect hops included.
    public private(set) var acquiredURLs: [URL] = []

    public init() {}

    public func acquire(for url: URL) async throws {
        try Task.checkCancellation()
        acquiredURLs.append(url)
    }
}
