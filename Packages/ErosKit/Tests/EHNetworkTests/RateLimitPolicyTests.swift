import EHNetwork
import Testing

struct RateLimitPolicyTests {
    /// The bucket key table, shared with the idempotence check.
    static let bucketKeyCases: [(String, String)] = [
        ("e-hentai.org", "group:e-hentai.org"), ("forums.e-hentai.org", "group:e-hentai.org"),
        ("upld.e-hentai.org", "group:e-hentai.org"), ("FORUMS.E-HENTAI.ORG", "group:e-hentai.org"),
        ("exhentai.org", "group:exhentai.org"), ("upld.exhentai.org", "group:exhentai.org"),
        ("s.exhentai.org", "group:s.exhentai.org"), ("ehgt.org", "group:ehgt.org"),
        ("abc123.hath.network", "group:hath.network"), ("hath.network", "host:hath.network"),
        ("notexhentai.org", "host:notexhentai.org"), ("e-hentai.org.example.com", "host:e-hentai.org.example.com"),
        ("ABC123.HATH.NETWORK.", "group:hath.network"), ("abc123.hath.network:8443", "group:hath.network"),
        ("ab.cd.hath.network", "host:ab.cd.hath.network"), ("AB.CD.HATH.NETWORK.", "host:ab.cd.hath.network"),
        ("ab.cd.hath.network:8443", "host:ab.cd.hath.network"), ("-abc.hath.network", "host:-abc.hath.network"),
        ("e-hentai.org.", "group:e-hentai.org"), ("[::1]:443", "host:[::1]"),
        ("e-hentai.org...", "group:e-hentai.org"), ("foo.com:443.", "host:foo.com"),
    ]

    @Test(arguments: bucketKeyCases)
    func bucketKeys(host: String, key: String) {
        #expect(RateLimitPolicy.flutterParity.bucket(for: host).key == key)
    }

    @Test func bucketRules() {
        let policy = RateLimitPolicy.flutterParity
        #expect(policy.bucket(for: "e-hentai.org").rule == TokenBucketRule(capacity: 5, refillInterval: .milliseconds(800)))
        #expect(policy.bucket(for: "ehgt.org").rule == TokenBucketRule(capacity: 20, refillInterval: .milliseconds(400)))
        #expect(policy.bucket(for: "api.github.com").rule == TokenBucketRule(capacity: 10, refillInterval: .milliseconds(500)))
        #expect(policy.minimumHostInterval == .milliseconds(200))
    }

    @Test func hathRulesFollowFlutter() {
        let policy = RateLimitPolicy.flutterParity
        let shared = TokenBucketRule(capacity: 20, refillInterval: .milliseconds(400))
        let perHost = TokenBucketRule(capacity: 10, refillInterval: .milliseconds(500))
        #expect(policy.bucket(for: "abc123.hath.network").rule == shared)
        #expect(policy.bucket(for: "ab.cd.hath.network").rule == perHost)
        #expect(policy.bucket(for: "hath.network").rule == perHost)
    }

    // Beyond the task brief: edge cases of normalizedHost that the bucket key table does not reach.
    static let normalizedHostCases: [(String, String)] = [
        ("E-Hentai.ORG", "e-hentai.org"), ("e-hentai.org.:443", "e-hentai.org"), ("e-hentai.org:", "e-hentai.org"),
        ("[::1]", "[::1]"), ("[::1]:443", "[::1]"), ("::1", "::1"), ("fe80::1:443", "fe80::1:443"),
        // Every trailing dot goes, and a port before one.
        ("e-hentai.org..", "e-hentai.org"), ("e-hentai.org...", "e-hentai.org"), ("foo.com:443.", "foo.com"),
        ("a...", "a"), ("[::1]:443.", "[::1]"), ("", ""), (".", ""),
    ]

    @Test(arguments: normalizedHostCases)
    func normalizedHosts(host: String, normalized: String) {
        #expect(RateLimitPolicy.normalizedHost(host) == normalized)
    }

    /// Normalizing a normalized host changes nothing, so the limiter's queue key, the schedule's bucket and a
    /// cancel all name the same bucket.
    @Test(arguments: bucketKeyCases.map(\.0) + normalizedHostCases.map(\.0) + ["A.B.HATH.NETWORK:8443..", "x:1:2."])
    func normalizingIsIdempotent(host: String) {
        let once = RateLimitPolicy.normalizedHost(host)
        #expect(RateLimitPolicy.normalizedHost(once) == once)
        #expect(RateLimitPolicy.flutterParity.bucket(for: once) == RateLimitPolicy.flutterParity.bucket(for: host))
    }
}
