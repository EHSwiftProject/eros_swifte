import EHFixtures
import EHModels
import FixtureCaptureCore
import Foundation
import Testing

/// `OwnContentCheck` against pages that show the fake account (`CaptureFakes`) or other people. Only rule names and
/// Booleans are asserted, so a failure never prints a value.
struct OwnContentTests {
    private let identity = OwnIdentity(
        words: [CaptureFakes.username, CaptureFakes.profileName], memberIDs: [CaptureFakes.memberID]
    )

    private func raw(path: String, body: Data) -> RawCapture {
        RawCapture(
            fixturePath: path, site: .eh, method: "GET", url: URL(string: "https://e-hentai.org/")!, status: 200,
            headers: [:], body: body, capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func raw(path: String, body: String) -> RawCapture {
        raw(path: path, body: Data(body.utf8))
    }

    private func rules(_ path: String, _ body: String, identity: OwnIdentity? = nil) -> [String] {
        OwnContentCheck.findings(in: [raw(path: path, body: body)], identity: identity ?? self.identity).map(\.rule)
    }

    /// The committed sample detail page, whose `#gdn` is replaced by `gdn` (the page keeps its `var gid` and
    /// `var token`, which the parser needs, unless `edit` takes them out).
    private func detail(gdn: String? = nil, edit: (String) -> String = { $0 }) throws -> String {
        var html = try Fixtures.string("eh/gallery/detail.html")
        if let gdn {
            let range = try #require(html.range(of: #"<div id="gdn">.*?</div>"#, options: .regularExpression))
            html.replaceSubrange(range, with: #"<div id="gdn">\#(gdn)</div>"#)
        }
        return edit(html)
    }

    /// `html` without the `var token` its gallery script sets, so `GalleryDetailParser` throws.
    private func withoutToken(_ html: String) -> String {
        html.replacingOccurrences(of: #"var token = "[0-9a-f]{10}";"#, with: "", options: .regularExpression)
    }

    /// `html` with the first comment header's poster link (`div.c3`) replaced by `poster`.
    private func firstCommenter(_ html: String, as poster: String) throws -> String {
        var html = html
        let range = try #require(html.range(
            of: #"(?<=<div class="c3">)([^<]*)<a href="https://e-hentai.org/uploader/[^"]*">[^<]*</a>"#,
            options: .regularExpression
        ))
        let lead = try #require(html[range].range(of: "<a "))
        html.replaceSubrange(lead.lowerBound..<range.upperBound, with: poster)
        return html
    }

    /// `html` with the member id of the first comment header's PM link replaced by `memberID`.
    private func firstCommenterID(_ html: String, as memberID: String) throws -> String {
        var html = html
        let header = try #require(html.range(of: #"<div class="c3">.*?</div>"#, options: .regularExpression))
        let id = try #require(html.range(of: #"(?<=showuser=)[0-9]+"#, options: .regularExpression, range: header))
        html.replaceSubrange(id, with: memberID)
        return html
    }

    private func uploaderLink(_ name: String) -> String {
        #"<a href="https://e-hentai.org/uploader/\#(name)">\#(name)</a>"#
    }

    private func list(uploaderCell: String) -> String {
        #"<html><body><table><tr><td class="gl4c glhide"><div>\#(uploaderCell)</div><div>74 pages</div></td></tr></table></body></html>"#
    }

    /// The committed sample torrent popup, every `Uploader:` cell naming `uploader`.
    private func torrents(uploader: String, edit: (String) -> String = { $0 }) throws -> String {
        let html = try Fixtures.string("eh/popup/torrents.html")
        let named = html.replacingOccurrences(
            of: #"(Uploader:</span>)[^<]*"#, with: "$1 \(uploader)", options: .regularExpression
        )
        return edit(named)
    }

    // MARK: Uploads and comments

    @Test func ownUploaderInAListIsRefused() {
        let body = list(uploaderCell: uploaderLink(CaptureFakes.username))
        #expect(rules("eh/list/front.html", body) == ["ownupload"])
    }

    @Test func profileNameAsUploaderIsRefused() {
        let body = list(uploaderCell: uploaderLink(CaptureFakes.profileName))
        #expect(rules("eh/list/front.html", body) == ["ownupload"])
    }

    @Test func otherUploadersPass() {
        for name in [CaptureFakes.uploaderName, "\(CaptureFakes.username)2"] {
            let body = list(uploaderCell: uploaderLink(name))
            #expect(rules("eh/list/front.html", body).isEmpty)
        }
    }

    @Test func unlinkedUploaderIsRefused() throws {
        let page = try detail(gdn: CaptureFakes.username)
        let unlinked = !page.localizedCaseInsensitiveContains("/uploader/\(CaptureFakes.username)")
        #expect(unlinked)
        #expect(rules("eh/gallery/detail.html", page) == ["ownupload"])
    }

    @Test func uploaderMemberIDIsRefused() throws {
        let page = try detail(
            gdn: uploaderLink(CaptureFakes.uploaderName)
                + #"&nbsp; <a href="https://forums.e-hentai.org/index.php?showuser=\#(CaptureFakes.memberID)">PM</a>"#
        )
        #expect(rules("eh/gallery/detail.html", page) == ["ownupload"])
    }

    @Test func ownCommentIsRefused() throws {
        let byName = try firstCommenter(detail(), as: uploaderLink(CaptureFakes.username))
        #expect(rules("eh/gallery/detail.html", byName) == ["owncomment"])
        let byID = try firstCommenterID(detail(), as: CaptureFakes.memberID)
        #expect(rules("eh/gallery/detail.html", byID) == ["owncomment"])
    }

    @Test func unlinkedCommenterIsRefused() throws {
        let page = try firstCommenter(detail(), as: CaptureFakes.username)
        #expect(rules("eh/gallery/detail.html", page) == ["owncomment"])
    }

    @Test func memberIDElsewherePasses() throws {
        let page = try detail { html in
            html.replacingOccurrences(of: "</body>", with: """
                <div id="nb"><a href="https://forums.e-hentai.org/index.php?showuser=\(CaptureFakes.memberID)">My profile</a></div>
                <script>var apiuid = \(CaptureFakes.memberID);</script></body>
                """)
        }
        let hasID = page.contains("showuser=\(CaptureFakes.memberID)") && page.contains("apiuid = \(CaptureFakes.memberID)")
        #expect(hasID)
        #expect(rules("eh/gallery/detail.html", page).isEmpty)
    }

    @Test func ownNameInAnyEncodingIsRefused() throws {
        let spaced = OwnIdentity(words: [CaptureFakes.spacedName], memberIDs: [])
        let paths = [
            CaptureFakes.spacedName.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "&", with: "%26"),
            CaptureFakes.spacedName.replacingOccurrences(of: " ", with: "+").replacingOccurrences(of: "&", with: "%26"),
            CaptureFakes.spacedName.uppercased().replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "&", with: "%26"),
        ]
        for path in paths {
            let body = list(uploaderCell: #"<a href="https://e-hentai.org/uploader/\#(path)">x</a>"#)
            #expect(rules("eh/list/front.html", body, identity: spaced) == ["ownupload"])
            // The same links in a gallery's `#gdn`.
            let page = try detail(gdn: #"<a href="https://e-hentai.org/uploader/\#(path)">x</a>"#)
            #expect(rules("eh/gallery/detail.html", page, identity: spaced) == ["ownupload"])
        }
        let escaped = try detail(gdn: CaptureFakes.spacedName.replacingOccurrences(of: "&", with: "&amp;"))
        #expect(rules("eh/gallery/detail.html", escaped, identity: spaced) == ["ownupload"])
        let upper = list(uploaderCell: #"<a href="https://e-hentai.org/uploader/\#(CaptureFakes.username.uppercased())">x</a>"#)
        #expect(rules("eh/list/front.html", upper) == ["ownupload"])
    }

    @Test func gdataUploaderIsRefused() {
        let body = #"{"gmetadata":[{"gid":1,"uploader": "\#(CaptureFakes.username)"}]}"#
        #expect(rules("eh/api/gdata.json", body) == ["ownupload"])
        let other = #"{"gmetadata":[{"gid":1,"uploader": "\#(CaptureFakes.uploaderName)"}]}"#
        #expect(rules("eh/api/gdata.json", other).isEmpty)
    }

    /// gdata as PHP's `json_encode` writes it: every non-ASCII character as `\uXXXX`, in either case of hex digit.
    @Test func gdataEscapedNameIsRefused() {
        let unicode = OwnIdentity(words: [CaptureFakes.nonASCIIName], memberIDs: [])
        let escaped = CaptureFakes.nonASCIIName.unicodeScalars.map { scalar in
            scalar.isASCII ? String(scalar) : String(format: #"\u%04x"#, scalar.value)
        }.joined()
        let hasEscape = escaped.contains(#"\u"#)
        #expect(hasEscape)
        for form in [escaped, escaped.uppercased().replacingOccurrences(of: #"\U"#, with: #"\u"#)] {
            let body = #"{"gmetadata":[{"gid":1,"uploader":"\#(form)"}]}"#
            #expect(rules("eh/api/gdata.json", body, identity: unicode) == ["ownupload"])
        }
    }

    /// `id='gdn'` and `class='c3'` in single quotes. The parser cannot read these pages (no `var token`), so only the
    /// text layer sees the member id.
    @Test func singleQuotedMarkupIsRefused() throws {
        let profile = #"<a href='https://forums.e-hentai.org/index.php?showuser=\#(CaptureFakes.memberID)'>PM</a>"#
        let uploader = try detail(gdn: profile) { html in
            self.withoutToken(html).replacingOccurrences(of: #"<div id="gdn">"#, with: "<div id='gdn'>")
        }
        #expect(rules("eh/gallery/detail.html", uploader) == ["owncheck", "ownupload"])
        let commenter = try withoutToken(firstCommenterID(detail(), as: CaptureFakes.memberID))
            .replacingOccurrences(of: #"<div class="c3">"#, with: "<div class='c3'>")
        #expect(rules("eh/gallery/detail.html", commenter) == ["owncheck", "owncomment"])
    }

    @Test func privatePagesPass() {
        let body = list(uploaderCell: uploaderLink(CaptureFakes.username))
        #expect(rules("eh/list/watched.html", body).isEmpty)
        #expect(rules("eh/list/favorites.html", body).isEmpty)
        // The same page at a public path is refused: only the path lets it through.
        #expect(rules("eh/list/front.html", body) == ["ownupload"])
    }

    @Test func oneFindingPerFileAndRule() {
        let link = uploaderLink(CaptureFakes.username)
        let body = "<p>a</p>\n<p>b</p>\n\(link)\n<p>c</p>\n\(link)\n<p>d</p>\n<p>e</p>\n<p>f</p>\n\(link)\n"
        let found = OwnContentCheck.findings(in: [raw(path: "eh/list/front.html", body: body)], identity: identity)
        #expect(found.count == 1)
        #expect(found.first?.line == 3)
    }

    @Test func findingsShowNoValues() {
        let link = uploaderLink(CaptureFakes.username)
        let found = OwnContentCheck.findings(in: [raw(path: "eh/list/front.html", body: link)], identity: identity)
        let shown = [String(describing: found), String(describing: identity), String(reflecting: identity)]
        let leaks = shown.contains { text in
            [CaptureFakes.username, CaptureFakes.profileName, CaptureFakes.memberID].contains { text.contains($0) }
        }
        #expect(!found.isEmpty)
        #expect(!leaks)
    }

    // MARK: Pages that cannot be checked (fail closed)

    @Test func uncheckableGalleryPageIsRefused() throws {
        let page = try withoutToken(detail())
        let othersOnly = !page.localizedCaseInsensitiveContains(CaptureFakes.username)
        #expect(othersOnly)
        #expect(rules("eh/gallery/detail.html", page) == ["owncheck"])
    }

    /// The text layer finds a name without a link in `#gdn` or a comment header by itself, so a page the parser
    /// cannot read still names the rule.
    @Test func unlinkedUploaderIsFoundWithoutTheParser() throws {
        let uploader = try withoutToken(detail(gdn: CaptureFakes.username))
        #expect(rules("eh/gallery/detail.html", uploader) == ["owncheck", "ownupload"])
        let commenter = try withoutToken(firstCommenter(detail(), as: CaptureFakes.username))
        #expect(rules("eh/gallery/detail.html", commenter) == ["owncheck", "owncomment"])
        // A longer name that starts with the account's is someone else.
        let longer = try withoutToken(detail(gdn: "\(CaptureFakes.username)2"))
        #expect(rules("eh/gallery/detail.html", longer) == ["owncheck"])
    }

    /// The text layer compares whole names in the text between tags only: an account named like one of the page's
    /// fixed words (in attributes such as `title="Contact Poster"`, or the `Posted on … by:` of a comment header) is
    /// not found on every page, and a longer name that only starts with the account's (`-x`, ` fan`, `-chan`) is
    /// someone else's.
    @Test func bareNamesInMarkupOrLongerNamesPass() throws {
        let page = try detail()
        for word in ["Contact", "Uploader", "Poster", "Posted", "PM"] {
            let fixed = OwnIdentity(words: [word], memberIDs: [])
            #expect(rules("eh/gallery/detail.html", page, identity: fixed).isEmpty, "\(word)")
        }
        let hyphenated = try detail(gdn: "\(CaptureFakes.username)-x")
        #expect(rules("eh/gallery/detail.html", hyphenated).isEmpty)
        let spaced = try detail(gdn: "\(CaptureFakes.username) fan")
        #expect(rules("eh/gallery/detail.html", spaced).isEmpty)
        let commenter = try firstCommenter(detail(), as: "\(CaptureFakes.username)-chan")
        #expect(rules("eh/gallery/detail.html", commenter).isEmpty)
        let torrent = try torrents(uploader: "\(CaptureFakes.username) fan")
        #expect(rules("eh/popup/torrents.html", torrent).isEmpty)
        let dotted = try torrents(uploader: "\(CaptureFakes.username).x")
        #expect(rules("eh/popup/torrents.html", dotted).isEmpty)
    }

    // MARK: The parser layer alone

    /// Names only the parsers see: the text layer, which compares a name with the text as written, misses a name
    /// broken over lines inside `#gdn` (the parser reads text with its whitespace collapsed). The same page at a path
    /// no parser reads shows what the text layer finds by itself: nothing.
    @Test func aNameOverTwoLinesInGdnIsFoundByTheParser() throws {
        let spaced = OwnIdentity(words: [CaptureFakes.spacedName], memberIDs: [])
        let name = Self.overTwoLines(CaptureFakes.spacedName)
        let page = try detail(gdn: name)
        #expect(rules(Self.unparsedPath, page, identity: spaced).isEmpty)
        #expect(rules("eh/gallery/detail.html", page, identity: spaced) == ["ownupload"])
    }

    /// A Compact row whose uploader is plain text (no `/uploader/` link), broken over lines: only the list parser
    /// reads it.
    @Test func aPlainUploaderInAListRowIsFoundByTheParser() {
        let spaced = OwnIdentity(words: [CaptureFakes.spacedName], memberIDs: [])
        let link = #"<a href="https://e-hentai.org/g/101/0a0a0a0a0a/"><div class="glink">A</div></a>"#
        let uploader = #"<div>\#(Self.overTwoLines(CaptureFakes.spacedName))</div><div>74 pages</div>"#
        let row = #"<tr><td class="gl1c glcat"><div>Doujinshi</div></td><td class="gl3c glname">\#(link)</td>"#
            + #"<td class="gl4c glhide">\#(uploader)</td></tr>"#
        let body = #"<html><body><table class="itg gltc">\#(row)</table></body></html>"#
        #expect(rules(Self.unparsedPath, body, identity: spaced).isEmpty)
        #expect(rules("eh/list/front.html", body, identity: spaced) == ["ownupload"])
    }

    /// A torrent whose uploader sits in an element of its own after the label (`<b>`): only the torrent parser, which
    /// reads the cell's text after `Uploader:`, finds it.
    @Test func aTorrentUploaderInItsOwnElementIsFoundByTheParser() throws {
        let own = try torrents(uploader: CaptureFakes.username) { html in
            html.replacingOccurrences(
                of: #"Uploader:</span>[^<]*"#, with: "Uploader:</span> <b>\(CaptureFakes.username)</b>",
                options: .regularExpression
            )
        }
        let wrapped = own.contains("Uploader:</span> <b>\(CaptureFakes.username)</b>")
        #expect(wrapped)
        #expect(rules(Self.unparsedPath, own).isEmpty)
        #expect(rules("eh/popup/torrents.html", own) == ["owntorrent"])
    }

    /// A path that is public and that no parser of the check reads (not a list, a gallery or the torrent popup).
    private static let unparsedPath = "eh/other/page.html"

    /// `name` with every space a line break and an indent, as a page's source may wrap it.
    private static func overTwoLines(_ name: String) -> String {
        name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: " ", with: "\n        ")
    }

    @Test func uncheckableListIsRefused() {
        // A Compact row without a title: `GalleryListParser` throws `missing("gallery rows")`.
        let row = #"<tr><td class="gl1c glcat"><div>Doujinshi</div></td><td class="gl3c glname"><a href="https://e-hentai.org/g/101/0a0a0a0a0a/"></a></td></tr>"#
        let body = #"<html><body><table class="itg gltc">\#(row)</table></body></html>"#
        #expect(rules("eh/list/front.html", body) == ["owncheck"])
        // Rows in markup the parser does not know, with only a gallery link left.
        let renamed = #"<html><body><div class="gallery-grid"><a href="https://e-hentai.org/g/101/0a0a0a0a0a/">x</a></div></body></html>"#
        #expect(rules("eh/list/front.html", renamed) == ["owncheck"])
    }

    @Test func pagesWithoutCheckedMarkupPass() throws {
        let contentWarning = """
            <html><body><div id="nb"><a href="https://forums.e-hentai.org/index.php?showuser=\(CaptureFakes.memberID)">My profile</a></div>
            <div><h1>Content Warning</h1><p>This gallery has been flagged as Offensive For Everyone.</p>
            <p><a href="https://e-hentai.org/g/456/0123456789/?nw=session">View Gallery</a>
            [<a href="https://e-hentai.org/g/456/0123456789/?nw=always">Never Warn Me Again</a>]</p></div></body></html>
            """
        #expect(rules("eh/gallery/content-warning.html", contentWarning).isEmpty)
        #expect(rules("eh/gallery/not-found.html", try Fixtures.string("eh/gallery/not-found.html")).isEmpty)
        #expect(rules("eh/gallery/not-found.html", "Key missing, or incorrect key provided.").isEmpty)
        #expect(rules("eh/list/image-lookup-redirect.html", "").isEmpty)
        #expect(rules("eh/list/search-empty.html", try Fixtures.string("eh/list/search-empty.html")).isEmpty)
        // A torrent popup without `#torrentinfo` (a gallery that no longer exists).
        #expect(rules("eh/popup/torrents.html", "<html><body><p>Gallery not found.</p></body></html>").isEmpty)
    }

    @Test func undecodableBodyIsRefused() {
        let bytes = Data([0xFF, 0xFE])
        let found = OwnContentCheck.findings(in: [raw(path: "eh/list/front.html", body: bytes)], identity: identity)
        #expect(found.map(\.rule) == ["owncheck"])
        #expect(found.first?.line == 1)
        let privatePage = OwnContentCheck.findings(in: [raw(path: "eh/list/watched.html", body: bytes)], identity: identity)
        #expect(privatePage.isEmpty)
    }

    /// Every checked-in captured fixture outside the private pages passes: the new rules refuse none of them.
    @Test func committedPublicFixturesPass() throws {
        let entries = try Fixtures.manifest().entries.filter { $0.source == .captured && !PrivateFixtures.isPrivate($0.path) }
        #expect(entries.count >= Fixtures.minimumCapturedFixtures.values.reduce(0, +))
        let raws = try entries.map { raw(path: $0.path, body: try Fixtures.data($0.path)) }
        let found = OwnContentCheck.findings(in: raws, identity: identity)
        #expect(found.isEmpty, "\(found)")
    }

    // MARK: Torrents

    @Test func ownTorrentUploaderIsRefused() throws {
        let own = try torrents(uploader: CaptureFakes.username)
        #expect(rules("eh/popup/torrents.html", own) == ["owntorrent"])
        let profileName = try torrents(uploader: CaptureFakes.profileName)
        #expect(rules("eh/popup/torrents.html", profileName) == ["owntorrent"])
        let other = try torrents(uploader: CaptureFakes.uploaderName)
        #expect(rules("eh/popup/torrents.html", other).isEmpty)
        let longer = try torrents(uploader: "\(CaptureFakes.username)2")
        #expect(rules("eh/popup/torrents.html", longer).isEmpty)
    }

    /// A torrent link without an info hash makes `TorrentListParser` throw: the popup cannot be checked, and the text
    /// layer still finds the account in `#torrentinfo`.
    @Test func uncheckableTorrentPopupIsRefused() throws {
        func withoutHash(_ html: String) -> String {
            html.replacingOccurrences(of: #"[0-9a-f]{40}\.torrent"#, with: "x.torrent", options: .regularExpression)
        }
        let other = try torrents(uploader: CaptureFakes.uploaderName, edit: withoutHash)
        #expect(rules("eh/popup/torrents.html", other) == ["owncheck"])
        let own = try torrents(uploader: CaptureFakes.username, edit: withoutHash)
        #expect(rules("eh/popup/torrents.html", own) == ["owncheck", "owntorrent"])
        // `#torrentinfo` on another element than a `div`: the parser still reads it (and throws), so the popup is
        // still one this check cannot read.
        let section = try torrents(uploader: CaptureFakes.uploaderName) { html in
            withoutHash(html).replacingOccurrences(of: #"<div id="torrentinfo""#, with: #"<section id="torrentinfo""#)
        }
        let moved = section.contains(#"<section id="torrentinfo""#) && !section.contains(#"<div id="torrentinfo""#)
        #expect(moved)
        #expect(rules("eh/popup/torrents.html", section) == ["owncheck"])
    }

    // MARK: Explanation

    @Test func explanationAdvisesOnEachRuleWithoutValues() {
        let rules = [
            OwnContentCheck.uploadRule, OwnContentCheck.torrentRule, OwnContentCheck.commentRule,
            OwnContentCheck.uncheckedRule,
        ]
        #expect(rules == ["ownupload", "owntorrent", "owncomment", "owncheck"])
        for rule in rules {
            let finding = HygieneViolation(file: "eh/gallery/detail.html", rule: rule, line: 3)
            let lines = OwnContentCheck.explanation(of: [finding]).split(separator: "\n").map(String.init)
            let first = lines.first ?? ""
            let refuses = first.hasPrefix("Refused to write:") && first.hasSuffix("No fixtures were written.")
            #expect(refuses, "\(rule)")
            #expect(lines.contains("  \(finding)"), "\(rule)")
            let advised = lines.filter { $0.hasPrefix("  \(rule): ") }.count == 1
            #expect(advised, "\(rule)")
            // Only the rules found are advised on.
            let others = rules.filter { $0 != rule }.filter { other in lines.contains { $0.hasPrefix("  \(other): ") } }
            #expect(others.isEmpty, "\(rule)")
        }
        let all = OwnContentCheck.explanation(of: rules.map { HygieneViolation(file: "eh/list/front.html", rule: $0, line: 1) })
        let leaks = [CaptureFakes.username, CaptureFakes.profileName, CaptureFakes.memberID].contains { all.contains($0) }
        #expect(!leaks)
        #expect(all.contains("could not be checked"))
    }
}
