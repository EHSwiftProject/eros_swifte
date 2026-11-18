import EHModels
import EHParsing
import Foundation

/// A cookie name or value the store refuses. Carries the name only: the value may be a credential.
public enum CookieValueError: Error, Equatable {
    case invalid(name: String)
}

/// The store refuses a change because the vault has not been read yet.
public enum CookieStoreError: Error, Equatable {
    /// `load()` has not succeeded (and `reset()` has not run) since the store was made.
    case notLoaded
}

/// The only source of the app's site cookies: one jar per site, persisted whole to a `CredentialVault`.
///
/// Every change writes the whole snapshot (JSON) to the vault first; when the write fails it throws and the
/// in-memory state stays as it was. A change that leaves the snapshot as it is writes nothing.
///
/// The store starts not loaded, and writes nothing to the vault until `load()` succeeds: when the Keychain
/// cannot be read for a while (before the first unlock after a restart, a signing problem) or its data does not
/// decode, an empty snapshot must not overwrite the real session. Until then:
/// - `ingest(_:from:)` changes memory only (responses keep working; a later `load()` replaces what it wrote);
/// - `set`, `remove` and `setAccount` throw `CookieStoreError.notLoaded` and change nothing;
/// - `reset()` works as always (it deletes the vault) and leaves the store loaded and empty;
/// - `snapshot()`, `cookieHeader(for:excluding:)`, `isLoggedIn` and `memberID` read memory.
///
/// Names must be RFC 6265 tokens; values must be non-empty and free of CR, LF, ";", U+0000–U+001F and U+007F.
/// `nw` is never stored: every site request starts with `nw=1` anyway.
///
/// Sessions: `epoch` goes up by one on `reset()` (logging out), at the start of every login (`beginLogin()`) and
/// when a failed login puts the store back (`restore(_:ifEpoch:)`). A request takes its Cookie header, cache scope and
/// epoch in one step (`requestIdentity(for:excludingUserAgentBound:)`); the cookies of its responses are written
/// only while the epoch is still that one (`ingest(_:from:epoch:)`), so a response that comes back after a logout or
/// a new login writes nothing, neither into the jars nor into the vault.
public actor CookieStore {
    private let vault: any CredentialVault
    private var state = SessionSnapshot.empty
    /// Whether the vault has been read (or deleted), so `state` may be written back to it.
    public private(set) var isLoaded = false
    /// The session; see the type's documentation. Starts at 0; `load()` does not change it.
    public private(set) var epoch: UInt64 = 0

    public init(vault: any CredentialVault) {
        self.vault = vault
    }

    /// Replaces the state with the vault's snapshot (a missing item gives `.empty`) and marks the store loaded.
    ///
    /// When reading or decoding fails it throws and the store stays as it was, not loaded: nothing is written to
    /// the vault, so a Keychain that cannot be read yet (before the first unlock) keeps the real session, and
    /// `load()` can be called again. A successful load takes the vault's contents over anything `ingest` put in
    /// memory meanwhile.
    public func load() throws {
        let loaded = try vault.read().map { try JSONDecoder().decode(SessionSnapshot.self, from: $0) } ?? .empty
        state = loaded
        isLoaded = true
    }

    public func snapshot() -> SessionSnapshot {
        state
    }

    /// The EH jar has a numeric `ipb_member_id` other than "0" and an `ipb_pass_hash`.
    public var isLoggedIn: Bool {
        guard memberID != nil, let passHash = state.cookies[.eh]?[CookieNames.passHash] else { return false }
        return !passHash.isEmpty
    }

    /// The EH jar's `ipb_member_id` when it is all ASCII digits and not zero.
    public var memberID: Int? {
        Self.memberID(from: state.cookies[.eh]?[CookieNames.memberID])
    }

    /// "nw=1; " then CookieNames.injected in order, then sp, then the rest by name, less `excluding` and, with
    /// `excludingUserAgentBound`, every `CookieNames.isUserAgentBound` name; nil for hosts outside both sites.
    ///
    /// The site is `EHSite(cookieHost:)` of the URL's host, so `ehgt.org`, `*.hath.network` and every other host get nil.
    /// `nw=1` is always first and never excluded.
    public func cookieHeader(for url: URL, excluding: Set<String> = [], excludingUserAgentBound: Bool = false) -> String? {
        guard let site = EHSite(cookieHost: url.host() ?? "") else { return nil }
        let jar = (state.cookies[site] ?? [:]).filter { name, _ in
            name != CookieNames.noWarning && !excluding.contains(name)
                && !(excludingUserAgentBound && CookieNames.isUserAgentBound(name))
        }
        let leading = CookieNames.injected + [CookieNames.profile]
        let rest = jar.keys.filter { !leading.contains($0) }.sorted()
        let pairs = (leading + rest).compactMap { name in jar[name].map { "\(name)=\($0)" } }
        return (["\(CookieNames.noWarning)=1"] + pairs).joined(separator: "; ")
    }

    /// The Cookie header (`cookieHeader(for:excludingUserAgentBound:)`), the cache scope (`cacheScope(for:)`) and the
    /// epoch for a request to `url`, read in one step: all three belong to the same session.
    func requestIdentity(for url: URL, excludingUserAgentBound: Bool) -> RequestIdentity {
        RequestIdentity(
            cookie: cookieHeader(for: url, excludingUserAgentBound: excludingUserAgentBound),
            scope: cacheScope(for: url), epoch: epoch
        )
    }

    /// The cache scope (`cacheScope(for:)`) and the epoch for `url`, read in one step: an answer the response cache
    /// gives under that scope belongs to that session (`EHClient.send(_:)`).
    func cacheIdentity(for url: URL) -> (scope: String, epoch: UInt64) {
        (cacheScope(for: url), epoch)
    }

    /// Sets `cookies` in the jar of every site in `sites`; validates all first; all or nothing.
    ///
    /// Throws `CookieValueError.invalid(name:)` for the first offending name in sorted order and changes nothing.
    /// `nw` is skipped. Throws `CookieStoreError.notLoaded` before a successful `load()`.
    public func set(_ cookies: [String: String], for sites: Set<EHSite>) throws {
        guard isLoaded else { throw CookieStoreError.notLoaded }
        for name in cookies.keys.sorted() where name != CookieNames.noWarning {
            guard Self.isValidName(name), Self.isValidValue(cookies[name]!) else {
                throw CookieValueError.invalid(name: name)
            }
        }
        var next = state
        for site in sites {
            for (name, value) in cookies where name != CookieNames.noWarning {
                next.cookies[site, default: [:]][name] = value
            }
        }
        try commit(next)
    }

    /// `set(_:for:)` while the epoch is `epoch`; otherwise nothing (a login that `logOut()` or another login has
    /// replaced writes nothing).
    func set(_ cookies: [String: String], for sites: Set<EHSite>, epoch: UInt64) throws {
        guard isLoaded else { throw CookieStoreError.notLoaded }
        guard epoch == self.epoch else { return }
        try set(cookies, for: sites)
    }

    /// Removes `names` from the jar of every site in `sites`; names a jar does not hold are ignored.
    /// Throws `CookieStoreError.notLoaded` before a successful `load()`.
    public func remove(_ names: Set<String>, for sites: Set<EHSite>) throws {
        guard isLoaded else { throw CookieStoreError.notLoaded }
        var next = state
        for site in sites {
            for name in names {
                next.cookies[site]?[name] = nil
            }
        }
        try commit(next)
    }

    /// Removes every `CookieNames.isUserAgentBound` cookie from the jar of every site in `sites`.
    /// Throws `CookieStoreError.notLoaded` before a successful `load()`.
    public func removeUserAgentBound(for sites: Set<EHSite>) throws {
        guard isLoaded else { throw CookieStoreError.notLoaded }
        var next = state
        for site in sites {
            next.cookies[site] = next.cookies[site]?.filter { !CookieNames.isUserAgentBound($0.key) }
        }
        try commit(next)
    }

    /// Writes the cookies of a response from `url` into their site's jar; deletions remove.
    ///
    /// The jar a cookie belongs to:
    /// - with a domain (HTTPCookie's form: ".e-hentai.org" for a `Domain` attribute, the bare request host for a
    ///   host-only cookie): the cookie must domain-match the response host (`ParsedCookie.domainMatches(host:)`),
    ///   and the jar is `EHSite(cookieHost:)` of the cookie's domain — never of the response host, because
    ///   `domainMatches` accepts public suffixes such as ".org". So an H@H node cannot set or delete
    ///   ".e-hentai.org" cookies, and an e-hentai.org response cannot touch ".exhentai.org" ones;
    /// - without a domain (nil): the jar is `EHSite(cookieHost:)` of the response host.
    ///
    /// A cookie with no jar is dropped. A deletion follows the same rule, so it removes nothing from another site.
    /// `nw` (the app adds nw=1 itself), igneous "mystery" or "" (deletion or not) and values that fail validation
    /// are skipped. One vault write per call, and none when nothing changed. Before a successful `load()` it
    /// changes memory only and writes nothing (see the type's documentation).
    ///
    /// `epoch`: the session of the request the response answers (`requestIdentity(for:excludingUserAgentBound:)`).
    /// When the store's epoch is no longer that one (logged out, a login began, a failed login put the store back),
    /// the whole batch is dropped: nothing written, nothing thrown. nil: no check.
    public func ingest(_ cookies: [ParsedCookie], from url: URL, epoch: UInt64? = nil) throws {
        if let epoch, epoch != self.epoch { return }
        var next = state
        Self.apply(cookies, fromHost: url.host() ?? "", to: &next)
        try finishIngest(next)
    }

    /// Writes cookies read from a WKWebView's cookie store (the web login, the WebView session bridge's `pull()`)
    /// into their sites' jars, all as one change.
    ///
    /// They come from WebKit's store, not from one response, and WebKit has checked their domains: each counts as a
    /// response from its own domain (without a leading "."), `https://<domain>/`, so both sites' cookies land in their
    /// jars. `fallback` stands in only for a cookie without a domain (an empty domain counts as none). A cookie whose
    /// domain makes no URL is dropped. Otherwise `ingest(_:from:)`'s rules hold: cookies of neither site are dropped,
    /// so are `nw`, igneous "mystery" or "" and invalid values; deletions remove; later cookies win. One vault write,
    /// none when nothing changed; before a successful `load()`, memory only.
    ///
    /// `expectedMemberID`: when not nil, the whole batch is dropped (nothing written, nothing thrown) unless
    /// - the EH jar's member id (`memberID`) is that one at the time: the account the WebView read for has not logged
    ///   out or been replaced meanwhile; and
    /// - every `ipb_member_id` in the batch, of either site and whatever its domain, is that one by `memberID`'s rule
    ///   (ASCII digits, not zero) and is no deletion. This refuses a leftover cookie of an earlier account that the
    ///   bridge's push could not replace (a host-only "forums.e-hentai.org" one, another path) and the forum's
    ///   `ipb_member_id=0` for a session it no longer accepts, which would otherwise sign the user out silently. A
    ///   batch without an `ipb_member_id` passes.
    /// It does not tell an earlier account's other cookies (`ipb_session_id`, `sk`, …) from the current one's: the
    /// WebView store must not keep them across accounts (the app clears it on logging out).
    ///
    /// With `expectedMemberID` nil (the logins, which clear the jars first and then let the cookies
    /// decide) every cookie is taken by the rules above.
    ///
    /// `epoch`: when not nil and no longer the store's epoch, the whole batch is dropped (nothing written, nothing
    /// thrown), as for `ingest(_:from:epoch:)`; the logins pass the epoch `beginLogin()` gave them.
    public func ingestWebViewCookies(
        _ cookies: [ParsedCookie], fallback url: URL, expectedMemberID: Int? = nil, epoch: UInt64? = nil
    ) throws {
        if let epoch, epoch != self.epoch { return }
        if let expectedMemberID {
            guard memberID == expectedMemberID else { return }
            let identities = cookies.filter { $0.name == CookieNames.memberID }
            guard identities.allSatisfy({ !$0.isDeletion && Self.memberID(from: $0.value) == expectedMemberID }) else {
                return
            }
        }
        let fallbackHost = url.host() ?? ""
        var next = state
        for cookie in cookies {
            if let domain = cookie.domain, !domain.isEmpty {
                let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
                guard let source = URL(string: "https://\(host)/"), let sourceHost = source.host() else { continue }
                Self.apply([cookie], fromHost: sourceHost, to: &next)
            } else {
                let hostless = ParsedCookie(
                    name: cookie.name, value: cookie.value, domain: nil, expiresAt: cookie.expiresAt,
                    isDeletion: cookie.isDeletion
                )
                Self.apply([hostless], fromHost: fallbackHost, to: &next)
            }
        }
        try finishIngest(next)
    }

    /// Throws `CookieStoreError.notLoaded` before a successful `load()`.
    public func setAccount(_ account: AccountInfo?) throws {
        guard isLoaded else { throw CookieStoreError.notLoaded }
        var next = state
        next.account = account
        try commit(next)
    }

    /// Changes the account in one step, when the EH jar's member id (`memberID`) is `memberID` and there is an
    /// account; returns whether it did (nothing is written otherwise). For what the forum profile page of a member
    /// showed: a page read for an account that has logged out or been replaced meanwhile is dropped. Throws
    /// `CookieStoreError.notLoaded` before a successful `load()`.
    func updateAccount(ifMember memberID: Int, _ change: @Sendable (inout AccountInfo) -> Void) throws -> Bool {
        guard isLoaded else { throw CookieStoreError.notLoaded }
        guard self.memberID == memberID, var account = state.account else { return false }
        change(&account)
        var next = state
        next.account = account
        try commit(next)
        return true
    }

    // MARK: - Logins

    /// What `beginLogin()` gives a login: its session, and what to put back when it fails.
    struct LoginStart: Sendable {
        /// The login's session: what it writes is dropped once the epoch is another one.
        let epoch: UInt64
        /// The whole state from before the login.
        let before: SessionSnapshot
        /// `memberID` before the login.
        let previousMember: Int?
    }

    /// How `finishLogin(account:sharing:epoch:)` ended.
    enum LoginFinish: Sendable, Equatable {
        /// Signed in as this member; the shared cookies and the account were written.
        case signedIn(Int)
        /// The EH jar holds no numeric, non-zero `ipb_member_id` with an `ipb_pass_hash`; nothing was written.
        case rejected
        /// The epoch is no longer the login's (`logOut()` or another login came meanwhile); nothing was written.
        case superseded
    }

    /// Starts a login: a new session (the epoch goes up by one, so the cookies of a response to a request sent
    /// before are dropped), and, as one change, the jars cleared of every cookie but the UA-bound Cloudflare ones
    /// (`CookieNames.isUserAgentBound`: bound to the device's user agent, not to an account), and the account. Signed
    /// in or not: what the account signed in now or an earlier one left behind
    /// (`hath_perks`, `sk`, `igneous`, `sp`, …) must not be sent with the new account's identity, and an igneous in
    /// the EX jar must not tell ExHentai access for it. Signing in again as the same member therefore starts over
    /// too (its profile run sets `sp` again; ExHentai access is asked again). The state from before is in
    /// `LoginStart.before`, for `restore(_:ifEpoch:)` when the login fails.
    ///
    /// Throws `CookieStoreError.notLoaded` before a successful `load()` (nothing changes), or the vault's error (the
    /// jars stay as they were; the epoch has gone up).
    func beginLogin() throws -> LoginStart {
        guard isLoaded else { throw CookieStoreError.notLoaded }
        epoch += 1
        let start = LoginStart(epoch: epoch, before: state, previousMember: memberID)
        var next = state
        for site in EHSite.allCases {
            next.cookies[site] = next.cookies[site]?.filter { CookieNames.isUserAgentBound($0.key) }
        }
        next.account = nil
        try commit(next)
        return start
    }

    /// Ends a login that `beginLogin()` started with `epoch`, deciding and writing in one step: `.superseded` when the
    /// epoch is another one now; `.rejected` when the EH jar is not signed in (`isLoggedIn`); otherwise the `shared`
    /// names of the EH jar are copied into the EX jar and `account` is written, as one change, and `.signedIn`.
    /// Throws `CookieStoreError.notLoaded` before a successful `load()`, or the vault's error (nothing changes).
    func finishLogin(account: AccountInfo, sharing shared: Set<String>, epoch: UInt64) throws -> LoginFinish {
        guard isLoaded else { throw CookieStoreError.notLoaded }
        guard epoch == self.epoch else { return .superseded }
        guard isLoggedIn, let member = memberID else { return .rejected }
        var next = state
        for (name, value) in state.cookies[.eh] ?? [:] where shared.contains(name) {
            next.cookies[.ex, default: [:]][name] = value
        }
        next.account = account
        try commit(next)
        return .signedIn(member)
    }

    /// Puts the whole state (both jars and the account) back to `snapshot` after a failed login that began with
    /// `epoch`, as one change and as a new session (the epoch goes up by one, so what a response of the failed
    /// attempt brings later is dropped). Returns false and changes nothing when the epoch is no longer `epoch`:
    /// `logOut()` or another login came meanwhile, and that session stands. Throws `CookieStoreError.notLoaded`
    /// before a successful `load()`, or the vault's error (the jars stay as they are; the epoch has gone up).
    ///
    /// Precondition: nothing else changed the store since `snapshot` was taken that should be kept. It is replaced
    /// whole, so cookies another response wrote meanwhile (a new igneous, an sp) go back to their old values too.
    func restore(_ snapshot: SessionSnapshot, ifEpoch epoch: UInt64) throws -> Bool {
        guard isLoaded else { throw CookieStoreError.notLoaded }
        guard epoch == self.epoch else { return false }
        self.epoch += 1
        try commit(snapshot)
        return true
    }

    /// Deletes the vault's item, then forgets everything and begins a new session (the epoch goes up by one);
    /// `snapshot() == .empty` afterwards. When deleting throws, nothing changes.
    ///
    /// Works whether or not the store is loaded (logging out must always be possible), and leaves it loaded:
    /// the vault is known to be empty.
    public func reset() throws {
        try vault.delete()
        state = .empty
        isLoaded = true
        epoch += 1
    }

    /// `raw` as a member id: all ASCII digits, not empty, not zero, fits an `Int`; nil otherwise.
    private static func memberID(from raw: String?) -> Int? {
        guard let raw, !raw.isEmpty,
              raw.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let id = Int(raw), id != 0
        else { return nil }
        return id
    }

    /// `ingest`'s rules for the cookies of one response from `host`, applied to `next`.
    private static func apply(_ cookies: [ParsedCookie], fromHost host: String, to next: inout SessionSnapshot) {
        for cookie in cookies {
            guard cookie.name != CookieNames.noWarning, let site = site(of: cookie, fromHost: host) else { continue }
            if cookie.name == CookieNames.igneous, cookie.value.isEmpty || cookie.value == CookieNames.mysteryIgneous {
                continue
            }
            if cookie.isDeletion {
                next.cookies[site]?[cookie.name] = nil
            } else if isValidName(cookie.name), isValidValue(cookie.value) {
                next.cookies[site, default: [:]][cookie.name] = cookie.value
            }
        }
    }

    /// What ingested cookies end with: `commit(next)` once loaded, before that memory only.
    private func finishIngest(_ next: SessionSnapshot) throws {
        if isLoaded {
            try commit(next)
        } else {
            state = Self.normalized(next)
        }
    }

    /// Writes `next` to the vault, then adopts it; jars left empty are dropped first. Never writes before `load()`.
    private func commit(_ next: SessionSnapshot) throws {
        guard isLoaded else { throw CookieStoreError.notLoaded }
        let next = Self.normalized(next)
        guard next != state else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try vault.write(encoder.encode(next))
        state = next
    }

    /// `snapshot` without empty jars.
    private static func normalized(_ snapshot: SessionSnapshot) -> SessionSnapshot {
        var snapshot = snapshot
        snapshot.cookies = snapshot.cookies.filter { !$0.value.isEmpty }
        return snapshot
    }

    /// The jar a response cookie belongs to; see `ingest(_:from:)`. Internal: `AccountService` reads a response's
    /// `sp` by the same rule.
    static func site(of cookie: ParsedCookie, fromHost host: String) -> EHSite? {
        guard let domain = cookie.domain else { return EHSite(cookieHost: host) }
        guard cookie.domainMatches(host: host) else { return nil }
        return EHSite(cookieHost: domain)
    }

    /// An RFC 6265 cookie-name: a non-empty token (ASCII letters, digits and ! # $ % & ' * + - . ^ _ ` | ~).
    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9": true
            default: "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
            }
        }
    }

    /// Non-empty, without ";" and the C0 controls and DEL (which include CR and LF).
    private static func isValidValue(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar != ";" && scalar.value > 0x1F && scalar.value != 0x7F
        }
    }
}

