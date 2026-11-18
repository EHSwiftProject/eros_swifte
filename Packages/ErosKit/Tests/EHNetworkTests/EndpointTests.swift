import EHModels
import EHNetwork
import Foundation
import Testing

struct EndpointTests {
    let id = GalleryID(gid: 900001, token: "0f0f0f0f0f")

    @Test func galleryAndPageURLs() {
        #expect(EHEndpoints.gallery(id, site: .ex, thumbnailPage: 2).absoluteString == "https://exhentai.org/g/900001/0f0f0f0f0f/?p=2")
        #expect(EHEndpoints.gallery(id, site: .eh).absoluteString == "https://e-hentai.org/g/900001/0f0f0f0f0f/")
        #expect(EHEndpoints.imagePage(key: "abcdef0123", gid: 900001, page: 3, site: .eh).absoluteString == "https://e-hentai.org/s/abcdef0123/900001-3")
        #expect(EHEndpoints.imagePage(key: "abcdef0123", gid: 900001, page: 3, site: .ex, reloadToken: "1234-fake").absoluteString == "https://exhentai.org/s/abcdef0123/900001-3?nl=1234-fake")
        #expect(EHEndpoints.mpv(id, site: .eh).absoluteString == "https://e-hentai.org/mpv/900001/0f0f0f0f0f/")
    }

    @Test func popupAndAccountURLs() {
        #expect(EHEndpoints.favoritesPopup(id, site: .eh).absoluteString == "https://e-hentai.org/gallerypopups.php?gid=900001&t=0f0f0f0f0f&act=addfav")
        #expect(EHEndpoints.torrents(id, site: .ex).absoluteString == "https://exhentai.org/gallerytorrents.php?gid=900001&t=0f0f0f0f0f")
        #expect(EHEndpoints.uconfig(site: .ex).absoluteString == "https://exhentai.org/uconfig.php")
        #expect(EHEndpoints.myTags(site: .eh).absoluteString == "https://e-hentai.org/mytags")
        #expect(EHEndpoints.home.absoluteString == "https://e-hentai.org/home.php")
        #expect(EHEndpoints.api(site: .ex).absoluteString == "https://exhentai.org/api.php")
        #expect(EHEndpoints.forumsBaseURL.absoluteString == "https://forums.e-hentai.org")
        #expect(EHEndpoints.forumProfile(memberID: 1234567).absoluteString == "https://forums.e-hentai.org/index.php?showuser=1234567")
        #expect(EHEndpoints.forumLogin.absoluteString == "https://forums.e-hentai.org/index.php?act=Login&CODE=01")
        #expect(EHEndpoints.forumLoginReferer.absoluteString == "https://forums.e-hentai.org/index.php?act=Login&CODE=00")
        #expect(EHEndpoints.webLoginStart.absoluteString == "https://forums.e-hentai.org/index.php?act=Login")
    }

    @Test func imageLookupURLsAreTheCurrentOnes() {
        #expect(EHEndpoints.imageLookupURL(for: .eh).absoluteString == "https://upld.e-hentai.org/image_lookup.php")
        #expect(EHEndpoints.imageLookupURL(for: .ex).absoluteString == "https://exhentai.org/upld/image_lookup.php")
    }

    @Test func archiverURLHasNoOrKey() {
        let url = EHEndpoints.archiver(id, site: .ex).absoluteString
        #expect(url == "https://exhentai.org/archiver.php?gid=900001&token=0f0f0f0f0f")
        #expect(!url.contains("or="))
    }
}
