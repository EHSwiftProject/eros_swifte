import EHFixtures
import EHModels
import EHNetwork
@testable import FixtureCaptureCore
import Foundation
import Synchronization
import Testing

// Every page, cookie and credential here is made up; the settings page only follows the structure of
// eh/account/uconfig.html (a `profile_form` with a `profile_set` selector), not its text.

/// The profile numbers the made-up settings page offers.
private let offeredProfiles = [1, 5, 6, 8]

/// A settings page whose profile selector shows `selected` as the selected profile (none: no option selected).
private func settingsPage(host: String = "e-hentai.org", selected: Int?) -> String {
    let options = offeredProfiles.map { number in
        number == selected
            ? #"<option value="\#(number)" selected="selected">Zq Profile \#(number)</option>"#
            : #"<option value="\#(number)">Zq Profile \#(number)</option>"#
    }
    return """
    <html lang="en"><head><title>Zq Settings</title></head><body>
    <div class="zq" id="outer"><div id="zq1"><div id="zq2"><div>Zq</div><div>
    <form id="profile_form" action="https://\(host)/uconfig.php" method="post">
    <input type="hidden" id="profile_action" name="profile_action" value="">
    <input type="hidden" id="profile_name" name="profile_name" value="">
    <select name="profile_set" onchange="zq()">\(options.joined())</select>
    </form></div></div></div></div></body></html>
    """
}

private func page(_ text: String, status: Int = 200, headers: [String: String] = [:], site: EHSite = .eh) -> CaptureResponse {
    CaptureResponse(
        status: status, headers: ["Content-Type": "text/html; charset=UTF-8"].merging(headers) { _, new in new },
        body: Data(text.utf8), url: URL(string: "https://\(site.host)/uconfig.php")!
    )
}

/// A redirect as the site might send it: no body, a `Location` with a made-up query, optionally a `Set-Cookie`.
private func redirect(_ status: Int = 302, setCookie: String? = nil, site: EHSite = .eh) -> CaptureResponse {
    var headers = ["Location": "https://\(site.host)/uconfig.php?zq=fake-location-value"]
    headers["Set-Cookie"] = setCookie
    return CaptureResponse(status: status, headers: headers, body: Data(), url: URL(string: "https://\(site.host)/uconfig.php")!)
}

/// The `sp` pieces of a request's `Cookie` header; they hold profile numbers only, so they are safe to print.
private func profilePieces(_ request: CaptureRequest) -> [String] {
    (request.headers["Cookie"] ?? "").split(separator: "; ").map(String.init).filter { $0.hasPrefix("sp=") }
}

/// Answers like the site: the page selects the profile of the request's `sp` cookie, else profile 1.
private func siteLike(_ site: EHSite = .eh, headers: [String: String] = [:]) -> StubTransport {
    StubTransport { request, _ in
        let sent = profilePieces(request).first.flatMap { Int($0.dropFirst(3)) }
        return page(settingsPage(host: site.host, selected: sent ?? 1), headers: headers, site: site)
    }
}

