import Foundation

/// Connection settings. The 8 s request timeout mirrors the Flutter app's connect/send/receive
/// timeouts (webdav_controller.dart:189-196). The other limits are not legacy behaviour: the app
/// has no total-duration limit, and its `webDAVMaxConnections` (default 3,
/// ehsetting_service.dart:273) caps concurrent *tasks* in an `Executor`, whereas
/// ``maximumConnectionsPerHost`` caps TCP connections. A sync engine on top of this client has
/// to limit task concurrency itself.
public struct WebDAVConfiguration: Sendable {
    public enum Authentication: Sendable {
        /// Let URLSession answer `401` challenges; covers Basic and Digest, like webdav_client,
        /// which also starts without credentials and picks the scheme from `WWW-Authenticate`.
        case challenge
        /// Send `Authorization: Basic` with every request and never answer challenges.
        case preemptiveBasic
    }

    /// The user's server URL, e.g. `https://dav.jianguoyun.com/dav/`. Remote paths such as
    /// `/fehviewer/read/1.json` are appended to it.
    public var baseURL: URL
    public var username: String
    public var password: String
    public var authentication: Authentication
    /// URLSession's idle timeout; it also bounds connection setup, as there is no separate
    /// connect timeout.
    public var requestTimeout: TimeInterval
    /// Total duration per request. The legacy client has none; a large Depth 1 listing on a
    /// slow server may need more than the default.
    public var resourceTimeout: TimeInterval
    /// `httpMaximumConnectionsPerHost`: connections, not concurrent requests or tasks.
    public var maximumConnectionsPerHost: Int

    public init(
        baseURL: URL,
        username: String,
        password: String,
        authentication: Authentication = .challenge,
        requestTimeout: TimeInterval = 8,
        resourceTimeout: TimeInterval = 60,
        maximumConnectionsPerHost: Int = 3
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.authentication = authentication
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.maximumConnectionsPerHost = maximumConnectionsPerHost
    }
}

public enum WebDAVError: Error, Equatable, Sendable {
    case notFound(path: String)
    case unauthorized
    case unexpectedStatus(method: String, path: String, status: Int)
    case invalidResponse(path: String)
    case multiStatus(MultiStatusError)
}

/// The WebDAV operations the legacy sync uses, over `URLSession` with no third-party code.
///
/// Paths are relative to ``WebDAVConfiguration/baseURL``. Directory paths get a trailing `/`
/// (webdav_client's `fixSlashes`); file paths do not.
public final class WebDAVClient: Sendable {
    public enum MakeCollectionResult: Sendable, Equatable { case created, alreadyExists }
    public enum DeleteResult: Sendable, Equatable { case deleted, notFound }
    public enum Depth: String, Sendable { case zero = "0", one = "1" }

    public let configuration: WebDAVConfiguration
    private let session: URLSession

    /// `sessionConfiguration` lets tests inject `protocolClasses`; the client's own settings are
    /// applied on top of it.
    public init(configuration: WebDAVConfiguration, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.configuration = configuration
        let sessionConfiguration = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfiguration.timeoutIntervalForResource = configuration.resourceTimeout
        sessionConfiguration.httpMaximumConnectionsPerHost = configuration.maximumConnectionsPerHost
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.waitsForConnectivity = false
        session = URLSession(
            configuration: sessionConfiguration,
            delegate: SessionDelegate(configuration: configuration),
            delegateQueue: nil
        )
    }

    deinit {
        // URLSession keeps its delegate alive until it is invalidated.
        session.finishTasksAndInvalidate()
    }

    // MARK: - URLs

