import Foundation
import Synchronization

/// The delegate of `EHClient`'s sessions: answers connection-level authentication challenges (ServerTrust) by the
/// client's `TrustPolicy`.
///
/// It holds no reference back to the client, so a session (which retains its delegate) makes no cycle.
final class EHSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    private let trustPolicy: TrustPolicy

    init(trustPolicy: TrustPolicy) {
        self.trustPolicy = trustPolicy
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trustPolicy.answer(challenge)
    }
}

/// The per-task delegate of one `EHClient.send(_:)`: follows redirects through `follow`, or refuses them (nil).
///
/// URLSession runs the redirect callback in a task of its own, which the caller's cancellation does not reach, and
/// starts the returned request even when the task has been cancelled meanwhile. So each hop runs in a task this
/// delegate keeps, `cancel()` (wired to the caller's cancellation) cancels it, and a hop that still returns after
/// `cancel()` is refused.
final class RedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    /// Prepares the next hop's request from the redirect response; throwing refuses the redirect.
    typealias Follow = @Sendable (_ redirect: HTTPURLResponse, _ next: URLRequest) async throws -> URLRequest

    private struct State {
        var isCancelled = false
        /// The hop being prepared, if any; redirects come one at a time.
        var hop: Task<URLRequest, any Error>?
        var failure: (any Error)?
    }

    private let follow: Follow?
    private let state = Mutex(State())

    /// `follow` nil: every redirect is refused, so the task ends with the 3xx response.
    init(follow: Follow?) {
        self.follow = follow
    }

    /// Why a redirect was refused (the hop threw, or the request was cancelled); nil when none was, or when
    /// `follow` is nil.
    var failure: (any Error)? {
        state.withLock { $0.failure }
    }

    /// Cancels the hop being prepared and refuses every later redirect.
    func cancel() {
        let hop = state.withLock { state in
            state.isCancelled = true
            return state.hop
        }
        hop?.cancel()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let follow else { return nil }
        let hop: Task<URLRequest, any Error>? = state.withLock { state in
            guard !state.isCancelled else { return nil }
            let hop = Task { try await follow(response, request) }
            state.hop = hop
            return hop
        }
        guard let hop else { return refuse(CancellationError()) }
        do {
            let next = try await hop.value
            let isCancelled = state.withLock { state in
                state.hop = nil
                return state.isCancelled
            }
            return isCancelled ? refuse(CancellationError()) : next
        } catch {
            return refuse(error)
        }
    }

    /// Records the first reason a redirect was refused; returns nil, the refusal.
    private func refuse(_ error: any Error) -> URLRequest? {
        state.withLock { state in
            state.hop = nil
            if state.failure == nil { state.failure = error }
        }
        return nil
    }
}
