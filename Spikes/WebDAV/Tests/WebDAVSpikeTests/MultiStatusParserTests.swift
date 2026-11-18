import Foundation
import Testing
import WebDAVSpike

@Suite("MultiStatusParser")
struct MultiStatusParserTests {
    static let separator = LegacyLayout.groupSeparator
    static let chineseGroup = "汉语\(separator)00000000-0000-4000-8000-000000000001\(separator)1762000200000.json"
    static let artistGroup = "Fake Artist [Test] & 同人+\(separator)00000000-0000-4000-8000-000000000002\(separator)1762000210000.json"

    static func gmt(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    /// Captured from the local Apache 2.4.67 mod_dav server (scripts/serve-local-webdav.sh).
    @Test func parsesApacheModDavResponse() throws {
        let resources = try MultiStatusParser.parse(Fixtures.multiStatus("apache-mod-dav.xml"))
        #expect(resources.count == 3)

        let directory = resources[0]
        #expect(directory.isCollection)
        #expect(directory.path == "/dav/legacy-write/fehviewer/group/")
        #expect(directory.name == "group")
        #expect(directory.contentLength == nil)
        #expect(directory.lastModified == Self.gmt(2026, 11, 4, 0, 40, 30))

        let files = MultiStatusParser.children(of: "/dav/legacy-write/fehviewer/group/", in: resources)
        #expect(files.map(\.name) == [Self.chineseGroup, Self.artistGroup])
        #expect(files.map(\.isCollection) == [false, false])
        #expect(files.map(\.contentLength) == [304, 832])
        #expect(files[0].contentType == "application/json")
        #expect(files[0].etag == "\"130-65f68a03f3b80\"")
        #expect(files[0].displayName == nil, "the 404 propstat must be ignored")
        #expect(files[1].href.contains("&") && !files[1].href.contains("&amp;"))
    }

    @Test func parsesMixedPrefixesAndDefaultNamespace() throws {
        let resources = try MultiStatusParser.parse(Fixtures.multiStatus("mixed-prefixes.xml"))
        #expect(resources.count == 4)
        #expect(resources[0].etag == "\"6908f2bb5c1e1\"")
        #expect(resources[0].contentLength == nil)

        let children = MultiStatusParser.children(
            of: "/remote.php/dav/files/fake-user/fehviewer/history/s/", in: resources
        )
        #expect(children.map(\.name) == ["1000001_1762000000000.json", "1000002_1762000100000.json", "示例 目录"])
        #expect(children.map(\.isCollection) == [false, false, true])
        #expect(children[0].contentLength == 1772)
        #expect(children[0].contentType == "application/json")
        #expect(children[1].contentLength == 1728)
        #expect(children[1].contentType == nil)
        #expect(children[1].lastModified == Self.gmt(2025, 11, 5, 10, 20, 30))
    }

    @Test func parsesAbsoluteHrefsWithPercentEncodedChinese() throws {
        let resources = try MultiStatusParser.parse(Fixtures.multiStatus("absolute-hrefs.xml"))
        let base = "/dav/我的坚果云/fehviewer/group/"
        #expect(resources.map(\.path) == [base + Self.chineseGroup, base, base + Self.artistGroup])

        // The directory is the second response; it is still recognised by path.
        let children = MultiStatusParser.children(of: base, in: resources)
        #expect(children.map(\.name) == [Self.chineseGroup, Self.artistGroup])
        #expect(children.map(\.contentLength) == [304, 832])
    }

    @Test func requestedDirectoryMatchesWithOrWithoutTrailingSlashAndEncoding() throws {
        let resources = try MultiStatusParser.parse(Fixtures.multiStatus("absolute-hrefs.xml"))
        let encoded = "/dav/%E6%88%91%E7%9A%84%E5%9D%9A%E6%9E%9C%E4%BA%91/fehviewer/group"
        #expect(MultiStatusParser.children(of: encoded, in: resources).count == 2)
    }

    /// When no href matches the requested path (for example behind a rewriting proxy), fall
    /// back to webdav_client's rule: the first response is the directory itself.
    @Test func fallsBackToSkippingTheFirstResponse() throws {
        let resources = try MultiStatusParser.parse(Fixtures.multiStatus("apache-mod-dav.xml"))
        let children = MultiStatusParser.children(of: "/proxied/fehviewer/group/", in: resources)
        #expect(children.map(\.name) == [Self.chineseGroup, Self.artistGroup])
    }

    /// webdav_client only adds an entry from a 200 propstat (xml.dart:44-46), so a response that
    /// carries only 403/404 propstats, or a bare href with a status, does not become a resource.
    @Test func skipsResponsesWithoutA200Propstat() throws {
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response><d:href>/dav/fehviewer/read/</d:href><d:propstat><d:prop>\
            <d:resourcetype><d:collection/></d:resourcetype></d:prop>\
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
              <d:response><d:href>/dav/fehviewer/read/1000001.json</d:href><d:propstat><d:prop>\
            <d:getcontentlength/></d:prop><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat></d:response>
              <d:response><d:href>/dav/fehviewer/read/1000002.json</d:href>\
            <d:status>HTTP/1.1 404 Not Found</d:status></d:response>
              <d:response><d:href>/dav/fehviewer/read/1000003.json</d:href><d:propstat><d:prop>\
            <d:getcontentlength>128</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status>\
            </d:propstat></d:response>
            </d:multistatus>
            """
        let resources = try MultiStatusParser.parse(Data(xml.utf8))
        #expect(resources.map(\.name) == ["read", "1000003.json"])
        #expect(MultiStatusParser.children(of: "/dav/fehviewer/read/", in: resources).map(\.contentLength) == [128])
    }

    @Test func rejectsTruncatedXML() {
        let data = Data(#"<D:multistatus xmlns:D="DAV:"><D:response><D:href>/a"#.utf8)
        #expect(throws: MultiStatusError.self) { try MultiStatusParser.parse(data) }
    }

    @Test func rejectsDocumentsThatAreNotMultiStatus() {
        let html = Data("<html><body><h1>502 Bad Gateway</h1></body></html>".utf8)
        #expect(throws: MultiStatusError.self) { try MultiStatusParser.parse(html) }
    }
}
