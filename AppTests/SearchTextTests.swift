import EHModels
import Testing

@testable import Eros

/// `SearchText` and the word forms of `TagSuggestion`. Every tag here is made up.
@Suite struct SearchTextTests {
    private static func suggestion(
        _ namespace: String?, _ name: String, _ translation: String? = nil
    ) -> TagSuggestion {
        TagSuggestion(tag: TagRef(namespace: namespace, name: name), translation: translation)
    }

    @Test func currentTokenSplitsOnSpaceSemicolonAndQuote() {
        #expect(SearchText.currentToken(in: "female:example ta") == "ta")
        #expect(SearchText.currentToken(in: "fak") == "fak")
        #expect(SearchText.currentToken(in: "a ") == "")
        #expect(SearchText.currentToken(in: "f:\"fake") == "fake")
        #expect(SearchText.currentToken(in: "x;fak") == "fak")
        #expect(SearchText.currentToken(in: "") == "")
    }

    @Test func localQueryDropsPrefixAndDollar() {
        #expect(SearchText.localQuery(for: "f:fake") == "fake")
        #expect(SearchText.localQuery(for: "fake$") == "fake")
        #expect(SearchText.localQuery(for: "f:") == "")
        #expect(SearchText.localQuery(for: "fake") == "fake")
        // An exclusion's "-" goes first.
        #expect(SearchText.localQuery(for: "-f:fake") == "fake")
        #expect(SearchText.localQuery(for: "-fake$") == "fake")
        #expect(SearchText.localQuery(for: "-") == "")
    }

    @Test func applyingReplacesTheToken() {
        let artist = Self.suggestion("artist", "fakeartist")
        #expect(TagNamespace.abbreviation(for: "artist") == "a")
        #expect(SearchText.applying(artist, to: "fak") == "a:fakeartist$ ")
        #expect(SearchText.applying(artist, to: "a ") == "a a:fakeartist$ ")
        // A closed quote leaves the words before the current one alone.
        #expect(SearchText.applying(artist, to: "f:\"fake tag$\" fak") == "f:\"fake tag$\" a:fakeartist$ ")
    }

    @Test func applyingReplacesAnOpenQuote() {
        let tag = Self.suggestion("female", "example tag")
        #expect(SearchText.applying(tag, to: "x female:\"example ta") == "x f:\"example tag$\" ")
        // Without a namespace before the quote, only the quote onwards; an exclusion's "-" stays.
        #expect(SearchText.applying(tag, to: "x \"example ta") == "x f:\"example tag$\" ")
        #expect(SearchText.applying(tag, to: "-female:\"example") == "-f:\"example tag$\" ")
    }

    /// The "-" that starts the replaced word stays, with a quote open or not, so an exclusion stays one.
    @Test func applyingKeepsAnExclusion() {
        let artist = Self.suggestion("artist", "fakeartist")
        #expect(SearchText.applying(artist, to: "-fak") == "-a:fakeartist$ ")
        #expect(SearchText.applying(artist, to: "x -fak") == "x -a:fakeartist$ ")
        #expect(SearchText.applying(artist, to: "x -") == "x -a:fakeartist$ ")
        #expect(SearchText.applying(artist, to: "x -a:fak") == "x -a:fakeartist$ ")

        let tag = Self.suggestion("female", "example tag")
        #expect(SearchText.applying(tag, to: "x -female:\"example ta") == "x -f:\"example tag$\" ")
        #expect(SearchText.applying(tag, to: "x -\"example ta") == "x -f:\"example tag$\" ")
    }

    @Test func termsUseTagNamespaceAbbreviations() {
        #expect(Self.suggestion("female", "key").searchTerm == "f:key$")
        #expect(Self.suggestion("female", "example tag").searchTerm == "f:\"example tag$\"")
        #expect(TagNamespace.abbreviation(for: "uploader") == nil)
        #expect(Self.suggestion("uploader", "key").searchTerm == "uploader:key$")
        #expect(Self.suggestion(nil, "key").searchTerm == "key$")
        #expect(Self.suggestion(nil, "example tag").searchTerm == "\"example tag$\"")

        #expect(Self.suggestion("female", "example tag").displayName == "f:example tag")
        #expect(Self.suggestion("uploader", "key").displayName == "uploader:key")
        #expect(Self.suggestion(nil, "key").displayName == "key")
    }