    /// `rtrim(base, '/') + '/' + ltrim(path, '/')` (webdav_client utils.dart:114-116) with every
    /// path segment percent-encoded. The allowed set matches the characters Dart's `Uri.parse`
    /// leaves alone, so for ordinary names the request URL equals the legacy one byte for byte.
    /// Names are always taken literally, which differs from the legacy client in four cases
    /// where the legacy client itself sends the wrong path: `#` (rest becomes a fragment), `?`
    /// (rest becomes a query), a valid `%XX` (kept as an escape, unreserved ones even decoded:
    /// `a%41b` is sent as `aAb`) and `\` (becomes `/`). Swift sends `%23`, `%3F`, `%25` and
    /// `%5C`. In practice only group names can contain these characters.
    public func url(for remotePath: String) -> URL {
        var base = configuration.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let encoded = remotePath
            .drop(while: { $0 == "/" })
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: base + "/" + encoded)!
    }

    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()

    private static func directoryPath(_ path: String) -> String {
        var path = path.hasPrefix("/") ? path : "/" + path
        if !path.hasSuffix("/") { path += "/" }
        return path
    }

    // MARK: - Operations

    /// PROPFIND with the given depth; returns every response, including the target itself.
    public func propfind(_ path: String, depth: Depth) async throws -> [DAVResource] {
        let (data, status) = try await send("PROPFIND", path, body: Self.propfindBody, headers: [
            "Depth": depth.rawValue,
            "Content-Type": "application/xml; charset=utf-8",
            "Accept": "application/xml, text/xml",
        ])
        switch status {
        case 207:
            do { return try MultiStatusParser.parse(data) } catch let error as MultiStatusError {
                throw WebDAVError.multiStatus(error)
            }
        case 404: throw WebDAVError.notFound(path: path)
        default: throw WebDAVError.unexpectedStatus(method: "PROPFIND", path: path, status: status)
        }
    }

    /// `readDir`: PROPFIND Depth 1 on the directory, without the directory's own entry.
    public func list(_ directory: String) async throws -> [DAVResource] {
        let path = Self.directoryPath(directory)
        let resources = try await propfind(path, depth: .one)
        return MultiStatusParser.children(of: url(for: path).path(percentEncoded: true), in: resources)
    }

    public func get(_ path: String) async throws -> Data {
        let (data, status) = try await send("GET", path)
        switch status {
        case 200: return data
        case 404: throw WebDAVError.notFound(path: path)
        default: throw WebDAVError.unexpectedStatus(method: "GET", path: path, status: status)
        }
    }

    /// Uploads `data` as the whole file. Unlike `writeFromFile`, no OPTIONS and no MKCOL of the
    /// parent are sent first; call ``ensureLegacyDirectories()`` once per sync instead.
    public func put(_ path: String, data: Data) async throws {
        let (_, status) = try await send("PUT", path, body: data, headers: [
            "Content-Type": "application/octet-stream",
        ])
        guard [200, 201, 204].contains(status) else {
            throw WebDAVError.unexpectedStatus(method: "PUT", path: path, status: status)
        }
    }

    /// MKCOL; `405 Method Not Allowed` means the collection already exists.
    public func makeCollection(_ path: String) async throws -> MakeCollectionResult {
        let path = Self.directoryPath(path)
        let (_, status) = try await send("MKCOL", path)
        switch status {
        case 201: return .created
        case 405: return .alreadyExists
        default: throw WebDAVError.unexpectedStatus(method: "MKCOL", path: path, status: status)
        }
    }

    /// `mkdirAll` (client.dart:96-119): MKCOL the full path; on `409 Conflict` create every level
    /// from the top down.
    public func makeCollections(_ path: String) async throws {
        let path = Self.directoryPath(path)
        do {
            _ = try await makeCollection(path)
        } catch WebDAVError.unexpectedStatus(_, _, 409) {
            var prefix = "/"
            for segment in path.split(separator: "/") {
                prefix += segment + "/"
                _ = try await makeCollection(prefix)
            }
        }
    }

    /// DELETE. `404` is reported, not thrown: `removeAll` treats it as success (client.dart:128-136).
    public func delete(_ path: String) async throws -> DeleteResult {
        let (_, status) = try await send("DELETE", path)
        switch status {
        case 200, 204: return .deleted
        case 404: return .notFound
        default: throw WebDAVError.unexpectedStatus(method: "DELETE", path: path, status: status)
        }
    }

    /// `initClient` → `checkDir` for each startup directory (webdav_controller.dart:198-219), with
    /// a Depth 0 PROPFIND instead of a full listing.
    public func ensureLegacyDirectories() async throws {
        for directory in LegacyLayout.startupDirectories {
            do {
                _ = try await propfind(Self.directoryPath(directory), depth: .zero)
            } catch WebDAVError.notFound {
                try await makeCollections(directory)
            }
        }
    }

    // MARK: - Transport

    /// The properties webdav_client asks for (xml.dart:6-15).
    private static let propfindBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/>\
        <d:getcontenttype/><d:getetag/><d:getlastmodified/></d:prop></d:propfind>
        """.utf8)

    private func send(
        _ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:]
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if configuration.authentication == .preemptiveBasic {
            let token = Data("\(configuration.username):\(configuration.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse(path: path) }
        if http.statusCode == 401 { throw WebDAVError.unauthorized }
        return (data, http.statusCode)
    }
}

/// Answers authentication challenges and keeps redirects from being followed silently.
private final class SessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let username: String
    private let password: String
    private let answersChallenges: Bool

    init(configuration: WebDAVConfiguration) {
        username = configuration.username
        password = configuration.password
        answersChallenges = configuration.authentication == .challenge
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault:
            guard answersChallenges, challenge.previousFailureCount == 0 else {
                // A second challenge means the credentials were refused; let the 401 through.
                return (.rejectProtectionSpace, nil)
            }
            return (.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
        default:
            // Server trust and client certificates: system default, i.e. strict TLS evaluation.
            return (.performDefaultHandling, nil)
        }
    }

    /// A redirected PUT or PROPFIND can come back as a GET with status 200, which would look like
    /// success. Surface the 3xx instead; webdav_client re-sends 302s itself (webdav_dio.dart:135-153).
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