@Suite struct ProfileProbeTests {
    @Test(arguments: [EHSite.eh, .ex])
    func probeIsReadOnly(site: EHSite) async throws {
        let transport = siteLike(site)
        _ = try await probeProfiles(
            site: site, numbers: [5, 6, 8], credentials: CaptureFakes.credentials(sites: [site]), transport: transport
        )
        let requests = transport.requests
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.method == "GET" && $0.body == nil })
        #expect(requests.allSatisfy { $0.url.absoluteString == "https://\(site.host)/uconfig.php" })
        #expect(requests.allSatisfy { !CapturePlan.mentionsInlineSet($0) && CapturePlan.isReadOnly($0, site: site) })
        // The transport follows no redirect, so 4 sends are 4 HTTP requests.
        #expect(requests.allSatisfy { $0.followRedirects == false })
        #expect(transport.maxConcurrency == 1)
    }

    @Test func probeLeavesOutTheCloudflareCookies() async throws {
        var environment = CaptureFakes.environment(sites: [.eh])
        environment["EH_CF_CLEARANCE"] = "fake-clearance-0123"
        environment["EH_CF_DUID"] = "fake-duid-0123"
        environment["EH_USER_AGENT"] = "FakeAgent/1.0"
        environment["EH_SK"] = "fake-sk-0123"
        let credentials = try CaptureCredentials(environment: environment, sites: [.eh])
        let transport = siteLike()
        _ = try await probeProfiles(site: .eh, numbers: [5, 6], credentials: credentials, transport: transport)
        let requests = transport.requests
        #expect(requests.count == 3)
        for request in requests {
            let cookie = request.headers["Cookie"] ?? ""
            let leftOut = !cookie.contains("cf_clearance=") && !cookie.contains("cf_duid=")
            #expect(leftOut, "a Cloudflare cookie was sent")
            // The other credential cookies still go.
            let kept = cookie.contains("ipb_member_id=") && cookie.contains("sk=")
            #expect(kept)
            #expect(request.headers["User-Agent"] == "FakeAgent/1.0")
        }
    }

    @Test func probeReportsRedirectsWithoutFollowing() async throws {
        let credentials = try CaptureFakes.credentials(sites: [.eh])
        let mixed = StubTransport(responses: [
            page(settingsPage(selected: 1)),
            redirect(setCookie: "sp=1; path=/; domain=.e-hentai.org"),
            redirect(303),
            page(settingsPage(selected: 8)),
        ])
        let results = try await probeProfiles(site: .eh, numbers: [5, 6, 8], credentials: credentials, transport: mixed)
        // One request per number and none to follow a redirect.
        #expect(mixed.requests.count == 4)
        #expect(results.map(\.sentProfileNumber) == [nil, 5, 6, 8])
        #expect(results.map(\.status) == [200, 302, 303, 200])
        #expect(results.map(\.selectedProfileNumber) == [1, nil, nil, 8])
        #expect(results.map(\.setCookieNames) == [[], ["sp"], [], []])
        #expect(results.map(\.setProfileNumber) == [nil, 1, nil, nil])
        // The Location is not reported.
        let lines = results.map(\.outputLine)
        #expect(lines[1] == "sp=5 status=302 selected=none set-cookie=sp set-sp=1")
        let showsLocation = lines.contains { $0.contains("fake-location-value") || $0.contains("uconfig") }
        #expect(showsLocation == false)

        // Every answer a redirect: still 4 requests at most, and no stop.
        let redirecting = StubTransport { _, _ in redirect() }
        let all = try await probeProfiles(site: .eh, numbers: [5, 6, 8], credentials: credentials, transport: redirecting)
        #expect(redirecting.requests.count == 4)
        #expect(all.map(\.status) == [302, 302, 302, 302])
    }

    @Test func exRedirectWithoutBodyIsNotAccessDenied() async throws {
        let transport = StubTransport(responses: [
            redirect(site: .ex), redirect(setCookie: "sp=2; path=/; domain=.exhentai.org", site: .ex),
        ])
        let results = try await probeProfiles(
            site: .ex, numbers: [2], credentials: CaptureFakes.credentials(sites: [.ex]), transport: transport
        )
        #expect(transport.requests.count == 2)
        #expect(results.map(\.status) == [302, 302])
        #expect(results.map(\.setProfileNumber) == [nil, 2])
    }

    @Test func probeSendsTheGivenProfileNumbers() async throws {
        let credentials = try CaptureFakes.credentials(sites: [.eh])
        let transport = siteLike()
        let results = try await probeProfiles(site: .eh, numbers: [5, 6], credentials: credentials, transport: transport)
        let requests = transport.requests
        #expect(requests.count == 3)
        #expect(requests.map(profilePieces) == [[], ["sp=5"], ["sp=6"]])
        #expect(results.map(\.sentProfileNumber) == [nil, 5, 6])
        // The same headers as `capture`: user agent, Accept, Accept-Language, nw=1 and the credential cookies.
        for request in requests {
            #expect(request.headers["User-Agent"] == credentials.userAgent)
            #expect(request.headers["Accept"] == RequestDefaults.accept)
            #expect(request.headers["Accept-Language"] == RequestDefaults.acceptLanguage)
            let cookie = request.headers["Cookie"] ?? ""
            let carriesLogin = cookie.hasPrefix("nw=1; ") && cookie.contains("ipb_member_id=") && cookie.contains("ipb_pass_hash=")
            #expect(carriesLogin)
            #expect(request.timeout == RequestDefaults.timeouts(for: .eh).receive)
        }
    }

    @Test func probeReadsTheSelectedProfile() async throws {
        let credentials = try CaptureFakes.credentials(sites: [.eh])
        let fixed = StubTransport { _, _ in page(settingsPage(selected: 6)) }
        let results = try await probeProfiles(site: .eh, numbers: [5], credentials: credentials, transport: fixed)
        #expect(results.map(\.selectedProfileNumber) == [6, 6])
        #expect(results.map(\.status) == [200, 200])

        let following = try await probeProfiles(site: .eh, numbers: [6, 8], credentials: credentials, transport: siteLike())
        #expect(following.map(\.selectedProfileNumber) == [1, 6, 8])

        // No option selected, and a page without the selector: nothing is read.
        let unselected = StubTransport { _, index in
            page(index == 0 ? settingsPage(selected: nil) : "<html><body><p>Zq</p></body></html>")
        }
        let unread = try await probeProfiles(site: .eh, numbers: [5], credentials: credentials, transport: unselected)
        #expect(unread.map(\.selectedProfileNumber) == [nil, nil])
    }

    @Test func probeReportsSetCookieNamesAndSP() async throws {
        let setCookie = "sp=6; expires=Wed, 06-Nov-2030 00:00:00 GMT; Max-Age=31536000; path=/; domain=.e-hentai.org, "
            + "hath_perks=fake-perks-0123; path=/; domain=.e-hentai.org"
        let transport = StubTransport { _, index in
            page(settingsPage(selected: 6), headers: index == 1 ? ["Set-Cookie": setCookie] : [:])
        }
        let results = try await probeProfiles(
            site: .eh, numbers: [6, 5], credentials: CaptureFakes.credentials(sites: [.eh]), transport: transport
        )
        #expect(results.map(\.setCookieNames) == [[], ["hath_perks", "sp"], []])
        #expect(results.map(\.setProfileNumber) == [nil, 6, nil])

        // A deleted sp, and one that is not a number, give no profile number; the name is still listed.
        for value in ["sp=deleted; expires=Thu, 01-Jan-1970 00:00:01 GMT; path=/", "sp=zq; path=/"] {
            let odd = StubTransport { _, _ in page(settingsPage(selected: 1), headers: ["set-cookie": value]) }
            let result = try await probeProfiles(
                site: .eh, numbers: [], credentials: CaptureFakes.credentials(sites: [.eh]), transport: odd
            )
            #expect(result.map(\.setCookieNames) == [["sp"]])
            #expect(result.map(\.setProfileNumber) == [nil])
        }
    }

    @Test func probeStopsOn429AndBan() async throws {
        let credentials = try CaptureFakes.credentials(sites: [.eh])
        for status in [429, 509, 500, 503] {
            let limited = StubTransport(responses: [
                page(settingsPage(selected: 1)), page("<html><body>slow down</body></html>", status: status),
            ])
            await #expect(throws: CaptureAbort.stoppedByServer(site: .eh, fixturePath: "uconfig.php with sp=5", status: status)) {
                try await probeProfiles(site: .eh, numbers: [5, 6], credentials: credentials, transport: limited)
            }
            #expect(limited.requests.count == 2)
        }

        let banText = try String(decoding: Fixtures.data("constructed/eh/banned.txt"), as: UTF8.self)
        let banned = StubTransport(responses: [page(settingsPage(selected: 1)), page(banText)])
        await #expect(throws: CaptureAbort.banned(site: .eh, fixturePath: "uconfig.php with sp=5")) {
            try await probeProfiles(site: .eh, numbers: [5, 6], credentials: credentials, transport: banned)
        }
        #expect(banned.requests.count == 2)

        // Any other status stops too, as in `capture`.
        let missing = StubTransport(responses: [page("<html><body>Zq</body></html>", status: 404)])
        await #expect(throws: CaptureAbort.unexpectedStatus(site: .eh, fixturePath: "uconfig.php without sp", status: 404)) {
            try await probeProfiles(site: .eh, numbers: [5], credentials: credentials, transport: missing)
        }
        #expect(missing.requests.count == 1)

        // ExHentai answering without a page: the cookies do not grant access.
        let empty = StubTransport(responses: [page("", site: .ex)])
        await #expect(throws: CaptureAbort.exAccessDenied) {
            try await probeProfiles(
                site: .ex, numbers: [5], credentials: CaptureFakes.credentials(sites: [.ex]), transport: empty
            )
        }
        #expect(empty.requests.count == 1)
    }

    @Test func probeRefusesMoreThanThreeNumbers() async throws {
        let transport = siteLike()
        await #expect(throws: ProfileProbeError.tooManyProfileNumbers) {
            try await probeProfiles(
                site: .eh, numbers: [1, 5, 6, 8], credentials: CaptureFakes.credentials(sites: [.eh]), transport: transport
            )
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func probeRefusesASharedSPVariable() async throws {
        var environment = CaptureFakes.environment(sites: [.eh])
        environment["EH_SP"] = "2"
        let credentials = try CaptureCredentials(environment: environment, sites: [.eh])
        let transport = siteLike()
        await #expect(throws: ProfileProbeError.sharedProfileVariable) {
            try await probeProfiles(site: .eh, numbers: [5], credentials: credentials, transport: transport)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func probeRefusesARequestThatIsNotReadOnly() async throws {
        // The public entry never builds such a URL, so go through the internal seam.
        let transport = siteLike()
        await #expect(throws: ProfileProbeError.notReadOnly) {
            try await probeProfiles(
                site: .eh, numbers: [5], credentials: CaptureFakes.credentials(sites: [.eh]), transport: transport,
                onResult: nil, url: URL(string: "https://e-hentai.org/uconfig.php?inline_set=dm_t")!
            )
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func resultsReachTheCallbackBeforeALaterStop() async throws {
        let transport = StubTransport(responses: [
            page(settingsPage(selected: 1)), page(settingsPage(selected: 5)), page("", status: 429),
        ])
        let seen = Mutex<[Int?]>([])
        await #expect(throws: CaptureAbort.stoppedByServer(site: .eh, fixturePath: "uconfig.php with sp=6", status: 429)) {
            try await probeProfiles(
                site: .eh, numbers: [5, 6], credentials: CaptureFakes.credentials(sites: [.eh]), transport: transport,
                onResult: { result in seen.withLock { $0.append(result.sentProfileNumber) } }
            )
        }
        #expect(seen.withLock { $0 } == [nil, 5])
    }

    @Test func probeOutputShowsNoCookieValues() async throws {
        let environment = [
            "EH_IPB_MEMBER_ID": "7654321", "EH_IPB_PASS_HASH": "fake-pass-hash", "EH_IGNEOUS": "fake-igneous",
            "EH_SK": "fake-sk-value", "EH_HATH_PERKS": "fake-perks", "EH_STAR": "fake-star", "EH_YAY": "fake-yay",
            "EH_IQ": "fake-iq", "EH_CF_CLEARANCE": "fake-clearance", "EH_CF_DUID": "fake-duid",
            "EH_USER_AGENT": "FakeAgent/1.0", "EH_USERNAME": "FakeProbeUser",
        ]
        let credentials = try CaptureCredentials(environment: environment, sites: [.ex])
        let setCookieValues = ["fake-set-perks", "fake-set-sk"]
        let setCookie = "sp=6; path=/; domain=.exhentai.org, hath_perks=\(setCookieValues[0]); path=/, "
            + "sk=\(setCookieValues[1]); path=/"
        let transport = StubTransport { _, index in
            page(settingsPage(host: "exhentai.org", selected: index == 0 ? 1 : 6), headers: index == 1 ? ["Set-Cookie": setCookie] : [:], site: .ex)
        }
        let results = try await probeProfiles(site: .ex, numbers: [6, 8], credentials: credentials, transport: transport)
        let lines = results.map(\.outputLine)
        // The lines hold numbers, statuses and cookie names only, so printing them on a mismatch is safe.
        #expect(lines == [
            "sp=none status=200 selected=1 set-cookie=none set-sp=none",
            "sp=6 status=200 selected=6 set-cookie=hath_perks,sk,sp set-sp=6",
            "sp=8 status=200 selected=6 set-cookie=none set-sp=none",
        ])
        let values = Array(environment.values) + setCookieValues
        let leaked = lines.contains { line in values.contains { line.contains($0) } }
        #expect(leaked == false, "a cookie or credential value appears in the probe output")
    }
}
