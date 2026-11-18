import EHModels
import EHParsing
import Foundation

/// The app's entry point for pages and API calls: `EHClient` plus the Compact guard for gallery lists.
public final class EHService: Sendable {
    fileprivate let client: EHClient
    fileprivate let gate: NoticeGate

    public init(client: EHClient, presenter: any SiteSettingPresenter, ledger: any NoticeLedger) {
        self.client = client
        self.gate = NoticeGate(presenter: presenter, ledger: ledger)
    }

    /// A page of a gallery list, always read in the Compact view: the page of `galleryListResult(_:site:refresh:)`.
    ///
    /// - Throws: as `galleryListResult(_:site:refresh:)`, `EHNetworkError.sessionEnded` included.
    public func galleryList(_ query: ListQuery, site: EHSite, refresh: Bool = false) async throws -> GalleryListPage {
        try await listPage(query, site: site, refresh: refresh).page
    }

    /// A page of a gallery list, always read in the Compact view, and whether the answer it was parsed from came from
    /// the response cache (`ListPageResult.isFromCache`; the page of a Compact resend never does).
    ///
    /// A page with no display-mode selector (an empty result) counts as Compact, as in Flutter. A page in another
    /// mode is dropped from the cache; then, unless the user already agreed once, the presenter is asked. Declining
    /// throws `.displayModeNotCompact` and changes nothing (the next call asks again). Otherwise the list is sent once
    /// more with `inline_set=dm_l`, which changes the user's setting on the site, and only in the session the first
    /// answer was read in (`EHClient.send(_:expectingEpoch:)`). If that answer is still not Compact the call throws
    /// `.displayModeStillNotCompact`; there is never a third request. The resent answer is cached under the URL of the
    /// first request, for the account and profile the resend went out with, and not at all when that session has
    /// ended meanwhile (`EHClient.storeInCache(_:for:)`).
    ///
    /// - Throws: `ListServiceError`; `EHNetworkError`, `.sessionEnded` among them when the session the list was asked
    ///   in (logged out, another account, a login began) ended before it was handed on, which callers drop silently
    ///   (an ended session's answer to the Compact question included); parser or SwiftSoup errors unchanged.
    public func galleryListResult(_ query: ListQuery, site: EHSite, refresh: Bool) async throws -> ListPageResult {
        let (page, response) = try await listPage(query, site: site, refresh: refresh)
        return ListPageResult(page: page, isFromCache: response.source == .cache)
    }

    /// A page of favorites.php (`folder`: one folder, 0…9, or all of them when nil; `search`: `f_search`), in the
    /// Compact view first (the flow of `galleryListResult(_:site:refresh:)`), then in `order` (Flutter
    /// http_transformer.dart:92-134, request.dart:156-178).
    ///
    /// A page with no order control, or already in `order`, is returned as it is. Otherwise, unless the user already
    /// agreed once for this account and site, the presenter is asked about `.favoritesOrder(order)`:
    /// - Declined: the page is returned in the site's order. That is not an error and changes nothing; the next call
    ///   asks again.
    /// - Agreed: the list is sent once more with `inline_set=fs_f` or `fs_p`, which changes the account's setting on
    ///   the site, and only in the session the first answer was read in. A numbered position is resent as the first
    ///   page (Flutter drops `page`); any other position stays. The resent answer is cached under the first request's
    ///   URL and parsed without comparing its order again (there is never a third request); its page is never from the
    ///   cache.
    ///
    /// Limitation: the resend of a `.page(n)` asks for the first page and caches it under the first request's URL, the
    /// one with `page=n`, so reading page n from the cache afterwards gives the first page. No caller gets there today:
    /// favorites.php pages by cursor, and `GalleryListModel` asks for `.page` only on a numbered list. Should the
    /// favorites ever page by number, cache that resend under the URL of `.first`, or not at all.
    ///
    /// - Throws: as `galleryListResult(_:site:refresh:)`, `EHNetworkError.sessionEnded` included when the session the
    ///   page was asked in ended while the question was open (whatever the answer) or before the resent page was
    ///   handed on: nothing is resent for an ended session.
    public func favorites(
        folder: Int?, search: String?, position: ListPosition, order: FavoritesOrder, site: EHSite, refresh: Bool
    ) async throws -> ListPageResult {
        let query = ListQuery(source: .favorites(folder: folder), search: search, position: position)
        let (page, response) = try await listPage(query, site: site, refresh: refresh)
        guard let shown = page.favoritesOrder, shown != order else {
            return ListPageResult(page: page, isFromCache: response.source == .cache)
        }
        let consent = await consent(to: .favoritesOrder(order), site: site, after: response)
        // As in the Compact flow: a cancelled caller sends nothing more, and the page of a session that ended while
        // the question was open is dropped, whatever the answer was.
        try Task.checkCancellation()
        try await requireCurrent(response)
        guard consent else { return ListPageResult(page: page, isFromCache: response.source == .cache) }
        var resend = query
        if case .page = position { resend.position = .first }
        let resent = try await send(
            EHRequests.list(resend, site: site, inlineSet: order.inlineSetting), inSessionOf: response
        )
        try await requireCurrent(resent)
        await client.storeInCache(resent, for: EHRequests.list(query, site: site, refresh: refresh))
        try await requireCurrent(resent)
        return ListPageResult(page: try GalleryListParser.parse(resent.text), isFromCache: false)
    }