    @Test func translatedNameUsesTheChineseNamespaceName() {
        #expect(Self.suggestion("female", "fake tag", "示例标签").translatedName == "女性:示例标签")
        #expect(Self.suggestion("fakespace", "fake tag", "示例标签").translatedName == "fakespace:示例标签")
        #expect(Self.suggestion(nil, "fake tag", "示例标签").translatedName == "示例标签")
        #expect(Self.suggestion("female", "fake tag").translatedName == nil)

        #expect(TagNamespaceNames.chinese("artist") == "作者")
        #expect(TagNamespaceNames.chinese("cosplayer") == "扮演者")
        #expect(TagNamespaceNames.chinese("temp") == "临时")
        #expect(TagNamespaceNames.chinese("rows") == nil)
    }

    // MARK: - Search page (search Q2)

    /// CR, LF and tabs become spaces, then the ends are trimmed; quotes stay as they are (the site's syntax).
    @Test func normalizedFlattensLineBreaks() {
        #expect(SearchText.normalized(" a\nb\tc\r\n") == "a b c")
        #expect(SearchText.normalized("a\rb") == "a b")
        #expect(SearchText.normalized("female:\"fake tag$\"\n") == "female:\"fake tag$\"")
        #expect(SearchText.normalized(" \n\t\r ") == "")
        #expect(SearchText.normalized("") == "")
    }

    /// Every line break (`CharacterSet.newlines`) becomes a space too, so a text stays one
    /// line in the history and the quick searches (search Q4 exports those one per line).
    @Test func normalizedFlattensEveryLineBreak() {
        #expect(SearchText.normalized("a\u{2028}b") == "a b")
        #expect(SearchText.normalized("a\u{2029}b") == "a b")
        #expect(SearchText.normalized("a\u{0085}b") == "a b")
        #expect(SearchText.normalized("a\u{000B}b\u{000C}c") == "a b c")
        #expect(SearchText.normalized("\u{2028}female:\"fake tag$\"\u{2029}") == "female:\"fake tag$\"")
    }

    @Test func tagTermQuotesAndEndsWithDollar() {
        #expect(SearchText.tagTerm(for: TagRef(namespace: "female", name: "example tag")) == "female:\"example tag$\"")
        #expect(SearchText.tagTerm(for: TagRef(namespace: "uploader", name: "x y")) == "uploader:\"x y\"")
        #expect(SearchText.tagTerm(for: TagRef(namespace: nil, name: "fake")) == "\"fake$\"")
        // A colon in the name stays (Flutter's split(':')[1] would cut it); quotes go.
        #expect(SearchText.tagTerm(for: TagRef(namespace: "other", name: "fake:\"tag\"")) == "other:\"fake:tag$\"")
        #expect(SearchText.tagTerm(for: TagRef(raw: "female:fake:tag")) == "female:\"fake:tag$\"")
    }

    @Test func appendingAddsOneSpaceEachSide() {
        #expect(SearchText.appending("t", to: "") == "t ")
        #expect(SearchText.appending("t", to: "a  ") == "a t ")
        #expect(SearchText.appending("t", to: "a") == "a t ")
        #expect(SearchText.appending("t", to: " \n") == "t ")
        #expect(SearchText.appending("female:\"fake tag$\"", to: "x") == "x female:\"fake tag$\" ")
    }

    /// Only a text without whitespace that is an http(s) URL with a host can be a link, and only a site page
    /// (`EHLink(url:)`) is one.
    @Test func linkOnlyForSiteURLs() {
        let gallery = GalleryID(gid: 1234, token: "0123456789")
        #expect(SearchText.link(in: "https://e-hentai.org/g/1234/0123456789/") == .gallery(gallery, site: .eh))
        #expect(SearchText.link(in: "http://exhentai.org/g/1234/0123456789/") == .gallery(gallery, site: .ex))
        #expect(
            SearchText.link(in: "https://e-hentai.org/tag/female:fake+tag")
                == .tag(TagRef(namespace: "female", name: "fake tag"), site: .eh)
        )
        #expect(SearchText.link(in: "https://example.com/g/1/abc/") == nil)
        #expect(SearchText.link(in: "a https://e-hentai.org/g/1234/0123456789/") == nil)
        #expect(SearchText.link(in: "https://e-hentai.org/g/1234/0123456789/ b") == nil)
        #expect(SearchText.link(in: "ftp://e-hentai.org/g/1234/0123456789/") == nil)
        #expect(SearchText.link(in: "e-hentai.org/g/1234/0123456789/") == nil)
        #expect(SearchText.link(in: "https://e-hentai.org/fake/page") == nil)
        #expect(SearchText.link(in: "female:fake") == nil)
        #expect(SearchText.link(in: "") == nil)
    }
}
