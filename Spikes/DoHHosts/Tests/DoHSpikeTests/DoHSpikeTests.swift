import DoHSpike
import EHNetwork
import Foundation
import Network
import Testing

// Live-network spike tests. All E-Hentai requests are anonymous GETs throttled by
// `SpikeEnvironment.rateLimiter`.
@Suite(.serialized)
struct DoHSpikeTests {
    static let cloudflare = URL(string: "https://cloudflare-dns.com/dns-query")!
    static let home = URL(string: "https://e-hentai.org/")!
    // Nothing listens on the discard port, so a resolver here can never answer.
    static let unreachableDoH = URL(string: "https://127.0.0.1:9/dns-query")!

    private func firstEHentaiIPv4() async throws -> String {
        let addresses = try await DoHResolver().resolveIPv4("e-hentai.org")
        return try #require(addresses.first)
    }

    @Test func resolvesEHentaiIPv4() async throws {
        let resolver = DoHResolver()
        for host in ["e-hentai.org", "exhentai.org", "ehgt.org"] {
            let addresses = try await resolver.resolveIPv4(host)
            #expect(!addresses.isEmpty, "\(host) has no A record")
            for address in addresses {
                #expect(IPv4Address(address) != nil, "\(host) -> \(address) is not IPv4")
            }
        }
    }

    @Test func pinnedGetReturns200() async throws {
        let ip = try await firstEHentaiIPv4()
        let response = try await PinnedTLSClient().get(Self.home, connectingTo: ip)
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self).contains("E-Hentai"))
    }

    @Test func pinnedGetRejectsMismatchedServerName() async throws {
        let ip = try await firstEHentaiIPv4()
        let error = await #expect(throws: NWError.self) {
            try await PinnedTLSClient().get(Self.home, connectingTo: ip, serverName: "example.com")
        }
        // `#expect(throws:)` already recorded the issue when nothing was thrown.
        guard let error else { return }
        guard case .tls = error else {
            Issue.record("expected a TLS failure, got \(error)")
            return
        }
    }

    // Extra control, not in the brief: the right name against a server that is not e-hentai.org's
    // (ehgt.org is not behind Cloudflare) must fail certificate validation.
    @Test func pinnedGetRejectsServerWithoutMatchingCertificate() async throws {
        let addresses = try await DoHResolver().resolveIPv4("ehgt.org")
        let wrongServer = try #require(addresses.first)
        try await SpikeEnvironment.rateLimiter.acquire(host: "ehgt.org")
        let error = await #expect(throws: NWError.self) {
            try await PinnedTLSClient().get(Self.home, connectingTo: wrongServer)
        }
        // `#expect(throws:)` already recorded the issue when nothing was thrown.
        guard let error else { return }
        guard case .tls = error else {
            Issue.record("expected a TLS failure, got \(error)")
            return
        }
    }

    @Test func urlProtocolRoutesThroughPinnedConnection() async throws {
        let ip = try await firstEHentaiIPv4()
        PinnedRoutingURLProtocol.setRoutes(["e-hentai.org": ip])
        defer { PinnedRoutingURLProtocol.setRoutes([:]) }

        let configuration = SpikeEnvironment.anonymousSessionConfiguration()
        configuration.protocolClasses = [PinnedRoutingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: Self.home)
        request.setValue(RequestDefaults.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "X-Eros-Route") == "pinned")
        #expect(String(decoding: data, as: UTF8.self).contains("E-Hentai"))
    }

    @Test func encryptedDNSConnects() async throws {
        let remote = try await EncryptedDNSProbe.connect(host: "e-hentai.org", port: 443, dohURL: Self.cloudflare)
        #expect(!remote.isEmpty)
    }

    // Extra control, not in the brief: the probe should report a DoH resolution, and with an unreachable
    // fallback resolver it must fail, which shows the name really is resolved by the fallback server.
    @Test func encryptedDNSProbeDependsOnFallbackResolver() async throws {
        let viaCloudflare = try await EncryptedDNSProbe.probe(host: "e-hentai.org", port: 443, dohURL: Self.cloudflare)
        #expect(viaCloudflare.dnsProtocols.contains("https"), "\(viaCloudflare)")
        await #expect(throws: (any Error).self) {
            try await EncryptedDNSProbe.probe(host: "e-hentai.org", port: 443, dohURL: Self.unreachableDoH, timeout: .seconds(10))
        }
    }

    // Extra, not in the brief: does URLSession honour the process-wide default privacy context?
    // Decides whether "DoH only" can stay on URLSession. Task metrics report "unknown" on the simulator,
    // so this relies on the unreachable-resolver control instead. Restores the default context afterwards.
    @Test func urlSessionFollowsDefaultPrivacyContext() async throws {
        defer { EncryptedDNSProbe.resetProcessDefault() }
        EncryptedDNSProbe.requireEncryptedDNSForProcess(dohURL: Self.cloudflare)
        let viaCloudflare = try await SessionProbe.get(Self.home)
        #expect(viaCloudflare.status == 200)

        EncryptedDNSProbe.requireEncryptedDNSForProcess(dohURL: Self.unreachableDoH)
        await #expect(throws: URLError.self, "URLSession resolved the name without the required resolver") {
            try await SessionProbe.get(Self.home, timeout: 10)
        }
    }

    // Extra, not in the brief: the same default-context control for a plain NWConnection, to tell apart
    // how a platform treats the default context and a dedicated one.
    @Test func nwConnectionFollowsDefaultPrivacyContext() async throws {
        defer { EncryptedDNSProbe.resetProcessDefault() }
        EncryptedDNSProbe.requireEncryptedDNSForProcess(dohURL: Self.unreachableDoH)
        await #expect(throws: (any Error).self) {
            try await EncryptedDNSProbe.probeUsingDefaultContext(host: "e-hentai.org", port: 443, timeout: .seconds(10))
        }
    }
}