    /// Fetches `url` (a GET, cached unless `refresh`) and parses the page text.
    ///
    /// - Throws: `EHNetworkError`, `.sessionEnded` among them when the session the page was read in ended before it
    ///   was handed on (callers drop it silently); whatever `parse` throws.
    public func page<Value: Sendable>(
        _ url: URL, site: EHSite, refresh: Bool = false, parse: @Sendable (String) throws -> Value
    ) async throws -> Value {
        let response = try await client.send(EHRequests.page(url, site: site, refresh: refresh))
        try await requireCurrent(response)
        return try parse(response.text)
    }

    /// Sends `request` and parses the body, for the JSON API.
    ///
    /// - Throws: `EHNetworkError`, `.sessionEnded` among them when the session the answer was read in ended before it
    ///   was handed on (callers drop it silently); whatever `parse` throws.
    public func api<Value: Sendable>(
        _ request: EHRequest, parse: @Sendable (Data) throws -> Value
    ) async throws -> Value {
        let response = try await client.send(request)
        try await requireCurrent(response)
        return try parse(response.body)
    }

    /// The metadata of `ids`, asked in batches of 25 and joined in batch order.
    ///
    /// The site may omit a gallery and the parser drops a bad entry, so the result can be shorter than `ids`:
    /// match entries to `ids` by `GalleryID`, never by index.
    ///
    /// - Throws: as `api(_:parse:)` (`EHNetworkError.sessionEnded` included), or the parser's error.
    public func galleryMetadata(_ ids: [GalleryID], site: EHSite) async throws -> [GalleryMetadata] {
        var result: [GalleryMetadata] = []
        for request in EHAPI.gdata(ids, site: site) {
            result += try await api(request, parse: APIResponseParser.galleryMetadata)
        }
        return result
    }
}

// MARK: - Image search (search Q5)

extension EHService {
    /// Searches the site for `image` (Flutter request.dart:1087-1147, with the file named by its real format): uploads
    /// it (`EHRequests.imageLookup(image:format:options:site:)`, throttled as every request, the redirect not
    /// followed), then reads the result list at the answer's `Location` (`galleryList(at:site:refresh:)`, from the
    /// site).
    ///
    /// The answer to the upload is checked against the session first, as a page is. Only
    /// an https `Location` on `site`'s host is asked for. A relative one is resolved against the upload's address: on
    /// E-Hentai that is `upld.e-hentai.org`, so a relative `Location` is refused there; only on ExHentai, whose upload
    /// is on the site's own host (`exhentai.org/upld/`), can it stay on the site and be asked for.
    ///
    /// - Throws: `EHNetworkError` (`.sessionEnded` among them when the session ended before the upload's answer or the
    ///   result page was handed on); `ImageLookupError.noRedirect(status:)` for an answer that is no redirect,
    ///   `.missingLocation` for a redirect without a usable `Location`, `.unexpectedLocation` for one off the site,
    ///   without https, with a port other than 443, a user or password, or a fragment, all three without a second
    ///   request; as `galleryList(at:site:refresh:)` for the result page.
    public func imageLookup(
        image: Data, format: ImageFormat, options: ImageLookupOptions, site: EHSite
    ) async throws -> ImageLookupResult {
        let upload = EHRequests.imageLookup(image: image, format: format, options: options, site: site)
        let response = try await client.send(upload)
        try await requireCurrent(response)
        guard (300..<400).contains(response.status) else {
            throw ImageLookupError.noRedirect(status: response.status)
        }
        guard let location = response.headers["location"], !location.isEmpty,
              let url = URL(string: location, relativeTo: upload.url)?.absoluteURL
        else { throw ImageLookupError.missingLocation }
        guard url.scheme?.lowercased() == "https", url.host()?.lowercased() == site.host,
              url.port == nil || url.port == 443, url.user == nil, url.password == nil, url.fragment == nil else {
            throw ImageLookupError.unexpectedLocation
        }
        let result = try await galleryList(at: url, site: site, refresh: true)
        return ImageLookupResult(resultURL: url, page: result.page)
    }

