import Foundation

/// Resolves A records through a DoH server's JSON API (`application/dns-json`).
public struct DoHResolver: Sendable {
    public let endpoint: URL

    public init(endpoint: URL = URL(string: "https://cloudflare-dns.com/dns-query")!) {
        self.endpoint = endpoint
    }

    /// IPv4 addresses from the `Answer` records of type A, in server order.
    public func resolveIPv4(_ host: String) async throws -> [String] {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw SpikeError.unsupportedURL(endpoint)
        }
        components.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
        guard let url = components.url else { throw SpikeError.unsupportedURL(endpoint) }

        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        try await SpikeEnvironment.rateLimiter.acquire(host: endpoint.host() ?? "")
        let (data, response) = try await Self.session.data(for: request)

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw SpikeError.badStatus(status) }
        let reply = try JSONDecoder().decode(DNSJSONReply.self, from: data)
        guard reply.status == 0 else { throw SpikeError.dnsFailure(host: host, status: reply.status) }
        let addresses = (reply.answer ?? []).filter { $0.type == 1 }.map(\.data)
        guard !addresses.isEmpty else { throw SpikeError.noAddress(host) }
        return addresses
    }

    private static let session = URLSession(configuration: SpikeEnvironment.anonymousSessionConfiguration())
}

private struct DNSJSONReply: Decodable {
    struct Record: Decodable {
        let type: Int
        let data: String
    }

    let status: Int
    let answer: [Record]?

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case answer = "Answer"
    }
}
