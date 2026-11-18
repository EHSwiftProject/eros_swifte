import EHModels
import Testing

@Test func siteEndpoints() {
    #expect(EHSite.eh.host == "e-hentai.org")
    #expect(EHSite.ex.host == "exhentai.org")
    #expect(EHSite.eh.baseURL.absoluteString == "https://e-hentai.org")
    #expect(EHSite.ex.baseURL.absoluteString == "https://exhentai.org")
}

@Test(arguments: [
    ("e-hentai.org", EHSite.eh), ("forums.e-hentai.org", .eh), ("upld.e-hentai.org", .eh), ("E-HENTAI.ORG.", .eh),
    (".e-hentai.org", .eh), ("exhentai.org", .ex), ("s.exhentai.org", .ex), (".exhentai.org", .ex),
])
func cookieHostFamilies(host: String, site: EHSite) {
    #expect(EHSite(cookieHost: host) == site)
}

@Test func otherHostsGetNoCookies() {
    for host in ["ehgt.org", "abc.hath.network", "notexhentai.org", "e-hentai.org.example.com"] {
        #expect(EHSite(cookieHost: host) == nil, "\(host)")
    }
}

/// Only one leading and one trailing dot are dropped; empty labels and an empty host match nothing.
@Test func malformedHostsGetNoCookies() {
    for host in ["", ".", "..e-hentai.org", "a..e-hentai.org", "e-hentai.org..", "-e-hentai.org"] {
        #expect(EHSite(cookieHost: host) == nil, "\(host)")
    }
}
