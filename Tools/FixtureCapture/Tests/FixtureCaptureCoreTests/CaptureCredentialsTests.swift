import EHFixtures
import EHModels
import EHNetwork
import FixtureCaptureCore
import Foundation
import Testing

// Fake credentials; none of these values is real. Assertions only ever see Booleans derived from them, so a
// failure cannot print a value.
private let fakeMemberID = "1234567"
private let fakePassHash = "f0e1d2c3b4a5968778695a4b3c2d1e0f"

private let requiredEnvironment: [String: String] = [
    "EH_IPB_MEMBER_ID": fakeMemberID,
    "EH_IPB_PASS_HASH": fakePassHash,
    "EH_USERNAME": "ZqUser",
]

private func environment(adding extra: [String: String]) -> [String: String] {
    requiredEnvironment.merging(extra) { _, new in new }
}

@Suite struct CaptureCredentialsTests {
    @Test func sharedProfileNumberIsRefusedForTwoSites() throws {
        let withProfile = environment(adding: ["EH_IGNEOUS": "9f8e7d6c5b4a", "EH_SP": "7"])
        #expect(throws: CredentialError.sharedProfileNumber) {
            try CaptureCredentials(environment: withProfile, sites: [.eh, .ex])
        }
        _ = try CaptureCredentials(environment: withProfile, sites: [.eh])
        _ = try CaptureCredentials(environment: withProfile, sites: [.ex])
    }

    @Test func sharedProfileCheckComesAfterMissing() {
        #expect(throws: CredentialError.missing(["EH_USERNAME"])) {
            try CaptureCredentials(
                environment: ["EH_IPB_MEMBER_ID": fakeMemberID, "EH_IPB_PASS_HASH": fakePassHash, "EH_IGNEOUS": "9f8e7d6c5b4a", "EH_SP": "7"],
                sites: [.eh, .ex]
            )
        }
    }

    @Test func environmentKeysAreInCookieOrder() {
        #expect(CaptureCredentials.environmentKeys == [
            "EH_IPB_MEMBER_ID", "EH_IPB_PASS_HASH", "EH_IGNEOUS", "EH_SK", "EH_HATH_PERKS", "EH_STAR", "EH_YAY",
            "EH_IQ", "EH_CF_CLEARANCE", "EH_CF_DUID", "EH_SP", "EH_USER_AGENT", "EH_USERNAME",
        ])
    }

    @Test func requiresMemberIDPassHashAndUsername() {
        #expect(throws: CredentialError.missing(["EH_IPB_MEMBER_ID", "EH_IPB_PASS_HASH", "EH_USERNAME"])) {
            try CaptureCredentials(environment: [:], sites: [.eh])
        }
        // Empty and blank values count as missing.
        #expect(throws: CredentialError.missing(["EH_IPB_MEMBER_ID", "EH_IPB_PASS_HASH", "EH_USERNAME"])) {
            try CaptureCredentials(
                environment: ["EH_IPB_MEMBER_ID": "", "EH_IPB_PASS_HASH": "  ", "EH_USERNAME": " "], sites: [.eh]
            )
        }
        #expect(throws: CredentialError.missing(["EH_IPB_MEMBER_ID", "EH_IPB_PASS_HASH", "EH_IGNEOUS", "EH_USERNAME"])) {
            try CaptureCredentials(environment: ["EH_SK": "fakesk0123"], sites: [.eh, .ex])
        }
    }

    @Test func usernameIsRequiredForEachSite() throws {
        let withoutUsername = requiredEnvironment.filter { $0.key != "EH_USERNAME" }
        for sites: Set<EHSite> in [[.eh], [.ex]] {
            let environment = sites.contains(.ex) ? withoutUsername.merging(["EH_IGNEOUS": "0a1b2c3d4e"]) { _, new in new } : withoutUsername
            #expect(throws: CredentialError.missing(["EH_USERNAME"])) {
                try CaptureCredentials(environment: environment, sites: sites)
            }
        }
    }

    @Test func exRequiresValidIgneous() throws {
        #expect(throws: CredentialError.missing(["EH_IGNEOUS"])) {
            try CaptureCredentials(environment: requiredEnvironment, sites: [.ex])
        }
        let mystery = environment(adding: ["EH_IGNEOUS": "mystery"])
        #expect(throws: CredentialError.invalidIgneous) {
            try CaptureCredentials(environment: mystery, sites: [.eh, .ex])
        }
        // EH alone needs no igneous, valid or not.
        _ = try CaptureCredentials(environment: requiredEnvironment, sites: [.eh])
        _ = try CaptureCredentials(environment: mystery, sites: [.eh])
        _ = try CaptureCredentials(environment: environment(adding: ["EH_IGNEOUS": "0a1b2c3d4e"]), sites: [.ex])
    }

    @Test func cfClearanceRequiresUserAgent() throws {
        let clearance = environment(adding: ["EH_CF_CLEARANCE": "fakeclearance0123"])
        #expect(throws: CredentialError.cfClearanceWithoutUserAgent) {
            try CaptureCredentials(environment: clearance, sites: [.eh])
        }
        let credentials = try CaptureCredentials(
            environment: clearance.merging(["EH_USER_AGENT": "TestAgent/1.0"]) { _, new in new },
            sites: [.eh]
        )
        #expect(credentials.userAgent == "TestAgent/1.0")
    }

    @Test func checksRunInOrder() {
        // Missing variables are reported before an invalid igneous, which comes before the user agent check.
        #expect(throws: CredentialError.missing(["EH_IPB_PASS_HASH"])) {
            try CaptureCredentials(
                environment: [
                    "EH_IPB_MEMBER_ID": fakeMemberID, "EH_USERNAME": "ZqUser", "EH_IGNEOUS": "mystery",
                    "EH_CF_CLEARANCE": "fakeclearance0123",
                ],
                sites: [.ex]
            )
        }
        #expect(throws: CredentialError.invalidIgneous) {
            try CaptureCredentials(
                environment: environment(adding: ["EH_IGNEOUS": "mystery", "EH_CF_CLEARANCE": "fakeclearance0123"]),
                sites: [.ex]
            )
        }
    }

    @Test func cookieHeaderScopesToSiteFamilies() throws {
        let credentials = try CaptureCredentials(environment: requiredEnvironment, sites: [.eh])
        for host in ["e-hentai.org", "forums.e-hentai.org", "s.exhentai.org", "exhentai.org", "E-Hentai.ORG"] {
            let header = credentials.cookieHeader(for: host, includeNW: true)
            let scoped = header.map { $0.contains("nw=1") && $0.contains("ipb_member_id=1234567") } ?? false
            #expect(scoped, "no site cookies for \(host)")
        }
        for host in ["ehgt.org", "abc.hath.network", "fake-e-hentai.org", "e-hentai.org.example.com"] {
            let sent = credentials.cookieHeader(for: host, includeNW: true) != nil
            #expect(sent == false, "cookies sent to \(host)")
        }
    }

    @Test func cookieHeaderListsSetCookiesInOrder() throws {
        let credentials = try CaptureCredentials(
            environment: environment(adding: [
                "EH_SP": "2", "EH_SK": "fakesk0123", "EH_IGNEOUS": "fakeigneous01", "EH_USERNAME": "ZqUser",
                "EH_USER_AGENT": "TestAgent/1.0", "EH_STAR": "",
            ]),
            sites: [.ex]
        )
        let header = credentials.cookieHeader(for: "exhentai.org", includeNW: true)
        let expected = "nw=1; ipb_member_id=1234567; ipb_pass_hash=\(fakePassHash); igneous=fakeigneous01; sk=fakesk0123; sp=2"
        let exact = header == expected
        #expect(exact, "cookie header differs from the expected order or set")
    }

    @Test func includeNWFalseOmitsNW() throws {
        let credentials = try CaptureCredentials(environment: requiredEnvironment, sites: [.eh])
        let header = credentials.cookieHeader(for: "e-hentai.org", includeNW: false)
        let omitted = header.map { !$0.contains("nw=") && $0.hasPrefix("ipb_member_id=1234567; ") } ?? false
        #expect(omitted)
    }

    @Test func userAgentDefaultsToChrome() throws {
        let credentials = try CaptureCredentials(environment: requiredEnvironment, sites: [.eh])
        #expect(credentials.userAgent == RequestDefaults.chromeUserAgent)
    }

    @Test func secretsFollowCredentialKinds() throws {
        let credentials = try CaptureCredentials(
            environment: environment(adding: [
                "EH_USERNAME": "ZqUser", "EH_SP": "2", "EH_USER_AGENT": "TestAgent/1.0", "EH_SK": "fakesk0123",
            ]),
            sites: [.eh]
        )
        let expected = [
            KnownSecret(kind: .numeric, value: fakeMemberID),
            KnownSecret(kind: .literal, value: fakePassHash),
            KnownSecret(kind: .literal, value: "fakesk0123"),
            KnownSecret(kind: .word, value: "ZqUser"),
        ]
        // KnownSecret descriptions are redacted, so comparing them is safe to print.
        #expect(credentials.secrets == expected)
    }

    @Test func descriptionDoesNotLeakValues() throws {
        let values = environment(adding: ["EH_SK": "fakesk0123", "EH_USERNAME": "ZqUser", "EH_USER_AGENT": "TestAgent/1.0"])
        let credentials = try CaptureCredentials(environment: values, sites: [.eh])
        let description = String(describing: credentials)
        let listsSetNames = description.contains("EH_IPB_PASS_HASH") && description.contains("EH_USERNAME")
        #expect(listsSetNames)
        let listsUnsetName = description.contains("EH_IGNEOUS")
        #expect(listsUnsetName == false, "unset variables are not listed")
        var dumped = ""
        dump(credentials, to: &dumped)
        for rendering in [description, String(reflecting: credentials), dumped] {
            let leaked = values.values.contains { rendering.contains($0) }
            #expect(leaked == false, "a credential value appears in a rendering")
        }
    }
}

