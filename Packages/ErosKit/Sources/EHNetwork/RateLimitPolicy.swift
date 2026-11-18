/// Token bucket parameters: `capacity` tokens, one refilled every `refillInterval`.
public struct TokenBucketRule: Sendable, Equatable {
    public let capacity: Int
    public let refillInterval: Duration

    public init(capacity: Int, refillInterval: Duration) {
        // A zero capacity never yields a token and a zero interval divides by zero in the scheduler.
        precondition(capacity > 0, "a token bucket needs at least one token")
        precondition(refillInterval > .zero, "a token bucket needs a positive refill interval")
        self.capacity = capacity
        self.refillInterval = refillInterval
    }
}

/// The bucket a host draws from, identified by `key`.
public struct BucketAssignment: Sendable, Equatable {
    public let key: String
    public let rule: TokenBucketRule

    public init(key: String, rule: TokenBucketRule) {
        self.key = key
        self.rule = rule
    }
}

/// A set of hosts that share one token bucket under `key`.
///
/// `domain` is compared byte for byte with normalized hosts (see `RateLimitPolicy.normalizedHost(_:)`),
/// so give it in lowercase without a trailing dot.
public struct HostGroup: Sendable, Equatable {
    public enum Match: Sendable, Equatable {
        /// The domain itself and every name ending in "." + domain.
        case domainAndSubdomains
        /// Exactly one label before the domain: 1–63 of [a-z0-9-], not starting or ending with "-" (Flutter's H@H regex).
        case singleLabelSubdomains
    }

    public let key: String
    public let domain: String
    public let match: Match
    public let rule: TokenBucketRule

    public init(key: String, domain: String, match: Match, rule: TokenBucketRule) {
        self.key = key
        self.domain = domain
        self.match = match
        self.rule = rule
    }

    /// Whether `host`, already normalized, belongs to this group.
    func contains(_ host: String) -> Bool {
        let hostBytes = Array(host.utf8), domainBytes = Array(domain.utf8)
        if hostBytes == domainBytes { return match == .domainAndSubdomains }
        // `dot` is where "." + domain starts.
        let dot = hostBytes.count - domainBytes.count - 1
        guard dot >= 0, hostBytes[dot] == UInt8(ascii: "."), hostBytes[(dot + 1)...].elementsEqual(domainBytes) else {
            return false
        }
        switch match {
        case .domainAndSubdomains:
            return true
        case .singleLabelSubdomains:
            return Self.isFlutterHathLabel(hostBytes[..<dot])
        }
    }

    /// Flutter's `^(?!-)[a-zA-Z0-9-]{1,63}(?<!-)` on a lowercased label. The regex's unescaped "." that
    /// follows it (which also accepts "abcXhath.network") is deliberately not reproduced.
    private static func isFlutterHathLabel(_ label: ArraySlice<UInt8>) -> Bool {
        let hyphen = UInt8(ascii: "-")
        guard (1...63).contains(label.count), label.first != hyphen, label.last != hyphen else { return false }
        return label.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == hyphen
        }
    }
}

/// Maps hosts to token buckets. Tuned values that avoid account bans; keep in sync with the Flutter app.
public struct RateLimitPolicy: Sendable {
    /// Minimum gap between two requests to the same host.
    public let minimumHostInterval: Duration

    private let groups: [HostGroup]
    private let defaultRule: TokenBucketRule

    /// The Flutter app's limits (`lib/network/app_dio/app_dio.dart:90-109`, user decision 2026-11-05).
    /// Single-label H@H hosts share one bucket because Flutter keys them by its H@H regex
    /// (`token_bucket_interceptor.dart:123-125`); two-label H@H hosts miss that regex and get a bucket
    /// each under the default rule. Ports never matter: Flutter keys by `uri.host`.
    public static let flutterParity = RateLimitPolicy(
        minimumHostInterval: .milliseconds(200),
        groups: [
            HostGroup(key: "group:hath.network", domain: "hath.network", match: .singleLabelSubdomains,
                      rule: TokenBucketRule(capacity: 20, refillInterval: .milliseconds(400))),
            HostGroup(key: "group:ehgt.org", domain: "ehgt.org", match: .domainAndSubdomains,
                      rule: TokenBucketRule(capacity: 20, refillInterval: .milliseconds(400))),
            HostGroup(key: "group:s.exhentai.org", domain: "s.exhentai.org", match: .domainAndSubdomains,
                      rule: TokenBucketRule(capacity: 20, refillInterval: .milliseconds(400))),
            HostGroup(key: "group:e-hentai.org", domain: "e-hentai.org", match: .domainAndSubdomains,
                      rule: TokenBucketRule(capacity: 5, refillInterval: .milliseconds(800))),
            HostGroup(key: "group:exhentai.org", domain: "exhentai.org", match: .domainAndSubdomains,
                      rule: TokenBucketRule(capacity: 5, refillInterval: .milliseconds(800))),
        ],
        defaultRule: TokenBucketRule(capacity: 10, refillInterval: .milliseconds(500))
    )

    /// `groups` are tried in order and the first match wins; hosts that match none get a bucket each under `defaultRule`.
    public init(minimumHostInterval: Duration, groups: [HostGroup], defaultRule: TokenBucketRule) {
        self.minimumHostInterval = minimumHostInterval
        self.groups = groups
        self.defaultRule = defaultRule
    }

    /// Returns the bucket for `host`, normalized first. Groups are tried in order and the first match wins;
    /// every host of a group shares the group's bucket. Any other host gets `host:<normalized host>`.
    public func bucket(for host: String) -> BucketAssignment {
        bucket(forNormalizedHost: Self.normalizedHost(host))
    }

    /// `bucket(for:)` of a host that is already normalized (`normalizedHost(_:)`), as it is.
    func bucket(forNormalizedHost h: String) -> BucketAssignment {
        for group in groups where group.contains(h) {
            return BucketAssignment(key: group.key, rule: group.rule)
        }
        return BucketAssignment(key: "host:\(h)", rule: defaultRule)
    }

    /// Lowercased; then a ":port" suffix and a trailing "." are dropped, again and again until neither is left
    /// (bracketed IPv6 keeps its colons). So "e-hentai.org..." and "foo.com:443." become "e-hentai.org" and
    /// "foo.com", and normalizing a normalized host changes nothing.
    ///
    /// The port is only recognised as ":" plus ASCII digits after the last label, or after "]" of a bracketed
    /// literal. An unbracketed IPv6 address has two or more colons and is left as it is.
    public static func normalizedHost(_ host: String) -> String {
        var h = host.lowercased()
        // Every round that changes something makes the string shorter, so this ends.
        while true {
            let next = droppingPortOrTrailingDot(h)
            if next == h { return h }
            h = next
        }
    }

    /// `h` without its ":port" suffix, then without one trailing ".".
    private static func droppingPortOrTrailingDot(_ host: String) -> String {
        var h = host
        if h.hasPrefix("[") {
            if let close = h.firstIndex(of: "]"), isPortSuffix(h[h.index(after: close)...]) {
                h = String(h[...close])
            }
        } else if let colon = h.firstIndex(of: ":"), isPortSuffix(h[colon...]) {
            h = String(h[..<colon])
        }
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// True for "" or ":" followed by ASCII digits only.
    private static func isPortSuffix(_ s: Substring) -> Bool {
        guard let first = s.utf8.first else { return true }
        return first == UInt8(ascii: ":") && s.utf8.dropFirst().allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }
}
