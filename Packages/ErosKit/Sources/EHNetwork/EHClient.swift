import EHModels
import EHParsing
import Foundation

/// Why `EHClient.send(_:)` failed.
public enum EHNetworkError: Error, Equatable {
    /// The site's notice instead of the content (ban, 429, 509, ExHentai's empty page, a stale showkey); the
    /// client never retries one.
    case issue(ResponseIssue)
    /// Any other status of 400 or more.
    case httpStatus(Int)
    /// The request did not complete; the URLError's code.
    case transport(URLError.Code)
    /// The task was cancelled: while waiting for the throttle (the first request or a redirect hop) or in flight.
    case cancelled
    /// Both sites are paused (`SiteBreaker`, after an IP ban or a 429) until the pause's end: the request was not sent.
    /// `BreakerThrottle` throws it, before the request waits for the rate limiter or once its turn has come.
    case paused(SitePause)
    /// The session the request went out in has ended (logged out, another account or a login began) before its answer
    /// was handed on: the page belongs to the earlier session and is dropped. `EHService` throws it, and so does
    /// `EHClient.send(_:expectingEpoch:)` for a request that would go out in another session; `EHClient.send(_:)` does
    /// not, since the login flows need the answer. Callers drop it silently.
    case sessionEnded
}

/// Sends the app's requests: one ephemeral URLSession per site, without the system's cookie storage or URL cache.
///
/// Every request, and every redirect hop, first waits for the `RequestThrottle`. Each carries the user agent store's
/// UA (to every host) and the cookie store's Cookie header for its own host (`e-hentai.org`, `exhentai.org` and
/// their subdomains only); while the UA is the Chrome fallback, the UA-bound Cloudflare cookies (`CookieNames.isUserAgentBound`) are left out. The
/// `Set-Cookie` of every response, redirects included, goes back to the cookie store with the URL of that response.
///
/// Sessions: after the throttle, a request takes its Cookie header, cache scope and the cookie store's epoch in one
/// step (`CookieStore.requestIdentity(for:excludingUserAgentBound:)`). The cookies of its responses are written under
/// that epoch, so they are dropped once the session has changed (logged out, a login began); a redirect hop that
/// would go out in another session is refused (`.cancelled`). The cache stores the page under that scope.
/// A response to a request sent with the Chrome fallback writes no UA-bound Cloudflare cookie (issued for a UA
/// the WebKit requests will not send).
public final class EHClient: Sendable {
    private let cookies: CookieStore
    private let userAgents: UserAgentStore
    private let throttle: any RequestThrottle
    private let ehSession: URLSession
    private let exSession: URLSession
    private let cache: ResponseCache?
    private let breaker: SiteBreaker?

    /// The cookie store is used as it is: loading it is the app's job (an unloaded store still answers and ingests).
    /// `cache` nil: nothing is cached. `breaker`: every site notice a response is goes to it (`SiteBreaker.record`),
    /// so an IP ban or a 429 pauses both sites; it pauses nothing by itself: `throttle` (a `BreakerThrottle` over the
    /// same breaker) refuses the requests. nil: notices are only thrown.
    public init(
        configuration: EHClientConfiguration = .standard, cookies: CookieStore, userAgents: UserAgentStore,
        throttle: any RequestThrottle, cache: ResponseCache? = nil, breaker: SiteBreaker? = nil
    ) {
        self.cache = cache
        self.breaker = breaker
        self.cookies = cookies
        self.userAgents = userAgents
        self.throttle = throttle
        let delegate = EHSessionDelegate(trustPolicy: configuration.trustPolicy)
        func session(for site: EHSite) -> URLSession {
            URLSession(
                configuration: Self.makeSessionConfiguration(for: site, configuration: configuration),
                delegate: delegate, delegateQueue: nil
            )
        }
        ehSession = session(for: .eh)
        exSession = session(for: .ex)
    }

    deinit {
        // A session keeps its delegate until it is invalidated. No task is running: `send` holds the client.
        ehSession.finishTasksAndInvalidate()
        exSession.finishTasksAndInvalidate()
    }

