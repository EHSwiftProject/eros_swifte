import EHModels
import EHNetwork
import EHParsing
import Foundation

/// How one probed page compares with the M0 sample of the same kind.
public struct StructureProbeResult: Sendable, Equatable {
    public let site: EHSite
    public let kind: PageKind
    public let status: Int
    /// `StructureSignature.differences`; empty: the structure is the same.
    public let differences: [String]
}

/// Why a probe could not compare a page; paths and page kinds only.
public enum StructureProbeError: Error, Equatable {
    /// The M0 sample is missing or not readable.
    case sampleUnreadable(path: String)
    /// The page before this one held no link to follow.
    case noLink(from: PageKind)
    /// A request of the probe would not have been read-only (`CapturePlan.isReadOnly`); nothing was sent for it.
    case notReadOnly(kind: PageKind)
}

extension CaptureCredentials {
    /// Cookies the probes (`probeStructure`, `probeProfiles`) leave out: Cloudflare ties them to the user agent that
    /// earned them.
    static let probeExcludedCookies: Set<String> = ["cf_clearance", "cf_duid"]
}

/// One site per run, strictly one request at a time and read-only: GET the front page with the M0 Disable Filters
/// parameters, then the first gallery found there, then that gallery's first image page; each compared with the M0
/// sample (`{s}/list/front.html`, `{s}/gallery/detail.html`, `{s}/image/page.html`). Sends `userAgent` and no
/// cf_clearance or cf_duid (they are bound to another UA). Writes nothing.
/// - Parameter onResult: Called with each page's result as soon as it is compared, so a run that stops later keeps
///   what it already learned.
/// - Throws: `CaptureAbort` on 429, 509, 5xx, a ban notice or another unexpected answer; `StructureProbeError`.
public func probeStructure(
    site: EHSite, userAgent: String, credentials: CaptureCredentials, fixturesRoot: URL,
    transport: any CaptureTransport, onResult: (@Sendable (StructureProbeResult) -> Void)? = nil
) async throws -> [StructureProbeResult] {
    try await probeStructure(
        site: site, userAgent: userAgent, credentials: credentials, fixturesRoot: fixturesRoot, transport: transport,
        onResult: onResult, startURL: CapturePlan.disablingFilters(URL(string: "https://\(site.host)/")!)
    )
}

/// `probeStructure` starting from `startURL`; the seam that lets tests start from a URL the public entry never builds.
func probeStructure(
    site: EHSite, userAgent: String, credentials: CaptureCredentials, fixturesRoot: URL,
    transport: any CaptureTransport, onResult: (@Sendable (StructureProbeResult) -> Void)?, startURL: URL
) async throws -> [StructureProbeResult] {
    let base = "https://\(site.host)"
    // Read every sample first, so a missing one costs no request.
    var samples: [PageKind: StructureSignature] = [:]
    let samplePaths: [PageKind: String] = [
        .list: "\(site.rawValue)/list/front.html", .detail: "\(site.rawValue)/gallery/detail.html",
        .image: "\(site.rawValue)/image/page.html",
    ]
    for kind in PageKind.allCases {
        let path = samplePaths[kind]!
        guard let data = try? Data(contentsOf: fixturesRoot.appending(path: path)),
              let signature = try? StructureSignature.of(String(decoding: data, as: UTF8.self), kind: kind) else {
            throw StructureProbeError.sampleUnreadable(path: path)
        }
        samples[kind] = signature
    }

    var results: [StructureProbeResult] = []
    var url = startURL
    for kind in PageKind.allCases {
        let label = samplePaths[kind]!
        var request = CaptureRequest(url: url, timeout: RequestDefaults.timeouts(for: site).receive)
        request.headers["User-Agent"] = userAgent
        request.headers["Accept"] = RequestDefaults.accept
        request.headers["Accept-Language"] = RequestDefaults.acceptLanguage
        if let cookie = credentials.cookieHeader(
            for: url.host() ?? "", includeNW: request.includeNW, excluding: CaptureCredentials.probeExcludedCookies
        ) {
            request.headers["Cookie"] = cookie
        }
        guard CapturePlan.isReadOnly(request, site: site) else {
            throw StructureProbeError.notReadOnly(kind: kind)
        }

        let response: CaptureResponse
        do {
            response = try await transport.send(request)
        } catch {
            let masker = Sanitizer(secrets: SecretSet(credentialSecrets: credentials.secrets, extraSecrets: []))
            throw CaptureAbort.transport(
                site: site, fixturePath: label, message: masker.sanitize(error.localizedDescription)
            )
        }
        let text = response.text
        let status = response.status
        if status == 429 || status == 509 || status >= 500 {
            throw CaptureAbort.stoppedByServer(site: site, fixturePath: label, status: status)
        }
        let isHTML = text.range(of: "<html", options: .caseInsensitive) != nil
        if !isHTML, text.range(of: "banned", options: .caseInsensitive) != nil {
            throw CaptureAbort.banned(site: site, fixturePath: label)
        }
        if site == .ex, !isHTML { throw CaptureAbort.exAccessDenied }
        guard status == 200 else { throw CaptureAbort.unexpectedStatus(site: site, fixturePath: label, status: status) }

        let signature: StructureSignature
        do {
            signature = try StructureSignature.of(text, kind: kind)
        } catch {
            // The parser's message could quote the page.
            throw CaptureAbort.transport(site: site, fixturePath: label, message: "the page could not be parsed.")
        }
        let result = StructureProbeResult(
            site: site, kind: kind, status: status, differences: signature.differences(from: samples[kind]!)
        )
        results.append(result)
        onResult?(result)

        // The link to the next page of the walk.
        switch kind {
        case .list:
            guard let gallery = LinkExtractor.galleries(in: text).first,
                  let next = URL(string: "\(base)/g/\(gallery.gid)/\(gallery.token)/") else {
                throw StructureProbeError.noLink(from: .list)
            }
            url = next
        case .detail:
            guard let page = LinkExtractor.imagePageURLs(in: text).first, page.host()?.lowercased() == site.host else {
                throw StructureProbeError.noLink(from: .detail)
            }
            url = page
        case .image:
            break
        }
    }
    return results
}