    /// A page of a list at `url` (an image search's results, `ImageLookupResult.url(for:)`) in the Compact view, by the
    /// flow of `galleryListResult(_:site:refresh:)`: a GET of `url` (cached unless `refresh`), and when the page is
    /// not Compact and the user agrees, `url` with `inline_set=dm_l` (never cached), whose answer is cached under
    /// `url`.
    ///
    /// - Throws: as `galleryListResult(_:site:refresh:)`, `EHNetworkError.sessionEnded` included.
    public func galleryList(at url: URL, site: EHSite, refresh: Bool) async throws -> ListPageResult {
        // Appended to the query, as `EHRequests.list(_:site:inlineSet:)` does, and never after a fragment.
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { throw URLError(.badURL) }
        components.percentEncodedQuery = [components.percentEncodedQuery, "inline_set=dm_l"]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "&")
        guard let compact = components.url else { throw URLError(.badURL) }
        let (page, response) = try await listPage(
            first: EHRequests.page(url, site: site, refresh: refresh),
            resend: EHRequest(url: compact, site: site, cachePolicy: .none), site: site
        )
        return ListPageResult(page: page, isFromCache: response.source == .cache)
    }
}

extension EHService {
    /// The Compact flow of `galleryListResult(_:site:refresh:)` with its session checkpoints (C5): the page and the
    /// answer it was parsed from (the first one, or the resend's). The pages of the favorites (browse B8) and of
    /// search results (search Q5) go through it too.
    ///
    /// Each answer is checked against the cookie store's session (`requireCurrent(_:)`) as soon as it arrives and
    /// again right before the page is handed on: once the session it was read in has ended, it throws `.sessionEnded`
    /// instead of asking the question, acting on its answer, resending or reporting a display mode. The page it returns
    /// is the current session's when it returns; a caller that suspends before handing it on checks again.
    func listPage(
        _ query: ListQuery, site: EHSite, refresh: Bool
    ) async throws -> (page: GalleryListPage, response: EHResponse) {
        try await listPage(
            first: EHRequests.list(query, site: site, refresh: refresh),
            resend: EHRequests.list(query, site: site, refresh: true, forceCompact: true), site: site
        )
    }

    /// The Compact flow of `listPage(_:site:refresh:)` over the requests themselves: `first`, then, after the
    /// question, `resend` (`first`'s list with `inline_set=dm_l`, never cached), whose answer is cached under `first`.
    /// The image search's results (`galleryList(at:site:refresh:)`, search Q5) have an address rather than a query.
    func listPage(
        first: EHRequest, resend second: EHRequest, site: EHSite
    ) async throws -> (page: GalleryListPage, response: EHResponse) {
        let firstResponse = try await client.send(first)
        try await requireCurrent(firstResponse)
        // The page is read twice (detect, then parse): the document-level detect is internal to EHParsing.
        guard let current = try ListDisplayMode.detect(in: firstResponse.text), current != .compact else {
            return (try GalleryListParser.parse(firstResponse.text), firstResponse)
        }
        // A page that is not Compact is never served from the cache.
        await client.evictCache(for: first)
        // Concurrent lists share one question per account and site (see `NoticeGate`); after "Continue" each resends
        // its own page.
        let consent = await consent(to: .compactView(current: current), site: site, after: firstResponse)
        // A cancelled caller sends nothing more, whatever the answer was (a presenter answers false on cancel).
        try Task.checkCancellation()
        // The session may have ended while the question was open: its list is dropped, whatever the answer was, so
        // nothing is resent for it and a "Cancel" given for it is not reported either.
        try await requireCurrent(firstResponse)
        guard consent else { throw ListServiceError.displayModeNotCompact(current) }
        let secondResponse = try await send(second, inSessionOf: firstResponse)
        // The session may have ended while the resend was out: its answer is dropped, whatever display mode it shows.
        try await requireCurrent(secondResponse)
        if let again = try ListDisplayMode.detect(in: secondResponse.text), again != .compact {
            throw ListServiceError.displayModeStillNotCompact(again)
        }
        await client.storeInCache(secondResponse, for: first)
        try await requireCurrent(secondResponse)
        return (try GalleryListParser.parse(secondResponse.text), secondResponse)
    }

