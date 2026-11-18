import EHModels
import EHParsing
import Foundation

/// Why a login did not sign in. Carries no value: the password and the cookies stay out of errors.
public enum LoginError: Error, Equatable {
    /// After the login the EH jar has no numeric, non-zero `ipb_member_id` with an `ipb_pass_hash` (a wrong password,
    /// a web login closed before it finished). The cookie store is as it was before the attempt.
    case rejected
    /// A typed or pasted member id that is not ASCII digits, is zero, or does not fit an `Int`. Nothing was written.
    case invalidMemberID
    /// A typed or pasted pass hash that is not 32 lowercase hexadecimal characters. Nothing was written.
    case invalidPassHash
}

/// Whether the account can use ExHentai.
public enum ExAccess: Sendable, Equatable {
    /// The EX jar holds an `igneous` other than "mystery".
    case granted
    /// ExHentai answered its empty page, or gave no usable `igneous`.
    case denied
}

/// What one run of `AccountService.ensureErosProfile(site:)` ended with; the numbers are the site's profile numbers.
public enum ProfileOutcome: Sendable, Equatable {
    /// The settings page already showed the Eros-FE profile.
    case alreadySelected(Int)
    /// The Eros-FE profile existed and was selected.
    case selected(Int)
    /// The Eros-FE profile was created (the site selects a new profile).
    case created(Int)
    /// The settings page lists no profiles; nothing was changed.
    case noProfiles
    /// No round gave the expected page; nothing was written.
    case failed
    /// The site answered with a notice (429, 509, a ban, ExHentai's empty page): the run stopped at once, and the
    /// caller must stop sending too. For a login and the EX check, also both sites paused by an earlier notice
    /// (`EHNetworkError.paused`): the notice that began the pause (`.banned(remaining: nil)` or `.tooManyRequests`).
    case stopped(ResponseIssue)
}

/// How the last profile run of a site went, for the session diagnostics and `docs/notes/sp-cookie.md` (account A5).
public struct ProfileDiagnostics: Sendable, Equatable {
    public let outcome: ProfileOutcome
    /// A response of the run set the site's `sp` cookie itself (`sp` written back by the server).
    public let serverSetProfileCookie: Bool
    /// The site jar's `sp` after the run, as a number; nil when it has none (or not a number).
    public let profileCookieAfter: Int?

    public init(outcome: ProfileOutcome, serverSetProfileCookie: Bool, profileCookieAfter: Int?) {
        self.outcome = outcome
        self.serverSetProfileCookie = serverSetProfileCookie
        self.profileCookieAfter = profileCookieAfter
    }
}

/// A successful login.
///
/// `description` and the mirror leave out the member id: it is the value of the `ipb_member_id` cookie.
public struct LoginOutcome: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    /// The EH jar's `ipb_member_id`.
    public let memberID: Int
    /// The EH profile run after the login; nil when profile selection is off. `.stopped` means the site sent a
    /// notice, or both sites are paused after one: the login stands, but nothing more should be sent for now.
    public let profile: ProfileOutcome?

    public init(memberID: Int, profile: ProfileOutcome?) {
        self.memberID = memberID
        self.profile = profile
    }

    /// "LoginOutcome(profile: selected(5))", or "LoginOutcome(profile: none)".
    public var description: String {
        "LoginOutcome(profile: \(profile.map { "\($0)" } ?? "none"))"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["description": description])
    }
}

/// Whether a login and the EX check go on to choose the Eros-FE profile.
public enum ProfileSelectionMode: Sendable, Equatable {
    /// After every login (EH) and every granted EX check (EX), `ensureErosProfile(site:)` runs.
    case automatic
    /// Only an explicit `ensureErosProfile(site:)` call touches the profiles.
    case off
}

