import EHModels
import EHNetwork
import EHParsing
import Foundation
import Nuke
import Synchronization

/// Why `EHImageDataLoader` refused an answer (the site's notices are thrown as `EHNetworkError.issue`).
nonisolated enum ImageLoadError: Error, Equatable {
    /// The image's answer, after redirects, was not a 200.
    case status(Int)
    /// A 200 whose Content-Type is not `image/…`.
    case notAnImage
    /// The load's request was built before `EHImageDataLoader.supersedeLoads()` (logged out, a login began): its answer
    /// belongs to the earlier session and is dropped, as a cancellation is (nothing reaches Nuke's caches).
    case superseded
}

/// Nuke's data loader for every site image: throttle → authorized request → manual redirects → 200 only.
///
/// Each load runs in a task of its own, which Nuke's `cancel()` cancels:
/// 1. `throttle.acquire(for:)` (`AppEnvironment.throttle`: the breaker refuses with `EHNetworkError.paused`, the rate
///    limiter lets a load cancelled while it waits go without a request);
/// 2. `EHClient.authorizedURLRequest(for:site:)`: the WebKit user agent and the Cookie header of the image's own host
///    only (none for `ehgt.org` or H@H nodes). The site is `.ex` for `exhentai.org` and its subdomains, `.eh` for any
///    other host; it picks the request's timeout and the session (one per site, built with
///    `EHClient.makeSessionConfiguration(for:configuration:)`: no cookie storage, no URL cache, the sites' timeouts,
///    the client's configurator, so UI tests stay offline or replayed);
/// 3. redirects are followed by hand: each hop waits for the throttle first (a refusal ends the load), then continues
///    with `EHClient.redirectedRequest(_:site:)`, never with the request URLSession copied; a hop to anything but
///    https is refused. `/fullimg/` and forum images redirect to third-party H@H nodes, which must get neither the
///    site's cookies nor an unthrottled request;
/// 4. only a 200 whose Content-Type is `image/…` reaches Nuke. Any other answer is classified first
///    (`ResponseClassifier`, the response's URL): a notice goes to the breaker (a ban or a 429 pauses both sites) and
///    is thrown as `EHNetworkError.issue`; anything else fails with `ImageLoadError`. Image bodies are never searched
///    for a notice.
///
/// A cancelled load records nothing and reports nothing to the breaker; it ends with the cancellation error, so Nuke
/// frees its slot.
///
/// Sessions (design §5.2: what went out before a logout and comes back after it is not stored): a load reads the
/// loader's generation right before its Cookie header is read. `supersedeLoads()` moves the generation on; a redirect
/// hop prepared after that is refused, and an image that comes back after it ends with `ImageLoadError.superseded`
/// instead of reaching Nuke, so neither cache keeps what the earlier session's cookies fetched. A site notice is still
/// classified and recorded first (a ban is the IP's, whatever the session).
nonisolated final class EHImageDataLoader: DataLoading, Sendable {
    private let client: EHClient
    private let throttle: any RequestThrottle
    private let breaker: SiteBreaker?
    private let ehSession: URLSession
    private let exSession: URLSession
    /// One more on every `supersedeLoads()`.
    private let generation = Mutex(0)

    /// `configuration` is the client's (`AppEnvironment.clientConfiguration`); its trust policy answers the sessions'
    /// certificate challenges as the client's do. `breaker` nil: notices are only thrown.
    init(client: EHClient, throttle: any RequestThrottle, breaker: SiteBreaker?, configuration: EHClientConfiguration) {
        self.client = client
        self.throttle = throttle
        self.breaker = breaker
        let delegate = ImageSessionDelegate(trustPolicy: configuration.trustPolicy)
        func session(for site: EHSite) -> URLSession {
            URLSession(
                configuration: EHClient.makeSessionConfiguration(for: site, configuration: configuration),
                delegate: delegate, delegateQueue: nil
            )
        }
        ehSession = session(for: .eh)
        exSession = session(for: .ex)
    }

    deinit {
        ehSession.finishTasksAndInvalidate()
        exSession.finishTasksAndInvalidate()
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        let task = Task {
            do {
                guard let url = request.url else { throw URLError(.badURL) }
                let (data, response) = try await self.data(at: url)
                didReceiveData(data, response)
                completion(nil)
            } catch {
                completion(error)
            }
        }
        return LoadCancellation(task: task)
    }

    /// Loads whose request was built before this call end with `ImageLoadError.superseded`; nothing reaches Nuke's caches.
    /// `AppEnvironment` calls it when logging out and when a login starts, before it empties the caches.
    func supersedeLoads() {
        generation.withLock { $0 += 1 }
    }

    /// The site whose session and timeout a request to `url` uses: `.ex` for `exhentai.org` and its subdomains.
    static func site(for url: URL) -> EHSite {
        EHSite(cookieHost: url.host() ?? "") == .ex ? .ex : .eh
    }

    /// The body and answer of a 200 image for `url`, as the type's documentation says.
    private func data(at url: URL) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        try await throttle.acquire(for: url)
        let site = Self.site(for: url)
        // The session the load goes out in: read before its Cookie header is.
        let started = generation.withLock { $0 }
        let request = await client.authorizedURLRequest(for: url, site: site)
        let redirects = ImageRedirectDelegate(client: client, throttle: throttle, site: site) { [self] in
            generation.withLock { $0 } == started
        }
        // The throttle may have let the load through just as it was cancelled: do not start it.
        try Task.checkCancellation()
        let (data, response) = try await withTaskCancellationHandler {
            try await session(for: site).data(for: request, delegate: redirects)
        } onCancel: {
            redirects.cancel()
        }
        // A refused hop leaves the task with its 3xx answer; that is not the image.
        if let failure = redirects.failure { throw failure }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let status = http.statusCode
        guard status == 200, Self.isImage(http) else {
            let answered = http.url ?? url
            let issue = ResponseClassifier.issue(status: status, body: data, expectsJSON: false, host: answered.host())
            if let issue {
                _ = await breaker?.record(issue, at: answered)
                throw EHNetworkError.issue(issue)
            }
            throw status == 200 ? ImageLoadError.notAnImage : ImageLoadError.status(status)
        }
        // Logged out, or a login began, while it was in flight: the image went out with the earlier session's cookies.
        guard generation.withLock({ $0 }) == started else { throw ImageLoadError.superseded }
        return (data, http)
    }

    private func session(for site: EHSite) -> URLSession {
        switch site {
        case .eh: ehSession
        case .ex: exSession
        }
    }

    /// Whether the answer's Content-Type is `image/…` (any case).
    private static func isImage(_ response: HTTPURLResponse) -> Bool {
        guard let type = response.value(forHTTPHeaderField: "Content-Type") else { return false }
        return type.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("image/")
    }
}