    /// Throws `.sessionEnded` when the session `response` was read in is no longer the cookie store's (an answer from
    /// the cache belongs to the session its scope was read in). Called right before a page is handed on, with no
    /// suspension between the check and the hand-over.
    func requireCurrent(_ response: EHResponse) async throws {
        guard await client.isCurrentSession(response) else { throw EHNetworkError.sessionEnded }
    }

    /// Sends `request` only in the session `response` was read in (`EHClient.send(_:expectingEpoch:)`, else
    /// `.sessionEnded`): a resend that changes a setting of that account on the site (`inline_set`: the Compact view
    /// here, the favorites order in browse B8) never goes out with another session's cookies. A response built by hand
    /// has no session: `request` is sent as it is.
    func send(_ request: EHRequest, inSessionOf response: EHResponse) async throws -> EHResponse {
        guard let epoch = response.origin?.epoch else { return try await client.send(request) }
        return try await client.send(request, expectingEpoch: epoch)
    }

    /// Whether the user agreed to `change` on `site`, for the account `response` was read for: from the ledger, or
    /// by asking (concurrent callers for the same account and site share one question). Used for the Compact view
    /// here and for the favorites order (browse B8).
    func consent(to change: SiteSettingChange, site: EHSite, after response: EHResponse) async -> Bool {
        let scope = NoticeScope(kind: change.kind, site: site, memberID: await client.memberID(for: response))
        return await gate.consent(to: change, scope: scope) { [client] in await client.isCurrentSession(response) }
    }
}

/// Makes concurrent callers share one question to the user, per `NoticeScope`.
///
/// The question of a scope runs in one shared task; callers of that scope that arrive meanwhile wait for the same
/// answer, while other scopes ask their own. It is cleared when it ends, so a "Cancel" is asked again next time. When
/// every caller waiting for it is cancelled, the question's task is cancelled too, so the presenter can take its
/// prompt down.
private actor NoticeGate {
    private struct Question {
        let id: Int
        let task: Task<Bool, Never>
        var waiters: Int
    }

    private let presenter: any SiteSettingPresenter
    private let ledger: any NoticeLedger
    private var questions: [NoticeScope: Question] = [:]
    private var generation = 0

    init(presenter: any SiteSettingPresenter, ledger: any NoticeLedger) {
        self.presenter = presenter
        self.ledger = ledger
    }

    /// true: the user agreed now or earlier. false: the user declined (or the question was cancelled).
    ///
    /// `isCurrent` says whether the session the question was asked for is still the cookie store's; the answer is
    /// recorded in the ledger only if it is (a question that outlived a logout or an account switch records nothing,
    /// so one "Continue" never covers another account's scope). The question's starter supplies it.
    func consent(
        to change: SiteSettingChange, scope: NoticeScope, isCurrent: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        if await ledger.isAcknowledged(scope) { return true }
        // No suspension from here to the end of the setup: a caller either joins the question or starts it.
        let task: Task<Bool, Never>
        let id: Int
        // A question already cancelled (every earlier waiter left) is not joined: its answer would be false.
        if var running = questions[scope], !running.task.isCancelled {
            running.waiters += 1
            questions[scope] = running
            task = running.task
            id = running.id
        } else {
            generation += 1
            id = generation
            task = Task { [presenter, ledger] in
                // Asked again inside the task: the answer may have been recorded since the check above.
                if await ledger.isAcknowledged(scope) {
                    self.finish(scope, id)
                    return true
                }
                let agreed = await presenter.confirm(change, site: scope.site)
                if agreed, await isCurrent() { await ledger.acknowledge(scope) }
                self.finish(scope, id)
                return agreed
            }
            questions[scope] = Question(id: id, task: task, waiters: 1)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leave(scope, id) }
        }
    }

    private func finish(_ scope: NoticeScope, _ id: Int) {
        if questions[scope]?.id == id { questions[scope] = nil }
    }

    private func leave(_ scope: NoticeScope, _ id: Int) {
        guard var question = questions[scope], question.id == id else { return }
        question.waiters -= 1
        questions[scope] = question
        if question.waiters <= 0 { question.task.cancel() }
    }
}
