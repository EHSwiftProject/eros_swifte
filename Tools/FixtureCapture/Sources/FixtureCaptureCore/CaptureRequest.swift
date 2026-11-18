import Foundation

/// One request of a capture plan. Once `Capturer` has added the default headers it carries the login cookies, so
/// printing, debug-printing or dumping it shows only the method, host, path, header names and body size.
public struct CaptureRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// False: a 3xx answer is returned as it is instead of being followed.
    public var followRedirects: Bool
    /// Whether the `Cookie` header starts with `nw=1` (skip the content warning).
    public var includeNW: Bool
    public var timeout: Duration

    public init(
        method: String = "GET",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        followRedirects: Bool = true,
        includeNW: Bool = true,
        timeout: Duration = .seconds(20)
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.followRedirects = followRedirects
        self.includeNW = includeNW
        self.timeout = timeout
    }
}

extension CaptureRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "CaptureRequest(\(method) \(url.host() ?? "")\(url.path()), headers: \(headers.keys.sorted()), "
            + "body: \(body?.count ?? 0) bytes)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "method": method, "host": url.host() ?? "", "path": url.path(), "headers": headers.keys.sorted(),
                "bodyBytes": body?.count ?? 0,
            ],
            displayStyle: .struct
        )
    }
}

/// A response as received. Its body may hold personal data, so printing, debug-printing or dumping it shows only
/// the status, header names and body size.
public struct CaptureResponse: Sendable {
    public let status: Int
    /// Response headers; names are matched case-insensitively.
    public let headers: [String: String]
    public let body: Data
    /// The URL that answered, after any redirects that were followed.
    public let url: URL

    public init(status: Int, headers: [String: String], body: Data, url: URL) {
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
    }

    /// The value of header `name`, any case. With several spellings of one name, the first in sorted order wins.
    func header(_ name: String) -> String? {
        headers.keys.sorted()
            .first { $0.caseInsensitiveCompare(name) == .orderedSame }
            .flatMap { headers[$0] }
    }

    /// The body as UTF-8, invalid bytes replaced.
    var text: String { String(decoding: body, as: UTF8.self) }
}

extension CaptureResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "CaptureResponse(\(status), headers: \(headers.keys.sorted()), body: \(body.count) bytes)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["status": status, "headers": headers.keys.sorted(), "bodyBytes": body.count],
            displayStyle: .struct
        )
    }
}