extension CookieStore {
    /// "<member id or anonymous>|<sp or ->" of `url`'s site, the scope of the response cache.
    ///
    /// The member id and `sp` come from that site's jar (a numeric, non-zero `ipb_member_id`; `sp`, the profile).
    /// A URL outside both sites (`ehgt.org`, `*.hath.network`, …) gets "anonymous|-": such requests carry no
    /// cookie, so what they return does not depend on the account.
    public func cacheScope(for url: URL) -> String {
        guard let site = EHSite(cookieHost: url.host() ?? "") else { return "anonymous|-" }
        let jar = snapshot().cookies[site] ?? [:]
        var member = "anonymous"
        if let raw = jar[CookieNames.memberID], !raw.isEmpty,
           raw.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
           let id = Int(raw), id != 0 {
            member = String(id)
        }
        let profile = jar[CookieNames.profile].flatMap { $0.isEmpty ? nil : $0 } ?? "-"
        return "\(member)|\(profile)"
    }
}

extension CookieStore: CustomReflectable {
    /// No children: the jars hold credentials.
    public nonisolated var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .class)
    }
}

/// What one request takes from the cookie store (`CookieStore.requestIdentity(for:excludingUserAgentBound:)`).
///
/// `description` and the mirror show the epoch only: the Cookie header holds credentials.
struct RequestIdentity: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    /// The Cookie header; nil for a host outside both sites.
    let cookie: String?
    /// The response cache scope ("<member id or anonymous>|<sp or ->").
    let scope: String
    /// The session it was read in.
    let epoch: UInt64

    var description: String {
        "RequestIdentity(epoch: \(epoch))"
    }

    var customMirror: Mirror {
        Mirror(self, children: ["description": description])
    }
}
