import Foundation
import Synchronization
import Testing
import WebDAVSpike

/// Serves canned responses per host, so tests that use different hosts can run in parallel.
final class StubURLProtocol: URLProtocol {
    struct Request: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
        var path: String { url.path(percentEncoded: true) }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    typealias Responder = @Sendable (Request) -> Response

    private static let responders = Mutex<[String: Responder]>([:])
    private static let recorded = Mutex<[String: [Request]]>([:])

    static func install(host: String, _ responder: @escaping Responder) {
        responders.withLock { $0[host] = responder }
        recorded.withLock { $0[host] = [] }
    }

    static func requests(host: String) -> [Request] {
        recorded.withLock { $0[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let host = url.host() ?? ""
        let recordedRequest = Request(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request)
        )
        Self.recorded.withLock { $0[host, default: []].append(recordedRequest) }
        guard let responder = Self.responders.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = responder(recordedRequest)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("WebDAVClient (offline)")
struct WebDAVClientTests {
    static func makeClient(
        host: String,
        basePath: String = "/dav/",
        authentication: WebDAVConfiguration.Authentication = .challenge
    ) -> WebDAVClient {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [StubURLProtocol.self]
        return WebDAVClient(
            configuration: WebDAVConfiguration(
                baseURL: URL(string: "http://\(host)\(basePath)")!,
                username: "user",
                password: "pass",
                authentication: authentication
            ),
            sessionConfiguration: session
        )
    }

    static func selfOnlyMultiStatus(_ href: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:"><D:response><D:href>\(href)</D:href><D:propstat><D:prop>\
        <D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status>\
        </D:propstat></D:response></D:multistatus>
        """.utf8)
    }

    /// Group names whose request path the legacy client itself gets wrong, with the start of the
    /// segment Swift sends instead. dio truncates at `#` (fragment) and `?` (query), keeps a valid
    /// `%XX` as an escape and decodes it when unreserved (`a%41b` is sent as `aAb`), and turns `\`
    /// into `/`. Swift takes every name literally.
    static let knownLegacyBreakage: [String: String] = [
        "C#": "C%23",
        "why?": "why%3F",
        "a%41b": "a%2541b",
        "x%e5%90%8Cy": "x%25e5%2590%258Cy",
        "a\\b": "a%5Cb",
    ]

    static func groupName(of remotePath: String) -> String? {
        guard remotePath.hasPrefix(LegacyLayout.groupDirectory + "/") else { return nil }
        let fileName = remotePath.dropFirst(LegacyLayout.groupDirectory.count + 1)
        return fileName.components(separatedBy: LegacyLayout.groupSeparator).first
    }

    /// The legacy path is wrong exactly when dio's decoded path differs from the intended one.
    static func legacyIsBroken(_ vector: URLVectors.Vector) -> Bool {
        vector.decodedPath != "/dav" + vector.remotePath
    }

    @Test func legacyBreaksExactlyTheKnownGroupNames() {
        let broken = Fixtures.urlVectors.vectors.filter(Self.legacyIsBroken).compactMap { Self.groupName(of: $0.remotePath) }
        #expect(Set(broken) == Set(Self.knownLegacyBreakage.keys))
        #expect(broken.count == Self.knownLegacyBreakage.count)
    }

    /// Request URLs must match what webdav_client 1.2.2 + dio 5.9.0 send (golden url-vectors.json)
    /// byte for byte, except for the names in ``knownLegacyBreakage``.
    @Test(arguments: Fixtures.urlVectors.vectors)
    func buildsTheSameURLsAsTheLegacyClient(_ vector: URLVectors.Vector) throws {
        let client = WebDAVClient(configuration: WebDAVConfiguration(
            baseURL: URL(string: Fixtures.urlVectors.baseURL)!, username: "", password: ""
        ))
        let url = client.url(for: vector.remotePath)
        #expect(url.path(percentEncoded: false) == "/dav" + vector.remotePath, "Swift keeps the name literally")
        if Self.legacyIsBroken(vector) {
            let name = try #require(Self.groupName(of: vector.remotePath))
            let expectedSegment = try #require(Self.knownLegacyBreakage[name])
            #expect(url.absoluteString.hasPrefix(Fixtures.urlVectors.baseURL + "fehviewer/group/" + expectedSegment + "%E2%80%96@"))
            #expect(url.absoluteString != vector.url)
        } else {
            #expect(url.absoluteString == vector.url)
        }
    }

    @Test func listSendsALegacyStylePropfindAndReturnsChildren() async throws {
        let host = "propfind.test"
        let body = try Fixtures.multiStatus("apache-mod-dav.xml")
        StubURLProtocol.install(host: host) { _ in .init(status: 207, body: body) }
        let client = Self.makeClient(host: host, basePath: "/dav/legacy-write/")

        let children = try await client.list(LegacyLayout.groupDirectory)
        #expect(children.count == 2)
        #expect(children.allSatisfy { LegacyLayout.entry(directory: LegacyLayout.groupDirectory, fileName: $0.name) != nil })

        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.method == "PROPFIND")
        #expect(request.url.absoluteString == "http://propfind.test/dav/legacy-write/fehviewer/group/")
        #expect(request.headers["Depth"] == "1")
        #expect(request.headers["Content-Type"]?.hasPrefix("application/xml") == true)
        let xml = String(decoding: request.body, as: UTF8.self)
        #expect(xml.contains("propfind") && xml.contains("getlastmodified") && xml.contains("resourcetype"))
        #expect(request.headers["Authorization"] == nil, "challenge mode sends no credentials up front")
    }

    @Test func missingDirectoryIsNotFound() async throws {
        StubURLProtocol.install(host: "missing.test") { _ in .init(status: 404) }
        let client = Self.makeClient(host: "missing.test")
        let error = await #expect(throws: WebDAVError.self) {
            try await client.list(LegacyLayout.readProgressDirectory)
        }
        #expect(error == .notFound(path: "/fehviewer/read/"))
    }

    /// The base directory is literally named `100%41`. Its path must be decoded exactly once, or
    /// it becomes `100A`, the directory entry (not the first response here) is not recognised
    /// and is returned as a child.
    @Test func baseDirectoryWithALiteralPercentIsDecodedOnce() async throws {
        let host = "percent.test"
        let base = "/dav/100%2541/fehviewer/read/"
        func response(_ href: String, collection: Bool) -> String {
            """
            <D:response><D:href>\(href)</D:href><D:propstat><D:prop>\
            <D:resourcetype>\(collection ? "<D:collection/>" : "")</D:resourcetype></D:prop>\
            <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
            """
        }
        let body = Data(("""
            <?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">
            """ + response(base + "1000001.json", collection: false) + response(base, collection: true)
            + response(base + "1000002.json", collection: false) + "</D:multistatus>").utf8)
        StubURLProtocol.install(host: host) { _ in .init(status: 207, body: body) }
        let client = Self.makeClient(host: host, basePath: "/dav/100%2541/")

        let children = try await client.list(LegacyLayout.readProgressDirectory)
        #expect(children.map(\.name) == ["1000001.json", "1000002.json"])
        #expect(StubURLProtocol.requests(host: host).first?.path == base)
    }

    @Test func makeCollectionsCreatesEachLevelAfterAConflict() async throws {
        let host = "mkcol.test"
        StubURLProtocol.install(host: host) { request in
            let earlier = StubURLProtocol.requests(host: host).dropLast().filter { $0.path == request.path }
            switch request.path {
            case "/dav/fehviewer/history/s/" where earlier.isEmpty: return .init(status: 409)
            case "/dav/fehviewer/": return .init(status: 405)
            default: return .init(status: 201)
            }
        }
        let client = Self.makeClient(host: host)
        try await client.makeCollections(LegacyLayout.historyDetailDirectory)
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.map(\.method) == ["MKCOL", "MKCOL", "MKCOL", "MKCOL"])
        #expect(requests.map(\.path) == [
            "/dav/fehviewer/history/s/", "/dav/fehviewer/", "/dav/fehviewer/history/", "/dav/fehviewer/history/s/",
        ])
    }

    @Test func makeCollectionReportsOtherStatuses() async throws {
        StubURLProtocol.install(host: "mkcol-forbidden.test") { _ in .init(status: 403) }
        let client = Self.makeClient(host: "mkcol-forbidden.test")
        let error = await #expect(throws: WebDAVError.self) {
            try await client.makeCollections(LegacyLayout.groupDirectory)
        }
        #expect(error == .unexpectedStatus(method: "MKCOL", path: "/fehviewer/group/", status: 403))
    }

    @Test func ensureLegacyDirectoriesOnlyCreatesMissingOnes() async throws {
        let host = "ensure.test"
        StubURLProtocol.install(host: host) { request in
            switch (request.method, request.path) {
            case ("PROPFIND", "/dav/fehviewer/history/s/"):
                .init(status: 207, body: Self.selfOnlyMultiStatus("/dav/fehviewer/history/s/"))
            case ("PROPFIND", _): .init(status: 404)
            default: .init(status: 201)
            }
        }
        let client = Self.makeClient(host: host)
        try await client.ensureLegacyDirectories()
        let mkcols = StubURLProtocol.requests(host: host).filter { $0.method == "MKCOL" }.map(\.path)
        #expect(mkcols == [
            "/dav/fehviewer/history/del/", "/dav/fehviewer/read/", "/dav/fehviewer/group/", "/dav/fehviewer/search/",
        ])
    }

    @Test func putSendsTheBytesUnchanged() async throws {
        let host = "put.test"
        StubURLProtocol.install(host: host) { request in
            .init(status: request.path.hasSuffix("full.json") ? 507 : 201)
        }
        let client = Self.makeClient(host: host)
        let payload = Data("qr05cwW1veiIYaLsJQ3hFi/nzNAhmXQXpCqFOJrM0i9f".utf8)
        try await client.put(LegacyLayout.path(for: .readProgress(gid: "1000001")), data: payload)
        try await client.put(LegacyLayout.path(for: .historyDeletion(gid: "1000003")), data: Data())

        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.map(\.method) == ["PUT", "PUT"])
        #expect(requests[0].body == payload)
        #expect(requests[0].path == "/dav/fehviewer/read/1000001.json")
        #expect(requests[1].body.isEmpty)

        let error = await #expect(throws: WebDAVError.self) {
            try await client.put("/fehviewer/read/full.json", data: payload)
        }
        #expect(error == .unexpectedStatus(method: "PUT", path: "/fehviewer/read/full.json", status: 507))
    }

    @Test func getReturnsTheBodyAndMapsMissingFiles() async throws {
        let host = "get.test"
        StubURLProtocol.install(host: host) { request in
            request.path.hasSuffix("1000001.json") ? .init(status: 200, body: Data("abc".utf8)) : .init(status: 404)
        }
        let client = Self.makeClient(host: host)
        #expect(try await client.get("/fehviewer/read/1000001.json") == Data("abc".utf8))
        let error = await #expect(throws: WebDAVError.self) {
            try await client.get("/fehviewer/read/1000002.json")
        }
        #expect(error == .notFound(path: "/fehviewer/read/1000002.json"))
    }

    /// webdav_client's removeAll treats 200, 204 and 404 as success (client.dart:128-136).
    @Test func deleteTreatsAMissingFileAsDone() async throws {
        let host = "delete.test"
        StubURLProtocol.install(host: host) { request in
            switch request.url.lastPathComponent {
            case "gone.json": .init(status: 404)
            case "locked.json": .init(status: 423)
            default: .init(status: 204)
            }
        }
        let client = Self.makeClient(host: host)
        #expect(try await client.delete("/fehviewer/search/here.json") == .deleted)
        #expect(try await client.delete("/fehviewer/search/gone.json") == .notFound)
        let error = await #expect(throws: WebDAVError.self) {
            try await client.delete("/fehviewer/search/locked.json")
        }
        #expect(error == .unexpectedStatus(method: "DELETE", path: "/fehviewer/search/locked.json", status: 423))
    }

    @Test func preemptiveBasicSendsTheAuthorizationHeader() async throws {
        let host = "basic.test"
        StubURLProtocol.install(host: host) { _ in .init(status: 200) }
        let client = Self.makeClient(host: host, authentication: .preemptiveBasic)
        _ = try await client.get("/fehviewer/read/1000001.json")
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.headers["Authorization"] == "Basic " + Data("user:pass".utf8).base64EncodedString())
    }

    @Test func unauthorizedResponseIsReported() async throws {
        StubURLProtocol.install(host: "denied.test") { _ in .init(status: 401) }
        let client = Self.makeClient(host: "denied.test")
        let error = await #expect(throws: WebDAVError.self) {
            try await client.list(LegacyLayout.rootDirectory)
        }
        #expect(error == .unauthorized)
    }
}
