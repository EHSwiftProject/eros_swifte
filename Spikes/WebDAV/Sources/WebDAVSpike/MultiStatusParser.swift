import Foundation

/// One `<response>` of a PROPFIND 207 Multi-Status body, built from its `200` propstats.
public struct DAVResource: Sendable, Equatable {
    /// The `<href>` text with XML entities resolved, still percent-encoded.
    public var href: String
    /// Percent-decoded path of `href` (scheme and authority removed for absolute URLs).
    public var path: String
    /// Last path segment of ``path``; empty for the server root.
    public var name: String
    public var isCollection: Bool
    public var displayName: String?
    public var contentLength: Int?
    public var contentType: String?
    public var etag: String?
    public var lastModified: Date?
}

public enum MultiStatusError: Error, Equatable, Sendable {
    /// The body is not well-formed XML.
    case malformed(String)
    /// Well-formed XML whose root is not a DAV `multistatus`.
    case notMultiStatus
}

/// Parses PROPFIND responses with `XMLParser`.
///
/// Namespace processing is on and elements are matched by local name in any namespace, like
/// webdav_client's `findAllElements(tag, namespace: '*')` (webdav_client-1.2.2/lib/src/xml.dart:25-29).
/// That makes `D:`, `d:`, `lp1:` and default-namespace responses look the same.
public enum MultiStatusParser {
    public static func parse(_ data: Data) throws -> [DAVResource] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw MultiStatusError.malformed(parser.parserError?.localizedDescription ?? "unknown error")
        }
        guard delegate.sawMultiStatus else { throw MultiStatusError.notMultiStatus }
        return delegate.resources
    }

    /// The entries inside `directoryPath`, without the entry for the directory itself.
    ///
    /// `directoryPath` is the request path in its percent-encoded form, as it appears in the URL;
    /// it is decoded once and compared with each resource's decoded ``DAVResource/path``
    /// (trailing slash ignored), so the directory may appear anywhere in the response. If no
    /// entry matches, for example behind a proxy that rewrites the path prefix, the first entry
    /// is dropped when it is a collection, which is webdav_client's rule (xml.dart:56-63).
    public static func children(of directoryPath: String, in resources: [DAVResource]) -> [DAVResource] {
        let target = normalized(directoryPath.removingPercentEncoding ?? directoryPath)
        if resources.contains(where: { normalized($0.path) == target }) {
            return resources.filter { normalized($0.path) != target }
        }
        if let first = resources.first, first.isCollection {
            return Array(resources.dropFirst())
        }
        return resources
    }

    private static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func decodedPath(ofHref href: String) -> String {
        var path = Substring(href)
        if let scheme = path.range(of: "://") {
            let afterAuthority = path[scheme.upperBound...]
            path = afterAuthority.firstIndex(of: "/").map { afterAuthority[$0...] } ?? "/"
        }
        // Uri.decodeFull in webdav_client; keep the raw text when the escapes are malformed.
        return path.removingPercentEncoding ?? String(path)
    }

    static func name(ofPath path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    }

    /// `getlastmodified` is an RFC 1123 date, e.g. `Wed, 04 Nov 2026 00:40:30 GMT`.
    static func httpDate(_ text: String) -> Date? {
        try? Date(text, strategy: Date.HTTPFormatStyle())
    }
}

private final class Delegate: NSObject, XMLParserDelegate {
    private struct Props {
        var isCollection = false
        var displayName: String?
        var contentLength: Int?
        var contentType: String?
        var etag: String?
        var lastModified: Date?
    }

    var resources: [DAVResource] = []
    var sawMultiStatus = false

    private var stack: [String] = []
    private var text = ""
    private var href: String?
    private var accepted = Props()
    private var pending = Props()
    private var status: String?
    private var sawOKPropstat = false

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        if stack.isEmpty, elementName == "multistatus" { sawMultiStatus = true }
        switch elementName {
        case "response":
            href = nil
            accepted = Props()
            sawOKPropstat = false
        case "propstat":
            pending = Props()
            status = nil
        case "collection" where stack.last == "resourcetype":
            pending.isCollection = true
        default:
            break
        }
        stack.append(elementName)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inProp = stack.last == "prop"
        switch elementName {
        case "href" where stack.last == "response":
            href = value
        case "status" where stack.last == "propstat":
            status = value
        case "displayname" where inProp:
            pending.displayName = value.isEmpty ? nil : value
        case "getcontentlength" where inProp:
            pending.contentLength = Int(value)
        case "getcontenttype" where inProp:
            pending.contentType = value.isEmpty ? nil : value
        case "getetag" where inProp:
            pending.etag = value.isEmpty ? nil : value
        case "getlastmodified" where inProp:
            pending.lastModified = MultiStatusParser.httpDate(value)
        case "propstat":
            // Only propstats with status 200 carry values (xml.dart:46).
            if let status, status.split(separator: " ").dropFirst().first == "200" {
                sawOKPropstat = true
                accepted.isCollection = accepted.isCollection || pending.isCollection
                accepted.displayName = pending.displayName ?? accepted.displayName
                accepted.contentLength = pending.contentLength ?? accepted.contentLength
                accepted.contentType = pending.contentType ?? accepted.contentType
                accepted.etag = pending.etag ?? accepted.etag
                accepted.lastModified = pending.lastModified ?? accepted.lastModified
            }
        case "response":
            // A response without any 200 propstat (only 403/404) is skipped, as webdav_client
            // only adds files from 200 propstats (xml.dart:44-46).
            if let href, sawOKPropstat {
                let path = MultiStatusParser.decodedPath(ofHref: href)
                resources.append(DAVResource(
                    href: href,
                    path: path,
                    name: MultiStatusParser.name(ofPath: path),
                    isCollection: accepted.isCollection,
                    displayName: accepted.displayName,
                    contentLength: accepted.isCollection ? nil : accepted.contentLength,
                    contentType: accepted.contentType,
                    etag: accepted.etag,
                    lastModified: accepted.lastModified
                ))
            }
        default:
            break
        }
        text = ""
    }
}
