#if DEBUG
import EHNetwork
import Foundation
import Synchronization

/// A constructed page a UI test serves for one request (`EROS_FIXTURE_ROUTES`): the file under the fixtures root, the
/// status (any code; 200 when left out) and an optional `Location`. With `then` (a file under the root too), only the
/// first request the route matches gets `path`; every one after gets `then`, with the same status and `Location`: a
/// refresh that asks again sees another page (M2 review F4 I-2). Without it, `path` every time.
nonisolated struct FixtureRoute: Codable, Sendable, Equatable {
    var path: String
    var status: Int = 200
    var location: String? = nil
    var then: String? = nil
}

nonisolated extension FixtureRoute {
    private enum CodingKeys: String, CodingKey {
        case path, status, location, then
    }

    /// `status`, `location` and `then` may be left out of the JSON (200, none, none). In an extension, so the
    /// memberwise initializer stays.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        status = try container.decodeIfPresent(Int.self, forKey: .status) ?? 200
        location = try container.decodeIfPresent(String.self, forKey: .location)
        then = try container.decodeIfPresent(String.self, forKey: .then)
    }
}

/// What the replay answers to one request: a fixture, a route's page, or a 404 with nothing.
nonisolated struct FixtureReplayAnswer: Sendable, Equatable {
    let status: Int
    let headers: [String: String]
    let body: Data

    static let notFound = FixtureReplayAnswer(status: 404, headers: [:], body: Data())
}

/// Why the fixtures cannot be replayed.
nonisolated enum FixtureReplayError: Error, Equatable {
    /// `manifest.json` is missing or not a manifest.
    case unreadableManifest
    /// A route key is not "METHOD URL".
    case invalidRouteKey(String)
    /// The manifest entry for this file is a request without a method or a URL, or with a URL the replay cannot
    /// read (no scheme or no host).
    case invalidEntry(String)
    /// A manifest entry or a route names a file that is not under the root.
    case missingFile(String)
}