/// Logins, ExHentai access and the Eros-FE settings profile, on top of `EHClient` and `CookieStore`.
///
/// None of the three logins changes the user agent: it is always the device's WebKit UA (or its fallback), as for
/// every request (N2, user decision 2026-11-05). The service never sees a password: the app's background WebView
/// posts the forum login form (account A3b).
///
/// Before the cookie store has loaded, everything but `logOut()` throws `CookieStoreError.notLoaded` (unchanged,
/// so the app can retry `load()`) and sends nothing. The service's own errors are `LoginError`; the client's
/// (`EHNetworkError`, vault errors) come through as they are.
///
/// Sessions: `logOut()` and the start of every login begin a new session (a generation here, an epoch in the cookie
/// store). That cancels every profile run in progress; a run never sends a select or create for a session other than
/// the one it started in. A login whose session has ended leaves nothing of its own: once the cookie store's epoch
/// has moved on, its cookies, the copy to EX and the account are dropped; while the epoch is still its own (the store
/// ran the later session's reset or login start first, or a logout's reset failed), what it wrote is put back to its
/// snapshot. It throws `CancellationError` (or the error it failed with). Whether it puts back is decided by the
/// epoch alone, so a login never undoes a logout or a later login that has reached the store. Requests in flight at
/// a session change write no cookie afterwards (`EHClient`, `CookieStore.epoch`).
///
/// Every login, signed in or not, begins with jars holding only the UA-bound Cloudflare cookies: nothing the
/// account signed in now or an earlier one left behind (`hath_perks`, `sk`, `igneous`, `sp`, …) goes out with the
/// new identity (`CookieStore.beginLogin()`); a failed login puts the whole state back.
public actor AccountService {
    /// The settings profile Eros uses on each site (the Flutter app's name, so both share one).
    public static let erosProfileName = "Eros-FE"
    /// The most rounds one profile run makes.
    static let profileRoundLimit = 3
    /// What a login copies from the EH jar into the EX jar: `CookieNames.injected` but the UA-bound Cloudflare
    /// cookies (`CookieNames.isUserAgentBound`; Cloudflare binds them to the host and UA they were issued for) and
    /// igneous (EX's own).
    static let sharedCookieNames: Set<String> = Set(CookieNames.injected)
        .filter { !CookieNames.isUserAgentBound($0) && $0 != CookieNames.igneous }

    /// One site's profile run in progress, shared by every call that joined it.
    private struct ProfileRun {
        let id: Int
        /// The signed-in member id the run is for; a call for another member never joins it.
        let member: Int?
        /// The session the run belongs to (see `generation`).
        let generation: Int
        let task: Task<ProfileOutcome, any Error>
        /// The calls waiting for it; when the last of them is cancelled, the run is cancelled.
        var callers: Set<Int>
    }

    private let client: EHClient
    private let store: CookieStore
    private let profileSelection: ProfileSelectionMode
    private let retryDelay: Duration
    /// The last profile run of each site that ended with an outcome or a site notice; forgotten on logout and when
    /// a login signs in another member.
    private var diagnostics: [EHSite: ProfileDiagnostics] = [:]
    private var runs: [EHSite: ProfileRun] = [:]
    /// Numbers for run ids and caller tokens.
    private var lastToken = 0
    /// The session: one more on every `logOut()` and at the start of every login.
    private var generation = 0

    /// `client` must use `cookies` as its cookie store. `retryDelay`: the wait between rounds of a profile run.
    public init(
        client: EHClient, cookies: CookieStore, profileSelection: ProfileSelectionMode = .automatic,
        retryDelay: Duration = .seconds(2)
    ) {
        self.client = client
        store = cookies
        self.profileSelection = profileSelection
        self.retryDelay = retryDelay
    }

    // MARK: - Logins

    /// The password login after the background WebView posted the forum form (account A3b): `cookies` are the WebView
    /// store's site cookies, ingested as `completeWebLogin(cookies:from:)` does; method `.password`, `username` recorded.
    /// The same rules as the other logins: the jars cleared first of every cookie but the UA-bound Cloudflare ones
    /// (`CookieStore.beginLogin()`), `.rejected` without an identity pair afterwards (store put back).
    ///
    /// The forum answers a URLSession POST of its login form with a Cloudflare 403 (A4), so the app posts the form in
    /// a WKWebView and hands over what that WebView's store holds afterwards: this service never sees the password.
    /// When the login is rejected or anything on the way throws, the cookie store goes back to its whole snapshot
    /// from before (a signed-in account stays signed in) and the error is thrown. When `logOut()` or another login
    /// comes in meanwhile, that one stands: the login leaves nothing of its own (see Sessions in the type's
    /// documentation) and throws `CancellationError`, or the error it failed with.
    ///
    /// Precondition: no other site request should be in flight during a login. A response to a request sent before
    /// the login began writes no cookie (the login is a new epoch); cookies a response to one sent during the login
    /// writes (a new igneous, an sp) are rolled back with the rest when the login fails.
    public func completePasswordLogin(
        cookies: [ParsedCookie], from url: URL, username: String
    ) async throws -> LoginOutcome {
        try await attemptLogin(method: .password, username: username) { epoch in
            try await store.ingestWebViewCookies(cookies, fallback: url, epoch: epoch)
        }
    }

    /// Writes a typed or pasted member id and pass hash into both jars, without asking the site (as the Flutter app).
    ///
    /// The member id must be ASCII digits and not zero (`.invalidMemberID`), the pass hash 32 lowercase hexadecimal
    /// characters (`.invalidPassHash`), as `CookieCredentials.validate()` checks; a refused value writes nothing.
    /// Nothing is trimmed: a line break or ";" is refused, not dropped.
    public func logIn(with credentials: CookieCredentials) async throws -> LoginOutcome {
        try credentials.validate()
        return try await attemptLogin(method: .cookie, username: nil) { epoch in
            try await store.set(
                [CookieNames.memberID: credentials.memberID, CookieNames.passHash: credentials.passHash],
                for: Set(EHSite.allCases), epoch: epoch
            )
        }
    }

    /// Takes the site cookies of the web login's WKWebView, then decides as the other logins do.
    ///
    /// The cookies go in by `CookieStore.ingestWebViewCookies(_:fallback:expectedMemberID:)`, as the WebView session
    /// bridge's `pull()` does: WebKit has checked their domains, so each counts as a response from its own domain and
    /// both sites' cookies land in their jars; `url` stands in only for a cookie without a domain; all in one change.
    /// The cookie store's rules still apply: cookies of neither site are dropped, so are igneous "mystery" and invalid
    /// values. As for a password login, the jars are cleared first of every cookie but the UA-bound Cloudflare ones,
    /// a rejected login puts the store back as it was, one that `logOut()` or another login superseded leaves nothing
    /// of its own (`CancellationError`, or the error it failed with), and the same precondition holds: no other site
    /// request in flight, since what it writes meanwhile is rolled back too.
    public func completeWebLogin(cookies: [ParsedCookie], from url: URL) async throws -> LoginOutcome {
        try await attemptLogin(method: .web, username: nil) { epoch in
            try await store.ingestWebViewCookies(cookies, fallback: url, epoch: epoch)
        }
    }

    /// Forgets the session: cancels every profile run in progress, then `CookieStore.reset()` (the vault item, both
    /// jars, the account; a new epoch, so a response still in flight writes no cookie), the profile diagnostics, and
    /// every cached response (`EHClient.removeAllCachedResponses()`: the account's pages must not stay on disk; a
    /// page still in flight is not stored afterwards). The cache is cleared also when the reset throws. A login in
    /// flight leaves nothing of its own, and never puts its snapshot back over the reset (a new epoch). Works before
    /// the store has loaded. The WebView's cookies are cleared by the app (`WebSessionBridge.clear()`, account A1).
    public func logOut() async throws {
        beginSession()
        do {
            try await store.reset()
        } catch {
            await client.removeAllCachedResponses()
            throw error
        }
        // After the reset (see `EHClient.send(_:)`): a request that read the ended session read the cache generation
        // before this clear, so its page is not stored afterwards.
        await client.removeAllCachedResponses()
        diagnostics = [:]
    }

    /// Stores what the forum profile page of `memberID` showed (account A2): `displayName`, `avatarURL` and now as
    /// `profileFetchedAt`; nil clears all three. Writes nothing unless `memberID` is the member signed in now and
    /// there is an account, so a page read for an account that has logged out (or been replaced) meanwhile is
    /// dropped; the check and the write are one step of the cookie store. Returns whether it wrote.
    @discardableResult
    public func updateForumProfile(_ profile: ForumProfile?, memberID: Int) async throws -> Bool {
        let fetchedAt = profile == nil ? nil : Date()
        return try await store.updateAccount(ifMember: memberID) { account in
            account.displayName = profile?.displayName
            account.avatarURL = profile?.avatarURL
            account.profileFetchedAt = fetchedAt
        }
    }

    // MARK: - ExHentai

    /// Asks ExHentai for its settings page, always from the site (no cache, so a 401, 403 or 503 is thrown as
    /// `.httpStatus` instead of being answered by an old page): its empty page → `.denied`; afterwards an `igneous`
    /// other than "mystery" in the EX jar → `.granted`, then (`.automatic`) the EX profile run; otherwise
    /// `.denied`. Other request errors are thrown.
    ///
    /// A site notice in the profile run (or a pause of both sites that began meanwhile, as the notice that began it)
    /// is thrown as `EHNetworkError.issue` although access was granted (the caller must stop; the igneous in the EX
    /// jar still tells the access). Other profile errors do not change the answer. An igneous already in the jar
    /// counts: use `refreshIgneous()` to get a new one.
    public func activateExHentai() async throws -> ExAccess {
        // The session the check is asked in: its profile run belongs to it (see `ensureErosProfile(site:session:)`).
        let session = generation
        guard await store.isLoaded else { throw CookieStoreError.notLoaded }
        do {
            _ = try await client.send(Self.settingsRequest(site: .ex))
        } catch EHNetworkError.issue(.exAccessDenied) {
            return .denied
        }
        let igneous = await store.snapshot().cookies[.ex]?[CookieNames.igneous]
        guard let igneous, !igneous.isEmpty, igneous != CookieNames.mysteryIgneous else { return .denied }
        if case .stopped(let issue)? = try await automaticProfile(site: .ex, session: session) {
            throw EHNetworkError.issue(issue)
        }
        return .granted
    }

    /// Removes igneous from the EX jar, then `activateExHentai()`, so the request carries none and EX issues a new one.
    public func refreshIgneous() async throws -> ExAccess {
        try await store.remove([CookieNames.igneous], for: [.ex])
        return try await activateExHentai()
    }

    // MARK: - Eros-FE profile

    /// Makes sure `site` uses the profile named "Eros-FE", choosing or creating it; at most 3 rounds, `retryDelay`
    /// apart. Runs whatever the profile selection mode (which only decides whether logins call it).
    ///
    /// One run per site at a time: a call while a run for the same signed-in member and session is in progress joins
    /// it and gets its result. When every call waiting for a run is cancelled, the run is cancelled; a cancelled call
    /// whose run still has other callers does not return early: it waits for the run to end and gets the shared
    /// result (which may be `.created`), not a cancellation. A cancelled run is never joined: the next call starts a
    /// new one. `logOut()` and every login cancel the runs in progress; their callers get a cancellation error
    /// (`EHNetworkError.cancelled` or `CancellationError`).
    ///
    /// A round asks for the settings page, always from the site (no cache: a 401, 403 or 503 is thrown, never
    /// answered by an old page), and reads it:
    /// - no profiles → `.noProfiles`, nothing written;
    /// - the selected profile is Eros-FE → `.alreadySelected(n)`;
    /// - an Eros-FE profile that is not selected → `selectProfile(n)`; the answer shows n selected → `.selected(n)`;
    /// - no Eros-FE profile, and the page has the settings form → `createProfile(named: "Eros-FE")`; the answer
    ///   shows a new Eros-FE profile selected → `.created(n)`. Without the form (not the account's settings page) it
    ///   creates nothing. A run creates at most once: after a create, later rounds only ask for the page again
    ///   (and select an Eros-FE profile they find).
    ///
    /// A page that does not parse, or an answer that does not show the expected selection, ends the round; after
    /// the third, `.failed` (nothing written). On success, when the site jar's `sp` is not n (the server did not
    /// write it back), it writes `sp=n` into that jar only.
    ///
    /// Request errors are thrown at once, never retried. A site notice (`EHNetworkError.issue`) is thrown as it is
    /// and recorded in the diagnostics as `.stopped`. When the signed-in member id changes while the run waits
    /// (`logOut()`, another login), the run stops with `CancellationError`: no further request, no `sp`, no
    /// diagnostics. Before every request, a select or create in particular, it checks that its session and member
    /// are still the current ones.
    ///
    /// The call belongs to the session it is made in (N7 m6): when that session ends before the run has started
    /// (while the call waits for the cookie store), it throws `CancellationError` and sends nothing. It never starts a
    /// run for the session that followed, with the member the store holds by then (none after a logout).
    public func ensureErosProfile(site: EHSite) async throws -> ProfileOutcome {
        try await ensureErosProfile(site: site, session: generation)
    }

    /// The last profile run of `site` that ended with an outcome or a site notice; nil before one, and after logout.
    public func profileDiagnostics(for site: EHSite) -> ProfileDiagnostics? {
        diagnostics[site]
    }

    /// How many calls are waiting for `site`'s profile run now; 0 when none runs. For the session diagnostics (a
    /// button that starts a run can wait while one runs).
    public func profileCallers(for site: EHSite) -> Int {
        runs[site]?.callers.count ?? 0
    }

    // MARK: - Private: logins

    /// One login: `CookieStore.beginLogin()` (a new epoch; the jars cleared of everything but the UA-bound
    /// Cloudflare cookies, signed in or not), `deliver` brings the new cookies under that epoch, then
    /// `CookieStore.finishLogin(account:sharing:epoch:)` decides and writes in one step: signed in, the shared cookies
    /// go to EX and the account is written; then (`.automatic`) the EH profile run, outside the attempt (the login
    /// stands whatever it does). Rejected, or anything thrown on the way: the store goes back to its snapshot from
    /// before the attempt, then the error is thrown (the restore's own error when that fails too, since the store is
    /// then not as it was). The attempt is a new session (`beginSession()`); when a later one has begun meanwhile
    /// (`logOut()`, another login), no profile run starts and it throws `CancellationError` (or the error it failed
    /// with), leaving nothing of its own: what it brings once the store's epoch has moved on is dropped by the store,
    /// and what it wrote while the epoch was still its own is put back to the snapshot, signed in or not. Whether to
    /// put back is decided by the epoch alone (`restore(_:ifEpoch:)`), never by the generation: a later session that
    /// has reached the store stands, one that has not yet (or whose reset failed) finds the store as before.
    private func attemptLogin(
        method: LoginMethod, username: String?, deliver: (_ epoch: UInt64) async throws -> Void
    ) async throws -> LoginOutcome {
        guard await store.isLoaded else { throw CookieStoreError.notLoaded }
        let attempt = beginSession()
        let start = try await store.beginLogin()
        let memberID: Int
        do {
            try await deliver(start.epoch)
            let account = AccountInfo(method: method, username: username)
            switch try await store.finishLogin(account: account, sharing: Self.sharedCookieNames, epoch: start.epoch) {
            case .signedIn(let signedIn): memberID = signedIn
            case .rejected: throw LoginError.rejected
            case .superseded: throw CancellationError()
            }
        } catch {
            // By the epoch alone (`restore(_:ifEpoch:)`): once a logout's reset or a later login's start has reached
            // the store, that session stands and nothing is put back; until then the attempt's writes are undone,
            // also when a later session has begun here meanwhile.
            _ = try await store.restore(start.before, ifEpoch: start.epoch)
            throw error
        }
        // Signed in, then logged out (or another login began) before the profile run: the login leaves nothing of its
        // own. The store may still be in its epoch, and then holds what it wrote: the store ran the later session's
        // reset or login start before this login's start (an actor may run a job enqueued later first, by priority),
        // or the logout's reset failed. Put back as above; once the epoch has moved on, that session stands.
        guard generation == attempt else {
            _ = try await store.restore(start.before, ifEpoch: start.epoch)
            throw CancellationError()
        }
        if memberID != start.previousMember { diagnostics = [:] }
        return LoginOutcome(memberID: memberID, profile: try await automaticProfile(site: .eh, session: attempt))
    }

    /// The profile run of session `session` (`ensureErosProfile(site:session:)`: the login's own, the EX check's)
    /// when profile selection is automatic, nil when it is off. A site notice becomes `.stopped(issue)`, and so does a
    /// pause of both sites (`EHNetworkError.paused`, as the notice that began it), so the caller stops
    /// sending as for a notice; `CookieStoreError` is thrown; any other error becomes `.failed` (a profile problem
    /// never fails the login or the EX check).
    private func automaticProfile(site: EHSite, session: Int) async throws -> ProfileOutcome? {
        guard profileSelection == .automatic else { return nil }
        do {
            return try await ensureErosProfile(site: site, session: session)
        } catch EHNetworkError.issue(let issue) {
            return .stopped(issue)
        } catch EHNetworkError.paused(let pause) {
            return .stopped(Self.notice(of: pause))
        } catch let error as CookieStoreError {
            throw error
        } catch {
            return .failed
        }
    }

    // MARK: - Private: profile runs

    /// `ensureErosProfile(site:)` in session `session`, the generation its caller read before its first wait. The
    /// member is read afterwards; when the session has moved on by then, `CancellationError` before any run is made
    /// or joined (`checkSession` covers the run from there on).
    private func ensureErosProfile(site: EHSite, session: Int) async throws -> ProfileOutcome {
        guard await store.isLoaded else { throw CookieStoreError.notLoaded }
        let member = await store.memberID
        guard generation == session else { throw CancellationError() }
        let caller = nextToken()
        let run: ProfileRun
        if var current = runs[site], current.member == member, current.generation == session,
           !current.task.isCancelled {
            current.callers.insert(caller)
            runs[site] = current
            run = current
        } else {
            // A run for another member or session is over: it must not send anything more.
            runs[site]?.task.cancel()
            run = ProfileRun(
                id: nextToken(), member: member, generation: session,
                task: Task { try await self.profileRun(site: site, member: member, generation: session) },
                callers: [caller]
            )
            runs[site] = run
        }
        let runID = run.id
        let result = await withTaskCancellationHandler {
            await run.task.result
        } onCancel: {
            Task { await self.leave(site: site, run: runID, caller: caller) }
        }
        if runs[site]?.id == runID { runs[site] = nil }
        return try result.get()
    }

    private func nextToken() -> Int {
        lastToken += 1
        return lastToken
    }

    /// The kind of notice that began `pause`. A ban's remaining time is nil: it was not read from a notice now.
    private static func notice(of pause: SitePause) -> ResponseIssue {
        switch pause.reason {
        case .banned: .banned(remaining: nil)
        case .tooManyRequests: .tooManyRequests
        }
    }

    /// Starts a new session: the generation goes up and every profile run in progress is cancelled (a cancelled
    /// request does not go out, not even one waiting for the throttle). Returns the new generation.
    @discardableResult
    private func beginSession() -> Int {
        generation += 1
        for run in runs.values { run.task.cancel() }
        runs = [:]
        return generation
    }

    /// A caller of run `id` was cancelled: it stops counting, and the run is cancelled when no caller is left.
    private func leave(site: EHSite, run id: Int, caller: Int) {
        guard var run = runs[site], run.id == id else { return }
        run.callers.remove(caller)
        runs[site] = run
        if run.callers.isEmpty { run.task.cancel() }
    }

    /// One shared run: the rounds, then `sp` and the diagnostics; a site notice is recorded, then thrown.
    private func profileRun(site: EHSite, member: Int?, generation session: Int) async throws -> ProfileOutcome {
        let (outcome, serverSetProfileCookie) = try await profileRounds(site: site, member: member, session: session)
        if let number = outcome.profileNumber, await profileCookie(of: site) != String(number) {
            try await checkSession(member: member, session: session)
            try await store.set([CookieNames.profile: String(number)], for: [site])
        }
        let profileCookieAfter = await profileCookie(of: site).flatMap { Int($0) }
        try await checkSession(member: member, session: session)
        diagnostics[site] = ProfileDiagnostics(
            outcome: outcome, serverSetProfileCookie: serverSetProfileCookie, profileCookieAfter: profileCookieAfter
        )
        if case .stopped(let issue) = outcome { throw EHNetworkError.issue(issue) }
        return outcome
    }

    /// The rounds of a profile run, and whether a response set the site's `sp`. A site notice ends them as
    /// `.stopped`; other errors are thrown.
    private func profileRounds(site: EHSite, member: Int?, session: Int) async throws -> (ProfileOutcome, Bool) {
        var serverSet = false
        var hasCreated = false
        do {
            for round in 1...Self.profileRoundLimit {
                if round > 1 {
                    try await Task.sleep(for: retryDelay)
                    try await checkSession(member: member, session: session)
                }
                guard let page = try await settingsPage(
                    for: Self.settingsRequest(site: site), site: site, member: member, session: session, serverSet: &serverSet
                ) else { continue }
                if page.profiles.isEmpty { return (.noProfiles, serverSet) }
                if let selected = page.selectedProfile, selected.name == Self.erosProfileName {
                    return (.alreadySelected(selected.number), serverSet)
                }
                if let eros = page.profiles.first(where: { $0.name == Self.erosProfileName }) {
                    let answer = try await settingsPage(
                        for: EHRequests.selectProfile(eros.number, site: site), site: site, member: member,
                        session: session, serverSet: &serverSet
                    )
                    if answer?.selectedProfile?.number == eros.number { return (.selected(eros.number), serverSet) }
                } else if !hasCreated, !page.form.fields.isEmpty {
                    let known = Set(page.profiles.map(\.number))
                    hasCreated = true
                    let answer = try await settingsPage(
                        for: EHRequests.createProfile(named: Self.erosProfileName, site: site), site: site,
                        member: member, session: session, serverSet: &serverSet
                    )
                    if let created = answer?.selectedProfile, created.name == Self.erosProfileName,
                       !known.contains(created.number) {
                        return (.created(created.number), serverSet)
                    }
                }
            }
        } catch EHNetworkError.issue(let issue) {
            return (.stopped(issue), serverSet)
        }
        return (.failed, serverSet)
    }

    /// A GET of `site`'s settings page that neither reads nor writes the cache: what decides access or a write must
    /// be the site's answer now, never a cached page standing in for a 401, 403 or 503.
    private static func settingsRequest(site: EHSite) -> EHRequest {
        EHRequest(url: EHEndpoints.uconfig(site: site), site: site, cachePolicy: .none)
    }

    /// Sends `request` and reads the answer as a settings page (nil when it does not parse). The session and member
    /// are checked right before sending (no select or create for a session that has ended) and after the answer.
    /// Sets `serverSet` when the response set the site's `sp`: the jar's `sp` changed to a value meanwhile (redirect
    /// hops included), or the final response's Set-Cookie sets it (also when the value stays the same).
    private func settingsPage(
        for request: EHRequest, site: EHSite, member: Int?, session: Int, serverSet: inout Bool
    ) async throws -> UConfigPage? {
        let before = await profileCookie(of: site)
        try await checkSession(member: member, session: session)
        let response = try await client.send(request)
        try await checkSession(member: member, session: session)
        let after = await profileCookie(of: site)
        if (after != nil && after != before) || Self.setsProfileCookie(response, site: site) { serverSet = true }
        return try? UConfigParser.parse(response.text)
    }

    /// Throws `CancellationError` when the session is no longer `session` or the signed-in member id is no longer
    /// `member`.
    private func checkSession(member: Int?, session: Int) async throws {
        let current = await store.memberID
        guard generation == session, current == member else { throw CancellationError() }
    }

    private func profileCookie(of site: EHSite) async -> String? {
        await store.snapshot().cookies[site]?[CookieNames.profile]
    }

    /// Whether `response`'s Set-Cookie sets `site`'s `sp`, by the cookie store's rule for the jar a cookie belongs to.
    private static func setsProfileCookie(_ response: EHResponse, site: EHSite) -> Bool {
        let host = response.url.host() ?? ""
        return SetCookieParser.cookies(headerFields: response.headers, url: response.url).contains { cookie in
            cookie.name == CookieNames.profile && !cookie.isDeletion
                && CookieStore.site(of: cookie, fromHost: host) == site
        }
    }
}

extension ProfileOutcome {
    /// The profile in use after the run, for the outcomes that have one.
    var profileNumber: Int? {
        switch self {
        case .alreadySelected(let number), .selected(let number), .created(let number): number
        case .noProfiles, .failed, .stopped: nil
        }
    }
}
