import EHModels

/// Where a fixture came from.
public enum FixtureSource: String, Codable, Sendable {
    /// A real response saved by the capture tool, sanitized before it was written.
    case captured
    /// Written by hand, or edited from a captured fixture, for cases the site cannot serve on demand.
    case constructed
}

/// One fixture file and how it was obtained. Every value here is already sanitized.
public struct FixtureEntry: Codable, Sendable, Equatable {
    /// Path relative to the fixture root, e.g. "eh/list/front.html".
    public var path: String
    public var site: EHSite
    public var source: FixtureSource
    /// HTTP method of the captured request.
    public var method: String?
    /// Requested URL.
    public var url: String?
    /// HTTP status code of the response.
    public var status: Int?
    /// `Content-Type` response header.
    public var contentType: String?
    /// `Location` response header, for redirects.
    public var location: String?
    /// Names of the cookies the response set; values are never recorded.
    public var setCookieNames: [String]
    /// Capture time, ISO 8601 UTC.
    public var capturedAt: String?
    /// Fixture this one was edited from; constructed fixtures only.
    public var derivedFrom: String?
    public var note: String?

    public init(
        path: String,
        site: EHSite,
        source: FixtureSource,
        method: String? = nil,
        url: String? = nil,
        status: Int? = nil,
        contentType: String? = nil,
        location: String? = nil,
        setCookieNames: [String] = [],
        capturedAt: String? = nil,
        derivedFrom: String? = nil,
        note: String? = nil
    ) {
        self.path = path
        self.site = site
        self.source = source
        self.method = method
        self.url = url
        self.status = status
        self.contentType = contentType
        self.location = location
        self.setCookieNames = setCookieNames
        self.capturedAt = capturedAt
        self.derivedFrom = derivedFrom
        self.note = note
    }
}

/// Contents of `manifest.json`: one entry per fixture file.
public struct FixtureManifest: Codable, Sendable, Equatable {
    public var entries: [FixtureEntry]

    public init(entries: [FixtureEntry] = []) {
        self.entries = entries
    }
}
