import EHFixtures
import EHModels
import EHParsing
import Foundation
import Testing

// Captured pages and answers are checked by structure only: presence, formats, counts, and agreement with another
// fixture of the same site (the gallery page, the MPV page). Their URLs, keys, tokens and file names are compared as
// Booleans bound before `#expect`, so that a failure prints no value. Hand-written pages and answers carry made-up
// values (gid 900001, token 0f0f0f0f0f, abc.hath.network, "Fake …") and are compared exactly.

// MARK: Helpers for captured fixtures

/// The optional parts of an `ImagePageInfo`; a string counts only when it is not empty.
private enum Part: String, CaseIterable, CustomStringConvertible {
    case gid, token, pageCount, imageSize, fileName, fileSizeText, originalImageURL, reloadToken, showKey, imageKey
    var description: String { rawValue }
}

/// The parts `info` has. Compared as a whole, so a failure prints part names only.
private func parts(of info: ImagePageInfo) -> Set<Part> {
    let present: [Part: Bool] = [
        .gid: info.gid != nil,
        .token: info.token?.isEmpty == false,
        .pageCount: info.pageCount != nil,
        .imageSize: info.imageSize != nil,
        .fileName: info.fileName?.isEmpty == false,
        .fileSizeText: info.fileSizeText?.isEmpty == false,
        .originalImageURL: info.originalImageURL != nil,
        .reloadToken: info.reloadToken?.isEmpty == false,
        .showKey: info.showKey?.isEmpty == false,
        .imageKey: info.imageKey?.isEmpty == false,
    ]
    return Set(present.filter(\.value).keys)
}

private let allParts = Set(Part.allCases)

private func detail(_ site: EHSite) throws -> GalleryDetail {
    try GalleryDetailParser.parse(Fixtures.string("\(site.rawValue)/gallery/detail.html"))
}

private func imagePage(_ path: String) throws -> ImagePageInfo {
    try ImagePageParser.parse(Fixtures.string(path))
}

private func mpv(_ site: EHSite) throws -> MPVInfo {
    try MPVPageParser.parse(Fixtures.string("\(site.rawValue)/mpv/mpv.html"))
}

private func isHexKey(_ text: String) -> Bool {
    text.count == 10 && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
}

/// "393.4 KiB", "1.2 MiB", "512 B": the size line's last part.
private func isFileSize(_ text: String?) -> Bool {
    text?.wholeMatch(of: /[0-9]+(\.[0-9]+)? (B|KiB|MiB|GiB)/) != nil
}

private func isPositive(_ size: ImageSize?) -> Bool {
    size.map { $0.width > 0 && $0.height > 0 } ?? false
}

// MARK: Hand-written image page, after the captured pages' markup

/// An H@H address of the captured pages' shape: a hash path, then `keystamp=…;fileindex=…;xres=…`, then the name.
private let fakeImageSource =
    "https://abc.hath.network:1111/h/fakehash-1-1280-1808-wbp/keystamp=1-fake;fileindex=1;xres=1280/fake.webp"

private let fakeNavigation = """
<div class="sn"><a onclick="return load_image(1, '0a0a0a0a0a')" href="https://e-hentai.org/s/0a0a0a0a0a/900001-1">\
<img src="https://ehgt.org/g/f.png" /></a><a id="prev" href="https://e-hentai.org/s/0b0b0b0b0b/900001-2">\
<img src="https://ehgt.org/g/p.png" /></a><div><span>3</span> / <span>1,234</span></div>\
<a id="next" href="https://e-hentai.org/s/0d0d0d0d0d/900001-4"><img src="https://ehgt.org/g/n.png" /></a></div>
"""

private let fakeFileInfo = "<div>Fake Page 03 &amp; more.jpg :: 1280 x 1808 :: 393.4 KiB</div>"