@Suite struct CaptureCredentialsExclusionTests {
    @Test func excludedCookiesAreLeftOut() throws {
        let credentials = try CaptureCredentials(
            environment: environment(adding: ["EH_CF_CLEARANCE": "fakeclr0123", "EH_CF_DUID": "fakeduid0123", "EH_SK": "fakesk0123", "EH_USER_AGENT": "Fake UA"]),
            sites: [.eh]
        )
        let full = try #require(credentials.cookieHeader(for: "e-hentai.org", includeNW: true))
        let reduced = try #require(
            credentials.cookieHeader(for: "e-hentai.org", includeNW: true, excluding: ["cf_clearance", "cf_duid"])
        )
        #expect(full.contains("cf_clearance=") && full.contains("cf_duid="))
        #expect(!reduced.contains("cf_clearance") && !reduced.contains("cf_duid"))
        // The rest keeps its order.
        let kept = full.split(separator: "; ").filter { !$0.hasPrefix("cf_clearance=") && !$0.hasPrefix("cf_duid=") }
        #expect(reduced == kept.joined(separator: "; "))
        #expect(credentials.cookieHeader(for: "example.com", includeNW: true, excluding: []) == nil)
    }
}

@Suite struct CaptureCredentialsProfileNumberTests {
    @Test func profileNumberOverrideIsAppended() throws {
        let credentials = try CaptureCredentials(
            environment: environment(adding: ["EH_SP": "2", "EH_SK": "fakesk0123"]), sites: [.eh]
        )
        #expect(credentials.setsProfileNumber)
        let unset = try CaptureCredentials(environment: requiredEnvironment, sites: [.eh])
        #expect(unset.setsProfileNumber == false)

        // The sp pieces hold profile numbers only, so comparing them is safe to print.
        func profilePieces(_ header: String) -> [Substring] {
            header.split(separator: "; ").filter { $0.hasPrefix("sp=") }
        }
        let header = try #require(
            credentials.cookieHeader(for: "e-hentai.org", includeNW: true, excluding: [], profileNumber: 7)
        )
        let endsWithOverride = header.hasSuffix("; sp=7")
        #expect(endsWithOverride)
        #expect(profilePieces(header) == ["sp=7"])

        // nil: no sp at all, not even EH_SP's; the rest as cookieHeader(for:includeNW:excluding:) without sp.
        let without = try #require(
            credentials.cookieHeader(for: "e-hentai.org", includeNW: true, excluding: [], profileNumber: nil)
        )
        #expect(profilePieces(without).isEmpty)
        let sameAsExcluding = without == credentials.cookieHeader(for: "e-hentai.org", includeNW: true, excluding: ["sp"])
        #expect(sameAsExcluding)
        let sameRest = header == without + "; sp=7"
        #expect(sameRest)

        // Exclusions and host scoping still apply.
        let reduced = try #require(
            credentials.cookieHeader(for: "e-hentai.org", includeNW: false, excluding: ["sk"], profileNumber: 3)
        )
        let reducedAsExpected = !reduced.contains("sk=") && !reduced.hasPrefix("nw=1") && reduced.hasSuffix("; sp=3")
        #expect(reducedAsExpected)
        #expect(credentials.cookieHeader(for: "ehgt.org", includeNW: true, excluding: [], profileNumber: 7) == nil)
    }
}
