import EHModels
import Foundation
import Testing

/// `EHLink(url:)`: which addresses are E-Hentai or ExHentai links the app opens, and what they open. Every tag,
/// uploader and search in these links is made up.
///
/// Every link is made with `URL(string:)`, the way the app gets one. That parser rewrites a string whose percent
/// encoding is not well formed instead of refusing it: `/uploader/%ZZ` becomes `/uploader/%25ZZ` and `/tag/%E4%`
/// becomes `/tag/%25E4%25` (a literal "%E4%"), so those never reach `EHLink` as written. The malformed links below
/// are well-formed escapes that are not UTF-8 (`%E4%B8`, a character cut short).
@Suite struct EHLinkTests {
    private static let id = GalleryID(gid: 1234, token: "0123456789")

    /// The link of `text`; records an issue when `URL(string:)` does not take it.
    private static func link(_ text: String) -> EHLink? {
        guard let url = URL(string: text) else {
            Issue.record("Not a URL: \(text)")
            return nil
        }
        return EHLink(url: url)
    }

    @Test func galleryLinks() {
        let links: [(String, EHSite)] = [
            ("https://e-hentai.org/g/1234/0123456789/", .eh),
            ("https://e-hentai.org/g/1234/0123456789", .eh),
            ("http://e-hentai.org/g/1234/0123456789/", .eh),
            ("http://e-hentai.org/g/1234/0123456789", .eh),
            ("https://exhentai.org/g/1234/0123456789/", .ex),
            ("https://exhentai.org/g/1234/0123456789", .ex),
            ("http://exhentai.org/g/1234/0123456789/", .ex),
            ("HTTPS://e-hentai.org/g/1234/0123456789/", .eh),
            ("Http://exhentai.org/g/1234/0123456789/", .ex),
        ]
        for (text, site) in links {
            #expect(Self.link(text) == .gallery(Self.id, site: site), "\(text)")
        }
        // The largest id an Int holds (19 digits).
        #expect(
            Self.link("https://e-hentai.org/g/9223372036854775807/0123456789/")
                == .gallery(GalleryID(gid: Int.max, token: "0123456789"), site: .eh)
        )
    }

    @Test func hostVariantsAreRecognized() {
        let hosts: [(String, EHSite)] = [
            ("E-Hentai.ORG", .eh), ("www.e-hentai.org", .eh), ("WWW.ExHentai.org", .ex), ("e-hentai.org.", .eh),
            ("www.exhentai.org.", .ex), ("EXHENTAI.ORG", .ex),
        ]
        for (host, site) in hosts {
            #expect(Self.link("https://\(host)/g/1234/0123456789/") == .gallery(Self.id, site: site), "\(host)")
        }
    }

    @Test func lookalikeHostsAreNotSiteLinks() {
        let hosts = [
            "forums.e-hentai.org", "upld.e-hentai.org", "g.e-hentai.org", "e-hentai.org.example.com", "xe-hentai.org",
            "s.exhentai.org", "www.www.e-hentai.org", "e-hentai.org..", "e-hentai.org@example.com",
        ]
        for host in hosts {
            #expect(Self.link("https://\(host)/g/1234/0123456789/") == nil, "\(host)")
        }
    }

    @Test func extraQueryAndFragmentAreIgnored() {
        #expect(
            Self.link("https://e-hentai.org/g/1/0123456789/?p=3#comments")
                == .gallery(GalleryID(gid: 1, token: "0123456789"), site: .eh)
        )
        #expect(Self.link("https://e-hentai.org/?f_search=x&advsearch=1&f_sh=on&next=9") == .search("x", site: .eh))
        #expect(
            Self.link("https://exhentai.org/tag/female:example+tag?page=2#top")
                == .tag(TagRef(namespace: "female", name: "example tag"), site: .ex)
        )
        #expect(
            Self.link("https://e-hentai.org/s/0123456789/1234-5?nl=1#image")
                == .imagePage(imageKey: "0123456789", gid: 1234, page: 5, site: .eh)
        )
    }

    @Test func imagePageLinks() {
        #expect(
            Self.link("https://e-hentai.org/s/0123456789/1234-5?nl=1")
                == .imagePage(imageKey: "0123456789", gid: 1234, page: 5, site: .eh)
        )
        #expect(
            Self.link("https://exhentai.org/s/0123456789/1234-5")
                == .imagePage(imageKey: "0123456789", gid: 1234, page: 5, site: .ex)
        )
        #expect(
            Self.link("https://e-hentai.org/s/abcdef0123/1-120/")
                == .imagePage(imageKey: "abcdef0123", gid: 1, page: 120, site: .eh)
        )
        let notLinks = [
            "https://e-hentai.org/s/0123456789/1234-0",  // page 0
            "https://e-hentai.org/s/012345678/1234-5",  // a 9-character key
            "https://e-hentai.org/s/01234567890/1234-5",  // an 11-character key
            "https://e-hentai.org/s/ABCDEF0123/1234-5",  // an uppercase key
            "https://e-hentai.org/s/0123456789/1234",  // no page
            "https://e-hentai.org/s/0123456789/1234-",  // an empty page
            "https://e-hentai.org/s/0123456789/0-5",  // gid 0
            "https://e-hentai.org/s/0123456789/1234-05",  // a page with a leading zero
            "https://e-hentai.org/s/0123456789/1234-5-6",
            "https://e-hentai.org/s/0123456789/1234-99999999999999999999",  // a page past Int
            "https://e-hentai.org/s/0123456789",
        ]
        for text in notLinks {
            #expect(Self.link(text) == nil, "\(text)")
        }
    }

    @Test func tagLinksAreDecoded() {
        let exampleTag = TagRef(namespace: "female", name: "example tag")
        let links: [(String, TagRef)] = [
            ("https://e-hentai.org/tag/female:example+tag", exampleTag),
            ("https://e-hentai.org/tag/female:example%20tag/", exampleTag),
            // Decoded first, then split at the first ":".
            ("https://e-hentai.org/tag/female%3Aexample+tag", exampleTag),
            ("https://e-hentai.org/tag/artist:a%2Bb", TagRef(namespace: "artist", name: "a+b")),
            ("https://e-hentai.org/tag/%E4%B8%AD", TagRef(namespace: nil, name: "中")),
            ("https://e-hentai.org/tag/other:a:b", TagRef(namespace: "other", name: "a:b")),
        ]
        for (text, tag) in links {
            #expect(Self.link(text) == .tag(tag, site: .eh), "\(text)")
        }
        #expect(Self.link("https://exhentai.org/tag/female:example+tag") == .tag(exampleTag, site: .ex))
    }

    @Test func uploaderLinksAreDecoded() {
        #expect(Self.link("https://e-hentai.org/uploader/Some+Uploader%21") == .uploader("Some Uploader!", site: .eh))
        #expect(Self.link("https://e-hentai.org/uploader/a%2Bb/") == .uploader("a+b", site: .eh))
        #expect(Self.link("https://e-hentai.org/uploader/%E4%B8%AD") == .uploader("中", site: .eh))
        #expect(Self.link("https://e-hentai.org/uploader/+Fake%20Uploader+") == .uploader("Fake Uploader", site: .eh))
        #expect(Self.link("https://exhentai.org/uploader/Some+Uploader%21") == .uploader("Some Uploader!", site: .ex))
    }

    @Test func malformedEncodingIsNotALink() {
        let links = [
            "https://e-hentai.org/tag/female:%E4%B8",
            "https://e-hentai.org/tag/%E4%B8",
            "https://e-hentai.org/uploader/%E4%B8",
            "https://e-hentai.org/uploader/%FF",
            "https://e-hentai.org/?f_search=%E4%B8",
        ]
        for text in links {
            #expect(Self.link(text) == nil, "\(text)")
        }
    }

    /// A tag needs a name, and a namespace when it has a ":"; an uploader and a search need more than white space.
    @Test func emptyNamesAreNotLinks() {
        let links = [
            "https://e-hentai.org/tag/:x",  // an empty namespace
            "https://e-hentai.org/tag/+:x",
            "https://e-hentai.org/tag/female:",
            "https://e-hentai.org/tag/female:+",
            "https://e-hentai.org/tag/+",
            "https://e-hentai.org/tag/%20",
            "https://e-hentai.org/uploader/+",
            "https://e-hentai.org/uploader/%20%0A",
        ]
        for text in links {
            #expect(Self.link(text) == nil, "\(text)")
        }
    }

    @Test func searchLinks() {
        let example = #"language:fake female:"example tag$""#
        #expect(
            Self.link("https://e-hentai.org/?f_search=language%3Afake+female%3A%22example+tag%24%22")
                == .search(example, site: .eh)
        )
        #expect(
            Self.link("https://exhentai.org/?f_search=language%3Afake+female%3A%22example+tag%24%22")
                == .search(example, site: .ex)
        )
        #expect(Self.link("https://e-hentai.org?f_search=fake") == .search("fake", site: .eh))
        #expect(Self.link("https://e-hentai.org/?f_search=+fake+search+") == .search("fake search", site: .eh))
        #expect(Self.link("https://e-hentai.org/?f_search=a%2Bb") == .search("a+b", site: .eh))
        // The first f_search counts.
        #expect(Self.link("https://e-hentai.org/?f_search=first&f_search=second") == .search("first", site: .eh))
        for text in [
            "https://e-hentai.org/?f_search=", "https://e-hentai.org/?f_search=+",
            "https://e-hentai.org/?f_search=%20%20", "https://e-hentai.org/?f_search", "https://e-hentai.org/?page=2",
        ] {
            #expect(Self.link(text) == nil, "\(text)")
        }
    }

    @Test func otherLinksAreNil() {
        let links = [
            "https://e-hentai.org/", "https://e-hentai.org", "https://e-hentai.org/mpv/1/0123456789/",
            "https://e-hentai.org/g/1/", "https://e-hentai.org/g/1/0123456789/extra",
            "https://e-hentai.org/g/1/ABCDEF0123/", "https://e-hentai.org/g/1/012345678/",
            "https://e-hentai.org/g/0/0123456789/", "https://e-hentai.org/g/01/0123456789/",
            "https://e-hentai.org/g/9223372036854775808/0123456789/",  // past Int
            "https://e-hentai.org/g/12345678901234567890/0123456789/",  // 20 digits
            "https://e-hentai.org/watched?f_search=x", "https://e-hentai.org/toplist.php",
            "https://e-hentai.org/tag/female:example+tag/extra", "https://e-hentai.org/uploader/",
            "ftp://e-hentai.org/g/1/0123456789/", "eros://e-hentai.org/g/1/0123456789/",
            "https://example.com/g/1/0123456789/",
        ]
        for text in links {
            #expect(Self.link(text) == nil, "\(text)")
        }
    }
}