/// The checked-in fixtures, replayed for DEBUG UI tests (`-EROS_FIXTURE_REPLAY 1` with `-EROS_UI_TESTING 1`).
///
/// Matching (M2 index §3.4): the same method; the same scheme, host (any case) and percent-decoded path, the fragment
/// ignored; the query as a set of decoded name-value pairs (names and values percent-decoded, a `+` in a value read
/// as a space), whatever their order and encoding. Without `advsearch` in the request, `f_sfl`, `f_sfu` and `f_sft`
/// are dropped on both sides (the capture added them to turn the filters off); with it they are kept.
///
/// Lookup: the routes first, then the manifest entries that have a `method` and a `url`. A POST to a path ending in
/// `/api.php` takes the entry whose file name stem is the body's JSON `"method"` (`tagsuggest` →
/// `eh/api/tagsuggest.json`); any other request takes the first entry that matches. Nothing → a 404 without a body.
/// A 3xx is a final answer, with its `Location` (nothing follows it). A route with `then` answers its `path` to the
/// first request it matches and `then` to every one after; the count is the replay's, shared by its copies (the URL
/// protocol's registry holds one).
nonisolated struct FixtureReplay: Sendable {
    // The switch names (`-EROS_FIXTURE_REPLAY 1`, `EROS_FIXTURE_ROUTES`) are `TestSwitches.fixtureReplay` and
    // `TestSwitches.fixtureRoutes`.

    /// The fixtures' directory in the Debug app bundle (`scripts/copy-replay-fixtures.sh`).
    static let bundleDirectory = "FixtureReplay"

    private struct Entry: Sendable {
        let key: RequestKey
        let path: String
        let status: Int
        let contentType: String
        let location: String?
        /// The file name without its extension, for `api.php` POSTs.
        let stem: String
        /// A route's file for every request after the first it matches (`FixtureRoute.then`).
        var then: String? = nil
    }

    private let root: URL
    private let routes: [Entry]
    private let entries: [Entry]
    /// The routes with a `then` that answered once.
    private let answeredRoutes = AnsweredRoutes()
    /// How much later than at once every answer comes (`TestSwitches.fixtureReplayDelay`); zero by default.
    var answerDelay: Duration = .zero

    /// Reads `root/manifest.json` and checks that every file the manifest's request entries and `routes` name is
    /// under `root`. A manifest entry with neither a method nor a URL is no request (a constructed page that only a
    /// route serves) and is left out; one with only one of them, or a URL the replay cannot read, throws
    /// `invalidEntry` rather than leaving a request unanswered later. Throws `FixtureReplayError`.
    init(root: URL, routes: [String: FixtureRoute] = [:]) throws {
        let root = root.standardizedFileURL
        self.root = root
        guard let data = try? Data(contentsOf: root.appending(path: "manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { throw FixtureReplayError.unreadableManifest }

        entries = try manifest.entries.compactMap { entry in
            if entry.method == nil, entry.url == nil { return nil }
            guard let method = entry.method, let text = entry.url, let url = URL(string: text),
                  let key = RequestKey(method: method, url: url)
            else { throw FixtureReplayError.invalidEntry(entry.path) }
            try Self.requireFile(entry.path, under: root)
            return Entry(
                key: key, path: entry.path, status: entry.status ?? 200,
                contentType: entry.contentType ?? Self.contentType(of: entry.path), location: entry.location,
                stem: Self.stem(of: entry.path)
            )
        }
        // Sorted by key, so that two routes that compare equal always resolve the same way.
        self.routes = try routes.sorted { $0.key < $1.key }.map { text, route in
            guard let key = RequestKey(routeKey: text) else { throw FixtureReplayError.invalidRouteKey(text) }
            try Self.requireFile(route.path, under: root)
            if let then = route.then { try Self.requireFile(then, under: root) }
            return Entry(
                key: key, path: route.path, status: route.status, contentType: Self.contentType(of: route.path),
                location: route.location, stem: Self.stem(of: route.path), then: route.then
            )
        }
    }

    /// The replay of the app bundle's fixtures with the routes of `EROS_FIXTURE_ROUTES` (`TestSwitches.fixtureRoutes`).
    /// A Debug build always carries the fixtures, so a missing or unreadable one is a broken build or test: it stops
    /// the app.
    static func forLaunch() -> FixtureReplay {
        guard let resources = Bundle.main.resourceURL else { fatalError("Fixture replay: the app has no resources") }
        let routesKey = TestSwitches.fixtureRoutes.description
        var routes: [String: FixtureRoute] = [:]
        if let json = ProcessInfo.processInfo.environment[routesKey] {
            do {
                routes = try JSONDecoder().decode([String: FixtureRoute].self, from: Data(json.utf8))
            } catch {
                fatalError("Fixture replay: \(routesKey) is not [String: FixtureRoute] JSON: \(error)")
            }
        }
        do {
            var replay = try FixtureReplay(
                root: resources.appending(path: bundleDirectory, directoryHint: .isDirectory), routes: routes
            )
            let delay = UserDefaults.standard.double(forKey: TestSwitches.fixtureReplayDelay.description)
            if delay > 0 { replay.answerDelay = .milliseconds(Int(delay * 1000)) }
            return replay
        } catch {
            fatalError("Fixture replay: \(error)")
        }
    }

    /// The route, fixture or 404 for this request; `body` is the request's body (for `api.php`).
    func answer(method: String, url: URL, body: Data?) -> FixtureReplayAnswer {
        guard let request = RequestKey(method: method, url: url) else { return .notFound }
        let keepsFilterSwitches = request.hasAdvancedSearch
        func matches(_ entry: Entry) -> Bool {
            keepsFilterSwitches
                ? entry.key == request
                : entry.key.withoutFilterSwitches() == request.withoutFilterSwitches()
        }
        if let index = routes.firstIndex(where: matches) {
            let route = routes[index]
            guard let then = route.then, answeredRoutes.answeredBefore(index) else { return answer(serving: route) }
            return answer(serving: route, file: then)
        }
        let candidates = entries.filter(matches)
        if request.method == "POST", request.path.hasSuffix("/api.php") {
            guard let apiMethod = Self.apiMethod(in: body),
                  let entry = candidates.first(where: { $0.stem == apiMethod })
            else { return .notFound }
            return answer(serving: entry)
        }
        return candidates.first.map { answer(serving: $0) } ?? .notFound
    }

    /// `entry`'s status and `Location` with the bytes of `file` (its own when nil).
    private func answer(serving entry: Entry, file: String? = nil) -> FixtureReplayAnswer {
        // The file was there when the replay was made; a read that fails now answers as nothing would.
        guard let body = try? Data(contentsOf: root.appending(path: file ?? entry.path)) else { return .notFound }
        var headers = ["Content-Type": file.map(Self.contentType(of:)) ?? entry.contentType]
        if let location = entry.location { headers["Location"] = location }
        return FixtureReplayAnswer(status: entry.status, headers: headers, body: body)
    }

    // MARK: - Files

    /// Throws `missingFile` unless `path` is a file under `root` (no `..` out of it).
    private static func requireFile(_ path: String, under root: URL) throws {
        let file = root.appending(path: path).standardizedFileURL
        var rootPath = root.path(percentEncoded: false)
        if !rootPath.hasSuffix("/") { rootPath += "/" }
        var isDirectory: ObjCBool = false
        guard file.path(percentEncoded: false).hasPrefix(rootPath),
              FileManager.default.fileExists(atPath: file.path(percentEncoded: false), isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { throw FixtureReplayError.missingFile(path) }
    }

    /// By extension: `.html` → `text/html; charset=UTF-8`, `.json` → `application/json`,
    /// `.txt` → `text/plain; charset=UTF-8`; anything else `application/octet-stream`.
    private static func contentType(of path: String) -> String {
        switch URL(filePath: path).pathExtension.lowercased() {
        case "html": "text/html; charset=UTF-8"
        case "json": "application/json"
        case "txt": "text/plain; charset=UTF-8"
        default: "application/octet-stream"
        }
    }

    private static func stem(of path: String) -> String {
        URL(filePath: path).deletingPathExtension().lastPathComponent
    }

    /// The `"method"` of a JSON object body; nil for anything else.
    private static func apiMethod(in body: Data?) -> String? {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return object["method"] as? String
    }
}

/// Which routes with a `then` answered once (by their index in `FixtureReplay`'s routes), behind a `Mutex`: requests
/// are answered on the URL loading system's threads.
nonisolated private final class AnsweredRoutes: Sendable {
    private let indexes = Mutex<Set<Int>>([])

    /// Whether route `index` answered before; from now on it has.
    func answeredBefore(_ index: Int) -> Bool {
        indexes.withLock { !$0.insert(index).inserted }
    }
}

// MARK: - Manifest

/// The fields of `manifest.json` the replay uses (EHFixtures has the full type; the app does not link it).
nonisolated private struct Manifest: Decodable {
    struct Entry: Decodable {
        let path: String
        let method: String?
        let url: String?
        let status: Int?
        let contentType: String?
        let location: String?
    }

    let entries: [Entry]
}

// MARK: - Request keys

/// A request as the replay compares it (see `FixtureReplay`).
nonisolated private struct RequestKey: Hashable, Sendable {
    struct QueryItem: Hashable, Sendable {
        let name: String
        let value: String
    }

    /// Added by the capture to turn the filters off (`CapturePlan.filterParameters`).
    static let filterSwitches: Set<String> = ["f_sfl", "f_sfu", "f_sft"]

    let method: String
    let scheme: String
    let host: String
    let path: String
    let query: Set<QueryItem>

    var hasAdvancedSearch: Bool { query.contains { $0.name == "advsearch" } }

    init?(method: String, url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme, let host = components.host
        else { return nil }
        self.method = method.uppercased()
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath
        // "https://e-hentai.org" and "https://e-hentai.org/" ask for the same page.
        self.path = path.isEmpty ? "/" : path
        query = Set((components.percentEncodedQuery ?? "").split(separator: "&").map(Self.item))
    }

    /// "METHOD URL", as a route key is written.
    init?(routeKey: String) {
        let parts = routeKey.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let url = URL(string: String(parts[1])) else { return nil }
        self.init(method: String(parts[0]), url: url)
    }

    private init(method: String, scheme: String, host: String, path: String, query: Set<QueryItem>) {
        self.method = method
        self.scheme = scheme
        self.host = host
        self.path = path
        self.query = query
    }

    func withoutFilterSwitches() -> RequestKey {
        RequestKey(
            method: method, scheme: scheme, host: host, path: path,
            query: query.filter { !Self.filterSwitches.contains($0.name) }
        )
    }

    /// `name=value` decoded; `name` alone has an empty value.
    private static func item(_ pair: Substring) -> QueryItem {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        let value = parts.count > 1 ? String(parts[1]).replacingOccurrences(of: "+", with: " ") : ""
        return QueryItem(name: name.removingPercentEncoding ?? name, value: value.removingPercentEncoding ?? value)
    }
}

// MARK: - URL protocol

/// Answers a session's requests from a `FixtureReplay` and never touches the network.
///
/// `configurator(serving:)` registers the replay under an id (a process-wide table behind a `Mutex`, so hosted tests
/// can run in parallel, as with `MockURLProtocol`), puts this protocol first in the session's `protocolClasses` and
/// adds the `X-Eros-Replay` header naming the registration. Only requests that carry the header are taken; a POST's
/// body is read from `httpBodyStream`.
nonisolated final class FixtureReplayURLProtocol: URLProtocol, @unchecked Sendable {
    /// The header the configurator adds; its value is the registration's id.
    static let headerName = "X-Eros-Replay"

    private static let registry = Mutex<[String: FixtureReplay]>([:])

    /// The configurator that routes a session's requests to `replay`. Every request of the session carries the header,
    /// so the replay answers all of them: one it does not match gets a 404 without a body. The offline protocol that
    /// `AppEnvironment` puts after it in UI testing only takes a request without the header.
    static func configurator(serving replay: FixtureReplay) -> SessionConfigurator {
        let id = UUID().uuidString
        registry.withLock { $0[id] = replay }
        return SessionConfigurator(usesCustomProxy: false) { configuration in
            configuration.protocolClasses = [FixtureReplayURLProtocol.self as AnyClass]
                + (configuration.protocolClasses ?? [])
            var headers = configuration.httpAdditionalHeaders ?? [:]
            headers[headerName] = id
            configuration.httpAdditionalHeaders = headers
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: headerName) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let replay = request.value(forHTTPHeaderField: Self.headerName).flatMap { id in
            Self.registry.withLock { $0[id] }
        }
        guard let client, let replay, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let answer = replay.answer(method: request.httpMethod ?? "GET", url: url, body: Self.body(of: request))
        guard let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers
        ) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        guard replay.answerDelay > .zero else {
            Self.deliver(answer, response: response, by: self, to: client)
            return
        }
        let (seconds, attoseconds) = replay.answerDelay.components
        let delay = Double(seconds) + Double(attoseconds) / 1e18
        // URLProtocol's client expects its calls on the thread the load started on (Apple's CustomHTTPProtocol), and
        // `stopLoading()` runs there too: the answer goes back to it, so the check for a stop cannot race the stop.
        delayed = (answer, response)
        loadingThread = Thread.current
        loadingModes = [(RunLoop.current.currentMode ?? .default).rawValue]
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard let thread = loadingThread else { return }
            perform(#selector(deliverDelayed), on: thread, with: nil, waitUntilDone: false, modes: loadingModes)
        }
    }

    override func stopLoading() {
        isStopped = true
    }

    /// Set by `stopLoading()`, on the loading thread: a delayed answer is no longer delivered.
    private var isStopped = false
    /// A delayed answer (`FixtureReplay.answerDelay`), until `deliverDelayed()` hands it over on `loadingThread`.
    private var delayed: (answer: FixtureReplayAnswer, response: HTTPURLResponse)?
    /// The thread `startLoading()` ran on, and its run loop's mode; set before the delay starts.
    private var loadingThread: Thread?
    private var loadingModes: [String] = []

    /// The delayed answer, on the loading thread, unless the load was stopped meanwhile.
    @objc private func deliverDelayed() {
        guard !isStopped, let client, let delayed else { return }
        self.delayed = nil
        Self.deliver(delayed.answer, response: delayed.response, by: self, to: client)
    }

    private static func deliver(
        _ answer: FixtureReplayAnswer, response: HTTPURLResponse, by loader: URLProtocol,
        to client: any URLProtocolClient
    ) {
        client.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !answer.body.isEmpty { client.urlProtocol(loader, didLoad: answer.body) }
        client.urlProtocolDidFinishLoading(loader)
    }

    /// `httpBody`, or the bytes of `httpBodyStream` (URLSession turns `httpBody` into one).
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        var body = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}
#endif