/// A made-up image page (page 3 of 1,234) with every part the parser reads.
private let fakeImagePage = """
<html><head><title>Fake Gallery 1</title></head><body>
<script type="text/javascript">var gid=900001;var startpage=3;var startkey="0c0c0c0c0c";var showkey="fakeshowkey";\
var base_url="https://e-hentai.org/";</script>
<div id="i1" class="sni"><h1>Fake Gallery 1</h1>
<div id="i2">\(fakeNavigation)\(fakeFileInfo)</div>
<div id="i3"><a href="https://e-hentai.org/s/0d0d0d0d0d/900001-4"><img id="img" src="\(fakeImageSource)" \
style="height:1808px;width:1280px" onerror="this.onerror=null; nl('fake-nl-3')" /></a></div>
<div id="i4">\(fakeFileInfo)\(fakeNavigation)</div>
<div id="i5"><div class="sb"><a href="https://e-hentai.org/g/900001/0f0f0f0f0f/"><img src="https://ehgt.org/g/b.png" /></a></div></div>
<div id="i6">
<div><a href="https://e-hentai.org/?f_shash=fake&amp;fs_from=fake">Load similar</a></div>
<div><a href="#" id="loadfail" onclick="return nl('fake-nl-3')">Reload broken image</a></div>
<div><a href="https://e-hentai.org/fullimg/900001/3/fakekey/Fake%20Page%2003.jpg?a=1&amp;b=2">Download original</a></div>
</div></div></body></html>
"""

private let fakeImagePageInfo = ImagePageInfo(
    gid: 900001,
    token: "0f0f0f0f0f",
    pageIndex: 3,
    pageCount: 1234,
    imageURL: URL(string: fakeImageSource)!,
    imageSize: ImageSize(width: 1280, height: 1808),
    fileName: "Fake Page 03 & more.jpg",
    fileSizeText: "393.4 KiB",
    originalImageURL: URL(string: "https://e-hentai.org/fullimg/900001/3/fakekey/Fake%20Page%2003.jpg?a=1&b=2")!,
    reloadToken: "fake-nl-3",
    showKey: "fakeshowkey",
    imageKey: nil,
    isBandwidthExceeded: false
)

private func replacing(_ pairs: [(String, String)], in text: String) -> String {
    pairs.reduce(text) { result, pair in
        precondition(result.contains(pair.0), "the fake page has no \(pair.0)")
        return result.replacingOccurrences(of: pair.0, with: pair.1)
    }
}

// MARK: Hand-written JSON answers

private func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// A made-up showpage answer for page 7, laid out as the captured ones (`x`, `y` and `p` as the site sends them).
private func fakeShowpage(removing removed: Set<String> = [], with changes: [String: Any] = [:]) throws -> Data {
    var object: [String: Any] = [
        "p": 7,
        "s": "s/0a0a0a0a0a/900001-7",
        "n": #"<div class="sn"><a href="https://e-hentai.org/s/0b0b0b0b0b/900001-6"><img src="https://ehgt.org/g/p.png" /></a><div><span>7</span> / <span>1,234</span></div></div>"#,
        "i": "<div>Fake Page 07 &amp; more.jpg :: 1280 x 1808 :: 393.4 KiB</div>",
        "k": "0a0a0a0a0a",
        "i3": #"<a onclick="return load_image(8, '0c0c0c0c0c')" href="https://e-hentai.org/s/0c0c0c0c0c/900001-8"><img id="img" src="https://abc.hath.network:1111/h/fake7/fake.webp" style="height:1808px;width:1280px" onerror="this.onerror=null; nl('fake-nl-7')" /></a>"#,
        "i5": #"<div class="sb"><a href="https://e-hentai.org/g/900001/0f0f0f0f0f/"><img src="https://ehgt.org/g/b.png" /></a></div>"#,
        "i6": ##"<div> &nbsp; <a href="#" onclick="prompt('Copy the URL below.', 'https://e-hentai.org/r/fake/900001-7/fake.jpg'); return false">Forum link</a></div><div> &nbsp; <a href="#" id="loadfail" onclick="return nl('fake-nl-7')">Reload broken image</a></div><div> &nbsp; <a href="/fullimg/900001/7/fakekey/Fake.jpg?a=1&amp;b=2">Download original</a></div>"##,
        "si": "fake",
        "x": "1280",
        "y": "1808",
    ]
    for key in removed { object[key] = nil }
    object.merge(changes) { $1 }
    return try json(object)
}

/// A made-up imagedispatch answer for page 7, laid out as the captured ones.
private func fakeDispatch(removing removed: Set<String> = [], with changes: [String: Any] = [:]) throws -> Data {
    var object: [String: Any] = [
        "d": "1280 x 1808 :: 393.4 KiB",
        "o": "Download original 2400 x 3390 1.2 MiB source",
        "lf": "fullimg/900001/7/fakekey/Fake.jpg",
        "ls": "?f_shash=fake&fs_from=fake",
        "ll": "fakehash-1-1280-1808-jpg/forumtoken/900001-7/Fake.webp",
        "lo": "s/0a0a0a0a0a/900001-7",
        "xres": "1280",
        "yres": "1808",
        "i": "https://abc.hath.network:1111/h/fake7/fake.webp",
        "s": "fake-nl-7",
    ]
    for key in removed { object[key] = nil }
    object.merge(changes) { $1 }
    return try json(object)
}