/// Cancels one load's task.
nonisolated private struct LoadCancellation: Cancellable {
    let task: Task<Void, Never>

    func cancel() {
        task.cancel()
    }
}

/// The image sessions' delegate: answers connection-level authentication challenges (ServerTrust) by the client's
/// `TrustPolicy`, with the answer `EHClient`'s sessions give (`TrustPolicy.answer(_:)`).
nonisolated private final class ImageSessionDelegate: NSObject, URLSessionDelegate, Sendable {
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

/// The per-task delegate of one image load: every redirect hop waits for the throttle and continues with
/// `EHClient.redirectedRequest(_:site:)`; a hop to anything but https, a throttle error, a cancellation or a hop
/// prepared once the load's session has ended (`isCurrent` false: `ImageLoadError.superseded`) refuses it.
///
/// URLSession runs the redirect callback in a task of its own, which the load's cancellation does not reach, so the
/// hop runs in a task this delegate keeps and `cancel()` cancels (as `EHClient` does for its own requests).
nonisolated private final class ImageRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private struct State {
        var isCancelled = false
        var hop: Task<URLRequest, any Error>?
        var failure: (any Error)?
    }

    private let client: EHClient
    private let throttle: any RequestThrottle
    private let site: EHSite
    /// Whether the load's session is still the loader's (`EHImageDataLoader.supersedeLoads()`).
    private let isCurrent: @Sendable () -> Bool
    private let state = Mutex(State())

    init(client: EHClient, throttle: any RequestThrottle, site: EHSite, isCurrent: @escaping @Sendable () -> Bool) {
        self.client = client
        self.throttle = throttle
        self.site = site
        self.isCurrent = isCurrent
    }

    /// Why a redirect was refused; nil when none was.
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
        guard let url = request.url, url.scheme?.lowercased() == "https" else {
            return refuse(URLError(.unsupportedURL))
        }
        let hop: Task<URLRequest, any Error>? = state.withLock { state in
            guard !state.isCancelled else { return nil }
            let hop = Task { [client, throttle, site, isCurrent] in
                try await throttle.acquire(for: url)
                try Task.checkCancellation()
                let next = await client.redirectedRequest(request, site: site)
                // Its Cookie header may come from a later session: the hop is not sent.
                guard isCurrent() else { throw ImageLoadError.superseded }
                return next
            }
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
