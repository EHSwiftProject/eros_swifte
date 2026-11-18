import EHFixtures
import EHModels
import FixtureCaptureCore
import Foundation
import Synchronization

/// Fake credentials and personal data planted in canned pages; none of these values is real. Tests only ever
/// assert Booleans derived from them, so a failure cannot print a value.
enum CaptureFakes {
    static let memberID = "7654321"
    static let passHash = "0a9b8c7d6e5f40312a3b4c5d6e7f8091"
    static let igneous = "9f8e7d6c5b4a"
    static let apikey = "0f1e2d3c4b5a69"
    static let username = "FakeCaptureUser"
    /// The uploader shown on canned detail pages (someone other than the account), and the member id of their PM link.
    static let uploaderName = "FakeOtherUploader"
    static let uploaderID = "2345678"
    /// The name `home.php` shows in `#profilename`; differs from `username` so persisting it is observable.
    static let profileName = "FakeProfileName"
    /// A second account's username, for an identity that changed after the fixtures were captured.
    static let secondUsername = "FakeSecondUser"
    /// A username with a space and an ampersand, for the encoded forms of a name.
    static let spacedName = "Fake Name&Co"
    /// A username with letters outside ASCII, for JSON's `\uXXXX` form.
    static let nonASCIIName = "FakeCapture名前"
    static let favnote = "a private favorite note"
    static let foreignIPv4 = "198.51.100.23"
    /// The torrent key on `home.php`.
    static let torrentKey = "Zq9fakeKey"
    /// The key of the personal torrent link, after `<member id>-`.
    static let torrentLinkKey = "zqfake0torrent0key1"
    /// The number in the announce URL and after `/get/` in the torrent links.
    static let trackerID = "3456789"
    /// The key segment after the tracker number in the torrent links.
    static let torrentSegment = "zq1fake2seg3abc4de"
    /// The info hash of the canned torrent; public, so it stays.
    static let infoHash = "0123456789abcdef0123456789abcdef01234567"
    /// A GP total and a toplist rank on `home.php`.
    static let gpTotal = "12,345,678"
    static let toplistRank = "4321"
    /// The image limit on `home.php`; not personal, so it stays.
    static let imageLimit = "5,000"

    /// The required variables for `sites`, including the username.
    static func environment(sites: Set<EHSite>) -> [String: String] {
        var environment = ["EH_IPB_MEMBER_ID": memberID, "EH_IPB_PASS_HASH": passHash, "EH_USERNAME": username]
        if sites.contains(.ex) { environment["EH_IGNEOUS"] = igneous }
        return environment
    }

    static func credentials(sites: Set<EHSite> = [.eh]) throws -> CaptureCredentials {
        try CaptureCredentials(environment: environment(sites: sites), sites: sites)
    }

    static func site(_ site: EHSite, contentWarning: Bool) -> CaptureTargets.Site {
        CaptureTargets.Site(
            gallery: URL(string: "https://\(site.host)/g/123/abcdef0123/")!,
            contentWarningGallery: contentWarning ? URL(string: "https://\(site.host)/g/456/0123456789/")! : nil,
            search: "language:chinese",
            tag: "language:chinese",
            uploader: "someone",
            tagSuggestText: "chin"
        )
    }

    static func targets(contentWarning: Bool = false) -> CaptureTargets {
        CaptureTargets(eh: site(.eh, contentWarning: contentWarning), ex: site(.ex, contentWarning: contentWarning))
    }

    /// The credentials and every value `CannedSite` plants, as the hygiene checks search for them.
    static var plantedSecrets: [KnownSecret] {
        [
            KnownSecret(kind: .numeric, value: memberID),
            KnownSecret(kind: .literal, value: passHash),
            KnownSecret(kind: .literal, value: igneous),
            KnownSecret(kind: .literal, value: apikey),
            KnownSecret(kind: .word, value: username),
            KnownSecret(kind: .literal, value: favnote),
            KnownSecret(kind: .literal, value: torrentKey),
            KnownSecret(kind: .literal, value: torrentLinkKey),
            KnownSecret(kind: .numeric, value: trackerID),
            KnownSecret(kind: .literal, value: torrentSegment),
            KnownSecret(kind: .numeric, value: gpTotal),
            KnownSecret(kind: .numeric, value: toplistRank),
        ]
    }
}

