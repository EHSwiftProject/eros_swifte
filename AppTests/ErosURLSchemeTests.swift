import EHModels
import Foundation
import Testing

@testable import Eros

/// `eros://` links (entry E2): the host form (`eros://<host>/<path>`) and the open form (`eros://open?url=<link>`) both
/// come down to a site URL, which `EHLink` reads; a site URL itself goes to `EHLink` directly. Every name and number
/// here is made up.
@Suite struct ErosURLSchemeTests {
    private static let gallery = GalleryID(gid: 1234, token: "0123456789")

    @Test func hostFormMapsToHTTPS() throws {
        let link = try Self.url("eros://e-hentai.org/g/1234/0123456789/")
        #expect(ErosURLScheme.siteURL(from: link)?.absoluteString == "https://e-hentai.org/g/1234/0123456789/")
        #expect(ErosURLScheme.link(from: link) == .gallery(Self.gallery, site: .eh))

        // The scheme in any case; the host as it is (`EHLink` reads it in any case).
        let shouted = try Self.url("EROS://www.exhentai.org/g/1234/0123456789/")
        #expect(ErosURLScheme.siteURL(from: shouted)?.absoluteString == "https://www.exhentai.org/g/1234/0123456789/")
        #expect(ErosURLScheme.link(from: shouted) == .gallery(Self.gallery, site: .ex))
        #expect(ErosURLScheme.link(from: try Self.url("Eros://E-Hentai.ORG/g/1234/0123456789/"))
            == .gallery(Self.gallery, site: .eh))
    }

    /// The path, the query and the fragment go over as they are, percent-encoding included: nothing is decoded and
    /// encoded again.
    @Test func hostFormKeepsQueryAndFragment() throws {
        let uploader = try Self.url("eros://e-hentai.org/uploader/Some+Uploader%21?x=1#y")
        #expect(
            ErosURLScheme.siteURL(from: uploader)?.absoluteString
                == "https://e-hentai.org/uploader/Some+Uploader%21?x=1#y"
        )
        #expect(ErosURLScheme.link(from: uploader) == .uploader("Some Uploader!", site: .eh))

        let search = try Self.url("eros://exhentai.org/?f_search=female%3Aexample+tag%26more&advsearch=1#a%20b")
        #expect(
            ErosURLScheme.siteURL(from: search)?.absoluteString
                == "https://exhentai.org/?f_search=female%3Aexample+tag%26more&advsearch=1#a%20b"
        )
        #expect(ErosURLScheme.link(from: search) == .search("female:example tag&more", site: .ex))
    }

    /// A malformed escape (`%E4%`) has already been rewritten by `URL(string:)` (to `%25E4%25`) before the scheme sees
    /// it, as it is in an `https` link (entry E1's note): the host form leaves that as it is, so `EHLink` reads the
    /// same URL and gives the same answer as for the `https` link itself, here a tag named `fake%E4%`.
    @Test func hostFormKeepsAMalformedEscapeAsTheSiteLinkHasIt() throws {
        let link = try Self.url("eros://e-hentai.org/tag/female:fake%E4%")
        let site = try Self.url("https://e-hentai.org/tag/female:fake%E4%")
        #expect(site.absoluteString == "https://e-hentai.org/tag/female:fake%25E4%25")
        #expect(ErosURLScheme.siteURL(from: link)?.absoluteString == site.absoluteString)
        #expect(ErosURLScheme.link(from: link) == EHLink(url: site))
        #expect(ErosURLScheme.link(from: link) == .tag(TagRef(namespace: "female", name: "fake%E4%"), site: .eh))
    }

    @Test func openFormTakesTheEncodedLink() throws {
        let imagePage = try Self.url("eros://open?url=https%3A%2F%2Fexhentai.org%2Fs%2F0123456789%2F1234-5")
        #expect(ErosURLScheme.siteURL(from: imagePage)?.absoluteString == "https://exhentai.org/s/0123456789/1234-5")
        #expect(
            ErosURLScheme.link(from: imagePage) == .imagePage(imageKey: "0123456789", gid: 1234, page: 5, site: .ex)
        )

        // What `encodeURIComponent(location.href)` gives for a tag page ("+" as %2B), with `open` and the scheme in any
        // case, and a query item before `url`.
        let tag = try Self.url(
            "EROS://Open?from=bookmarklet&url=https%3A%2F%2Fe-hentai.org%2Ftag%2Ffemale%3Aexample%2Btag"
        )
        #expect(ErosURLScheme.siteURL(from: tag)?.absoluteString == "https://e-hentai.org/tag/female:example+tag")
        #expect(
            ErosURLScheme.link(from: tag) == .tag(TagRef(namespace: "female", name: "example tag"), site: .eh)
        )

        // The first `url` item counts; an http link too.
        let twice = try Self.url(
            "eros://open?url=http%3A%2F%2Fe-hentai.org%2Fg%2F1234%2F0123456789%2F&url=https%3A%2F%2Fexample.com%2F"
        )
        #expect(ErosURLScheme.link(from: twice) == .gallery(Self.gallery, site: .eh))
    }

    @Test func openFormNeedsAnHTTPLink() throws {
        for text in [
            "eros://open",
            "eros://open?url=",
            "eros://open?link=https%3A%2F%2Fe-hentai.org%2Fg%2F1234%2F0123456789%2F",
            "eros://open?url=javascript%3Aalert(1)",
            "eros://OPEN?url=ftp%3A%2F%2Fx",
            "eros://open?url=eros%3A%2F%2Fe-hentai.org%2Fg%2F1234%2F0123456789%2F",
            "eros://open?url=e-hentai.org%2Fg%2F1234%2F0123456789%2F",
        ] {
            let url = try Self.url(text)
            #expect(ErosURLScheme.siteURL(from: url) == nil, "\(text)")
            #expect(ErosURLScheme.link(from: url) == nil, "\(text)")
        }
    }

    @Test func otherHostsAreNotLinks() throws {
        let other = try Self.url("eros://example.com/g/1234/0123456789/")
        #expect(ErosURLScheme.siteURL(from: other)?.absoluteString == "https://example.com/g/1234/0123456789/")
        #expect(ErosURLScheme.link(from: other) == nil)

        // The open form carrying an http(s) link to another site: a site URL, but no link.
        let openOther = try Self.url("eros://open?url=https%3A%2F%2Fexample.com%2F")
        #expect(ErosURLScheme.siteURL(from: openOther)?.absoluteString == "https://example.com/")
        #expect(ErosURLScheme.link(from: openOther) == nil)

        for text in ["eros:///g/1234/0123456789/", "eros:g/1234/0123456789/", "eros://"] {
            let url = try Self.url(text)
            #expect(ErosURLScheme.siteURL(from: url) == nil, "\(text)")
            #expect(ErosURLScheme.link(from: url) == nil, "\(text)")
        }
    }

    @Test func siteLinksPassThrough() throws {
        let tag = try Self.url("https://e-hentai.org/tag/female:example+tag")
        #expect(ErosURLScheme.link(from: tag) == .tag(TagRef(namespace: "female", name: "example tag"), site: .eh))
        #expect(ErosURLScheme.siteURL(from: tag) == nil)
        #expect(
            ErosURLScheme.link(from: try Self.url("HTTP://exhentai.org/g/1234/0123456789/"))
                == .gallery(Self.gallery, site: .ex)
        )

        for text in ["https://example.com/g/1234/0123456789/", "ftp://e-hentai.org/g/1234/0123456789/", "mailto:a@b"] {
            #expect(ErosURLScheme.link(from: try Self.url(text)) == nil, "\(text)")
        }
    }

    private static func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }
}
