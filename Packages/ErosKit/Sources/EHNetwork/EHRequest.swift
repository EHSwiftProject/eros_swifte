import EHModels
import Foundation

/// A `multipart/form-data` body, such as an image search upload.
///
/// `description`, `debugDescription` and the mirror show the parts' names and byte counts only, as do the `Part`s':
/// a file name may be the user's, and the data is the user's image.
public struct MultipartBody: Sendable, Equatable {
    /// One field of the form; a file when `fileName` is set.
    public struct Part: Sendable, Equatable {
        public let name: String
        public let fileName: String?
        /// The part's `Content-Type`; nil sends none.
        public let contentType: String?
        public let data: Data

        public init(name: String, fileName: String? = nil, contentType: String? = nil, data: Data) {
            self.name = name
            self.fileName = fileName
            self.contentType = contentType
            self.data = data
        }
    }

    public let boundary: String
    public let parts: [Part]

    public init(boundary: String = "Eros-" + UUID().uuidString, parts: [Part]) {
        self.boundary = boundary
        self.parts = parts
    }
}

/// Whether a GET may be answered from the response cache (N4); POST always behaves as `.none`.
public enum CachePolicy: Sendable, Equatable {
    /// Use a cached response when there is one (the default for pages).
    case preferCache
    /// Ask the site again and replace the cached response (pull to refresh).
    case reload
    /// Neither read nor write the cache.
    case none
}

/// One request to the site, an image host or the API, before `EHClient` adds the user agent and cookies.
///
/// `description` (and the mirror) show the method and URL only: the body may hold a password, the headers a token.
public struct EHRequest: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public enum Body: Sendable, Equatable {
        case none
        /// Sent as `application/json`.
        case json(Data)
        /// Sent as `application/x-www-form-urlencoded`; a nil value is sent as an empty one.
        case form([URLQueryItem])
        /// Sent as `multipart/form-data` with the body's boundary.
        case multipart(MultipartBody)
    }

    public var method: Method
    public var url: URL
    /// Picks the session and its timeouts; cookies follow the URL's host, whatever the site.
    public var site: EHSite
    public var body: Body
    /// Extra headers (Referer, Origin, …), set after the defaults and replacing them, except `Cookie` and
    /// `User-Agent` (any case): those come only from the cookie store and the user agent store.
    public var headers: [String: String]
    public var cachePolicy: CachePolicy
    /// false: a 3xx response is returned as it is (image search reads its `location`).
    public var followsRedirects: Bool
    /// The response is JSON (the API); see `ResponseClassifier.issue(status:body:expectsJSON:host:)`.
    public var expectsJSON: Bool

    public init(
        method: Method = .get, url: URL, site: EHSite, body: Body = .none, headers: [String: String] = [:],
        cachePolicy: CachePolicy = .preferCache, followsRedirects: Bool = true, expectsJSON: Bool = false
    ) {
        self.method = method
        self.url = url
        self.site = site
        self.body = body
        self.headers = headers
        self.cachePolicy = cachePolicy
        self.followsRedirects = followsRedirects
        self.expectsJSON = expectsJSON
    }

    /// "GET https://e-hentai.org/…": no body, headers or cookies.
    public var description: String {
        "\(method.rawValue) \(url.absoluteString)"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["description": description])
    }

    /// Headers `webViewRequest()` leaves out (lowercased), besides every name that starts with "accept".
    private static let webViewOwnedHeaders: Set<String> = ["cookie", "user-agent"]

    /// The request for a WKWebView to load: method, body with its Content-Type, and `headers` (Referer).
    /// No User-Agent, no Cookie, no Accept headers: the WebView sends its own.
    ///
    /// The body may hold a password (the forum login form, account A3b): the request is for one load, not to be kept.
    public func webViewRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        if let encoded = body.encoded {
            request.httpBody = encoded.data
            request.setValue(encoded.contentType, forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let lowercased = name.lowercased()
            guard !Self.webViewOwnedHeaders.contains(lowercased), !lowercased.hasPrefix("accept") else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

/// A response `EHClient.send(_:)` returns: a status below 400 and no site notice.
///
/// `description` (and the mirror) leave out the headers and body: `set-cookie` holds credentials. Two responses are
/// equal when status, URL, headers, body and source are; where a response of `send` came from (its session) is not
/// compared.
public struct EHResponse: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public enum Source: Sendable, Equatable {
        case network
        /// The response cache (N4).
        case cache
    }

    public let status: Int
    /// The URL of the response, after any redirects.
    public let url: URL
    /// Header names lowercased.
    public let headers: [String: String]
    public let body: Data
    public let source: Source
    /// The session a response of `EHClient.send(_:)` belongs to: what its request went out with (from the network),
    /// or what its cache lookup was read with (from the cache); nil for one built by hand.
    /// `EHClient.storeInCache(_:for:)` stores a network response under it.
    let origin: ResponseOrigin?

    /// Lowercases the header names; names that differ only in case are joined with ", " in sorted order.
    public init(status: Int, url: URL, headers: [String: String], body: Data, source: Source) {
        self.init(status: status, url: url, headers: headers, body: body, source: source, origin: nil)
    }

    init(status: Int, url: URL, headers: [String: String], body: Data, source: Source, origin: ResponseOrigin?) {
        var lowercased: [String: String] = [:]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let name = name.lowercased()
            lowercased[name] = lowercased[name].map { "\($0), \(value)" } ?? value
        }
        self.status = status
        self.url = url
        self.headers = lowercased
        self.body = body
        self.source = source
        self.origin = origin
    }

    public static func == (lhs: EHResponse, rhs: EHResponse) -> Bool {
        lhs.status == rhs.status && lhs.url == rhs.url && lhs.headers == rhs.headers && lhs.body == rhs.body
            && lhs.source == rhs.source
    }

    /// The body as UTF-8; invalid bytes become U+FFFD.
    public var text: String {
        String(decoding: body, as: UTF8.self)
    }

    /// "EHResponse(200, https://e-hentai.org/…, 1234 bytes, network)".
    public var description: String {
        "EHResponse(\(status), \(url.absoluteString), \(body.count) bytes, \(source))"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["description": description])
    }
}

