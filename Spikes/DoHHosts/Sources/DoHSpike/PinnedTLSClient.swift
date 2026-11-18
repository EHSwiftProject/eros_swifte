import EHNetwork
import Foundation
import Network
import Security
import Synchronization

public struct RawHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct PinnedGetResult: Sendable {
    public let response: RawHTTPResponse
    public let elapsed: Duration
    /// Subject summary of the leaf certificate the server presented and the system trusted.
    public let peerCertificateSubject: String?
    public let negotiatedALPN: String?
}

/// HTTP/1.1 GET over TLS to a fixed IP while SNI and certificate validation use the URL host
/// (or `serverName`). Trust evaluation is the system default: no verify block is installed.
public struct PinnedTLSClient: Sendable {
    private let timeout: Duration = .seconds(30)

    public init() {}

    public func get(_ url: URL, connectingTo ip: String, serverName: String? = nil) async throws -> RawHTTPResponse {
        try await inspectedGet(url, connectingTo: ip, serverName: serverName).response
    }

    /// Like `get`, also reporting timing (from the moment the rate limiter let the request through)
    /// and what the TLS handshake settled on.
    public func inspectedGet(
        _ url: URL,
        connectingTo ip: String,
        serverName: String? = nil
    ) async throws -> PinnedGetResult {
        guard url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else {
            throw SpikeError.unsupportedURL(url)
        }
        guard IPv4Address(ip) != nil || IPv6Address(ip) != nil else { throw SpikeError.invalidAddress(ip) }
        guard let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) else { throw SpikeError.unsupportedURL(url) }

        let request = Self.requestBytes(for: url, host: host)
        let parameters = Self.parameters(serverName: serverName ?? host)
        try await SpikeEnvironment.rateLimiter.acquire(host: host)

        let start = ContinuousClock.now
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: port, using: parameters)
        let (response, handshake) = try await connection.run(within: timeout) {
            try await connection.startAndWaitUntilReady()
            let handshake = connection.tlsHandshakeDetails()
            try await connection.sendAll(request)
            return (try HTTPResponseParser.parse(try await connection.receiveUntilClosed()), handshake)
        }
        return PinnedGetResult(
            response: response,
            elapsed: ContinuousClock.now - start,
            peerCertificateSubject: handshake.subject,
            negotiatedALPN: handshake.alpn
        )
    }

    static func parameters(serverName: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        // Sets both the SNI and the name the default trust evaluation checks the certificate against.
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        return NWParameters(tls: tls, tcp: tcp)
    }

    static func requestBytes(for url: URL, host: String) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? ""
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery { target += "?" + query }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        let lines = [
            "GET \(target) HTTP/1.1",
            "Host: \(hostHeader)",
            "User-Agent: \(RequestDefaults.chromeUserAgent)",
            "Accept-Encoding: identity",
            "Connection: close",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

extension NWConnection {
    /// Leaf certificate subject and negotiated ALPN of a ready TLS connection.
    func tlsHandshakeDetails() -> (subject: String?, alpn: String?) {
        guard let metadata = metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return (nil, nil)
        }
        let security = metadata.securityProtocolMetadata
        let subjects = Mutex<[String]>([])
        _ = sec_protocol_metadata_access_peer_certificate_chain(security) { certificate in
            let reference = sec_certificate_copy_ref(certificate).takeRetainedValue()
            let summary = (SecCertificateCopySubjectSummary(reference) as String?) ?? "?"
            subjects.withLock { $0.append(summary) }
        }
        var alpn: String?
        if let copied = sec_protocol_metadata_copy_negotiated_protocol(security) {
            alpn = String(cString: copied)
            free(UnsafeMutableRawPointer(mutating: copied))
        }
        return (subjects.withLock { $0.first }, alpn)
    }

    /// Reads until the peer closes. A trailing error is tolerated only if the message is already complete
    /// (some servers reset the connection instead of sending close_notify).
    func receiveUntilClosed(limit: Int = 32 << 20) async throws -> Data {
        var buffer = Data()
        while true {
            let chunk = await receiveChunk()
            if let data = chunk.data { buffer.append(data) }
            guard buffer.count <= limit else { throw SpikeError.malformedResponse("response exceeds \(limit) bytes") }
            if let error = chunk.error {
                if HTTPResponseParser.isComplete(buffer) { return buffer }
                throw error
            }
            if chunk.isComplete { return buffer }
        }
    }
}

