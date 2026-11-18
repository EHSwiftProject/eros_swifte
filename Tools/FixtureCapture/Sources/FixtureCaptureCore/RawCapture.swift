import EHFixtures
import EHModels
import Foundation

/// One response as received, before sanitizing. It holds credentials and personal data, so printing,
/// debug-printing or dumping it shows only the fixture path, site, method and status.
public struct RawCapture: Sendable {
    /// Where the fixture goes, relative to the fixture root, e.g. "eh/list/front.html".
    public let fixturePath: String
    public let site: EHSite
    public let method: String
    public let url: URL
    public let status: Int
    /// Response headers. Names are matched case-insensitively; several `Set-Cookie` headers may share one value,
    /// separated by commas or newlines.
    public let headers: [String: String]
    public let body: Data
    public let capturedAt: Date

    public init(
        fixturePath: String,
        site: EHSite,
        method: String,
        url: URL,
        status: Int,
        headers: [String: String],
        body: Data,
        capturedAt: Date
    ) {
        self.fixturePath = fixturePath
        self.site = site
        self.method = method
        self.url = url
        self.status = status
        self.headers = headers
        self.body = body
        self.capturedAt = capturedAt
    }

    /// The value of header `name`, any case. With several spellings of one name, the first in sorted order wins.
    func header(_ name: String) -> String? {
        headers.keys.sorted()
            .first { $0.caseInsensitiveCompare(name) == .orderedSame }
            .flatMap { headers[$0] }
    }

    /// Names of the cookies `Set-Cookie` sets, sorted and deduplicated. Each comma- or newline-separated piece
    /// whose first `;` segment is `token=value` names a cookie; pieces of an `Expires` date have no `=` there.
    var setCookieNames: [String] {
        guard let header = header("Set-Cookie") else { return [] }
        var names = Set<String>()
        for piece in header.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let pair = piece.prefix { $0 != ";" }
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<equals].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name.unicodeScalars.allSatisfy(Self.isTokenScalar) { names.insert(name) }
        }
        return names.sorted()
    }

    /// RFC 9110 `tchar`.
    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
    }
}

extension RawCapture: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "RawCapture(\(fixturePath), \(site.rawValue), \(method), \(status))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["fixturePath": fixturePath, "site": site, "method": method, "status": status],
            displayStyle: .struct
        )
    }
}

/// A capture after sanitizing: its manifest entry and the body to write. `FixtureWriter` checks both again before
/// anything reaches the disk. Anyone can build one, so it may still hold personal data: printing, debug-printing or
/// dumping it shows only the fixture path and the body size.
public struct SanitizedCapture: Sendable {
    public let entry: FixtureEntry
    public let body: Data

    public init(entry: FixtureEntry, body: Data) {
        self.entry = entry
        self.body = body
    }
}

extension SanitizedCapture: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SanitizedCapture(\(entry.path), \(body.count) bytes)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["path": entry.path, "bytes": body.count], displayStyle: .struct)
    }
}