// MARK: Hand-written MPV page

/// Two entries on one line, as the site writes them. The second name holds an unpaired `];`, where a lazy
/// `\[.*?\];` would stop; the thumbnails escape their slashes.
private let fakeImageList = #"""
[{"n":"Fake 01.jpg","k":"0a0a0a0a0a","t":"(https:\/\/abc.hath.network\/fake\/1.webp) -0px 0"},
{"n":"Fake ]; 02.jpg","k":"0b0b0b0b0b","t":"(https:\/\/abc.hath.network\/fake\/2.webp) -100px 0"}]
"""#.replacingOccurrences(of: "\n", with: "")

private let fakeMPVPage = """
<html><head><title>Fake Gallery 1</title></head><body><div id="pane_images"></div>
<script type="text/javascript">
var gid=900001;
var mpvkey = "fakempvkey";
var imagelist = \(fakeImageList);
var base_url = "https://e-hentai.org/";
var pagecount = 2;
</script></body></html>
"""

private let fakeMPVImages = [
    MPVImage(name: "Fake 01.jpg", key: "0a0a0a0a0a", thumbnail: "(https://abc.hath.network/fake/1.webp) -0px 0"),
    MPVImage(name: "Fake ]; 02.jpg", key: "0b0b0b0b0b", thumbnail: "(https://abc.hath.network/fake/2.webp) -100px 0"),
]

@Suite struct ImageChainParserTests {
    // MARK: Captured and constructed fixtures, one test per row of the plan's table

    @Test(arguments: EHSite.allCases)
    func imagePagesParse(site: EHSite) throws {
        let info = try imagePage("\(site.rawValue)/image/page.html")
        let gallery = try detail(site)
        #expect(info.pageIndex == 1)
        #expect(info.pageCount == gallery.pageCount)
        #expect(info.gid == gallery.id.gid)
        let sameToken = info.token == gallery.id.token
        #expect(sameToken)
        #expect(parts(of: info) == allParts.subtracting([.imageKey]))

        let onHathNode = info.imageURL.host()?.hasSuffix(".hath.network") == true
        #expect(onHathNode)
        #expect(isPositive(info.imageSize))
        #expect(isFileSize(info.fileSizeText))
        let originalIsFullImage = info.originalImageURL?.path().contains("/fullimg/") == true
            && info.originalImageURL?.host() == site.host
        #expect(originalIsFullImage)
        #expect(!info.isBandwidthExceeded)
        // The file shown is the first of the MPV page's list.
        let sameFileAsMPV = try info.fileName == mpv(site).images.first?.name
        #expect(sameFileAsMPV)
    }

    @Test(arguments: EHSite.allCases)
    func reloadedImagePagesParse(site: EHSite) throws {
        let page = try imagePage("\(site.rawValue)/image/page.html")
        let reloaded = try imagePage("\(site.rawValue)/image/page-nl.html")
        let gallery = try detail(site)
        #expect(reloaded.pageIndex == 1)
        #expect(reloaded.pageCount == gallery.pageCount)
        #expect(reloaded.gid == gallery.id.gid)
        let sameToken = reloaded.token == gallery.id.token
        #expect(sameToken)
        #expect(parts(of: reloaded) == allParts.subtracting([.imageKey]))
        let onHathNode = reloaded.imageURL.host()?.hasSuffix(".hath.network") == true
        #expect(onHathNode)
        #expect(isPositive(reloaded.imageSize))
        #expect(isFileSize(reloaded.fileSizeText))
        let originalIsFullImage = reloaded.originalImageURL?.path().contains("/fullimg/") == true
        #expect(originalIsFullImage)
        #expect(!reloaded.isBandwidthExceeded)

        // Another source for the same file.
        let otherSource = reloaded.imageURL != page.imageURL
        #expect(otherSource)
        let sameFile = reloaded.fileName == page.fileName && reloaded.imageSize == page.imageSize
        #expect(sameFile)
    }

    /// `constructed/eh/image-509.html`: a copy of `eh/image/page.html` whose image is the 509 placeholder.
    @Test func bandwidthExceededImagePage() throws {
        let blocked = try imagePage("constructed/eh/image-509.html")
        #expect(blocked.isBandwidthExceeded)
        #expect(blocked.imageURL.absoluteString == "https://ehgt.org/g/509.gif")
        // Only the image changed.
        var expected = try imagePage("eh/image/page.html")
        expected.imageURL = blocked.imageURL
        expected.isBandwidthExceeded = true
        let onlyTheImageDiffers = blocked == expected
        #expect(onlyTheImageDiffers)
    }

    @Test(arguments: EHSite.allCases)
    func showpageAnswersParse(site: EHSite) throws {
        let info = try ShowPageParser.parse(Fixtures.data("\(site.rawValue)/api/showpage.json"), site: site)
        let gallery = try detail(site)
        let viewer = try mpv(site)
        #expect(info.pageIndex == 2)
        #expect(info.gid == gallery.id.gid)
        let sameToken = info.token == gallery.id.token
        #expect(sameToken)
        #expect(info.pageCount == gallery.pageCount)
        #expect(parts(of: info) == allParts.subtracting([.showKey]))
        #expect(info.showKey == nil)

        let onHathNode = info.imageURL.host()?.hasSuffix(".hath.network") == true
        #expect(onHathNode)
        #expect(isPositive(info.imageSize))
        #expect(isFileSize(info.fileSizeText))
        let originalIsFullImage = info.originalImageURL?.path().contains("/fullimg/") == true
            && info.originalImageURL?.host() == site.host
        #expect(originalIsFullImage)
        #expect(!info.isBandwidthExceeded)
        // The key and the file are the second of the MPV page's list.
        let keyIsHex = info.imageKey.map(isHexKey) == true
        #expect(keyIsHex)
        let sameKeyAsMPV = info.imageKey == viewer.images[1].key
        #expect(sameKeyAsMPV)
        let sameFileAsMPV = info.fileName == viewer.images[1].name
        #expect(sameFileAsMPV)
    }

    /// `constructed/eh/showpage-509.json`: a copy of `eh/api/showpage.json` whose image is the 509 placeholder.
    @Test func bandwidthExceededShowpage() throws {
        let blocked = try ShowPageParser.parse(Fixtures.data("constructed/eh/showpage-509.json"), site: .eh)
        #expect(blocked.isBandwidthExceeded)
        #expect(blocked.imageURL.absoluteString == "https://ehgt.org/g/509.gif")
        var expected = try ShowPageParser.parse(Fixtures.data("eh/api/showpage.json"), site: .eh)
        expected.imageURL = blocked.imageURL
        expected.isBandwidthExceeded = true
        let onlyTheImageDiffers = blocked == expected
        #expect(onlyTheImageDiffers)
    }

    /// `constructed/eh/showpage-key-mismatch.json`: a stale showkey.
    @Test func keyMismatchIsAServerError() throws {
        let answer = try Fixtures.data("constructed/eh/showpage-key-mismatch.json")
        #expect(throws: APIError.server("Key mismatch")) { try ShowPageParser.parse(answer, site: .eh) }
        #expect(throws: APIError.server("Key mismatch")) { try ImageDispatchParser.parse(answer, site: .eh) }
    }

    @Test(arguments: EHSite.allCases)
    func mpvPagesParse(site: EHSite) throws {
        let viewer = try mpv(site)
        let gallery = try detail(site)
        #expect(viewer.images.count == viewer.pageCount)
        #expect(viewer.pageCount == gallery.pageCount)
        #expect(viewer.gid == gallery.id.gid)
        #expect(!viewer.mpvKey.isEmpty)
        let keysAreHex = viewer.images.allSatisfy { isHexKey($0.key) }
        #expect(keysAreHex)
        let namesAndThumbnails = viewer.images.allSatisfy { !$0.name.isEmpty && !$0.thumbnail.isEmpty }
        #expect(namesAndThumbnails)
        // Each page has its own key.
        #expect(Set(viewer.images.map(\.key)).count == viewer.images.count)
    }

    @Test(arguments: EHSite.allCases)
    func imagedispatchAnswersParse(site: EHSite) throws {
        let info = try ImageDispatchParser.parse(Fixtures.data("\(site.rawValue)/api/imagedispatch.json"), site: site)
        let gallery = try detail(site)
        let page = try imagePage("\(site.rawValue)/image/page.html")
        #expect(info.pageIndex == 1)
        #expect(info.gid == gallery.id.gid)
        #expect(info.token == nil)
        #expect(parts(of: info) == [.gid, .imageSize, .fileSizeText, .originalImageURL, .reloadToken])

        #expect(info.imageURL.scheme == "https")
        let onHathNode = info.imageURL.host()?.hasSuffix(".hath.network") == true
        #expect(onHathNode)
        #expect(isPositive(info.imageSize))
        let original = try #require(info.originalImageURL)
        let underSiteBase = original.scheme == site.baseURL.scheme && original.host() == site.host
            && original.path().hasPrefix("/fullimg/")
        #expect(underSiteBase)
        #expect(!info.isBandwidthExceeded)
        // The same page as the image page: the same image, size and original.
        let sameImage = info.imageURL == page.imageURL
        #expect(sameImage)
        #expect(info.imageSize == page.imageSize)
        let sameSizeText = info.fileSizeText == page.fileSizeText
        #expect(sameSizeText)
        let sameOriginal = original == page.originalImageURL
        #expect(sameOriginal)
    }

    // MARK: Image pages, hand-written

    @Test func imagePageFieldsAreRead() throws {
        #expect(try ImagePageParser.parse(fakeImagePage) == fakeImagePageInfo)
    }

    /// The legacy layout put the file line first in `#i2`; the one in `#i4` is read when `#i2` has none.
    @Test func fileLineIsReadFromEitherBlock() throws {
        let onlyBelow = fakeImagePage.replacingOccurrences(
            of: "<div id=\"i2\">\(fakeNavigation)\(fakeFileInfo)</div>", with: "<div id=\"i2\">\(fakeNavigation)</div>"
        )
        #expect(onlyBelow != fakeImagePage)
        #expect(try ImagePageParser.parse(onlyBelow) == fakeImagePageInfo)

        // A file line inside a div with a class (the navigation) is not read.
        let classed = replacing([(fakeFileInfo, "<div class=\"sn\">Fake.jpg :: 1 x 1 :: 1 B</div>")], in: fakeImagePage)
        let info = try ImagePageParser.parse(classed)
        #expect(info.fileName == nil && info.imageSize == nil && info.fileSizeText == nil)
    }

    @Test func imagePageWithoutImageOrPageNumberThrows() throws {
        #expect(throws: ParseError.missing("imageURL")) {
            try ImagePageParser.parse(replacing([(#"<img id="img" "#, "<img ")], in: fakeImagePage))
        }
        #expect(throws: ParseError.missing("imageURL")) {
            try ImagePageParser.parse(replacing([(fakeImageSource, "")], in: fakeImagePage))
        }
        #expect(throws: ParseError.missing("pageIndex")) {
            try ImagePageParser.parse(replacing([("<span>3</span> / <span>1,234</span>", "")], in: fakeImagePage))
        }
        #expect(throws: ParseError.malformed("pageIndex")) {
            try ImagePageParser.parse(replacing([("<span>3</span>", "<span>third</span>")], in: fakeImagePage))
        }
        // Without the total, the page number is still read.
        let onlyIndex = try ImagePageParser.parse(
            replacing([("<span>3</span> / <span>1,234</span>", "<span>3</span>")], in: fakeImagePage)
        )
        #expect(onlyIndex.pageIndex == 3 && onlyIndex.pageCount == nil)
    }

    @Test func imagePageOptionalPartsMayBeMissing() throws {
        let bare = """
        <html><body><div id="i1"><div id="i2">\(fakeNavigation)</div>
        <div id="i3"><img id="img" src="\(fakeImageSource)" /></div>
        <p>var showkey="notthekey";</p></div></body></html>
        """
        let info = try ImagePageParser.parse(bare)
        #expect(info.pageIndex == 3 && info.pageCount == 1234)
        #expect(info.imageURL == URL(string: fakeImageSource))
        // The showkey is read from scripts only, not from the page's text.
        #expect(parts(of: info) == [.pageCount])
        #expect(!info.isBandwidthExceeded)
    }

    /// The rule of the Flutter `EHConst.REG_509_URL`: `509.gif` or `509s.gif` on the site's own hosts only.
    @Test(arguments: [
        // The placeholder, on a site host or a subdomain of one.
        ("https://ehgt.org/g/509.gif", true),
        ("https://ehgt.org/g/509s.gif", true),
        ("https://exhentai.org/img/509.gif?v=1", true),
        ("https://exhentai.org/img/509s.gif", true),
        ("https://e-hentai.org/fake/509.gif", true),
        ("https://fake.ehgt.org/g/509s.gif", true),
        // An H@H node's image named like the placeholder is a page of the gallery.
        ("https://example.hath.network:1111/h/fakehash/509.gif", false),
        ("https://example.hath.network/h/fakehash/509s.gif", false),
        ("https://ehgt.org.example.hath.network/g/509.gif", false),
        // A site host, but not the placeholder's name.
        ("https://ehgt.org/g/fake.gif", false),
        ("https://ehgt.org/g/a509.gif", false),
        ("https://ehgt.org/g/509.gif.webp", false),
        ("https://exhentai.org/img/509.jpg", false),
    ])
    func onlyThe509PlaceholderIsBandwidthExceeded(source: String, exceeded: Bool) throws {
        let page = replacing([(fakeImageSource, source)], in: fakeImagePage)
        #expect(try ImagePageParser.parse(page).isBandwidthExceeded == exceeded)
        let answer = try fakeShowpage(with: ["i3": #"<img id="img" src="\#(source)" />"#])
        #expect(try ShowPageParser.parse(answer, site: .eh).isBandwidthExceeded == exceeded)
        let dispatched = try ImageDispatchParser.parse(fakeDispatch(with: ["i": source]), site: .eh)
        #expect(dispatched.isBandwidthExceeded == exceeded)
    }

    // MARK: showpage, hand-written

    @Test(arguments: EHSite.allCases)
    func showpageFieldsAreRead(site: EHSite) throws {
        let expected = ImagePageInfo(
            gid: 900001,
            token: "0f0f0f0f0f",
            pageIndex: 7,
            pageCount: 1234,
            imageURL: URL(string: "https://abc.hath.network:1111/h/fake7/fake.webp")!,
            imageSize: ImageSize(width: 1280, height: 1808),
            fileName: "Fake Page 07 & more.jpg",
            fileSizeText: "393.4 KiB",
            // The relative link is resolved against the site asked.
            originalImageURL: URL(string: "https://\(site.host)/fullimg/900001/7/fakekey/Fake.jpg?a=1&b=2")!,
            reloadToken: "fake-nl-7",
            showKey: nil,
            imageKey: "0a0a0a0a0a",
            isBandwidthExceeded: false
        )
        #expect(try ShowPageParser.parse(fakeShowpage(), site: site) == expected)
        // Numbers may come as JSON numbers or as strings.
        let numbers = try fakeShowpage(with: ["p": "7", "x": 1280, "y": 1808])
        #expect(try ShowPageParser.parse(numbers, site: site) == expected)
        // Without x and y the size comes from the file line.
        #expect(try ShowPageParser.parse(fakeShowpage(removing: ["x", "y"]), site: site) == expected)
        // The reload token of the image's onerror is used when i6 has no #loadfail.
        let onlyOriginal = #"<div><a href="https://e-hentai.org/fullimg/900001/7/fakekey/Fake.jpg">Original</a></div>"#
        let noLoadFail = try fakeShowpage(with: ["i6": onlyOriginal])
        let fromImage = try ShowPageParser.parse(noLoadFail, site: site)
        #expect(fromImage.reloadToken == "fake-nl-7")
        #expect(fromImage.originalImageURL == URL(string: "https://e-hentai.org/fullimg/900001/7/fakekey/Fake.jpg"))
    }

    @Test func showpageOptionalPartsMayBeMissing() throws {
        let bare = try fakeShowpage(removing: ["n", "i", "k", "i5", "i6", "x", "y", "s", "si"])
        let info = try ShowPageParser.parse(bare, site: .eh)
        #expect(info.pageIndex == 7)
        // i3's onerror still gives the reload token.
        #expect(parts(of: info) == [.reloadToken])
    }

    @Test func showpageWithoutRequiredFieldsThrows() throws {
        #expect(throws: ParseError.missing("pageIndex")) {
            try ShowPageParser.parse(fakeShowpage(removing: ["p"]), site: .eh)
        }
        #expect(throws: ParseError.malformed("pageIndex")) {
            try ShowPageParser.parse(fakeShowpage(with: ["p": "seven"]), site: .eh)
        }
        #expect(throws: ParseError.malformed("pageIndex")) {
            try ShowPageParser.parse(fakeShowpage(with: ["p": true]), site: .eh)
        }
        #expect(throws: ParseError.missing("imageURL")) {
            try ShowPageParser.parse(fakeShowpage(removing: ["i3"]), site: .eh)
        }
        #expect(throws: ParseError.missing("imageURL")) {
            try ShowPageParser.parse(fakeShowpage(with: ["i3": #"<img src="https://ehgt.org/g/b.png" />"#]), site: .eh)
        }
    }

    // MARK: JSON answers that are not results

    @Test(arguments: [
        "<html><body>Fake page</body></html>",
        "",
        #"["fake"]"#,
        #""fake""#,
        "{\"p\":",
    ])
    func answersThatAreNotJSONObjectsThrow(body: String) {
        let data = Data(body.utf8)
        #expect(throws: APIError.notJSON) { try ShowPageParser.parse(data, site: .eh) }
        #expect(throws: APIError.notJSON) { try ImageDispatchParser.parse(data, site: .eh) }
    }

    @Test func errorObjectsAreServerErrors() throws {
        let error = try json(["error": "Fake error"])
        #expect(throws: APIError.server("Fake error")) { try ShowPageParser.parse(error, site: .eh) }
        #expect(throws: APIError.server("Fake error")) { try ImageDispatchParser.parse(error, site: .ex) }
        // The error wins over any result fields.
        let both = try fakeShowpage(with: ["error": "Fake error"])
        #expect(throws: APIError.server("Fake error")) { try ShowPageParser.parse(both, site: .eh) }
    }

    // MARK: MPV, hand-written

    @Test func mpvPageFieldsAreRead() throws {
        let viewer = try MPVPageParser.parse(fakeMPVPage)
        #expect(viewer == MPVInfo(gid: 900001, mpvKey: "fakempvkey", pageCount: 2, images: fakeMPVImages))
    }

    /// Spaces around `=` are optional: the captured pages write `var gid=<n>;` and `var mpvkey = "…";`.
    @Test func mpvVariablesWithOrWithoutSpaces() throws {
        let spaced = replacing([
            ("var gid=900001;", "var gid = 900001 ;"),
            (#"var mpvkey = "fakempvkey";"#, #"var mpvkey="fakempvkey";"#),
            ("var imagelist = [", "var imagelist=["),
            ("var pagecount = 2;", "var pagecount=2;"),
        ], in: fakeMPVPage)
        #expect(try MPVPageParser.parse(spaced) == MPVPageParser.parse(fakeMPVPage))
        // A list on several lines is read too.
        let multiline = replacing([("},{", "},\n{")], in: fakeMPVPage)
        #expect(try MPVPageParser.parse(multiline).images == fakeMPVImages)
    }

    @Test func mpvPageWithoutVariablesThrows() throws {
        #expect(throws: ParseError.missing("gid")) {
            try MPVPageParser.parse(replacing([("var gid=900001;", "")], in: fakeMPVPage))
        }
        #expect(throws: ParseError.missing("mpvKey")) {
            try MPVPageParser.parse(replacing([(#"var mpvkey = "fakempvkey";"#, "")], in: fakeMPVPage))
        }
        #expect(throws: ParseError.missing("pageCount")) {
            try MPVPageParser.parse(replacing([("var pagecount = 2;", "")], in: fakeMPVPage))
        }
        #expect(throws: ParseError.missing("imagelist")) {
            try MPVPageParser.parse(replacing([("var imagelist = \(fakeImageList);", "")], in: fakeMPVPage))
        }
        #expect(throws: ParseError.malformed("imagelist")) {
            try MPVPageParser.parse(replacing([(fakeImageList, #"[{"n":"Fake 01.jpg","k":1}]"#)], in: fakeMPVPage))
        }
        #expect(throws: ParseError.malformed("imagelist")) {
            try MPVPageParser.parse(replacing([(fakeImageList, #"[{"n":"Fake 01.jpg""#)], in: fakeMPVPage))
        }
        // Variables are read from scripts only.
        let inText = "<html><body><p>var gid=900001; var mpvkey=\"fakempvkey\"; var pagecount=2;</p></body></html>"
        #expect(throws: ParseError.missing("gid")) { try MPVPageParser.parse(inText) }
    }

    // MARK: imagedispatch, hand-written

    @Test(arguments: EHSite.allCases)
    func imagedispatchFieldsAreRead(site: EHSite) throws {
        let expected = ImagePageInfo(
            gid: 900001,
            token: nil,
            pageIndex: 7,
            pageCount: nil,
            imageURL: URL(string: "https://abc.hath.network:1111/h/fake7/fake.webp")!,
            imageSize: ImageSize(width: 1280, height: 1808),
            fileName: nil,
            fileSizeText: "393.4 KiB",
            originalImageURL: URL(string: "https://\(site.host)/fullimg/900001/7/fakekey/Fake.jpg")!,
            reloadToken: "fake-nl-7",
            showKey: nil,
            imageKey: nil,
            isBandwidthExceeded: false
        )
        #expect(try ImageDispatchParser.parse(fakeDispatch(), site: site) == expected)
        let numbers = try fakeDispatch(with: ["xres": 1280, "yres": 1808])
        #expect(try ImageDispatchParser.parse(numbers, site: site) == expected)
        // lo with a leading slash, or as a whole address.
        for lo in ["/s/0a0a0a0a0a/900001-7", "https://\(site.host)/s/0a0a0a0a0a/900001-7"] {
            #expect(try ImageDispatchParser.parse(fakeDispatch(with: ["lo": lo]), site: site) == expected)
        }
        // A reload token sent as a number.
        let numericToken = try ImageDispatchParser.parse(fakeDispatch(with: ["s": 12345]), site: site)
        #expect(numericToken.reloadToken == "12345")
    }

    /// The Flutter parser read `lo` from `yres`, so every page came out as page 1; here the page is `lo`'s.
    @Test func imagedispatchPageComesFromLo() throws {
        let answer = try fakeDispatch(with: ["lo": "s/0a0a0a0a0a/900001-42", "yres": "1"])
        let info = try ImageDispatchParser.parse(answer, site: .eh)
        #expect(info.pageIndex == 42 && info.gid == 900001)
        #expect(info.imageSize == ImageSize(width: 1280, height: 1))
    }

    @Test func imagedispatchOptionalPartsMayBeMissing() throws {
        let bare = try fakeDispatch(removing: ["d", "o", "lf", "ls", "ll", "xres", "yres", "s"])
        let info = try ImageDispatchParser.parse(bare, site: .eh)
        #expect(info.pageIndex == 7)
        #expect(parts(of: info) == [.gid])
        #expect(try ImageDispatchParser.parse(fakeDispatch(with: ["s": ""]), site: .eh).reloadToken == nil)
    }

    @Test func imagedispatchWithoutRequiredFieldsThrows() throws {
        #expect(throws: ParseError.missing("imageURL")) {
            try ImageDispatchParser.parse(fakeDispatch(removing: ["i"]), site: .eh)
        }
        #expect(throws: ParseError.missing("pageIndex")) {
            try ImageDispatchParser.parse(fakeDispatch(removing: ["lo"]), site: .eh)
        }
        #expect(throws: ParseError.malformed("pageIndex")) {
            try ImageDispatchParser.parse(fakeDispatch(with: ["lo": "g/900001/0f0f0f0f0f/"]), site: .eh)
        }
        #expect(throws: ParseError.missing("imageURL")) {
            try ImageDispatchParser.parse(fakeDispatch(with: ["i": ""]), site: .eh)
        }
    }

    // MARK: Models

    @Test func imageChainValuesRoundTripThroughJSON() throws {
        let infos = try [
            imagePage("eh/image/page.html"),
            ShowPageParser.parse(Fixtures.data("ex/api/showpage.json"), site: .ex),
            ImageDispatchParser.parse(Fixtures.data("eh/api/imagedispatch.json"), site: .eh),
            fakeImagePageInfo,
        ]
        let decodedInfos = try JSONDecoder().decode([ImagePageInfo].self, from: JSONEncoder().encode(infos))
        let infosRoundTrip = decodedInfos == infos
        #expect(infosRoundTrip)
        let viewer = try mpv(.ex)
        let decodedViewer = try JSONDecoder().decode(MPVInfo.self, from: JSONEncoder().encode(viewer))
        let viewerRoundTrip = decodedViewer == viewer
        #expect(viewerRoundTrip)
    }
}
