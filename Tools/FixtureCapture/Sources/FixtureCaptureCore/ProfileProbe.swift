import EHModels
import EHNetwork
import EHParsing
import Foundation

/// What one `uconfig.php` request of `probeProfiles` showed: profile numbers, a status and cookie names, never a
/// cookie value.
public struct ProfileProbeResult: Sendable, Equatable {
    /// The `sp` cookie sent; nil: no sp cookie sent.
    public var sentProfileNumber: Int?
    public var status: Int
    /// The selected option of the page's profile selector (`select[name=profile_set]`, read by `UConfigParser`);
    /// nil when no option is selected, the page cannot be read as a settings page or the answer is a redirect.
    public var selectedProfileNumber: Int?
    /// Names of the cookies the response's `Set-Cookie` sets, sorted and deduplicated; names only.
    public var setCookieNames: [String]
    /// The value of a `Set-Cookie` `sp`, when there is one (a profile number, not a secret): the last `sp` the
    /// response sets; nil when there is none, when it deletes the cookie or when its value is not a number.
    public var setProfileNumber: Int?

    public init(
        sentProfileNumber: Int?, status: Int, selectedProfileNumber: Int?, setCookieNames: [String],
        setProfileNumber: Int?
    ) {
        self.sentProfileNumber = sentProfileNumber
        self.status = status
        self.selectedProfileNumber = selectedProfileNumber
        self.setCookieNames = setCookieNames
        self.setProfileNumber = setProfileNumber
    }

    /// The line `fixture-capture probe-sp` prints:
    /// `sp=<n|none> status=<code> selected=<n|none> set-cookie=<name,…|none> set-sp=<n|none>`. Numbers, the status
    /// and cookie names only.
    public var outputLine: String {
        func number(_ value: Int?) -> String { value.map(String.init) ?? "none" }
        let names = setCookieNames.isEmpty ? "none" : setCookieNames.joined(separator: ",")
        return "sp=\(number(sentProfileNumber)) status=\(status) selected=\(number(selectedProfileNumber)) "
            + "set-cookie=\(names) set-sp=\(number(setProfileNumber))"
    }
}

/// Why `probeProfiles` sent nothing.
public enum ProfileProbeError: Error, Equatable {
    /// More than 3 profile numbers were given (at most 4 requests per site).
    case tooManyProfileNumbers
    /// `EH_SP` is set: the probe chooses the `sp` cookie of each request itself.
    case sharedProfileVariable
    /// A request of the probe would not have been read-only (`CapturePlan.isReadOnly`, GET without a body).
    case notReadOnly
}

/// Most profile numbers one probe sends, after the request without `sp`.
let maximumProbedProfileNumbers = 3

/// GET {base}/uconfig.php once without sp, then once per number (at most 3), strictly one at a time, read-only.
///
/// Each request carries the headers of `capture` (the credentials' user agent, `Accept`, `Accept-Language`, `nw=1`
/// and the credential cookies) except `cf_clearance` and `cf_duid` (`probeExcludedCookies`: Cloudflare ties them to
/// the browser that earned them, and `sp` has nothing to do with them), and the site's receive timeout; the k-th
/// request after the first adds `sp=<numbers[k-1]>`, and none sends `EH_SP`. Redirects are not followed, so the
/// probe makes at most 4 HTTP requests per site. Every request is checked before the first one is sent. After each
/// answer, in this order: 429, 509 or a 5xx stops; a plain-text ban notice stops; a 3xx is reported as a result
/// (status, Set-Cookie names and sp; the `Location` is not read) and the probe goes on with the next number; on
/// ExHentai an empty or non-HTML answer stops; any other status but 200 stops. Nothing is retried and nothing is
/// written.
/// - Parameter onResult: Called with each result as soon as it is read, so a run that stops later keeps what it
///   already learned.
/// - Throws: `ProfileProbeError` before any request; `CaptureAbort` on 429/509/≥500/ban, on ExHentai refusing the
///   cookies, on another status and when a request fails.
public func probeProfiles(
    site: EHSite, numbers: [Int], credentials: CaptureCredentials, transport: any CaptureTransport,
    onResult: (@Sendable (ProfileProbeResult) -> Void)? = nil
) async throws -> [ProfileProbeResult] {
    try await probeProfiles(
        site: site, numbers: numbers, credentials: credentials, transport: transport, onResult: onResult,
        url: URL(string: "https://\(site.host)/uconfig.php")!
    )
}