/// The session a response of `EHClient.send(_:)` belongs to: what the request of a network response went out with,
/// so the response can be cached later under its own session (`EHClient.storeInCache(_:for:)`) rather than the one
/// current by then; for an answer from the cache, what its lookup was read with.
struct ResponseOrigin: Sendable {
    /// `EHSite(cookieHost:)` of the request URL's host: the site `scope` belongs to (nil outside both sites).
    let site: EHSite?
    /// The cache scope read with the request's Cookie header (or with the cache lookup).
    let scope: String
    /// The cookie store's epoch read with it.
    let epoch: UInt64
    /// The response cache's generation read before it; nil without a cache, and for an answer from the cache (which is
    /// never stored again).
    let cacheGeneration: UInt64?
}

// MARK: - Body description

extension EHRequest.Body: CustomStringConvertible, CustomReflectable {
    /// The case with field names and byte counts only, never a value: a form may hold a password (the forum login),
    /// JSON or a multipart part anything. "none", "json(42 bytes)", "form(UserName: 9 bytes, PassWord: 12 bytes)",
    /// "multipart(sfile: 1234 bytes, fs_similar: 2 bytes)" (file names left out too).
    public var description: String {
        switch self {
        case .none:
            "none"
        case .json(let data):
            "json(\(data.count) bytes)"
        case .form(let items):
            "form(\(items.map { "\($0.name): \(($0.value ?? "").utf8.count) bytes" }.joined(separator: ", ")))"
        case .multipart(let body):
            "multipart(\(body.partList))"
        }
    }

    /// Only `description`: the default mirror would show the form values.
    public var customMirror: Mirror {
        Mirror(self, children: ["description": description])
    }
}

extension MultipartBody.Part: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// "sfile: 1234 bytes": the name and the size, never the file name, content type or data.
    public var description: String {
        "\(name): \(data.count) bytes"
    }

    public var debugDescription: String { description }

    /// Only `description`: the default mirror would show the file name and the data.
    public var customMirror: Mirror {
        Mirror(self, children: ["description": description])
    }
}

extension MultipartBody: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// "MultipartBody(sfile: 1234 bytes, fs_similar: 2 bytes)": each part as `Part.description` gives it.
    public var description: String {
        "MultipartBody(\(partList))"
    }

    public var debugDescription: String { description }

    /// Only `description`: the default mirror would reach the parts' file names and data.
    public var customMirror: Mirror {
        Mirror(self, children: ["description": description])
    }

    /// The parts' descriptions, joined with ", ".
    fileprivate var partList: String {
        parts.map(\.description).joined(separator: ", ")
    }
}

// MARK: - Body encoding

extension EHRequest.Body {
    /// The bytes and `Content-Type` to send; nil for `.none`.
    var encoded: (data: Data, contentType: String)? {
        switch self {
        case .none:
            nil
        case .json(let data):
            (data, "application/json")
        case .form(let items):
            (FormEncoding.encode(items), "application/x-www-form-urlencoded")
        case .multipart(let body):
            (body.encoded(), "multipart/form-data; boundary=\(body.boundary)")
        }
    }
}

extension MultipartBody {
    /// Each part as `--boundary`, its headers and data; then `--boundary--`. Lines end in CRLF.
    func encoded() -> Data {
        var data = Data()
        for part in parts {
            var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.escaped(part.name))\""
            if let fileName = part.fileName {
                head += "; filename=\"\(Self.escaped(fileName))\""
            }
            head += "\r\n"
            if let contentType = part.contentType {
                head += "Content-Type: \(contentType)\r\n"
            }
            head += "\r\n"
            data.append(Data(head.utf8))
            data.append(part.data)
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    /// A field or file name as HTML's form submission writes it: LF, CR and '"' become %0A, %0D and %22.
    private static func escaped(_ name: String) -> String {
        var result = ""
        for scalar in name.unicodeScalars {
            switch scalar {
            case "\n": result += "%0A"
            case "\r": result += "%0D"
            case "\"": result += "%22"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

/// `application/x-www-form-urlencoded` as HTML forms send it.
enum FormEncoding {
    /// "name=value" pairs joined with "&", names and values encoded by `component(_:)`.
    static func encode(_ items: [URLQueryItem]) -> Data {
        let pairs = items.map { "\(component($0.name))=\(component($0.value ?? ""))" }
        return Data(pairs.joined(separator: "&").utf8)
    }

    /// The UTF-8 bytes of `value`: ASCII letters, digits and "*-._" as they are, space as "+", every other byte
    /// as "%XX" (uppercase hex).
    static func component(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"):
                bytes.append(byte)
            case UInt8(ascii: " "):
                bytes.append(UInt8(ascii: "+"))
            default:
                bytes += [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