    /// Sends `request` through `request.site`'s session and returns a response below 400 without a site notice.
    ///
    /// Throws `EHNetworkError`: `.issue` for a notice (`ResponseClassifier`, reported to the breaker first, with the
    /// response's URL), `.httpStatus` for other statuses of 400 or more, `.transport` for URL errors, `.cancelled` when
    /// the task is cancelled, and whatever the throttle throws (`.paused` from `BreakerThrottle`, for the request or a
    /// redirect hop). An error writing the response's cookies to the vault is thrown as it is (a login must not look
    /// successful without them), except for a response with a notice: `.issue` comes first, so a caller stops on 429,
    /// 509 or a ban instead of retrying. A GET answered from the cache (`.preferCache`, below) does not wait for the
    /// throttle, so a pause does not stop it.
    ///
    /// Cache (when the client has one; GET with a policy other than `.none`): `.preferCache` answers from a stored
    /// response under 3 days old (`source == .cache`) without the throttle or a request; `.reload` always asks. A
    /// 401, 403 or 503 is answered from the cache when it has the page, even if writing the response's cookies to
    /// the vault failed; a response with a notice never is (`.issue` comes first, and nothing stale stands in for
    /// it). Only a 2xx response without a notice is stored, keyed by the account and profile in the cookie store.
    ///
    /// The cache is looked up under the account and profile before the throttle; the page is stored, and a 401, 403
    /// or 503 answered, under the ones the request was sent with (read with its Cookie header after the throttle).
    /// A page is stored only while the session its request went out in is the cookie store's (`CookieStore.epoch`)
    /// and the cache was not cleared since (`removeAllCachedResponses()`, logging out).
    ///
    /// Every response belongs to a session (`isCurrentSession(_:)`): one from the site to the one its request went out
    /// in; one from the cache to the one its account and profile were read in, with the epoch in the same step of the
    /// cookie store (`CookieStore.cacheIdentity(for:)`); a 401, 403 or 503 answered from the cache to the request's.
    public func send(_ request: EHRequest) async throws -> EHResponse {
        try await send(request, expecting: nil)
    }

    /// `send(_:)`, but only in session `epoch` (`CookieStore.epoch`): throws `EHNetworkError.sessionEnded` instead of
    /// sending when the identity the request would go out with (read after the throttle, with its Cookie header)
    /// belongs to another session, or when a cached answer was read in another one. For a request that changes
    /// something of the account it was decided for (`inline_set`: the Compact resend, browse B8's favorites order),
    /// so that it never goes out with the cookies of a later session (logged out, another account, a login began).
    func send(_ request: EHRequest, expectingEpoch epoch: UInt64) async throws -> EHResponse {
        try await send(request, expecting: epoch)
    }

    /// `send(_:)`; with `epoch`, `send(_:expectingEpoch:)`.
    private func send(_ request: EHRequest, expecting epoch: UInt64?) async throws -> EHResponse {
        var request = request
        if request.method == .post { request.cachePolicy = .none }
        if request.cachePolicy == .preferCache, let cached = await cachedAnswer(to: request) {
            if let epoch, cached.origin?.epoch != epoch { throw EHNetworkError.sessionEnded }
            return cached
        }
        do {
            try await throttle.acquire(for: request.url)
        } catch {
            throw Self.reported(error)
        }
        // Read before the identity. Logging out resets the cookie store, then clears the cache: a request that reads
        // the session being ended has read the generation before that clear too, so its page is not stored after it.
        let cacheGeneration = await cache?.generation
        let (urlRequest, sent) = await makeURLRequest(for: request)
        if let epoch, sent.epoch != epoch { throw EHNetworkError.sessionEnded }
        let key = cacheKey(for: request, scope: sent.scope)
        let origin = ResponseOrigin(
            site: EHSite(cookieHost: request.url.host() ?? ""), scope: sent.scope, epoch: sent.epoch,
            cacheGeneration: cacheGeneration
        )
        let follow: RedirectDelegate.Follow? = request.followsRedirects
            ? { @Sendable [self] redirect, next in try await followRedirect(from: redirect, to: next, of: sent) }
            : nil
        let (body, response) = try await transfer(
            urlRequest, on: session(for: request.site), delegate: RedirectDelegate(follow: follow)
        )
        let url = response.url ?? request.url
        let headers = Self.headerFields(of: response)
        let status = response.statusCode
        let issue = ResponseClassifier.issue(status: status, body: body, expectsJSON: request.expectsJSON, host: url.host())
        // Before anything else can throw: a ban or a 429 pauses both sites even when the cookies cannot be written.
        if let issue { _ = await breaker?.record(issue, at: url) }
        do {
            try await ingestCookies(headers: headers, from: url, of: sent)
        } catch {
            // The site's notice comes first: hidden behind a vault error, a 429 or a ban could be retried.
            if let issue { throw EHNetworkError.issue(issue) }
            // A vault error does not close the way back to the cache either.
            if let stale = await cachedFallback(for: key, status: status, origin: origin) { return stale }
            throw error
        }
        if let issue { throw EHNetworkError.issue(issue) }
        if status >= 400 {
            if let stale = await cachedFallback(for: key, status: status, origin: origin) { return stale }
            throw EHNetworkError.httpStatus(status)
        }
        let fresh = EHResponse(
            status: status, url: url, headers: headers, body: body, source: .network, origin: origin
        )
        if let key { await store(fresh, as: key, origin: origin) }
        return fresh
    }