/// Minimal HTTP/1.1 response parser: status line, headers, then Content-Length, chunked or close-delimited body.
enum HTTPResponseParser {
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let lineBreak = Data("\r\n".utf8)

    static func parse(_ raw: Data) throws -> RawHTTPResponse {
        let head = try parseHead(raw)
        let response = RawHTTPResponse(status: head.status, headers: head.headers, body: head.rest)
        if isChunked(response) {
            return RawHTTPResponse(status: head.status, headers: head.headers, body: try dechunk(head.rest))
        }
        if let length = contentLength(response) {
            guard head.rest.count >= length else {
                throw SpikeError.malformedResponse("body has \(head.rest.count) of \(length) bytes")
            }
            return RawHTTPResponse(status: head.status, headers: head.headers, body: head.rest.prefix(length))
        }
        return response
    }

    /// Whether `raw` already holds a whole message that does not rely on the connection closing.
    static func isComplete(_ raw: Data) -> Bool {
        guard let head = try? parseHead(raw) else { return false }
        let response = RawHTTPResponse(status: head.status, headers: head.headers, body: head.rest)
        if isChunked(response) { return (try? dechunk(head.rest)) != nil }
        if let length = contentLength(response) { return head.rest.count >= length }
        return false
    }

    private static func parseHead(_ raw: Data) throws -> (status: Int, headers: [String: String], rest: Data) {
        guard let split = raw.range(of: headerTerminator) else {
            throw SpikeError.malformedResponse("no end of headers in \(raw.count) bytes")
        }
        var lines = String(decoding: raw[raw.startIndex..<split.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
            throw SpikeError.malformedResponse("bad status line '\(statusLine)'")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                headers[existing, default: ""] += ", " + value
            } else {
                headers[name] = value
            }
        }
        return (status, headers, Data(raw[split.upperBound...]))
    }

    private static func isChunked(_ response: RawHTTPResponse) -> Bool {
        response.header("Transfer-Encoding")?.lowercased().contains("chunked") == true
    }

    private static func contentLength(_ response: RawHTTPResponse) -> Int? {
        response.header("Content-Length").flatMap { Int($0) }
    }

    static func dechunk(_ data: Data) throws -> Data {
        var output = Data()
        var cursor = data.startIndex
        while true {
            guard let lineEnd = data.range(of: lineBreak, in: cursor..<data.endIndex) else {
                throw SpikeError.malformedResponse("truncated chunk size line")
            }
            let sizeLine = String(decoding: data[cursor..<lineEnd.lowerBound], as: UTF8.self)
            let hex = sizeLine.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(hex, radix: 16), size >= 0 else {
                throw SpikeError.malformedResponse("bad chunk size '\(sizeLine)'")
            }
            cursor = lineEnd.upperBound
            if size == 0 { return output }  // Trailers, if any, are ignored.
            guard data.distance(from: cursor, to: data.endIndex) >= size + lineBreak.count else {
                throw SpikeError.malformedResponse("truncated chunk")
            }
            let chunkEnd = data.index(cursor, offsetBy: size)
            output.append(data[cursor..<chunkEnd])
            let next = data.index(chunkEnd, offsetBy: lineBreak.count)
            guard data[chunkEnd..<next].elementsEqual(lineBreak) else {
                throw SpikeError.malformedResponse("missing CRLF after chunk")
            }
            cursor = next
        }
    }
}