/// `probeProfiles` requesting `url`; the seam that lets tests use a URL the public entry never builds.
func probeProfiles(
    site: EHSite, numbers: [Int], credentials: CaptureCredentials, transport: any CaptureTransport,
    onResult: (@Sendable (ProfileProbeResult) -> Void)?, url: URL
) async throws -> [ProfileProbeResult] {
    guard numbers.count <= maximumProbedProfileNumbers else { throw ProfileProbeError.tooManyProfileNumbers }
    guard !credentials.setsProfileNumber else { throw ProfileProbeError.sharedProfileVariable }

    let sentNumbers: [Int?] = [nil] + numbers.map(Optional.some)
    let requests = sentNumbers.map { number in
        // Not following redirects keeps the request count at one per number and shows a 3xx's own Set-Cookie.
        var request = CaptureRequest(url: url, followRedirects: false, timeout: RequestDefaults.timeouts(for: site).receive)
        request.headers["User-Agent"] = credentials.userAgent
        request.headers["Accept"] = RequestDefaults.accept
        request.headers["Accept-Language"] = RequestDefaults.acceptLanguage
        if let cookie = credentials.cookieHeader(
            for: url.host() ?? "", includeNW: request.includeNW, excluding: CaptureCredentials.probeExcludedCookies,
            profileNumber: number
        ) {
            request.headers["Cookie"] = cookie
        }
        return request
    }
    // All of them before the first is sent, so a refusal costs no request.
    guard requests.allSatisfy({ $0.method == "GET" && $0.body == nil && CapturePlan.isReadOnly($0, site: site) }) else {
        throw ProfileProbeError.notReadOnly
    }

    var results: [ProfileProbeResult] = []
    for (number, request) in zip(sentNumbers, requests) {
        // Names the request in messages; a profile number is not a secret.
        let label = number.map { "uconfig.php with sp=\($0)" } ?? "uconfig.php without sp"
        let response: CaptureResponse
        do {
            response = try await transport.send(request)
        } catch {
            let masker = Sanitizer(secrets: SecretSet(credentialSecrets: credentials.secrets, extraSecrets: []))
            throw CaptureAbort.transport(site: site, fixturePath: label, message: masker.sanitize(error.localizedDescription))
        }
        let status = response.status
        if status == 429 || status == 509 || status >= 500 {
            throw CaptureAbort.stoppedByServer(site: site, fixturePath: label, status: status)
        }
        let text = response.text
        let isHTML = text.range(of: "<html", options: .caseInsensitive) != nil
        if !isHTML, text.range(of: "banned", options: .caseInsensitive) != nil {
            throw CaptureAbort.banned(site: site, fixturePath: label)
        }
        // Before the ExHentai check: a redirect usually has an empty body.
        let isRedirect = (300..<400).contains(status)
        if !isRedirect {
            if site == .ex, response.body.isEmpty || !isHTML { throw CaptureAbort.exAccessDenied }
            guard status == 200 else { throw CaptureAbort.unexpectedStatus(site: site, fixturePath: label, status: status) }
        }

        // A redirect shows no profile. A page the parser cannot read shows none either; its error could quote the page.
        let selected = isRedirect ? nil : (try? UConfigParser.parse(text))?.profiles.first(where: \.isSelected)?.number
        // The app's own Set-Cookie parser, so the probe sees what the app will.
        let cookies = SetCookieParser.cookies(headerFields: response.headers, url: response.url)
        let setProfile = cookies.last { $0.name == "sp" }.flatMap { $0.isDeletion ? nil : Int($0.value) }
        let result = ProfileProbeResult(
            sentProfileNumber: number, status: status, selectedProfileNumber: selected,
            setCookieNames: Set(cookies.map(\.name)).sorted(), setProfileNumber: setProfile
        )
        results.append(result)
        onResult?(result)
    }
    return results
}
