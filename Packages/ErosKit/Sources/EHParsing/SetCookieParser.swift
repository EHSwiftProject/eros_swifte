import Foundation

/// A cookie from a `Set-Cookie` response header.
public struct ParsedCookie: Sendable, Equatable {
    public let name: String
    public let value: String
    /// The cookie's domain as HTTPCookie writes it: a `Domain` attribute with a leading "." (".e-hentai.org"); a
    /// host-only cookie (no `Domain` attribute) as the bare request host ("forums.e-hentai.org").
    public let domain: String?
    /// nil: a session cookie.
    public let expiresAt: Date?
    /// The header removes the cookie: empty value, "deleted", or already expired.
    public let isDeletion: Bool

    public init(name: String, value: String, domain: String?, expiresAt: Date?, isDeletion: Bool) {
        self.name = name
        self.value = value
        self.domain = domain
        self.expiresAt = expiresAt
        self.isDeletion = isDeletion
    }

    /// Whether a response from (or a request to) `host` may set or receive this cookie: RFC 6265 domain-matching.
    ///
    /// Case-insensitive (ASCII); one trailing "." of `host` and of `domain` is ignored. A `domain` with a leading "."
    /// (a `Domain` attribute) matches the domain itself and its subdomains: `host` equals it without the dot, or ends
    /// with "." + it. A bare `domain` (host-only) and an IP address `host` match only when equal. A nil or empty
    /// `domain` and an empty `host` match nothing.
    ///
    /// `SetCookieParser` does not drop cookies that fail this check (HTTPCookie does not either); callers that store
    /// cookies must check it against the request's host.
    public func domainMatches(host: String) -> Bool {
        guard let domain else { return false }
        let isHostOnly = !domain.hasPrefix(".")
        let cookieDomain = Self.normalizedName(isHostOnly ? Substring(domain) : domain.dropFirst())
        let requestHost = Self.normalizedName(Substring(host))
        guard !cookieDomain.isEmpty, !requestHost.isEmpty else { return false }
        if requestHost == cookieDomain { return true }
        guard !isHostOnly, !Self.isIPAddress(requestHost) else { return false }
        return requestHost.hasSuffix(".\(cookieDomain)")
    }

    /// ASCII-lowercased, one trailing "." dropped.
    private static func normalizedName(_ name: Substring) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            scalars.append(("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar)
        }
        var result = String(scalars)
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }

    /// An IPv6 address (it has a ":"; `URL.host()` gives it without brackets) or a dotted IPv4 address.
    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy { ("0"..."9").contains($0) }
        }
    }
}

/// Reads the cookies of a response's `Set-Cookie` header.
public enum SetCookieParser {
    /// Takes the Set-Cookie value whatever the key's case (EHResponse lowercases header names), then hands it to
    /// HTTPCookie.cookies(withResponseHeaderFields:for:) under the key "Set-Cookie" (the only spelling that API reads),
    /// so one header holding several comma-joined cookies works.
    ///
    /// Keys differing only in case are joined with ", " in sorted key order. A cookie is a deletion when its value is
    /// empty or "deleted", or when it expires at or before `now` or the moment it was received (`Max-Age=0`). Every
    /// cookie HTTPCookie reads is returned, whatever its domain: check `ParsedCookie.domainMatches(host:)` before
    /// storing one.
    public static func cookies(headerFields: [String: String], url: URL, now: Date = Date()) -> [ParsedCookie] {
        let values = headerFields
            .filter { $0.key.caseInsensitiveCompare(headerName) == .orderedSame }
            .sorted { $0.key < $1.key }
            .map(\.value)
        guard !values.isEmpty else { return [] }
        let fields = [headerName: values.joined(separator: ", ")]
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        // HTTPCookie dates a Max-Age expiry from the moment it parses the header, which is no later than this.
        let receivedAt = Date()
        let reference = max(now, receivedAt)
        return parsed.map { cookie in
            let expired = cookie.expiresDate.map { $0 <= reference } ?? false
            return ParsedCookie(
                name: cookie.name,
                value: cookie.value,
                domain: cookie.domain.isEmpty ? nil : cookie.domain,
                expiresAt: cookie.expiresDate,
                isDeletion: cookie.value.isEmpty || cookie.value == deletedValue || expired
            )
        }
    }

    private static let headerName = "Set-Cookie"
    /// The value PHP's `setcookie` sends to delete a cookie.
    private static let deletedValue = "deleted"
}
