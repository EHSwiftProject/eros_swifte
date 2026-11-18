// Runs experiments 1–5 (plus extra experiment 6) and the timing comparison, printing results.
// Every E-Hentai request is an anonymous GET throttled by SpikeEnvironment.rateLimiter.
import DoHSpike
import EHNetwork
import Foundation
import Network
import Security

let cloudflare = URL(string: "https://cloudflare-dns.com/dns-query")!
// Negative control: nothing listens on the discard port, so this resolver can never answer.
let unreachableDoH = URL(string: "https://127.0.0.1:9/dns-query")!
let home = URL(string: "https://e-hentai.org/")!

extension Duration {
    var ms: String {
        let (seconds, attoseconds) = components
        return String(format: "%.0f ms", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    }
}

func describe(_ error: any Error) -> String {
    if let networkError = error as? NWError, case .tls(let status) = networkError {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "no message"
        return "NWError.tls(\(status)) \"\(message)\""
    }
    return String(describing: error)
}

func median(_ values: [Duration]) -> String {
    values.isEmpty ? "n/a" : values.sorted()[values.count / 2].ms
}

func containsSiteName(_ body: Data) -> Bool {
    String(decoding: body, as: UTF8.self).contains("E-Hentai")
}

print("doh-spike  \(Date().formatted(.iso8601))  \(ProcessInfo.processInfo.operatingSystemVersionString)")

// MARK: 1
print("\n== 1. DoH JSON API resolves EH hosts via \(cloudflare)")
let resolver = DoHResolver(endpoint: cloudflare)
var resolved: [String: [String]] = [:]
for host in ["e-hentai.org", "exhentai.org", "ehgt.org"] {
    let start = ContinuousClock.now
    do {
        let addresses = try await resolver.resolveIPv4(host)
        let valid = addresses.allSatisfy { IPv4Address($0) != nil }
        print("  \(valid ? "PASS" : "FAIL") \(host) -> \(addresses.joined(separator: ", ")) (\((ContinuousClock.now - start).ms))")
        resolved[host] = addresses
    } catch {
        print("  FAIL \(host): \(describe(error))")
    }
}
guard let ip = resolved["e-hentai.org"]?.first else {
    print("no address for e-hentai.org, stopping")
    exit(1)
}

// MARK: 2
print("\n== 2. Pinned TLS GET: connect to \(ip), SNI and trust check use e-hentai.org")
let client = PinnedTLSClient()
do {
    let result = try await client.inspectedGet(home, connectingTo: ip)
    let response = result.response
    let pass = response.status == 200 && containsSiteName(response.body)
    print("  \(pass ? "PASS" : "FAIL") status=\(response.status) body=\(response.body.count) bytes "
        + "transfer-encoding=\(response.header("Transfer-Encoding") ?? "-") "
        + "content-length=\(response.header("Content-Length") ?? "-") server=\(response.header("Server") ?? "-") "
        + "alpn=\(result.negotiatedALPN ?? "-") certificate=\(result.peerCertificateSubject ?? "-") (\(result.elapsed.ms))")
} catch {
    print("  FAIL \(describe(error))")
}

// MARK: 3
print("\n== 3. Same IP with serverName example.com must be rejected")
func expectTLSRejection(_ label: String, _ attempt: () async throws -> PinnedGetResult) async {
    do {
        let result = try await attempt()
        print("  FAIL \(label): handshake accepted, status=\(result.response.status) "
            + "server=\(result.response.header("Server") ?? "-") certificate=\(result.peerCertificateSubject ?? "-")")
    } catch let error as NWError {
        if case .tls = error {
            print("  PASS \(label): rejected by TLS: \(describe(error))")
        } else {
            print("  FAIL \(label): failed, but not in TLS: \(describe(error))")
        }
    } catch {
        print("  FAIL \(label): unexpected error: \(describe(error))")
    }
}
await expectTLSRejection("serverName example.com") {
    try await client.inspectedGet(home, connectingTo: ip, serverName: "example.com")
}
// Extra control: the right name against a server that is not e-hentai.org's (ehgt.org is not behind
// Cloudflare). A wrong custom-hosts entry would hit exactly this.
if let wrongServer = resolved["ehgt.org"]?.first {
    print("  extra control: connect to ehgt.org's \(wrongServer), SNI and trust check use e-hentai.org")
    await expectTLSRejection("e-hentai.org name on ehgt.org server") {
        try await SpikeEnvironment.rateLimiter.acquire(host: "ehgt.org")
        return try await client.inspectedGet(home, connectingTo: wrongServer)
    }
}

// MARK: 4
print("\n== 4. URLSession with PinnedRoutingURLProtocol (e-hentai.org -> \(ip))")
PinnedRoutingURLProtocol.setRoutes(["e-hentai.org": ip])
do {
    let configuration = SpikeEnvironment.anonymousSessionConfiguration()
    configuration.protocolClasses = [PinnedRoutingURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: home)
    request.setValue(RequestDefaults.chromeUserAgent, forHTTPHeaderField: "User-Agent")
    let start = ContinuousClock.now
    let (data, response) = try await session.data(for: request)
    let http = response as? HTTPURLResponse
    let route = http?.value(forHTTPHeaderField: PinnedRoutingURLProtocol.routeHeader) ?? "-"
    let pass = http?.statusCode == 200 && route == "pinned" && containsSiteName(data)
    print("  \(pass ? "PASS" : "FAIL") status=\(http?.statusCode ?? -1) X-Eros-Route=\(route) body=\(data.count) bytes "
        + "(\((ContinuousClock.now - start).ms))")
} catch {
    print("  FAIL \(describe(error))")
}
PinnedRoutingURLProtocol.setRoutes([:])

// MARK: 5
print("\n== 5. NWConnection with PrivacyContext requiring encrypted DNS, fallback \(cloudflare)")
do {
    let result = try await EncryptedDNSProbe.probe(host: "e-hentai.org", port: 443, dohURL: cloudflare)
    print("  PASS remote=\(result.remoteAddress) dns=\(result.dnsProtocols) source=\(result.resolutionSources) "
        + "(\(result.elapsed.ms))")
} catch {
    print("  FAIL \(describe(error))")
}
print("  control: same probe with an unreachable fallback resolver \(unreachableDoH)")
do {
    let result = try await EncryptedDNSProbe.probe(
        host: "e-hentai.org", port: 443, dohURL: unreachableDoH, timeout: .seconds(10))
    print("  control connected anyway: remote=\(result.remoteAddress) dns=\(result.dnsProtocols) "
        + "source=\(result.resolutionSources) -> the fallback was not what resolved the name")
} catch {
    print("  control failed as expected: \(describe(error))")
}

// MARK: Timing
print("\n== Timing: 5 x plain URLSession GET vs 5 x (DoH lookup + pinned GET) of \(home)")
print("   (rate-limiter waits excluded; plain uses a fresh ephemeral session each time)")
var plainTimes: [Duration] = []
for run in 1...5 {
    do {
        let result = try await SessionProbe.get(home)
        plainTimes.append(result.elapsed)
        print("  plain  #\(run) status=\(result.status) \(result.elapsed.ms) dns=\(result.resolutionProtocols) "
            + "protocol=\(result.networkProtocols) remote=\(result.remoteAddresses) proxied=\(result.proxied)")
    } catch {
        print("  plain  #\(run) FAIL \(describe(error))")
    }
}
var dohTimes: [Duration] = []
var pinnedTimes: [Duration] = []
var totalTimes: [Duration] = []
for run in 1...5 {
    do {
        let start = ContinuousClock.now
        let addresses = try await resolver.resolveIPv4("e-hentai.org")
        let lookup = ContinuousClock.now - start
        let result = try await client.inspectedGet(home, connectingTo: addresses[0])
        dohTimes.append(lookup)
        pinnedTimes.append(result.elapsed)
        totalTimes.append(lookup + result.elapsed)
        print("  pinned #\(run) status=\(result.response.status) doh=\(lookup.ms) get=\(result.elapsed.ms) "
            + "ip=\(addresses[0]) alpn=\(result.negotiatedALPN ?? "-")")
    } catch {
        print("  pinned #\(run) FAIL \(describe(error))")
    }
}
print("  median plain=\(median(plainTimes))  doh=\(median(dohTimes))  pinned get=\(median(pinnedTimes))  "
    + "doh+pinned=\(median(totalTimes))")

// MARK: 6
print("\n== 6. (extra) Does URLSession follow the process-wide default PrivacyContext?")
EncryptedDNSProbe.requireEncryptedDNSForProcess(dohURL: cloudflare)
do {
    let result = try await SessionProbe.get(home)
    print("  require encrypted + Cloudflare fallback: status=\(result.status) dns=\(result.resolutionProtocols) "
        + "remote=\(result.remoteAddresses) (\(result.elapsed.ms))")
} catch {
    print("  require encrypted + Cloudflare fallback: FAIL \(describe(error))")
}
EncryptedDNSProbe.requireEncryptedDNSForProcess(dohURL: unreachableDoH)
do {
    let result = try await SessionProbe.get(home, timeout: 10)
    print("  control, unreachable fallback: connected anyway status=\(result.status) dns=\(result.resolutionProtocols)")
} catch {
    print("  control, unreachable fallback: failed: \(describe(error))")
}
do {
    let result = try await EncryptedDNSProbe.probeUsingDefaultContext(host: "e-hentai.org", port: 443, timeout: .seconds(10))
    print("  control, plain NWConnection on the default context: connected anyway remote=\(result.remoteAddress) "
        + "dns=\(result.dnsProtocols) source=\(result.resolutionSources)")
} catch {
    print("  control, plain NWConnection on the default context: failed: \(describe(error))")
}
EncryptedDNSProbe.resetProcessDefault()
print("\ndone")
