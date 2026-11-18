import Foundation
import Network

/// What a probe connection reported once it was ready.
public struct EncryptedDNSProbeResult: Sendable {
    public let remoteAddress: String
    /// DNS transport of each resolution step in the establishment report (udp, tcp, tls, https, unknown).
    public let dnsProtocols: [String]
    /// Where each resolution came from (query, cache, expiredCache).
    public let resolutionSources: [String]
    public let elapsed: Duration
}

/// TLS connections whose name resolution must be encrypted (`NWParameters.PrivacyContext`),
/// with a DoH server as the fallback resolver when the system has no encrypted DNS of its own.
public enum EncryptedDNSProbe {
    /// Returns the remote address the connection actually reached.
    public static func connect(host: String, port: UInt16, dohURL: URL) async throws -> String {
        try await probe(host: host, port: port, dohURL: dohURL).remoteAddress
    }

    public static func probe(
        host: String,
        port: UInt16,
        dohURL: URL,
        timeout: Duration = .seconds(15)
    ) async throws -> EncryptedDNSProbeResult {
        let context = NWParameters.PrivacyContext(description: "proj.eros.swifte.doh-probe")
        context.requireEncryptedNameResolution(true, fallbackResolver: .https(dohURL, serverAddresses: []))
        // On the simulator a brand-new context still answered from cache; flush so each probe really resolves.
        context.flushCache()
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        parameters.setPrivacyContext(context)
        return try await connect(host: host, port: port, parameters: parameters, timeout: timeout)
    }

    /// Same connection without a dedicated context, so it runs on the process-wide default context.
    public static func probeUsingDefaultContext(
        host: String,
        port: UInt16,
        timeout: Duration = .seconds(15)
    ) async throws -> EncryptedDNSProbeResult {
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        return try await connect(host: host, port: port, parameters: parameters, timeout: timeout)
    }

    private static func connect(
        host: String,
        port: UInt16,
        parameters: NWParameters,
        timeout: Duration
    ) async throws -> EncryptedDNSProbeResult {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw SpikeError.invalidAddress("\(host):\(port)") }
        try await SpikeEnvironment.rateLimiter.acquire(host: host)
        let start = ContinuousClock.now
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        return try await connection.run(within: timeout) {
            try await connection.startAndWaitUntilReady()
            let elapsed = ContinuousClock.now - start
            guard let remote = connection.currentPath?.remoteEndpoint else {
                throw SpikeError.malformedResponse("ready connection has no remote endpoint")
            }
            let resolutions = await connection.establishmentReport()?.resolutions ?? []
            return EncryptedDNSProbeResult(
                remoteAddress: "\(remote)",
                dnsProtocols: resolutions.map(\.dnsProtocol.label),
                resolutionSources: resolutions.map(\.source.label),
                elapsed: elapsed
            )
        }
    }

    /// Requires encrypted DNS on the process-wide default privacy context, which every connection
    /// without its own context uses. Used to test whether URLSession follows it.
    public static func requireEncryptedDNSForProcess(dohURL: URL) {
        NWParameters.PrivacyContext.default.requireEncryptedNameResolution(
            true, fallbackResolver: .https(dohURL, serverAddresses: []))
        NWParameters.PrivacyContext.default.flushCache()
    }

    public static func resetProcessDefault() {
        NWParameters.PrivacyContext.default.requireEncryptedNameResolution(false, fallbackResolver: nil)
        NWParameters.PrivacyContext.default.flushCache()
    }
}