    /// Deletes every cached response (`ResponseCache.removeAll()`): logging out must not leave an account's pages
    /// (its favorites, its settings) on disk. A request that went out before does not store its page afterwards.
    public func removeAllCachedResponses() async {
        await cache?.removeAll()
    }

    /// Keeps `response` as the cached answer to `request`'s URL (N6: a list page resent with `inline_set=dm_l` stays
    /// cached under the URL the caller asked for). Stores only what `send` would: a GET with a cache policy other
    /// than `.none`, status 2xx, from the network (a response that came from the cache is not stored again, which
    /// would renew its age).
    ///
    /// A response of `send(_:)` is stored under the account and profile its request went out with, never the ones
    /// current by now, and only while that session is still the cookie store's and the cache was not cleared since:
    /// after a logout, another login or another profile meanwhile, it lands under no other session's key. `request`
    /// must be on the same site as the request that got `response` (otherwise nothing is stored). A response built
    /// by hand has no such record: it is stored under the account and profile now in the cookie store.
    public func storeInCache(_ response: EHResponse, for request: EHRequest) async {
        guard response.source == .network else { return }
        guard let origin = response.origin else {
            guard let key = await cacheKey(for: request) else { return }
            await store(response, as: key, origin: nil)
            return
        }
        guard let key = cacheKey(for: request, scope: origin.scope),
              EHSite(cookieHost: request.url.host() ?? "") == origin.site else { return }
        await store(response, as: key, origin: origin)
    }

    /// The member id `response` was read for: the one in its origin's scope ("<member id or anonymous>|<sp or ->"),
    /// so a login or logout since does not change it; nil when that was no account. An answer from the cache has the
    /// scope it was looked up under. A response without an origin (built by hand): the member id of the jar of the
    /// site its URL belongs to, now in the cookie store (nil for a URL outside both sites). Never the E-Hentai jar's
    /// for an ExHentai page.
    func memberID(for response: EHResponse) async -> Int? {
        if let origin = response.origin { return Self.memberID(inScope: origin.scope) }
        return Self.memberID(inScope: await cookies.cacheScope(for: response.url))
    }

    /// The member id in a cache scope ("<member id or anonymous>|<sp or ->").
    private static func memberID(inScope scope: String) -> Int? {
        scope.split(separator: "|", maxSplits: 1).first.flatMap { Int($0) }
    }

    /// Whether the session `response` was read in is still the cookie store's: a response from the site, or from the
    /// cache, belongs to the session `send` read its identity in (see `send(_:)`). A response without an origin (built
    /// by hand) belongs to no session and counts as current.
    func isCurrentSession(_ response: EHResponse) async -> Bool {
        guard let origin = response.origin else { return true }
        return await cookies.epoch == origin.epoch
    }

    /// Forgets the cached answer to `request`'s URL for the account and profile now in the cookie store.
    public func evictCache(for request: EHRequest) async {
        guard let cache else { return }
        await cache.remove(CacheKey(url: request.url, scope: await cookies.cacheScope(for: request.url)))
    }

