import EHFixtures
import EHModels
import EHNetwork
import Foundation

/// Why the capture credentials cannot be used. Cases carry variable names only, never values.
public enum CredentialError: Error, Equatable {
    /// Required variables that are unset or empty, in `CaptureCredentials.environmentKeys` order.
    case missing([String])
    /// `EH_IGNEOUS` is "mystery", the value ExHentai hands to sessions it does not let in.
    case invalidIgneous
    /// `EH_CF_CLEARANCE` is set without `EH_USER_AGENT`; Cloudflare ties a clearance to the browser that earned it.
    case cfClearanceWithoutUserAgent
    /// `EH_SP` is set while capturing more than one site: a profile number selects one site's profile only.
    case sharedProfileNumber
}

/// Cookies and settings for a capture run, read from environment variables only (e.g. injected by `op run`).
/// Printing, debug-printing or dumping it lists the variables that are set, never their values.
public struct CaptureCredentials: Sendable, CustomStringConvertible {
    /// The variable holding the member id, which is also the account's identity on the forums (`showuser=`).
    public static let memberIDVariable = "EH_IPB_MEMBER_ID"

    /// Every variable read, in order. The first 11 are cookies (see `cookieNames`).
    public static let environmentKeys: [String] = [
        "EH_IPB_MEMBER_ID", "EH_IPB_PASS_HASH", "EH_IGNEOUS", "EH_SK", "EH_HATH_PERKS", "EH_STAR", "EH_YAY", "EH_IQ",
        "EH_CF_CLEARANCE", "EH_CF_DUID", "EH_SP", "EH_USER_AGENT", "EH_USERNAME",
    ]

    /// Cookie variables and their cookie names, in header order: the 10 cookies the Flutter app's
    /// `EhCookieInterceptor` sends, plus `sp`, which selects the site profile.
    private static let cookieNames: [(key: String, name: String)] = [
        ("EH_IPB_MEMBER_ID", "ipb_member_id"), ("EH_IPB_PASS_HASH", "ipb_pass_hash"), ("EH_IGNEOUS", "igneous"),
        ("EH_SK", "sk"), ("EH_HATH_PERKS", "hath_perks"), ("EH_STAR", "star"), ("EH_YAY", "yay"), ("EH_IQ", "iq"),
        ("EH_CF_CLEARANCE", "cf_clearance"), ("EH_CF_DUID", "cf_duid"), ("EH_SP", "sp"),
    ]

    /// Hosts, with their subdomains, that receive the login cookies. Image servers (`ehgt.org`, `*.hath.network`)
    /// get none.
    private static let cookieDomains = ["e-hentai.org", "exhentai.org"]

    /// Set variables, trimmed, keyed by name; empty values are dropped.
    private let values: [String: String]

    /// `EH_USER_AGENT`, or `RequestDefaults.chromeUserAgent` when it is not set.
    public let userAgent: String

    /// - Parameter sites: Sites the run captures; `.ex` additionally requires a valid `EH_IGNEOUS`.
    /// - Throws: `CredentialError`, checked in this order: missing variables, an invalid igneous, a clearance
    ///   without a user agent, `EH_SP` with more than one site.
    public init(environment: [String: String], sites: Set<EHSite>) throws {
        var values: [String: String] = [:]
        for key in Self.environmentKeys {
            let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { values[key] = value }
        }
        // The username is not sent, but without it nothing removes it from the fixtures: both sites require it.
        let required: Set<String> = sites.contains(.ex)
            ? ["EH_IPB_MEMBER_ID", "EH_IPB_PASS_HASH", "EH_IGNEOUS", "EH_USERNAME"]
            : ["EH_IPB_MEMBER_ID", "EH_IPB_PASS_HASH", "EH_USERNAME"]
        let missing = Self.environmentKeys.filter { required.contains($0) && values[$0] == nil }
        guard missing.isEmpty else {
            throw CredentialError.missing(missing)
        }
        if sites.contains(.ex), values["EH_IGNEOUS"] == "mystery" {
            throw CredentialError.invalidIgneous
        }
        if values["EH_CF_CLEARANCE"] != nil, values["EH_USER_AGENT"] == nil {
            throw CredentialError.cfClearanceWithoutUserAgent
        }
        if sites.count > 1, values["EH_SP"] != nil {
            throw CredentialError.sharedProfileNumber
        }
        self.values = values
        userAgent = values["EH_USER_AGENT"] ?? RequestDefaults.chromeUserAgent
    }

    /// The `Cookie` header for a request to `host`: `nw=1` first when `includeNW`, then every set cookie as
    /// `name=value` in `environmentKeys` order, joined by "; ".
    /// - Returns: nil unless `host` (any case) is `e-hentai.org`, `exhentai.org` or a subdomain of either.
    public func cookieHeader(for host: String, includeNW: Bool) -> String? {
        cookieHeader(for: host, includeNW: includeNW, excluding: [])
    }

    /// `cookieHeader(for:includeNW:)` without the cookies in `names` (cookie names, e.g. `cf_clearance`).
    public func cookieHeader(for host: String, includeNW: Bool, excluding names: Set<String>) -> String? {
        let host = host.lowercased()
        guard Self.cookieDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return nil }
        let cookies = Self.cookieNames.compactMap { cookie in
            names.contains(cookie.name) ? nil : values[cookie.key].map { "\(cookie.name)=\($0)" }
        }
        return ((includeNW ? ["nw=1"] : []) + cookies).joined(separator: "; ")
    }

    /// The cookie that selects the site profile; `EH_SP` sets it.
    private static let profileCookieName = "sp"

    /// Whether `EH_SP` is set.
    public var setsProfileNumber: Bool {
        values["EH_SP"] != nil
    }

    /// As `cookieHeader(for:includeNW:excluding:)`, with `sp=<profileNumber>` appended when it is given (the `EH_SP`
    /// value is never sent here): the caller chooses the profile of this one request.
    /// - Returns: nil for the hosts `cookieHeader(for:includeNW:)` gives nil for.
    public func cookieHeader(
        for host: String, includeNW: Bool, excluding names: Set<String>, profileNumber: Int?
    ) -> String? {
        guard let header = cookieHeader(
            for: host, includeNW: includeNW, excluding: names.union([Self.profileCookieName])
        ) else { return nil }
        guard let profileNumber else { return header }
        let profile = "\(Self.profileCookieName)=\(profileNumber)"
        return header.isEmpty ? profile : "\(header); \(profile)"
    }

    /// Credential values that must never reach a fixture, classified by `FixtureHygiene.credentialEnvironmentKinds`,
    /// in `environmentKeys` order.
    public var secrets: [KnownSecret] {
        namedSecrets.map(\.secret)
    }

    /// `secrets` with the variable each came from, so warnings can name the variable instead of the value.
    var namedSecrets: [(name: String, secret: KnownSecret)] {
        Self.environmentKeys.compactMap { key in
            guard let kind = FixtureHygiene.credentialEnvironmentKinds[key], let value = values[key] else { return nil }
            return (key, KnownSecret(kind: kind, value: value))
        }
    }

    /// Names of the set variables, in `environmentKeys` order.
    private var setKeys: [String] {
        Self.environmentKeys.filter { values[$0] != nil }
    }

    public var description: String {
        "CaptureCredentials(set: \(setKeys.joined(separator: ", ")))"
    }
}

// Debug-printing or dumping shows the same names-only summary.
extension CaptureCredentials: CustomDebugStringConvertible, CustomReflectable {
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["set": setKeys], displayStyle: .struct) }
}
