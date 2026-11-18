// `localOnlyTokens` is internal on purpose: it returns the private values themselves (see its documentation).
@testable import EHFixtures
import Foundation
import Testing

/// The private pages under this machine's `local/` that the leak check takes its values from; none on CI or a fresh
/// clone.
private let privatePagesOnThisMachine = (try? FixtureFiles.localPrivatePages()) ?? (myTags: [], lists: [])

// Every value in the fakes below is made up: the tags `female:zzfakeqq` and `female:zzfake qqtag`, the tagset
// "Zzfake set", the titles "Zzfake Title & Sequel 題名" and "Zzfake Favorite", and the galleries 999001/0f0f0f0f0f
// and 999002/0e0e0e0e0e. Token sets are compared as Booleans, as the real ones must never reach an expectation.

/// A fake mytags page: one tag, titled as the site titles it, between the site's own tips and a weight input.
private let fakeMyTags = """
<div id="usertag_1"><label class="lc" title="Watch this tag">x</label>
<div id="tagpreview_1" class="gt" title="female:zzfakeqq">zzfakeqq</div>
<input type="text" class="tagcolor" title="Tag Color"><input type="text" title="+10"></div>
"""

/// A fake favorites page: one gallery, its link and its title.
private let fakeFavorites =
    #"<td class="gl3c glname"><a href="https://e-hentai.org/g/999001/0f0f0f0f0f/"><div class="glink">Zzfake Favorite</div></a></td>"#

