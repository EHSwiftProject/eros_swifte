import EHFixtures
import EHModels
import EHParsing
@testable import FixtureCaptureCore
import Foundation
import Synchronization
import Testing

private let webKitUserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 27_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

/// Credentials with the Cloudflare cookies the probe must leave out.
private func credentials(site: EHSite) throws -> CaptureCredentials {
    var environment = CaptureFakes.environment(sites: [site])
    environment["EH_CF_CLEARANCE"] = "fakeclearance0123"
    environment["EH_CF_DUID"] = "fakeduid0123"
    environment["EH_USER_AGENT"] = "Fake Chrome UA"
    return try CaptureCredentials(environment: environment, sites: [site])
}

private func sample(_ site: EHSite, _ name: String) throws -> CaptureResponse {
    CaptureResponse(
        status: 200, headers: ["Content-Type": "text/html; charset=UTF-8"],
        body: try Fixtures.data("\(site.rawValue)/\(name)"), url: URL(string: "https://\(site.host)/")!
    )
}

/// The M0 samples in the order the probe asks for them.
private func samples(_ site: EHSite) throws -> [CaptureResponse] {
    try ["list/front.html", "gallery/detail.html", "image/page.html"].map { try sample(site, $0) }
}

private func probe(_ site: EHSite, transport: StubTransport) async throws -> [StructureProbeResult] {
    try await probeStructure(
        site: site, userAgent: webKitUserAgent, credentials: credentials(site: site),
        fixturesRoot: Fixtures.rootURL, transport: transport
    )
}

@Suite struct StructureProbeTests {
    @Test(arguments: [EHSite.eh, .ex])
    func probeIsReadOnlyAndSendsThreeRequests(site: EHSite) async throws {
        let transport = StubTransport(responses: try samples(site))
        _ = try await probe(site, transport: transport)
        let requests = transport.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.method == "GET" && $0.body == nil })
        #expect(requests.allSatisfy { $0.url.host() == site.host && !($0.url.query() ?? "").contains("inline_set") })
        #expect(transport.maxConcurrency == 1)
        #expect(CannedSite.disablesFilters(requests[0].url))
        #expect(requests[1].url.path().hasPrefix("/g/"))
        #expect(requests[2].url.path().hasPrefix("/s/"))
    }

    @Test func probeSendsTheGivenUserAgentWithoutClearance() async throws {
        let transport = StubTransport(responses: try samples(.eh))
        _ = try await probe(.eh, transport: transport)
        for request in transport.requests {
            #expect(request.headers["User-Agent"] == webKitUserAgent)
            let cookie = request.headers["Cookie"] ?? ""
            #expect(!cookie.contains("cf_clearance") && !cookie.contains("cf_duid"))
            #expect(cookie.hasPrefix("nw=1"))
            #expect(cookie.contains("ipb_member_id="))
        }
    }

    @Test(arguments: [EHSite.eh, .ex])
    func identicalPagesAreReportedSame(site: EHSite) async throws {
        let results = try await probe(site, transport: StubTransport(responses: try samples(site)))
        #expect(results.map(\.kind) == [.list, .detail, .image])
        #expect(results.allSatisfy { $0.site == site && $0.status == 200 && $0.differences.isEmpty })
    }

    @Test func changedLayoutIsReported() async throws {
        var pages = try samples(.eh)
        let detail = String(decoding: pages[1].body, as: UTF8.self)
        let stripped = detail.replacingOccurrences(of: "id=\"taglist\"", with: "id=\"zqtaglist\"")
        #expect(stripped != detail)
        pages[1] = CaptureResponse(status: 200, headers: pages[1].headers, body: Data(stripped.utf8), url: pages[1].url)
        let results = try await probe(.eh, transport: StubTransport(responses: pages))
        #expect(results.map(\.differences) == [[], ["#taglist tr"], []])
    }

    @Test func probeStopsOn429AndBan() async throws {
        let first = try sample(.eh, "list/front.html")
        let limited = StubTransport(responses: [
            first, CaptureResponse(status: 429, headers: [:], body: Data("slow down".utf8), url: first.url),
        ])
        await #expect(throws: CaptureAbort.stoppedByServer(site: .eh, fixturePath: "eh/gallery/detail.html", status: 429)) {
            try await probe(.eh, transport: limited)
        }
        #expect(limited.requests.count == 2)

        let banText = try String(decoding: Fixtures.data("constructed/eh/banned.txt"), as: UTF8.self)
        let banned = StubTransport(responses: [
            first, CaptureResponse(status: 200, headers: [:], body: Data(banText.utf8), url: first.url),
        ])
        await #expect(throws: CaptureAbort.banned(site: .eh, fixturePath: "eh/gallery/detail.html")) {
            try await probe(.eh, transport: banned)
        }
        #expect(banned.requests.count == 2)
    }

    @Test func probeWritesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = directory.appending(path: ".fixture-secrets.local")
        try Data("EH_USERNAME=FakeCaptureUser\n".utf8).write(to: secrets)

        func snapshot() throws -> [String: Data] {
            var result: [String: Data] = [:]
            let root = Fixtures.rootURL
            for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    result[url.path(percentEncoded: false)] = try Data(contentsOf: url)
                }
            }
            result[secrets.path(percentEncoded: false)] = try Data(contentsOf: secrets)
            return result
        }
        let before = try snapshot()
        _ = try await probe(.eh, transport: StubTransport(responses: try samples(.eh)))
        #expect(try snapshot() == before)
    }

    @Test func probeRefusesARequestThatIsNotReadOnly() async throws {
        // The public entry never builds such a URL, so start from one through the internal seam.
        let transport = StubTransport(responses: try samples(.eh))
        let url = URL(string: "https://e-hentai.org/?inline_set=dm_t")!
        await #expect(throws: StructureProbeError.notReadOnly(kind: .list)) {
            try await probeStructure(
                site: .eh, userAgent: webKitUserAgent, credentials: credentials(site: .eh),
                fixturesRoot: Fixtures.rootURL, transport: transport, onResult: nil, startURL: url
            )
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func resultsReachTheCallbackBeforeALaterStop() async throws {
        let pages = try samples(.eh)
        let transport = StubTransport(responses: [
            pages[0], pages[1], CaptureResponse(status: 429, headers: [:], body: Data(), url: pages[1].url),
        ])
        let seen = Mutex<[PageKind]>([])
        await #expect(throws: CaptureAbort.stoppedByServer(site: .eh, fixturePath: "eh/image/page.html", status: 429)) {
            try await probeStructure(
                site: .eh, userAgent: webKitUserAgent, credentials: credentials(site: .eh),
                fixturesRoot: Fixtures.rootURL, transport: transport,
                onResult: { result in seen.withLock { $0.append(result.kind) } }
            )
        }
        #expect(seen.withLock { $0 } == [.list, .detail])
    }
}