/// A transport that answers from a closure, records every request and tracks how many were in flight at once.
final class StubTransport: CaptureTransport {
    struct Exhausted: Error {}

    private struct State {
        var requests: [CaptureRequest] = []
        var inFlight = 0
        var maxInFlight = 0
    }

    private let state = Mutex(State())
    private let respond: @Sendable (CaptureRequest, Int) throws -> CaptureResponse

    /// - Parameter respond: Gets each request and its 0-based index.
    init(_ respond: @escaping @Sendable (CaptureRequest, Int) throws -> CaptureResponse) {
        self.respond = respond
    }

    /// Answers with `responses` in order, then throws `Exhausted`.
    convenience init(responses: [CaptureResponse]) {
        self.init { _, index in
            guard index < responses.count else { throw Exhausted() }
            return responses[index]
        }
    }

    func send(_ request: CaptureRequest) async throws -> CaptureResponse {
        let index = state.withLock { state in
            state.requests.append(request)
            state.inFlight += 1
            state.maxInFlight = max(state.maxInFlight, state.inFlight)
            return state.requests.count - 1
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        // Gives a concurrent caller the chance to overlap with this request.
        await Task.yield()
        return try respond(request, index)
    }

    var requests: [CaptureRequest] { state.withLock { $0.requests } }
    var maxConcurrency: Int { state.withLock { $0.maxInFlight } }
}

/// Minimal pages for every step of a site's plan that pass the extraction each step needs, with
/// `CaptureFakes` values planted in them.
struct CannedSite: Sendable {
    /// The canned cover: the start of a JPEG file.
    static let jpegCover = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])

    var site: EHSite = .eh
    var detailHasImagePages = true
    /// False: the detail page has no cover element, so the cover download step is skipped.
    var detailHasCover = true
    /// Whether the detail page's archiver link has the `or=` parameter the current site no longer sends.
    var archiverHasOrKey = true
    /// Whether the detail page shows the account as its uploader (name and PM link).
    var detailUploaderIsSelf = false
    /// Whether the detail page lacks the `var token` the parser needs (its `#gdn` stays).
    var detailIsUnparsable = false
    /// Whether the torrent popup shows the account as a torrent's uploader.
    var torrentUploaderIsSelf = false
    /// Extra text on `home.php`.
    var homeExtra = ""
    /// A favorite note shown on the (private) favorites list, if any.
    var favoritesNote: String?
    /// The cover's `Content-Type` (nil: none) and bytes.
    var coverContentType: String? = "image/jpeg"
    var coverBytes = CannedSite.jpegCover
    /// A tag colored by the account's My Tags, the "Filtered" count and the archiver's funds, as the site renders
    /// them; all values fake.
    static let coloredTag =
        #"<div class="gt" style="color:#123456;border-color:#abcdef;background:radial-gradient(#111111,#222222) !important" title="zqns:zqfaketag">zqfaketag</div>"#
    static let plainTag = #"<div class="gt" title="zqns:zqfaketag">zqfaketag</div>"#
    static let filteredLine = "<p>Found about 12,345 results. Filtered 23 galleries from this page.</p>"
    /// The same paragraph on a list requested with the filters disabled: nothing hidden, so no "Filtered" part.
    static let resultLine = "<p>Found about 12,345 results.</p>"
    static let fundsParagraph =
        #"<p>Current Funds:</p><p>7,654,321 GP [<a href="https://ehwiki.org/wiki/Gallery_Points">?</a>] &nbsp; 432 Credits</p>"#

    /// The image lookup's status (302 with a `Location` by default) and the result page's (200 by default).
    var lookupStatus = 302
    var lookupResultStatus = 200
    /// Whether the site honors the Disable Filters parameters; false: the list pages still say they filtered.
    var honorsDisabledFilters = true

    /// Whether a request of the list at `/` carries all three Disable Filters parameters set to `on`.
    static func disablesFilters(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return ["f_sft", "f_sfu", "f_sfl"].allSatisfy { name in items.contains { $0.name == name && $0.value == "on" } }
    }

    /// Whether the account's filters hide something from this list request: every list at `/` unless the request
    /// disables them (and the site honors that), except the empty search and the image lookup result, which showed no
    /// "Filtered" line in the M0 run either.
    func filters(_ url: URL) -> Bool {
        let query = url.query() ?? ""
        if query.contains("f_shash=") || query.contains("eros0fixture0nohit") { return false }
        return !(honorsDisabledFilters && Self.disablesFilters(url))
    }

    func respond(_ request: CaptureRequest) -> CaptureResponse {
        let url = request.url
        let host = url.host() ?? ""
        let path = url.path()
        let base = "https://\(site.host)"
        if host == "ehgt.org" {
            return CaptureResponse(
                status: 200, headers: coverContentType.map { ["Content-Type": $0] } ?? [:], body: coverBytes, url: url
            )
        }
        if url.lastPathComponent == "image_lookup.php" {
            guard lookupStatus == 302 else { return Self.html("<html><body>Forbidden</body></html>", status: lookupStatus, url: url) }
            return CaptureResponse(
                status: 302,
                headers: ["Content-Type": "text/html; charset=UTF-8", "Location": "\(base)/?f_shash=0123456789abcdef&fs_from=a.jpg"],
                body: Data(), url: url
            )
        }
        if url.query()?.contains("f_shash=") == true, lookupResultStatus != 200 {
            return Self.html("<html><body>Not Found</body></html>", status: lookupResultStatus, url: url)
        }
        if path == "/api.php" {
            return CaptureResponse(
                status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"ok":1}"#.utf8), url: url
            )
        }
        if path == "/g/1/0000000000/" {
            // Plain text, as the site may answer an unknown gallery.
            return Self.html("Key missing, or incorrect key provided.", url: url)
        }
        if path.hasPrefix("/g/") {
            return Self.html(
                Self.detailPage(
                    host: site.host, imagePages: detailHasImagePages, archiverOrKey: archiverHasOrKey, cover: detailHasCover,
                    uploaderIsSelf: detailUploaderIsSelf, parsable: !detailIsUnparsable
                ),
                url: url
            )
        }
        if path.hasPrefix("/s/") {
            return Self.html(
                ##"<html><body><script>var showkey="abc123def4";</script><a href="#" id="loadfail" onclick="return nl('12345-430636')">Reload broken image</a></body></html>"##,
                url: url
            )
        }
        if path.hasPrefix("/mpv/") {
            return Self.html(
                #"<html><body><script>var mpvkey = "k1a2b3"; var imagelist = [{"n":"1.jpg","k":"fedcba9876","t":"x"}];</script></body></html>"#,
                url: url
            )
        }
        if path == "/gallerypopups.php" {
            return Self.html(#"<html><body><textarea name="favnote">\#(CaptureFakes.favnote)</textarea></body></html>"#, url: url)
        }
        if path == "/favorites.php", let favoritesNote {
            return Self.html(#"<html><body><div class="glfnote">Note: \#(favoritesNote)</div></body></html>"#, url: url)
        }
        if path == "/archiver.php" {
            return Self.html("<html><body>\(Self.fundsParagraph)<p>Download Cost: 1,234 GP</p></body></html>", url: url)
        }
        if path == "/gallerytorrents.php" {
            return Self.html(
                Self.torrentsPage(uploader: torrentUploaderIsSelf ? CaptureFakes.username : CaptureFakes.uploaderName),
                url: url
            )
        }
        if path == "/home.php" {
            return Self.html(
                #"<html><body><div id="profilename">\#(CaptureFakes.profileName)</div><p>Current IP: \#(CaptureFakes.foreignIPv4)</p>\#(homeExtra)"#
                    + Self.homeSections + "</body></html>",
                url: url
            )
        }
        if path == "/uconfig.php" {
            return Self.html("<html><body><p>ipb_pass_hash=\(CaptureFakes.passHash)</p></body></html>", url: url)
        }
        if path == "/" {
            return Self.html(Self.listPage(mode: "l", host: site.host, filtered: filters(url)), url: url)
        }
        return Self.html("<html><body><p>ok</p></body></html>", url: url)
    }

    /// The file search form action each site's front page has: E-Hentai's upload host, ExHentai's own `/upld/` path
    /// (the hosts `CapturePlan.isImageLookupURL` accepts).
    static func lookupAction(host: String) -> String {
        host == "exhentai.org" ? "https://exhentai.org/upld/image_lookup.php" : "https://upld.\(host)/image_lookup.php"
    }

    /// A gallery list with the display mode selector (`mode` selected, none without it), four Compact rows that link
    /// a gallery each (so `GalleryListParser` reads the page), a next page link (`nextHref`, defaulting to page 2 on
    /// `host`), the file search form (`lookupAction`) and the result total, with the "Filtered" count when `filtered`.
    static func listPage(
        mode: String?, host: String = "e-hentai.org", nextHref: String? = nil, lookupAction: String? = nil,
        filtered: Bool = true
    ) -> String {
        let selector = mode.map { selected in
            let options = ["m", "p", "l", "e", "t"].map { code in
                code == selected
                    ? #"<option value="\#(code)" selected="selected">\#(code)</option>"#
                    : #"<option value="\#(code)">\#(code)</option>"#
            }
            return #"<div id="dms"><div><select>\#(options.joined())</select></div></div>"#
        } ?? ""
        let next = nextHref ?? "https://\(host)/?next=104&amp;f_search=x"
        let rows = [("101", "0a0a0a0a0a", "A"), ("102", "0b0b0b0b0b", "B"), ("103", "0c0c0c0c0c", "C"), ("104", "0d0d0d0d0d", "D")]
            .map { gid, token, title in
                #"<tr><td class="gl1c glcat"><div>Doujinshi</div></td><td class="gl3c glname"><a href="https://\#(host)/g/\#(gid)/\#(token)/"><div class="glink">\#(title)</div></a></td></tr>"#
            }
            .joined(separator: "\n")
        let action = lookupAction ?? Self.lookupAction(host: host)
        return """
        <html><body>
        <form action="\(action)" method="post" enctype="multipart/form-data"><input type="file" name="sfile"></form>
        \(selector)
        <table class="itg gltc">
        \(rows)
        </table>
        <a id="unext" href="\(next)">Next &gt;</a>
        \(filtered ? Self.filteredLine : Self.resultLine)
        <table><tr><td>\(Self.coloredTag)\(Self.plainTag)</td></tr></table>
        <script>var apiuid = \(CaptureFakes.memberID); var apikey = "\(CaptureFakes.apikey)";</script>
        </body></html>
        """
    }

    /// A detail page with the `var gid`, `var token` and `#gn` the parser needs; `archiverOrKey: false` gives the
    /// archiver link the current site's shape, without `or=`; `parsable: false` leaves out `var token`.
    static func detailPage(
        host: String, imagePages: Bool, archiverOrKey: Bool = true, cover: Bool = true, uploaderIsSelf: Bool = false,
        parsable: Bool = true
    ) -> String {
        let uploader = uploaderIsSelf ? CaptureFakes.username : CaptureFakes.uploaderName
        let uploaderID = uploaderIsSelf ? CaptureFakes.memberID : CaptureFakes.uploaderID
        let links = imagePages
            ? """
            <a href="https://\(host)/s/0a1b2c3d4e/123-1">1</a>
            <a href="https://\(host)/s/f0e1d2c3b4/123-2">2</a>
            """
            : ""
        let archiver = archiverOrKey
            ? "popUp('https://\(host)/archiver.php?gid=123&amp;token=abcdef0123&amp;or=474357--a8c5d0', 480, 320)"
            : "popUp('https://\(host)/archiver.php?gid=123&amp;token=abcdef0123',480,320)"
        return """
        <html><body>
        \(cover ? #"<div id="gd1"><div style="width:250px;background:transparent url(https://ehgt.org/ab/cd/x.jpg) 0 0 no-repeat"></div></div>"# : "")
        <h1 id="gn">Fake gallery title</h1>
        <div id="nb"><a href="https://forums.e-hentai.org/index.php?showuser=\(CaptureFakes.memberID)">My profile</a></div>
        <div id="gdn"><a href="https://\(host)/uploader/\(uploader)">\(uploader)</a>&nbsp; <a href="https://forums.e-hentai.org/index.php?showuser=\(uploaderID)">PM</a></div>
        \(links)
        <a href="#" onclick="return \(archiver)">Archive Download</a>
        <script>var gid = 123; \(parsable ? #"var token = "abcdef0123"; "# : "")var apiuid = \(CaptureFakes.memberID); var apikey = "\(CaptureFakes.apikey)";</script>
        </body></html>
        """
    }

    /// The torrent popup, its torrent uploaded by someone other than the account.
    static var torrentsPage: String { torrentsPage(uploader: CaptureFakes.uploaderName) }

    /// The torrent popup: one torrent by `uploader` with the plain and the personal download link, and the announce
    /// URL for new torrents.
    static func torrentsPage(uploader: String) -> String {
        let path = "https://ehtracker.org/get/\(CaptureFakes.trackerID)/\(CaptureFakes.torrentSegment)"
        return """
        <html><body>
        <div id="torrentinfo"><div>
        <form method="post" action="https://e-hentai.org/gallerytorrents.php?gid=123&amp;t=abcdef0123">
        <table><tr><td colspan="5"><span style="font-weight:bold">Uploader:</span> \(uploader)</td></tr>
        <tr><td colspan="5"><a href="\(path)/\(CaptureFakes.infoHash).torrent" onclick="document.location='\(path)/\(CaptureFakes.memberID)-\(CaptureFakes.torrentLinkKey)/\(CaptureFakes.infoHash).torrent'; return false">x.zip</a></td></tr></table>
        </form></div>
        <p>Announce: <span style="font-weight:bold">http://ehtracker.org/\(CaptureFakes.trackerID)/announce</span></p>
        </div>
        </body></html>
        """
    }

    /// The `home.php` sections after the profile: image limits (kept), the torrent key, and statistics (masked).
    static var homeSections: String {
        """
        <h2>Image Limits</h2>
        <div class="homebox"><p>You are currently at <strong>12</strong> towards a limit of <strong>\(CaptureFakes.imageLimit)</strong>.</p></div>
        <h2>EHTracker</h2>
        <div class="homebox">
        <table><tr><td class="c1">2.50 GiB</td><td> Uploaded</td></tr></table>
        <p>Your current key is: <span style="font-weight:bold">\(CaptureFakes.torrentKey)</span></p>
        </div>
        <h2>Total GP Gained</h2>
        <div class="homebox"><table><tr><td style="font-weight:bold">\(CaptureFakes.gpTotal)</td><td>GP from Hentai@Home</td></tr></table></div>
        <h2>Toplists</h2>
        <div class="homebox"><table><tr><td><strong>#\(CaptureFakes.toplistRank)</strong></td><td>on the <a href="https://e-hentai.org/toplist.php?tl=31">Hentai@Home Past Year</a> toplist</td></tr></table></div>
        """
    }

    static func html(_ text: String, status: Int = 200, url: URL = URL(string: "https://e-hentai.org/")!) -> CaptureResponse {
        CaptureResponse(status: status, headers: ["Content-Type": "text/html; charset=UTF-8"], body: Data(text.utf8), url: url)
    }
}
