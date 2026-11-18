import FixtureCaptureCore
import Foundation
import Testing

@Suite struct LinkExtractorTests {
    @Test func extractsGalleriesInOrderWithoutDuplicates() {
        let html = """
        <a href="https://e-hentai.org/g/123/abcdef0123/">A</a>
        <a href="https://e-hentai.org/g/456/0123456789/?p=1">B</a>
        <a href="https://e-hentai.org/g/123/abcdef0123/">A again</a>
        """
        #expect(LinkExtractor.galleries(in: html) == [
            GalleryRef(gid: 123, token: "abcdef0123"), GalleryRef(gid: 456, token: "0123456789"),
        ])
        // Not a 10-digit lowercase hex token.
        #expect(LinkExtractor.galleries(in: #"<a href="/g/1/ABCDEF0123/">"#).isEmpty)
    }

    @Test func extractsNextPageURL() {
        let html = #"<a id="unext" href="https://e-hentai.org/?next=123&amp;f_search=x">Next &gt;</a>"#
        #expect(LinkExtractor.nextPageURL(in: html) == URL(string: "https://e-hentai.org/?next=123&f_search=x"))
        // The last page has a span instead of a link.
        #expect(LinkExtractor.nextPageURL(in: #"<span id="unext">Next &gt;</span>"#) == nil)
        #expect(LinkExtractor.nextPageURL(in: #"<a id="uprev" href="https://e-hentai.org/?prev=1">"#) == nil)
    }

    @Test func extractsImagePageURLs() {
        let html = """
        <a href="https://e-hentai.org/s/0a1b2c3d4e/123-1"><img></a>
        <a href="https://exhentai.org/s/f0e1d2c3b4/123-2"><img></a>
        <a href="https://e-hentai.org/s/0a1b2c3d4e/123-1">again</a>
        """
        #expect(LinkExtractor.imagePageURLs(in: html) == [
            URL(string: "https://e-hentai.org/s/0a1b2c3d4e/123-1")!, URL(string: "https://exhentai.org/s/f0e1d2c3b4/123-2")!,
        ])
        #expect(LinkExtractor.imagePageURLs(in: #"<a href="https://example.org/s/0a1b2c3d4e/123-1">"#).isEmpty)
    }

    @Test func extractsShowkeyAndReloadToken() {
        let html = #"""
        <script>var showkey="abc123";</script>
        <a href="#" id="loadfail" onclick="return nl('12345-430636')">Reload broken image</a>
        """#
        #expect(LinkExtractor.showkey(in: html) == "abc123")
        #expect(LinkExtractor.reloadToken(in: html) == "12345-430636")
        #expect(LinkExtractor.showkey(in: "<p>none</p>") == nil)
        // nl() outside #loadfail does not count.
        #expect(LinkExtractor.reloadToken(in: #"<a onclick="return nl('1-2')">"#) == nil)
    }

    @Test func extractsMPVKeys() {
        let html = #"<script>var mpvkey = "k1"; var imagelist = [{"n":"1.jpg","k":"fedcba9876","t":"x"}];</script>"#
        #expect(LinkExtractor.mpvKeys(in: html) == MPVKeys(mpvkey: "k1", firstImageKey: "fedcba9876"))
        #expect(LinkExtractor.mpvKeys(in: #"var mpvkey = "k1"; var imagelist = [];"#) == nil)
        #expect(LinkExtractor.mpvKeys(in: #"var imagelist = [{"k":"fedcba9876"}];"#) == nil)
    }

    @Test func extractsArchiverKeyAndCover() {
        let archiver = "<a onclick=\"return popUp('https://e-hentai.org/archiver.php?gid=1&amp;token=t&amp;or=OR123', 480, 320)\">"
        #expect(LinkExtractor.archiverKey(in: archiver) == "OR123")
        // "or=" inside another word does not count.
        #expect(LinkExtractor.archiverKey(in: "<font color='red'>") == nil)

        let cover = #"<div id="gd1"><div style="width:250px;background:transparent url(https://ehgt.org/ab/cd/x.jpg) 0 0 no-repeat"></div></div>"#
        #expect(LinkExtractor.coverURL(in: cover) == URL(string: "https://ehgt.org/ab/cd/x.jpg"))
        #expect(LinkExtractor.coverURL(in: #"<div id="gd2"><div style="background:url(https://ehgt.org/x.jpg)">"#) == nil)
    }

    @Test func archiverLinkWithoutOrKeyHasNoKey() {
        // The site's current shape: no `or=` at all.
        let current = ##"<a href="#" onclick="return popUp('https://e-hentai.org/archiver.php?gid=1&amp;token=t',480,320)">"##
        #expect(LinkExtractor.archiverKey(in: current) == nil)
        // An `or=` in another link is not the archiver's.
        let elsewhere = current + #"<a href="https://e-hentai.org/?f_search=x&amp;or=zz1">x</a><a onclick="go('?or=zz2')">"#
        #expect(LinkExtractor.archiverKey(in: elsewhere) == nil)
        // The old shape still works, with `or` first or after `&`, and ends at the next parameter.
        #expect(LinkExtractor.archiverKey(in: "popUp('https://e-hentai.org/archiver.php?or=K1&amp;gid=1')") == "K1")
        #expect(LinkExtractor.archiverKey(in: "popUp(\"https://e-hentai.org/archiver.php?gid=1&or=K2\")") == "K2")
        #expect(LinkExtractor.archiverKey(in: "popUp('https://e-hentai.org/archiver.php?gid=1&amp;token=t&amp;or=')") == nil)
    }

    @Test func extractsImageLookupFormAction() {
        let eh = #"<form action="/" method="get"></form><form action="https://upld.e-hentai.org/image_lookup.php" method="post" enctype="multipart/form-data">"#
        #expect(LinkExtractor.imageLookupURL(in: eh) == URL(string: "https://upld.e-hentai.org/image_lookup.php"))
        let ex = "<FORM method='post' action='https://upld.exhentai.org/upld/image_lookup.php?a=1&amp;b=2'>"
        #expect(LinkExtractor.imageLookupURL(in: ex) == URL(string: "https://upld.exhentai.org/upld/image_lookup.php?a=1&b=2"))
        #expect(LinkExtractor.imageLookupURL(in: #"<form action="https://e-hentai.org/" method="get">"#) == nil)
        #expect(LinkExtractor.imageLookupURL(in: #"<a href="https://upld.e-hentai.org/image_lookup.php">"#) == nil)
    }
}