/// A `manifest.json` with one constructed entry per path, edited from the given fixture (nil: written by hand).
private func manifest(_ constructed: [String: String?]) -> String {
    let entries = constructed.sorted { $0.key < $1.key }.map { path, source in
        let derived = source.map { #","derivedFrom":"\#($0)""# } ?? ""
        return #"{"path":"\#(path)","site":"eh","source":"constructed","setCookieNames":[]\#(derived)}"#
    }
    return #"{"entries":["# + entries.joined(separator: ",") + "]}"
}

/// A fake root whose `local/` holds `fakeMyTags` and `fakeFavorites`, plus `files`.
private func fakeRoot(_ files: [String: String]) throws -> TemporaryFixtureRoot {
    let base = [
        "manifest.json": #"{"entries":[]}"#,
        "local/eh/account/mytags.html": fakeMyTags,
        "local/eh/list/favorites.html": fakeFavorites,
    ]
    return try TemporaryFixtureRoot(files: base.merging(files) { $1 })
}

/// The leak check on a fake root, without the repository's own files.
private func leaks(_ root: TemporaryFixtureRoot) throws -> [HygieneViolation] {
    try FixtureScan.leakViolations(root: root.url, sourceRoot: root.url, repositoryFiles: [])
}

@Suite struct LocalLeakTests {
    // MARK: Values and spellings

    @Test func leakCheckFindsTagNamesAndGalleryLinks() throws {
        let root = try fakeRoot([
            "constructed/eh/fake.html": """
            <div class="gt" title="female:zzfakeqq">zzfakeqq</div>
            <a href="https://e-hentai.org/g/999001/0f0f0f0f0f/">x</a>
            """,
        ])
        defer { root.remove() }
        #expect(try leaks(root).map(\.description) == [
            "constructed/eh/fake.html:1: localleak", "constructed/eh/fake.html:2: localleak",
        ])
    }

    /// Each line spells a fake tag, title or gallery another way; each is one violation.
    @Test func leakCheckCoversOtherSpellings() {
        let myTags = [#"<div id="tagpreview_1" class="gt" title="female:zzfake qqtag"></div>"#]
        let lists = [
            #"<a href="https://exhentai.org/g/999001/0f0f0f0f0f/"><div class="glink">Zzfake Title &amp; Sequel 題名</div></a>"#,
        ]
        let spellings = [
            #"<div class="gt" title="female:zzfake qqtag">"#, // a list page's tag title
            #"<div id="td_female:zzfake_qqtag" class="gt">"#, // a gallery page's tag id
            #"<a href="https://e-hentai.org/tag/female:zzfake+qqtag">"#, // a tag link
            "?f_search=female%3Azzfake+qqtag", // a search
            "?f_search=female%3A%22zzfake+qqtag%24%22", // an exact search: the bare tag after an escape
            "<a>zzfake qqtag</a>", // the bare tag
            "FEMALE:ZZFAKE QQTAG", // any case
            #"https:\/\/e-hentai.org\/g\/999001\/0f0f0f0f0f\/"#, // a JSON-escaped link
            "https://e-hentai.org/mpv/999001/0f0f0f0f0f/", // a multi-page viewer link
            "%2Fg%2F999001%2F0f0f0f0f0f%2F", // a percent-encoded link
            #"{"method":"gdata","gidlist":[[999001,"0f0f0f0f0f"]]}"#, // an API request
            #"{"gmetadata":[{"gid":999001,"token":"0f0f0f0f0f"}]}"#, // an API response
            "gallerypopups.php?gid=999001&t=0f0f0f0f0f&act=addfav", // a popup query
            #"<a href="gallerytorrents.php?gid=999001&amp;t=0f0f0f0f0f">"#, // an escaped query
            "archiver.php?gid=999001&token=0f0f0f0f0f", // the archiver's query
            #"var gid = 999001; var token = "0f0f0f0f0f";"#, // a gallery page's script
            #"{"gid": 999001, "token": "0f0f0f0f0f"}"#, // JSON with spaces
            #"{"token":"0f0f0f0f0f","gid":"999001"}"#, // JSON, keys swapped, the gid a string
            "/g/999001&#47;0f0f0f0f0f&#47;", // character references for "/"
            #"<div class="glink">Zzfake Title &amp; Sequel 題名</div>"#, // a title as a list shows it
            #"{"title":"Zzfake Title & Sequel 題名"}"#, // a title in JSON
            "ZZFAKE TITLE & SEQUEL 題名", // a title in any (ASCII) case
        ]
        let text = FixtureHygiene.LeakSearchFile(file: "t.html", text: spellings.joined(separator: "\n"))
        let violations = FixtureHygiene.localLeakViolations(myTags: myTags, lists: lists, searching: [text])
        #expect(violations.map(\.line) == Array(1...spellings.count))
        #expect(violations.allSatisfy { $0.file == "t.html" && $0.rule == FixtureHygiene.localLeakRule })
        // A longer tag, another token or part of a title is not the same value.
        let lookalikes = [
            "female:zzfake qqtags", "zzfake qqtagx", "xzzfake qqtag", "/g/999001/0f0f0f0f0e/", "t=0f0f0f0f0fa",
            "t=x0f0f0f0f0f", "t=10f0f0f0f0f", "zzfake title & sequel", "題名",
        ]
        let none = FixtureHygiene.LeakSearchFile(file: "t.html", text: lookalikes.joined(separator: "\n"))
        #expect(FixtureHygiene.localLeakViolations(myTags: myTags, lists: lists, searching: [none]).isEmpty)
    }

    @Test func leakCheckReportsEachLineOnce() {
        let tokens: Set<String> = ["female:zzfakeqq", "zzfakeqq", "/g/999001/0f0f0f0f0f/"]
        let text = "female:zzfakeqq zzfakeqq /g/999001/0f0f0f0f0f/\nclean\n\nzzfakeqq"
        let lines = FixtureHygiene.leakViolations(in: text, file: "t.html", tokens: tokens).map(\.line)
        #expect(lines == [1, 4])
        #expect(FixtureHygiene.leakViolations(in: text, file: "t.html", tokens: []).isEmpty)
    }

    /// Tag names come only from namespaced `title`s of mytags pages (the site's own tips and weight inputs never
    /// start that way), tagset names from its tagset chooser (the site's default names aside), gallery links and
    /// titles only from favorites and watched pages.
    @Test func valuesComeFromTheirPlaces() {
        let myTags = [
            fakeMyTags,
            #"<div class="gt" title='male:zzfake&#039;s tag'></div><a href="/g/999002/0e0e0e0e0e/">"#
                + #"<div class="glink">Zzfake Not A List</div>"#,
            #"<select onchange="update_tagset(this.value)"><option value="1" selected="selected">Zzfake set (3)</option>"#
                + #"<option value="2">Tagset #2 (0)</option></select>"#
                + #"<select id="tagset_target" name="usertag_target"><option value="0">Zzfake Target Choice</option></select>"#,
        ]
        let lists = [#"<div class="gt" title="female:zzlistonly"></div>"# + fakeFavorites]
        let tokens = FixtureHygiene.localOnlyTokens(myTags: myTags, lists: lists, publicTexts: [])
        let expected: Set<String> = [
            "female:zzfakeqq", "zzfakeqq", "male:zzfake's tag", "zzfake's tag", "zzfake set", "zzfake favorite",
            "/g/999001/0f0f0f0f0f/",
        ]
        let taken = tokens == expected
        #expect(taken)
        let counts = FixtureHygiene.localValueCounts(myTags: myTags, lists: lists)
        #expect(counts == FixtureHygiene.LocalValueCounts(tagNames: 4, tagsets: 1, titles: 1, links: 1))
        // A value with a character reference is searched for in its escaped spellings too.
        let escaped = FixtureHygiene.leakViolations(
            in: #"title="male:zzfake&#039;s tag""#, file: "t.html", tokens: tokens
        )
        #expect(escaped.count == 1)
    }

    // MARK: What a file may show

    /// A constructed fixture may show what the checked-in page it was edited from (`derivedFrom`) shows.
    @Test func tokensAlsoInPublicPagesAreIgnored() throws {
        let leaked = """
        <div class="gt" title="female:zzfakeqq">zzfakeqq</div>
        <a href="https://e-hentai.org/g/999001/0f0f0f0f0f/"><div class="glink">Zzfake Favorite</div></a>
        """
        let root = try fakeRoot([
            "manifest.json": manifest(["constructed/eh/fake.html": "eh/list/front.html"]),
            "constructed/eh/fake.html": leaked,
            "eh/list/front.html": leaked,
        ])
        defer { root.remove() }
        #expect(try leaks(root).isEmpty)

        // The source page may spell them another way.
        let otherSpellings = [
            #"<div id="td_female:zzfakeqq">"#, "https://e-hentai.org/mpv/999001/0f0f0f0f0f/",
            #"{"title":"Zzfake Favorite"}"#,
        ]
        let none = FixtureHygiene.localOnlyTokens(
            myTags: [fakeMyTags], lists: [fakeFavorites], publicTexts: otherSpellings
        )
        #expect(none.isEmpty)
        // A longer tag, another token or a longer title does not make the value public.
        let lookalikes = ["female:zzfakeqqx zzfakeqqx", "/g/999001/0f0f0f0f0e/", "Zzfake Favorites"]
        let all = FixtureHygiene.localOnlyTokens(myTags: [fakeMyTags], lists: [fakeFavorites], publicTexts: lookalikes)
        let kept = all == ["female:zzfakeqq", "zzfakeqq", "zzfake favorite", "/g/999001/0f0f0f0f0f/"]
        #expect(kept)
        // Only the bare tag public: the namespaced name still is not.
        let bareOnly = FixtureHygiene.localOnlyTokens(myTags: [fakeMyTags], lists: [], publicTexts: ["<a>zzfakeqq</a>"])
        let namespacedKept = bareOnly == ["female:zzfakeqq"]
        #expect(namespacedKept)
    }

    /// Only the page a constructed fixture was edited from lets its values through: a value that happens to be on
    /// another checked-in page is still reported, and so is one in a hand-written fixture, a fixture "edited from" a
    /// private page, the README or the manifest.
    @Test func onlyTheSourcePageLetsValuesThrough() throws {
        let copied = "<p>female:zzfakeqq</p>\n"
        let root = try fakeRoot([
            "manifest.json": manifest([
                "constructed/eh/from-front.html": "eh/list/front.html",
                "constructed/eh/from-detail.html": "eh/gallery/detail.html",
                "constructed/eh/from-local.html": "local/eh/account/mytags.html",
                "constructed/eh/handmade.html": nil,
            ]),
            "eh/list/front.html": copied,
            "eh/gallery/detail.html": "<p>no private value</p>\n",
            "constructed/eh/from-front.html": copied,
            "constructed/eh/from-detail.html": copied,
            "constructed/eh/from-local.html": copied,
            "constructed/eh/handmade.html": copied,
            "README.md": "# Fixtures\n" + copied,
        ])
        defer { root.remove() }
        #expect(try leaks(root).map(\.description) == [
            "constructed/eh/from-detail.html:1: localleak", "constructed/eh/from-local.html:1: localleak",
            "constructed/eh/handmade.html:1: localleak", "README.md:2: localleak",
        ])
        let manifestLeak = try fakeRoot([
            "manifest.json": #"{"entries":[],"note":"female:zzfakeqq"}"#, "eh/list/front.html": copied,
        ])
        defer { manifestLeak.remove() }
        #expect(try leaks(manifestLeak).map(\.description) == ["manifest.json:1: localleak"])
    }

    // MARK: Scan chain

    /// Searched: every file under `constructed/` (its README too), `manifest.json`, `README.md` and the repository's
    /// files. Not the captured fixtures (public by definition), nor `local/`, where the values come from.
    @Test func leakCheckSearchesCheckedInFilesOnly() throws {
        let leak = "by female:zzfakeqq\n"
        let root = try fakeRoot([
            "README.md": "# Fixtures\n" + leak,
            "constructed/README.md": leak,
            "constructed/eh/fake.json": "{}\n" + leak,
            "manifest.json": #"{"entries":[],"note":"female:zzfakeqq"}"#,
            "eh/list/front.html": leak,
            "local/eh/list/watched.html": fakeFavorites + leak,
            "local/manifest.local.json": leak,
        ])
        defer { root.remove() }
        #expect(try leaks(root).map(\.description) == [
            "constructed/README.md:1: localleak", "constructed/eh/fake.json:2: localleak",
            "manifest.json:1: localleak", "README.md:2: localleak",
        ])
    }

    /// The repository's tests, docs and capture targets are searched too, reported from the repository root.
    /// There a bare tag that a captured fixture shows is an ordinary word; a namespaced tag name, a title or a link
    /// still counts, even when public, and so does the same bare tag in a fixture.
    @Test func leakCheckSearchesRepositoryFiles() throws {
        let root = try fakeRoot([
            "eh/list/front.html": "<p>zzfakeqq, female:zzfakeqq and Zzfake Favorite</p>\n",
            "constructed/eh/handmade.html": "<p>zzfakeqq</p>\n",
        ])
        defer { root.remove() }
        let repository = try TemporaryFixtureRoot(files: [
            "README.md": "# Repository\nzzfake favorite\n",
            "docs/clean.md": "nothing private\n",
            "docs/words.md": "zzfakeqq, as a word\n",
            "docs/notes/zz.md": "# Notes\nfemale:zzfakeqq\n",
            "Packages/ErosKit/Tests/EHParsingTests/ZzTests.swift":
                "// fake\n#expect(link == \"/g/999001/0f0f0f0f0f/\")\n",
            "Tools/FixtureCapture/targets.json": #"{"eh":{"tag":"female:zzfakeqq"}}"#,
        ])
        defer { repository.remove() }
        let paths = [
            "README.md", "docs/clean.md", "docs/notes/zz.md", "docs/words.md",
            "Packages/ErosKit/Tests/EHParsingTests/ZzTests.swift", "Tools/FixtureCapture/targets.json",
        ]
        let violations = try FixtureScan.leakViolations(
            root: root.url, sourceRoot: root.url, repositoryFiles: paths.map { ($0, repository.url) }
        )
        #expect(violations.map(\.description) == [
            "constructed/eh/handmade.html:1: localleak",
            "/README.md:2: localleak", "/docs/notes/zz.md:2: localleak",
            "/Packages/ErosKit/Tests/EHParsingTests/ZzTests.swift:2: localleak",
            "/Tools/FixtureCapture/targets.json:1: localleak",
        ])
    }

    /// The checked-in scan's repository files: everything git tracks or would add, the samples aside.
    @Test(.enabled(if: FixtureFiles.canListRepository, "git cannot list the repository here (not a Mac, or no checkout)"))
    func repositoryListingCoversTestsDocsAndTargets() throws {
        let root = try #require(FixtureFiles.repositoryRoot)
        let paths = try FixtureFiles.repositoryTextFiles(root: root)
        let fixtures = "Packages/ErosKit/Tests/Fixtures/"
        for required in [
            "Tools/FixtureCapture/targets.json", "Packages/ErosKit/Tests/EHFixturesTests/LocalLeakTests.swift",
            fixtures + "FixtureHygiene.swift", "docs/superpowers/plans/2026-11-03-eros-ios-roadmap.md", "README.md",
        ] {
            #expect(paths.contains(required), "\(required)")
        }
        let parsingTests = paths.contains { $0.hasPrefix("Packages/ErosKit/Tests/EHParsingTests/") }
        #expect(parsingTests)
        let samples = paths.filter { path in
            ["eh/", "ex/", "local/", "constructed/"].contains { path.hasPrefix(fixtures + $0) }
                || path == fixtures + "manifest.json" || path == fixtures + "README.md"
        }
        #expect(samples.isEmpty, "\(samples)")
        let images = paths.filter { $0.hasSuffix(".png") }
        #expect(images.isEmpty, "\(images)")
    }

    @Test func privatePagesAreFoundByName() throws {
        let root = try TemporaryFixtureRoot(files: [
            "local/eh/account/mytags.html": "", "local/ex/account/mytags.html": "",
            "local/eh/list/favorites.html": "", "local/eh/list/favorites-cat0.html": "",
            "local/ex/list/favorites-search.html": "", "local/ex/list/watched.html": "",
            "local/eh/list/front.html": "", "local/eh/account/home.html": "", "local/manifest.local.json": "",
        ])
        defer { root.remove() }
        let pages = try FixtureFiles.localPrivatePages(root: root.url)
        #expect(pages.myTags == ["local/eh/account/mytags.html", "local/ex/account/mytags.html"])
        #expect(pages.lists == [
            "local/eh/list/favorites-cat0.html", "local/eh/list/favorites.html",
            "local/ex/list/favorites-search.html", "local/ex/list/watched.html",
        ])
    }

    /// Without a mytags, favorites or watched page there is nothing to take values from, and nothing is reported.
    @Test func leakCheckIsEmptyWithoutPrivatePages() throws {
        let root = try TemporaryFixtureRoot(files: [
            "manifest.json": #"{"entries":[]}"#,
            "local/.gitkeep": "",
            "local/eh/list/front.html": fakeFavorites,
            "local/manifest.local.json": "female:zzfakeqq",
            "constructed/eh/fake.html": "female:zzfakeqq\n/g/999001/0f0f0f0f0f/\n",
        ])
        defer { root.remove() }
        let pages = try FixtureFiles.localPrivatePages(root: root.url)
        #expect(pages.myTags.isEmpty && pages.lists.isEmpty)
        #expect(try leaks(root).isEmpty)
        let bare = try TemporaryFixtureRoot(files: ["manifest.json": #"{"entries":[]}"#])
        defer { bare.remove() }
        #expect(try leaks(bare).isEmpty)
    }

    @Test func leakReportShowsNoValues() throws {
        let root = try fakeRoot([
            "constructed/eh/fake.html": "female:zzfakeqq\n/g/999001/0f0f0f0f0f/\nZzfake Favorite\n",
        ])
        defer { root.remove() }
        let violations = try leaks(root)
        let count = violations.count
        #expect(count == 3)
        let searched = FixtureHygiene.LeakSearchFile(
            file: "t.html", text: "female:zzfakeqq", derivedFromText: "0f0f0f0f0f"
        )
        var dumped = ""
        dump(violations, to: &dumped)
        dump(searched, to: &dumped)
        let renderings = [
            String(describing: violations), String(reflecting: violations), dumped, String(describing: searched),
            String(reflecting: searched),
        ]
        for rendered in renderings {
            let leaked = ["zzfakeqq", "999001", "0f0f0f0f0f", "Zzfake"].contains { rendered.contains($0) }
            #expect(leaked == false, "a rendering shows a fake value")
        }
    }

    // MARK: This machine

    /// The real private pages under `local/`: none of their values may appear in a checked-in file other than where
    /// its source page shows it. Only counts and "file:line: rule" reach the expectations, never a value.
    @Test(
        .enabled(
            if: !privatePagesOnThisMachine.myTags.isEmpty || !privatePagesOnThisMachine.lists.isEmpty,
            "no mytags, favorites or watched page under local/, so there is nothing to check"
        ),
        .enabled(if: FixtureFiles.canListRepository, "git cannot list the repository here (not a Mac, or no checkout)")
    )
    func checkedInFixturesLeakNothingFromLocal() throws {
        let source = FixtureFiles.sourceRoot
        let myTags = try privatePagesOnThisMachine.myTags.map { try FixtureFiles.text($0, root: source) }
        let lists = try privatePagesOnThisMachine.lists.map { try FixtureFiles.text($0, root: source) }
        // Fail closed: private pages that yield no tag name, gallery link or title mean the extraction no longer
        // fits them, and the check would pass without checking anything. Tagsets may all have default names.
        let hasMyTags = !myTags.isEmpty
        let hasLists = !lists.isEmpty
        let counts = FixtureHygiene.localValueCounts(myTags: myTags, lists: lists)
        #expect(!hasMyTags || counts.tagNames > 0, "the mytags pages under local/ yield no tag names")
        #expect(!hasLists || counts.links > 0, "the favorites and watched pages under local/ yield no gallery links")
        #expect(!hasLists || counts.titles > 0, "the favorites and watched pages under local/ yield no titles")
        let violations = try FixtureScan.leakViolations()
        #expect(violations.isEmpty, "\(violations)")
    }
}
