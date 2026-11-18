import Foundation

/// A time limit for calls into WebKit, which do not answer Swift cancellation: a store call (`WKHTTPCookieStore`,
/// `WKWebsiteDataStore`), a rule list compile or a script run waits for a WebKit process, and one that hangs may never
/// return (measured on the iPad simulator, M2 review: a cookie store call held a forum profile read for 87–217 s).
///
/// `run(_:_:)` races the operation against the time and the caller's cancellation, and returns as soon as one of them
/// decides; the operation is then cancelled and not waited for. What it still does once it returns is up to the caller
/// (`WebSessionBridge` orders its store calls one after another, so a late one cannot run over the next).
@MainActor enum WebKitDeadline {
    /// The operation had not finished when the time ran out.
    nonisolated struct TimedOut: Error, Equatable {}

    /// `operation`'s result (or its error), `TimedOut` once `timeout` has passed, or `CancellationError` when the
    /// caller is cancelled, whichever comes first; `operation` is cancelled once the race is decided, and not waited
    /// for. A caller that is cancelled already gets `CancellationError` without the operation starting.
    static func run<Value: Sendable>(
        _ timeout: Duration, _ operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = Race<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation, timeout: timeout, operation: operation)
            }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }

    /// One `run` call: the first of the operation, the timer and the caller's cancellation resumes it.
    private final class Race<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, any Error>?
        private var tasks: [Task<Void, Never>] = []
        private var isFinished = false

        func start(
            _ continuation: CheckedContinuation<Value, any Error>, timeout: Duration,
            operation: @escaping @MainActor @Sendable () async throws -> Value
        ) {
            // Cancelled before the continuation was stored (the handler ran first), or already: nothing starts.
            guard !isFinished, !Task.isCancelled else {
                isFinished = true
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            tasks.append(Task { @MainActor in
                let result: Result<Value, any Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                self.finish(result)
            })
            tasks.append(Task { @MainActor in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self.finish(.failure(TimedOut()))
            })
        }

        func finish(_ result: Result<Value, any Error>) {
            guard !isFinished else { return }
            isFinished = true
            for task in tasks {
                task.cancel()
            }
            tasks = []
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