    /// UA, Accept headers and the scoped Cookie header for image loaders and downloads (M2, M4, M5). Not throttled: the caller acquires.
    ///
    /// The timeout is `site`'s idle timeout; the request does not let a session handle cookies itself
    /// (`httpShouldHandleCookies` false). Send it with a session from `makeSessionConfiguration(for:configuration:)`.
    ///
    /// The Cookie header is for `url`'s host only, so the caller's session must handle redirects itself, with a task
    /// delegate (`urlSession(_:task:willPerformHTTPRedirection:newRequest:)`), and never let URLSession follow one
    /// with the request it copied: first `try await throttle.acquire(for:)` the new URL (refuse the redirect,
    /// returning nil, when that throws), then return `redirectedRequest(_:site:)` of the copied request. `/fullimg/`
    /// redirects to third-party H@H nodes, which must get neither the site's cookies nor an unthrottled request.
    public func authorizedURLRequest(for url: URL, site: EHSite) async -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.idleTimeout(for: site)
        )
        request.httpShouldHandleCookies = false
        request.setValue(RequestDefaults.accept, forHTTPHeaderField: "Accept")
        request.setValue(RequestDefaults.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        await setIdentity(of: &request, for: url)
        return request
    }

    /// The request a redirect continues with: `request` (the one URLSession copied from the redirected request) with
    /// its Cookie and User-Agent (any case) removed, then set again for `request.url` as every request gets them —
    /// no Cookie outside both sites, no UA-bound Cloudflare cookie (`CookieNames.isUserAgentBound`) with the Chrome fallback. Its other headers stay;
    /// the timeout becomes `site`'s idle timeout, and `httpShouldHandleCookies` false. Not throttled: the caller
    /// acquires first (see `authorizedURLRequest(for:site:)`). The same step as a redirect hop of `send(_:)`.
    public func redirectedRequest(_ request: URLRequest, site: EHSite) async -> URLRequest {
        var (next, _) = await rescoped(request)
        next.timeoutInterval = Self.idleTimeout(for: site)
        next.httpShouldHandleCookies = false
        return next
    }

    /// `.ephemeral` without cookie storage, cookie handling or URL cache, ignoring local cache data, with `site`'s
    /// timeouts (`RequestTimeouts.urlSession`); then `configuration.sessionConfigurator` (a proxy, a test's mock).
    public static func makeSessionConfiguration(
        for site: EHSite, configuration: EHClientConfiguration
    ) -> URLSessionConfiguration {
        let timeouts = RequestDefaults.timeouts(for: site).urlSession
        let session = URLSessionConfiguration.ephemeral
        session.httpCookieStorage = nil
        session.httpShouldSetCookies = false
        session.urlCache = nil
        session.requestCachePolicy = .reloadIgnoringLocalCacheData
        session.timeoutIntervalForRequest = timeouts.idle.timeInterval
        session.timeoutIntervalForResource = timeouts.resource.timeInterval
        configuration.sessionConfigurator.apply(to: session)
        return session
    }

    // MARK: - Requests

    /// Headers a request's `headers` cannot set (lowercased): they come only from the stores.
    private static let storeOwnedHeaders: Set<String> = ["cookie", "user-agent"]

    private func session(for site: EHSite) -> URLSession {
        switch site {
        case .eh: ehSession
        case .ex: exSession
        }
    }

    private static func idleTimeout(for site: EHSite) -> TimeInterval {
        RequestDefaults.timeouts(for: site).urlSession.idle.timeInterval
    }

    /// What a request went out with, for its responses: the cookie store's session and cache scope (read with its
    /// Cookie header), and whether its UA was WebKit's (false: the Chrome fallback).
    private struct Sent: Sendable {
        let epoch: UInt64
        let scope: String
        let isWebKit: Bool
    }

    /// Method, body and its Content-Type, Accept, Accept-Language, User-Agent and Cookie, then `request.headers`.
    private func makeURLRequest(for request: EHRequest) async -> (URLRequest, Sent) {
        var urlRequest = URLRequest(
            url: request.url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.idleTimeout(for: request.site)
        )
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = false
        if let encoded = request.body.encoded {
            urlRequest.httpBody = encoded.data
            urlRequest.setValue(encoded.contentType, forHTTPHeaderField: "Content-Type")
        }
        urlRequest.setValue(RequestDefaults.accept, forHTTPHeaderField: "Accept")
        urlRequest.setValue(RequestDefaults.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        let sent = await setIdentity(of: &urlRequest, for: request.url)
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key })
        where !Self.storeOwnedHeaders.contains(name.lowercased()) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return (urlRequest, sent)
    }

    /// Sets User-Agent and the Cookie header of `url`'s host; removes Cookie for a host outside both sites. Returns
    /// what they were read with: the Cookie header, cache scope and epoch come from one step of the cookie store.
    @discardableResult
    private func setIdentity(of urlRequest: inout URLRequest, for url: URL) async -> Sent {
        // isWebKit before current: adopting a UA only ever turns isWebKit on, so a concurrent adopt can leave
        // UA-bound Cloudflare cookies out of a request with the new UA, but never send them with the Chrome fallback.
        let isWebKit = await userAgents.isWebKit
        let userAgent = await userAgents.current
        let identity = await cookies.requestIdentity(for: url, excludingUserAgentBound: !isWebKit)
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue(identity.cookie, forHTTPHeaderField: "Cookie")
        return Sent(epoch: identity.epoch, scope: identity.scope, isWebKit: isWebKit)
    }

    /// Runs one task; the caller's cancellation also cancels a redirect hop that is waiting for the throttle.
    private func transfer(
        _ urlRequest: URLRequest, on session: URLSession, delegate: RedirectDelegate
    ) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            // The throttle may have let a request through just as its task was cancelled: do not start it.
            try Task.checkCancellation()
            (data, response) = try await withTaskCancellationHandler {
                try await session.data(for: urlRequest, delegate: delegate)
            } onCancel: {
                delegate.cancel()
            }
        } catch {
            throw Self.reported(error)
        }
        // A refused hop leaves the task with its 3xx response; that is not the page asked for.
        if let failure = delegate.failure { throw Self.reported(failure) }
        guard let response = response as? HTTPURLResponse else { throw EHNetworkError.transport(.badServerResponse) }
        return (data, response)
    }

    /// One redirect hop of a request that went out as `sent`: the redirect response's cookies (with its own URL, under
    /// the request's session), the throttle, then User-Agent and Cookie for the new host (`rescoped`, as
    /// `redirectedRequest(_:site:)`). Throwing refuses the redirect: a hop whose Cookie header would come from another
    /// session (logged out or a login began while it waited) throws `CancellationError`, so neither the old
    /// account's page nor the new one's ends up under the scope the request was sent with.
    private func followRedirect(
        from redirect: HTTPURLResponse, to next: URLRequest, of sent: Sent
    ) async throws -> URLRequest {
        if let hopURL = redirect.url {
            try await ingestCookies(headers: Self.headerFields(of: redirect), from: hopURL, of: sent)
        }
        guard let url = next.url else { throw URLError(.badURL) }
        try await throttle.acquire(for: url)
        let (request, hop) = await rescoped(next)
        guard hop?.epoch == sent.epoch else { throw CancellationError() }
        return request
    }

    /// `request` with its Cookie and User-Agent headers (any case) removed, then set for `request.url`'s host
    /// (only User-Agent when it has no URL), and what they were read with (nil without a URL).
    private func rescoped(_ request: URLRequest) async -> (URLRequest, Sent?) {
        var request = request
        let names = (request.allHTTPHeaderFields ?? [:]).keys
        for name in names where Self.storeOwnedHeaders.contains(name.lowercased()) {
            request.setValue(nil, forHTTPHeaderField: name)
        }
        guard let url = request.url else {
            request.setValue(await userAgents.current, forHTTPHeaderField: "User-Agent")
            return (request, nil)
        }
        let sent = await setIdentity(of: &request, for: url)
        return (request, sent)
    }

    // MARK: - Cache

    /// The key of a request the cache may serve and store for, under the account and profile now in the cookie
    /// store: a GET, with a cache and a policy other than `.none`.
    private func cacheKey(for request: EHRequest) async -> CacheKey? {
        guard isCacheable(request) else { return nil }
        return CacheKey(url: request.url, scope: await cookies.cacheScope(for: request.url))
    }

    /// `cacheKey(for:)` under `scope`, the one the request went out with.
    private func cacheKey(for request: EHRequest, scope: String) -> CacheKey? {
        isCacheable(request) ? CacheKey(url: request.url, scope: scope) : nil
    }

    private func isCacheable(_ request: EHRequest) -> Bool {
        cache != nil && request.method == .get && request.cachePolicy != .none
    }

    /// The stored answer to `request` (a GET the cache may serve) under the account and profile now in the cookie
    /// store, as a response of the session they were read in (one step: `CookieStore.cacheIdentity(for:)`); nil when
    /// the cache has none.
    private func cachedAnswer(to request: EHRequest) async -> EHResponse? {
        guard let cache, isCacheable(request) else { return nil }
        let identity = await cookies.cacheIdentity(for: request.url)
        guard let cached = await cache.lookup(CacheKey(url: request.url, scope: identity.scope)) else { return nil }
        let origin = ResponseOrigin(
            site: EHSite(cookieHost: request.url.host() ?? ""), scope: identity.scope, epoch: identity.epoch,
            cacheGeneration: nil
        )
        return Self.response(from: cached, origin: origin)
    }

    /// The stored page standing in for a 401, 403 or 503, when there is one: under the scope of the request (`key`),
    /// so of its session (`origin`), without a cache generation, as every answer from the cache.
    private func cachedFallback(for key: CacheKey?, status: Int, origin: ResponseOrigin) async -> EHResponse? {
        guard let key, [401, 403, 503].contains(status), let cached = await cache?.lookup(key) else { return nil }
        let fromCache = ResponseOrigin(site: origin.site, scope: origin.scope, epoch: origin.epoch, cacheGeneration: nil)
        return Self.response(from: cached, origin: fromCache)
    }

    /// Stores a 2xx `response` under `key`. With `origin`: only while its epoch is still the cookie store's, and
    /// unless the cache was cleared after its generation was read (the cache checks that in the same step as the
    /// write, so a logout's clear never lets the page back in). nil: neither is checked.
    private func store(_ response: EHResponse, as key: CacheKey, origin: ResponseOrigin?) async {
        guard let cache, (200..<300).contains(response.status) else { return }
        if let origin, await cookies.epoch != origin.epoch { return }
        let cached = CachedResponse(
            status: response.status, url: response.url, headers: response.headers, body: response.body,
            storedAt: cache.currentDate()
        )
        await cache.store(cached, for: key, ifGeneration: origin?.cacheGeneration)
    }

    /// A cached page as a response from the cache of the session `origin` names (never stored again: see
    /// `storeInCache(_:for:)`).
    private static func response(from cached: CachedResponse, origin: ResponseOrigin) -> EHResponse {
        EHResponse(
            status: cached.status, url: cached.url, headers: cached.headers, body: cached.body, source: .cache,
            origin: origin
        )
    }

    // MARK: - Responses

    /// Writes the `Set-Cookie` of a response from `url` to the cookie store (which keeps what `url`'s host may set),
    /// under the session the request went out in (`sent.epoch`: dropped once that session has ended).
    ///
    /// A request that went out with the Chrome fallback (`sent.isWebKit` false) writes or deletes no UA-bound
    /// Cloudflare cookie: Cloudflare issued it for the Chrome UA, and once the WebKit UA is known (whether or not
    /// its string changed) it would go out with that UA. Such a request never sends them, so dropping them changes
    /// nothing for it. A redirect chain counts as one request: the first request's UA decides for every hop. Adopting
    /// a UA only ever turns WebKit on, so when the first went out with WebKit's every hop did; when it went out with
    /// the fallback, a hop that got WebKit's meanwhile only loses its Cloudflare cookies.
    private func ingestCookies(headers: [String: String], from url: URL, of sent: Sent) async throws {
        var parsed = SetCookieParser.cookies(headerFields: headers, url: url)
        if !sent.isWebKit { parsed.removeAll { CookieNames.isUserAgentBound($0.name) } }
        guard !parsed.isEmpty else { return }
        try await cookies.ingest(parsed, from: url, epoch: sent.epoch)
    }

    /// The response's header fields as strings (URLSession joins repeated fields, `Set-Cookie` included, with ", ").
    private static func headerFields(of response: HTTPURLResponse) -> [String: String] {
        var fields: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            fields[name] = value
        }
        return fields
    }

    /// What `send` throws for `error`: either kind of cancellation → `.cancelled`; other URL errors → `.transport`;
    /// anything else unchanged.
    private static func reported(_ error: any Error) -> any Error {
        switch error {
        case let error as EHNetworkError: error
        case is CancellationError: EHNetworkError.cancelled
        case let error as URLError where error.code == .cancelled: EHNetworkError.cancelled
        case let error as URLError: EHNetworkError.transport(error.code)
        default: error
        }
    }
}
