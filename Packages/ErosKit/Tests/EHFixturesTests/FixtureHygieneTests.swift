import EHFixtures
import Foundation
import Testing

/// Where the local secrets file is looked up, and whether `EH_FIXTURE_SECRETS_FILE` chose it.
private let localSecretsFile: (url: URL, isOverride: Bool)? = locateLocalSecretsFile()

/// Secrets known on this machine: credential environment variables plus the local secrets file. Empty on CI.
private let localKnownSecrets: [KnownSecret] = FixtureHygiene.knownSecrets(
    environment: ProcessInfo.processInfo.environment,
    secretsFile: localSecretsFile?.url
)

/// True when a secrets file is configured or present, so it must be usable (see `localSecretsFileIsUsable`).
private let localSecretsFileNeedsCheck: Bool = {
    guard let file = localSecretsFile else { return false }
    return file.isOverride || FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false))
}()

/// `EH_FIXTURE_SECRETS_FILE` if set, else `.fixture-secrets.local` at the repository (or worktree) root above
/// this file.
private func locateLocalSecretsFile() -> (url: URL, isOverride: Bool)? {
    if let override = ProcessInfo.processInfo.environment["EH_FIXTURE_SECRETS_FILE"], !override.isEmpty {
        return (URL(filePath: override), true)
    }
    var directory = (#filePath as NSString).deletingLastPathComponent
    while true {
        if FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(".git")) {
            return (URL(filePath: directory).appending(path: ".fixture-secrets.local"), false)
        }
        let parent = (directory as NSString).deletingLastPathComponent
        if parent == directory { return nil }
        directory = parent
    }
}

/// Captured `home.php` pages, for the check that does not use the structural rules.
private let capturedHomePages: [String] = ((try? FixtureFiles.captured()) ?? []).filter { $0.hasSuffix("/account/home.html") }

private func structural(_ text: String) -> [String] {
    FixtureHygiene.structuralViolations(in: text, file: "t.html").map(\.rule)
}

private func secretRules(_ text: String, _ secret: KnownSecret) -> [String] {
    FixtureHygiene.secretViolations(in: text, file: "t.html", secrets: [secret]).map(\.rule)
}

private func fileAndRule(_ violations: [HygieneViolation]) -> Set<String> {
    Set(violations.map { "\($0.file) \($0.rule)" })
}

/// The judged text of `rule`'s violations in `text`.
private func captured(_ rule: String, _ text: String) -> [String] {
    FixtureHygiene.violatingCaptures(ofRule: rule, in: text).map { String(text[$0]) }
}

/// A fake torrent info hash; public data, never judged.
private let infoHash = "0123456789abcdef0123456789abcdef01234567"

/// A fake `home.php` shaped like the real page: image limits, then the EHTracker, Total GP Gained, Toplists and
/// Moderation Power sections, then the footer. Every value is made up.
private let fakeHome = """
<html><body><div class="stuffbox">
<h2>Image Limits</h2>
<div class="homebox">
    <p>You are currently at <strong>12</strong> towards a limit of <strong>5,000</strong>.</p><p>Reset for <strong>3</strong> GP.</p>
</div>
<h2>EHTracker</h2>
<div class="homebox">
    <table style="margin:auto">
        <tr><td class="c1">2.50 GiB</td><td class="c2"> Uploaded</td><td class="c1">-</td><td class="c2">Up/Down Ratio</td></tr>
        <tr><td class="c1">7</td><td class="c2">Torrent Completes</td></tr>
    </table>
    <div style="margin:5px auto"><a href="https://e-hentai.org/torrents.php?u=1111111">Show My Torrents</a></div>
    <p>Your current key is: <span style="font-weight:bold">Aa1aaaaAaa</span></p>
</div>
<h2>Total GP Gained</h2>
<div class="homebox">
    <table><tr><td style="font-weight:bold; text-align:right">12,345,678</td><td>GP from Hentai@Home</td></tr></table>
</div>
<h2>Toplists</h2>
<div class="homebox">
    <table><tr><td style="text-align:right"><strong>#4321</strong></td><td>on the <a href="https://e-hentai.org/toplist.php?tl=31">Hentai@Home Past Year</a> toplist</td></tr></table>
</div>
<h2>Moderation Power</h2>
<div class="homebox">
    <div style="width:40%; border-right:1px solid #5C0D11">Current Moderation Power<div>25</div></div>
    <table><tr><td>Level</td><td style="font-weight:bold">+4.25</td></tr>
    <tr><td>(capped at 25)</td><td style="font-weight:bold">= 13.50</td></tr></table>
    <p>It&#039;s been 7 days</p>
</div>
</div>
<div class="dp"><p>2007-2026</p></div>
</body></html>
"""

@Suite struct FixtureHygieneTests {
    // MARK: Structural rules

    @Test func flagsUnmaskedApikey() {
        #expect(structural(#"var apikey = "0f1e2d3c4b5a69";"#) == ["apikey"])
        #expect(structural(#"var apikey = "1a1a1a1a1a1a11";"#) == [])
    }

    @Test func flagsUnmaskedApiuid() {
        #expect(structural("var apiuid = 1234567;") == ["apiuid"])
        #expect(structural("var apiuid = 1111111;") == [])
    }

    @Test func flagsCookieValues() {
        #expect(structural("ipb_pass_hash=0123456789abcdef") == ["cookie"])
        #expect(structural("ipb_pass_hash=1111111111aaaaaa") == [])
        #expect(structural("task=0123456789abcdef") == [])
        // The forum's session cookie, as a real login response sets it.
        #expect(structural("Set-Cookie: ipb_session_id=0123456789abcdef0123456789abcdef; path=/") == ["cookie"])
        #expect(structural("Set-Cookie: ipb_session_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; path=/") == [])
    }

    @Test func flagsForeignIPv4() {
        #expect(structural("http://8.8.8.8/x") == ["ipv4"])
        #expect(structural("203.0.113.7") == [])
        #expect(structural("1.2.3.400") == [])
    }

    @Test func flagsIPv4NextToDots() {
        #expect(structural("Your IP is 8.8.8.8.") == ["ipv4"])
        #expect(structural(".8.8.8.8") == ["ipv4"])
        #expect(structural("1.2.3.4.5") == [])
        #expect(structural("1.2.3.400") == [])
        #expect(structural("203.0.113.7.") == [])
    }

    @Test func flagsFavnotes() {
        #expect(structural(#"<textarea name="favnote" rows="4">my note</textarea>"#) == ["favnote"])
        #expect(structural(#"<textarea name="favnote" rows="4">[favnote]</textarea>"#) == [])
        #expect(structural(#"<textarea name="favnote" rows="4"></textarea>"#) == [])
        #expect(structural("<textarea name=\"favnote\">first line\nsecond line</textarea>") == ["favnote"])
        #expect(structural(#"<div class="glfnote">Note: my note</div>"#) == ["glfnote"])
        #expect(structural(#"<div class="glfnote">Note: [favnote]</div>"#) == [])
        #expect(structural(#"<textarea name="commenttext_new"></textarea>"#) == [])
    }

    @Test func emptyGlfnoteIsAllowed() {
        #expect(structural(#"<div class="glfnote"></div>"#) == [])
        #expect(structural("<div class=\"glfnote\"> \n\t</div>") == [])
        #expect(structural(#"<div class="glfnote">Note: my note</div>"#) == ["glfnote"])
        #expect(structural(#"<div class="glfnote">Note: [favnote]</div>"#) == [])
    }

    // MARK: Torrent keys, tracker links and home.php statistics

    // Every value below is fake. Captures are compared as Booleans, so a failure prints no value.

    @Test func flagsTorrentKey() {
        #expect(structural(#"<p>Your current key is: <span style="font-weight:bold">Zq9fakeKey</span></p>"#) == ["torrentkey"])
        let key = captured("torrentkey", "<p>Your current key is: <span>Zq9fakeKey</span></p>") == ["Zq9fakeKey"]
        #expect(key)
        // Other spellings: <strong>, lowercase, &nbsp; or &#160; after the label, no colon, a line break inside the
        // label, two nested tags.
        let spellings = [
            "<p>Your current key is: <strong>Zq9fakeKey</strong></p>",
            "your current key is: Zq9fakeKey",
            "<p>Your current key is:&nbsp;<span>Zq9fakeKey</span></p>",
            "<p>Your current key is:&#160;&nbsp;Zq9fakeKey</p>",
            "<p>Your current key is <span>Zq9fakeKey</span></p>",
            "<p>Your current\n    key is: <span>Zq9fakeKey</span></p>",
            "<p>Your current key is: <span><b>Zq9fakeKey</b></span></p>",
        ]
        for (index, text) in spellings.enumerated() {
            let found = structural(text) == ["torrentkey"] && captured("torrentkey", text) == ["Zq9fakeKey"]
            #expect(found, "spelling \(index)")
        }
        // Masked; the same span without the label; another sentence; no value within two tags.
        #expect(structural(#"<p>Your current key is: <span style="font-weight:bold">Aa1aaaaAaa</span></p>"#) == [])
        #expect(structural(#"<span style="font-weight:bold">Zq9fakeKey</span>"#) == [])
        #expect(structural("<p>Your current torrent count is: 5</p>") == [])
        #expect(structural("<p>Your current key is: <span></span></p>\n<h2>Total GP Gained</h2>") == [])
    }

    @Test func flagsPersonalTorrentLink() {
        let link = "https://ehtracker.org/get/1111111/aa1aaaa1aaa1aaa1aa/7654321-zqfake0torrent0key1/\(infoHash).torrent"
        #expect(structural(link) == ["torrentlink", "trackerurl"])
        let both = captured("torrentlink", link) == ["7654321", "zqfake0torrent0key1"]
        #expect(both, "the uid and the key are judged separately")
        let uidMasked = link.replacingOccurrences(of: "7654321-", with: "1111111-")
        let keyOnly = captured("torrentlink", uidMasked) == ["zqfake0torrent0key1"]
        #expect(keyOnly)
        #expect(structural(uidMasked.replacingOccurrences(of: "zqfake0torrent0key1", with: "aaaaaa1aaaaaaa1aaa1")) == [])
        // Without the key segment, under /torrent/, upper case, JSON-escaped, percent-encoded, as character
        // references, and a key holding "_" or "-".
        let shapes = [
            "https://exhentai.org/torrent/1111111/7654321-zqfake0torrent0key1/\(infoHash).torrent",
            link.uppercased(),
            link.replacingOccurrences(of: "/", with: "\\/"),
            link.replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: "/", with: "%2F"),
            link.replacingOccurrences(of: "/", with: "&#47;"),
            link.replacingOccurrences(of: "/", with: "&#x2F;"),
            link.replacingOccurrences(of: "zqfake0torrent0key1", with: "zqfake_torrent-key1"),
        ]
        for (index, shape) in shapes.enumerated() {
            let found = structural(shape).contains("torrentlink") && captured("torrentlink", shape).count == 2
            #expect(found, "shape \(index)")
        }
        // A personal segment in an announce URL, with or without the number before it.
        for announce in [
            "http://ehtracker.org/1111111/7654321-zqfake0torrent0key1/announce",
            "http://ehtracker.org/7654321-zqfake0torrent0key1/announce",
        ] {
            let found = captured("torrentlink", announce) == ["7654321", "zqfake0torrent0key1"]
            #expect(found)
        }
        // Lookalikes: an image page, a gallery.
        #expect(structural("https://e-hentai.org/s/0a1b2c3d4e/7654321-12") == [])
        #expect(structural("https://e-hentai.org/g/7654321/abcdef0123/") == [])
        // A tracker link of an unknown shape: no specific rule fits, but the fail-closed check still refuses it.
        #expect(structural("https://ehtracker.org/get/1111111/aa/7654321-zqfake/notahash.torrent") == ["trackerurl", "trackerurl"])
    }

    @Test func flagsTrackerNumbers() {
        #expect(structural("http://ehtracker.org/3456789/announce") == ["tracker", "trackerurl"])
        let announce = captured("tracker", "<span>http://ehtracker.org/3456789/announce</span>") == ["3456789"]
        #expect(announce)
        let plain = "https://ehtracker.org/get/3456789/zq1fake2seg3abc4de/\(infoHash).torrent"
        #expect(structural(plain) == ["tracker", "trackerurl", "trackerurl"])
        let plainCaptures = captured("tracker", plain) == ["3456789", "zq1fake2seg3abc4de"]
        #expect(plainCaptures)
        let personal = "https://ehtracker.org/get/3456789/zq1fake2seg3abc4de/7654321-zqfake0torrent0key1/\(infoHash).torrent"
        #expect(Set(structural(personal)) == ["torrentlink", "tracker", "trackerurl"])
        let personalCaptures = captured("tracker", personal) == ["3456789", "zq1fake2seg3abc4de"]
        #expect(personalCaptures)
        // Escaped separators, a key segment holding "-", a personal announce, a port.
        let shapes: [(String, [String])] = [
            (#"http:\/\/ehtracker.org\/3456789\/announce"#, ["3456789"]),
            ("http%3A%2F%2Fehtracker.org%2f3456789%2Fannounce", ["3456789"]),
            ("http:&#47;&#47;ehtracker.org&#47;3456789&#47;announce", ["3456789"]),
            (plain.replacingOccurrences(of: "zq1fake2seg3abc4de", with: "zq1fake-seg3abc4de"), ["3456789", "zq1fake-seg3abc4de"]),
            ("http://ehtracker.org/3456789/7654321-zqfake0torrent0key1/announce", ["3456789"]),
            ("http://ehtracker.org:6969/3456789/announce", ["3456789"]),
        ]
        for (index, (shape, expected)) in shapes.enumerated() {
            let found = captured("tracker", shape) == expected
            #expect(found, "shape \(index)")
        }
        // Masked.
        #expect(structural("http://ehtracker.org/1111111/announce") == [])
        #expect(structural("https://ehtracker.org/get/1111111/aa1aaaa1aaa1aaa1aa/\(infoHash).torrent") == [])
        // An announce URL on another host is not this rule's (see flagsAnnounceOnOtherHosts).
        #expect(captured("tracker", "http://tracker.example.org/3456789/announce").isEmpty)
        // Lookalikes: another word, no number, a gallery, a query parameter.
        #expect(structural("https://e-hentai.org/3456789/announcements") == [])
        #expect(structural(#"<a href="https://ehtracker.org/get/">x</a> <a href="https://ehtracker.org/">y</a>"#) == [])
        #expect(structural("https://e-hentai.org/g/3456789/abcdef0123/ gallerytorrents.php?gid=3456789&amp;t=abcdef0123") == [])
    }

    @Test func flagsAnnounceOnOtherHosts() {
        // Masked in place on any host but the tracker's; the capture tool never takes these values as secrets.
        let shapes: [(String, [String])] = [
            ("http://tracker.example.org/3456789/announce", ["3456789"]),
            ("https://example.org/2024/announce", ["2024"]),
            ("https://example.org/5/announce", ["5"]),
            ("https://example.org/2024-12/announce", ["2024", "12"]),
            ("https://example.org/12345-abcd/announce", ["12345", "abcd"]),
            ("https://example.org/3456789/7654321-zqfake0torrent0key1/announce", ["3456789", "7654321", "zqfake0torrent0key1"]),
            (#"https:\/\/example.org\/2024\/announce"#, ["2024"]),
        ]
        for (index, (shape, expected)) in shapes.enumerated() {
            let found = structural(shape) == ["announce"] && captured("announce", shape) == expected
            #expect(found, "shape \(index)")
        }
        // Masked; another word; the tracker's own announce (tracker's rule, not this one).
        #expect(structural("https://example.org/1111/announce") == [])
        #expect(structural("https://example.org/2024/announcements") == [])
        #expect(captured("announce", "http://ehtracker.org/3456789/announce").isEmpty)
    }

    @Test func trackerURLCheckFailsClosed() {
        // Every segment of an ehtracker.org URL that is not get, torrent, announce or the info hash must be masked.
        let unknown = "https://ehtracker.org/dl/zqfakekey99/\(infoHash).torrent"
        #expect(structural(unknown) == ["trackerurl", "trackerurl"])
        let segments = captured("trackerurl", unknown) == ["dl", "zqfakekey99"]
        #expect(segments)
        #expect(structural("http://EHTRACKER.ORG/zq%20fake/announce") == ["trackerurl"])
        // Query values count too (names do not), and a port does not switch the check off.
        let passkey = captured("trackerurl", "http://ehtracker.org/1111111/announce?passkey=zqfakepasskey9") == ["zqfakepasskey9"]
        #expect(passkey)
        let key = captured("trackerurl", "https://ehtracker.org/get/1111111/aa1a/\(infoHash).torrent?p=1&amp;key=zqfakekey99")
            == ["zqfakekey99"]
        #expect(key)
        let port = captured("trackerurl", "https://ehtracker.org:443/dl/zqfakekey99/x") == ["dl", "zqfakekey99", "x"]
        #expect(port)
        #expect(structural("http://ehtracker.org/1111111/announce?passkey=aaaaaaaaaaaaa1&amp;x=") == [])
        // Masked segments, the fixed words and the info hash pass; so do other hosts.
        #expect(structural("https://ehtracker.org/aa/aaaaaaaa11/\(infoHash).torrent") == [])
        #expect(structural("https://ehtracker.org/torrent/1111111/\(infoHash).torrent") == [])
        #expect(structural("https://e-hentai.org/dl/zqfakekey99/x") == [])
    }

    @Test func trackerURLJudgesBareQueryAndFragment() {
        // A query item without "=" is judged whole, as a value; so is the fragment after "#".
        for (index, url) in ["https://ehtracker.org/announce?Zq9fakeKey123", "https://ehtracker.org/announce#Zq9fakeKey123"]
            .enumerated() {
            let found = structural(url) == ["trackerurl"] && captured("trackerurl", url) == ["Zq9fakeKey123"]
            #expect(found, "shape \(index)")
            #expect(structural(url.replacingOccurrences(of: "Zq9fakeKey123", with: "Aa1aaaaAaa111")) == [], "shape \(index)")
        }
        // A path segment is still judged on its own: "x" is no fixed word, so it is flagged besides the bare item.
        let segmentAndItem = captured("trackerurl", "https://ehtracker.org/x?Zq9fakeKey123") == ["x", "Zq9fakeKey123"]
        #expect(segmentAndItem)
        #expect(structural("https://ehtracker.org/a?Aa1aaaaAaa111") == [])
        // After "&" or "&amp;", a fragment after a query, JSON-escaped separators, no path; a value after an empty name.
        let shapes = [
            "https://ehtracker.org/announce?p=1&Zq9fakeKey123",
            "https://ehtracker.org/announce?p=1&amp;Zq9fakeKey123",
            "https://ehtracker.org/announce?p=1#Zq9fakeKey123",
            #"http:\/\/ehtracker.org\/announce#Zq9fakeKey123"#,
            "https://ehtracker.org?Zq9fakeKey123",
            "https://ehtracker.org/announce?=Zq9fakeKey123",
        ]
        for (index, shape) in shapes.enumerated() {
            let found = structural(shape) == ["trackerurl"] && captured("trackerurl", shape) == ["Zq9fakeKey123"]
            #expect(found, "shape \(index)")
        }
        let slashFragment = captured("trackerurl", "https://ehtracker.org/announce#Zq9/fakeKey123") == ["Zq9/fakeKey123"]
        #expect(slashFragment, "the fragment is one value, slashes included")
        // Character references are separators, not query items or fragments; empty items pass.
        #expect(structural("http://ehtracker.org/1111111/announce?passkey=aaaaaaaaaaaaa1&amp;") == [])
        #expect(structural("http:&#47;&#47;ehtracker.org&#47;1111111&#47;announce") == [])
        #expect(structural("http://ehtracker.org/1111111/announce?&amp;#") == [])
        #expect(structural("<a href=\"https://ehtracker.org/\">ehtracker.org</a>, see ehtracker.org. Is it ehtracker.org?") == [])
    }

    // MARK: Account-rendered list pages and funds (all values fake)

    @Test func flagsTagStyles() {
        let colored = #"<div class="gt" style="color:#123456;border-color:#abcdef;background:radial-gradient(#111111,#222222) !important" title="zqns:zqfaketag">zqfaketag</div>"#
        #expect(structural(colored) == ["tagstyle"])
        let attribute = captured("tagstyle", colored)
            == [#" style="color:#123456;border-color:#abcdef;background:radial-gradient(#111111,#222222) !important""#]
        #expect(attribute, "the whole attribute, with its leading space, is the capture")
        // Any style counts, in any attribute order, quoting or case, on any tag token, among other classes.
        for shape in [
            #"<div id="td_zqns:zqfaketag" class="gtl" style="opacity:0.4">x</div>"#,
            #"<div style="color:#000" class="gt">x</div>"#,
            "<div class='gt' style='color:#000'>x</div>",
            #"<a class="zqx gtw" style=color:#000>x</a>"#,
            #"<DIV CLASS="GT" STYLE="color:#000">x</DIV>"#,
            #"<div class="gtb" style="">x</div>"#,
        ] {
            #expect(structural(shape) == ["tagstyle"], "\(shape)")
        }
        // No style; another class; the gallery's average rating and thumbnail styles stay.
        #expect(structural(#"<div class="gt" title="zqns:zqfaketag">zqfaketag</div>"#) == [])
        #expect(structural(#"<div class="gtx" style="color:#000">x</div><div class="xgt" style="color:#000">x</div>"#) == [])
        #expect(structural(#"<div class="ir" style="background-position:-16px -1px;opacity:0.93333"></div>"#) == [])
        #expect(structural(#"<div class="glthumb" id="it123" style="height:211px;top:-3px"></div>"#) == [])
    }

    @Test func flagsTagStylesWithUnquotedClass() {
        let unquoted = #"<div class=gt style="color:#123456">zqfaketag</div>"#
        #expect(structural(unquoted) == ["tagstyle"])
        let attribute = captured("tagstyle", unquoted) == [#" style="color:#123456""#]
        #expect(attribute)
        // Any tag token, before or after the style, unquoted style too, any case, a tab before the next attribute.
        for shape in [
            "<div class=gtl style=opacity:0.4>x</div>",
            #"<div style="color:#000" class=gtw>x</div>"#,
            #"<A CLASS=GTB STYLE="color:#000">x</A>"#,
            "<div class=gt\tstyle='color:#000'>x</div>",
        ] {
            #expect(structural(shape) == ["tagstyle"], "\(shape)")
        }
        // Other unquoted classes, and no style.
        #expect(structural(#"<div class=gtx style="color:#000">x</div><div class=xgt style="color:#000">x</div>"#) == [])
        #expect(structural("<div class=gt title=zqfaketag>x</div>") == [])
    }

    @Test func flagsFilteredCount() {
        // `filteredlist` also flags every such line; this test is about the count.
        func masking(_ text: String) -> [String] { structural(text).filter { $0 != "filteredlist" } }
        #expect(masking("<p>Found about 12,345 results. Filtered 12 galleries from this page. [<a href=\"x\">Show</a>]</p>") == ["filtered"])
        let count = captured("filtered", "Filtered <b>1,234</b> galleries from this page.") == ["1,234"]
        #expect(count)
        #expect(masking("Filtered 7 gallery from this page.") == ["filtered"])
        #expect(masking("Filtered&nbsp;8&#160;galleries from this page.") == ["filtered"])
        // Masked; the result total; other uses of the word.
        #expect(masking("<p>Filtered 11 galleries from this page.</p>") == [])
        #expect(structural("<p>Found about 12,345 results.</p>") == [])
        #expect(structural("<p>Tags with a weight below this are filtered from the 5 lists.</p>") == [])
    }

    @Test func flagsFilteredLists() {
        // The line as the site writes it, with N masked: still a violation, since the list lacks galleries.
        let line = #"<p>Filtered 11 galleries from this page. <a href="https://e-hentai.org/?f_sft=on&amp;f_sfu=on&amp;f_sfl=on">Disable Filters</a></p>"#
        #expect(structural(line) == ["filteredlist"])
        // Unmasked, a single gallery, no-break spaces in any spelling, tags around N, any case.
        #expect(structural("Filtered 23 galleries from this page.") == ["filtered", "filteredlist"])
        for shape in [
            "Filtered 1 gallery from this page.", "Filtered&nbsp;11&nbsp;galleries", "Filtered&#160;11&#xA0;galleries",
            "Filtered <b>11</b> galleries", "<P>FILTERED 11 GALLERIES</P>", "Filtered\n11\ngalleries",
        ] {
            #expect(structural(shape) == ["filteredlist"], "\(shape)")
        }
        // A list captured with filters disabled has no such line; the result total and other uses of the word pass.
        #expect(structural(#"<p>Found about 12,345 results.</p><a href="https://e-hentai.org/?f_sft=on&amp;f_sfu=on&amp;f_sfl=on&amp;next=5">Next</a>"#) == [])
        #expect(structural("<p>Tags with a weight below this are filtered from the 5 lists.</p>") == [])
        #expect(structural("<p>Filtered galleries are hidden.</p>") == [])
    }

    @Test func onlyListedConstructedFixturesAreExempt() {
        let violation = { (file: String, rule: String) in HygieneViolation(file: file, rule: rule, line: 1) }
        #expect(FixtureHygiene.isExempt(violation("constructed/eh/list-filtered.html", "filteredlist")))
        // Another rule in the same file, the same rule elsewhere, a captured page at a look-alike path.
        #expect(!FixtureHygiene.isExempt(violation("constructed/eh/list-filtered.html", "filtered")))
        #expect(!FixtureHygiene.isExempt(violation("constructed/eh/list-non-compact.html", "filteredlist")))
        #expect(!FixtureHygiene.isExempt(violation("eh/list/front.html", "filteredlist")))
        #expect(!FixtureHygiene.isExempt(violation("local/constructed/eh/list-filtered.html", "filteredlist")))
        // The constructed favorites page may show favorite marks and the account's rating, and nothing else that the
        // rules flag.
        #expect(FixtureHygiene.isExempt(violation("constructed/eh/list-favorites.html", "favmark")))
        #expect(FixtureHygiene.isExempt(violation("constructed/eh/list-favorites.html", "accountmark")))
        #expect(!FixtureHygiene.isExempt(violation("constructed/eh/list-favorites.html", "glfnote")))
        #expect(!FixtureHygiene.isExempt(violation("constructed/eh/list-watched.html", "favmark")))
        #expect(!FixtureHygiene.isExempt(violation("constructed/eh/list-watched.html", "accountmark")))
        // The constructed favorited gallery page may show favorite marks and the account's rating and votes, and no
        // tag style.
        #expect(FixtureHygiene.isExempt(violation("constructed/eh/detail-favorited.html", "favmark")))
        #expect(FixtureHygiene.isExempt(violation("constructed/eh/detail-favorited.html", "accountmark")))
        #expect(!FixtureHygiene.isExempt(violation("constructed/eh/detail-favorited.html", "tagstyle")))
        #expect(!FixtureHygiene.isExempt(violation("eh/gallery/detail.html", "accountmark")))
        // The constructed mytags page may color its tags, and its apikey must still be masked.
        #expect(FixtureHygiene.isExempt(violation("constructed/eh/account-mytags.html", "tagstyle")))
        #expect(!FixtureHygiene.isExempt(violation("constructed/eh/account-mytags.html", "apikey")))
        // Every entry is under constructed/ and names known rules only.
        for (path, rules) in FixtureHygiene.constructedExemptions {
            #expect(path.hasPrefix("constructed/"), "\(path)")
            #expect(rules.isSubset(of: Set(FixtureHygiene.structuralRuleNames)), "\(path)")
        }
    }

    @Test func flagsFunds() {
        let funds = #"<p>Current Funds:</p><p>1,234,567 GP [<a href="https://ehwiki.org/wiki/Gallery_Points">?</a>] &nbsp; 234 Credits [<a href="https://ehwiki.org/wiki/Credits">?</a>]</p>"#
        #expect(structural(funds) == ["funds", "funds"])
        let numbers = captured("funds", funds) == ["1,234,567", "234"]
        #expect(numbers)
        let sameParagraph = captured("funds", "<p>Current Funds: <strong>5,000 GP</strong>, 25 Credits</p>") == ["5,000", "25"]
        #expect(sameParagraph)
        // Masked; the archive costs after the paragraph are the gallery's, not the account's.
        let masked = funds.replacingOccurrences(of: "1,234,567", with: "1,111,111").replacingOccurrences(of: "234 Credits", with: "111 Credits")
        #expect(structural(masked + "<table><tr><td>Download Cost: 1,234 GP</td><td>23.4 MiB</td></tr></table>") == [])
        #expect(structural("<td>Download Cost: 1,234 GP</td>") == [])
    }

    @Test func flagsFundsWithNbspLabelOrNoClosingParagraph() {
        let text = "Current&nbsp;Funds: <strong>12,345</strong> GP"
        #expect(structural(text) == ["funds"])
        let number = captured("funds", text) == ["12,345"]
        #expect(number)
        #expect(structural(text.replacingOccurrences(of: "12,345", with: "11,111")) == [])
        // An `&#160;` label, no-break spaces around the colon, a label paragraph that is not closed.
        let shapes: [(String, [String])] = [
            ("<p>Current&#160;Funds:</p><p>1,234,567 GP &nbsp; 234 Credits</p>", ["1,234,567", "234"]),
            ("<p>Current&nbsp;Funds&nbsp;:&nbsp;</p>\n<p>5,000 GP</p>", ["5,000"]),
            ("<p>Current Funds:<p>5,000 GP</p>", ["5,000"]),
            // A `</p>` follows, so a `<p` or `</div>` before it does not end the range (a malformed page loses a
            // download cost to masking rather than keep a balance).
            ("<p>Current Funds: 5,000 GP<p>Download Cost: 1,234 GP</p>", ["5,000", "1,234"]),
            ("<div><p>Current Funds: <b>5,000</b> GP</div><p>Download Cost: 1,234 GP</p>", ["5,000", "1,234"]),
            ("<p>Current Funds:<br><p>12,345 GP</p>", ["12,345"]),
            (#"<p>Current Funds: <div class="x"></div> 12,345 GP</p>"#, ["12,345"]),
            ("<div><span>Current Funds:</span></div><div>12,345 GP</div></p>", ["12,345"]),
            ("<p>Current Funds: <span>12,345</span> GP</div><div>25 Credits</div></p>", ["12,345", "25"]),
            // No `</p>` anywhere after: the range ends at the next `<p`, `</div>` or the end of the text.
            ("Current Funds: 5,000 GP<p>Download Cost: 1,234 GP", ["5,000"]),
            ("<div>Current Funds: <b>5,000</b> GP</div><div>Download Cost: 1,234 GP</div>", ["5,000"]),
            ("Current Funds: 5,000 GP, 25 Credits", ["5,000", "25"]),
        ]
        for (index, (shape, expected)) in shapes.enumerated() {
            let found = captured("funds", shape) == expected
            #expect(found, "shape \(index)")
        }
    }

    // MARK: Forum pages (all values fake)

    @Test func flagsForumSessionKeys() {
        let key = "0123456789abcdef0123456789ABCDEF"
        // The session id, the log-out key, auth_key and md5check, after "?", "&amp;" or "&".
        for shape in [
            "https://forums.e-hentai.org/index.php?s=\(key)&act=x",
            "index.php?act=Login&amp;CODE=03&amp;k=\(key)",
            "index.php?act=x&auth_key=\(key)",
            "index.php?act=x&md5check=\(key)",
        ] {
            let found = structural(shape) == ["forumkey"] && captured("forumkey", shape) == [key]
            #expect(found, "\(shape)")
        }
        // Masked; a word; too short; 33 hex digits; other names.
        #expect(structural("index.php?s=1111111111aaaaaa1111111111AAAAAA&act=x") == [])
        #expect(structural("index.php?s=Search&act=x") == [])
        #expect(structural("index.php?act=x&k=abc") == [])
        #expect(structural("index.php?s=\(key)0") == [])
        #expect(structural("index.php?ks=\(key)&task=\(key)&s_k=\(key)") == [])
    }

    @Test func flagsForumKeysInScriptsAndHiddenInputs() {
        let key = "0123456789abcdef0123456789ABCDEF"
        // The page script's variables, JSON (escaped too), and hidden inputs, the name before or after the value.
        for shape in [
            #"var ipb_var_s = "\#(key)";"#,
            "var ipb_md5_check = '\(key)';",
            "ipb.vars['secure_hash'] = '\(key)';",
            #"{"session_id":"\#(key)"}"#,
            #"{\"s\":\"\#(key)\"}"#,
            "{k: \"\(key)\"}",
            #"<input type="hidden" name="auth_key" value="\#(key)" />"#,
            "<input type='hidden' name='md5check' value='\(key)'>",
            #"<input value="\#(key)" type="hidden" name="k">"#,
            "<input type=hidden name=s value=\(key)>",
        ] {
            let found = structural(shape) == ["forumkey"] && captured("forumkey", shape) == [key]
            #expect(found, "\(shape)")
        }
        // Masked; other names (a site verification meta, a beacon token, look-alike variables and inputs); 33 digits.
        for shape in [
            #"var ipb_var_s = "1111111111aaaaaa1111111111AAAAAA";"#,
            #"<meta name="verification" content="\#(key)">"#,
            #"<script data-cf-beacon='{"token": "\#(key)"}'></script>"#,
            #"<input type="hidden" name="keyword" value="\#(key)">"#,
            #"var ipb_var_session = "\#(key)"; var my_s = "\#(key)";"#,
            #"var ipb_var_s = "\#(key)0";"#,
        ] {
            #expect(structural(shape) == [], "\(shape)")
        }
    }

    // MARK: Favorite marks

    // Shapes as the site renders them; names, gids and tokens are fake.

    @Test func flagsFavoriteMarks() {
        // A gallery outside the account's favorites, and the site's default category names (or masked ones).
        let unfavorited = [
            #"<div onclick="popUp('https://e-hentai.org/gallerypopups.php?gid=1&amp;t=0f0f0f0f0f&amp;act=addfav',675,415)" id="posted_1">2026-01-01 00:00</div>"#,
            #"<div style="float:left; cursor:pointer" id="fav"></div>"#,
            ##"<a id="favoritelink" href="#" onclick="return false"><img src="https://ehgt.org/g/mr.gif" /> Add to Favorites</a>"##,
            #"<input type="radio" name="favcat" value="0" id="fav0" checked="checked" />"#,
            #"<div style="float:left" onclick="document.getElementById('fav0').click()">Favorites 0</div>"#,
            #"<input type="text" name="favorite_0" value="Favorites 0" size="11" maxlength="11" />"#,
            #"<div class="i" style="background-image:url(https://ehgt.org/g/fav.png)" title="Favorites 3"></div>"#,
            #"<option value="fav9">Favorites 9</option>"#,
            #"<input type="text" name="favorite_1" value="Aaaaaaaaa 1" />"#,
        ]
        for (index, text) in unfavorited.enumerated() {
            #expect(structural(text) == [], "unfavorited \(index)")
        }
        // A favorited gallery, and names the account gave its categories.
        let favorited = [
            #"<div style="border-color:#000;background-color:rgba(0,0,0,.1)" onclick="x" id="posted_1" title="Favorites 0">x</div>"#,
            #"<div id="posted_1" style="border-color:#000">2026-01-01 00:00</div>"#,
            #"<div id=posted_1 title='Favorites 0'>2026-01-01 00:00</div>"#,
            #"<div style="float:left" id="fav"><div class="i" style="background-position:0px -2px" title="Favorites 0"></div></div>"#,
            ##"<a id="favoritelink" href="#"><div class="i"></div> Favorites 0</a>"##,
            #"<input type="radio" name="favcat" value="favdel" />"#,
            #"<div style="float:left" onclick="document.getElementById('fav0').click()">Zzfake Folder</div>"#,
            #"<input type="text" name="favorite_0" value="Zzfake Folder" />"#,
            #"<div class="i" title="Zzfake Folder"></div>"#,
            "<div class=\"i\" style=\"x\"></div>\n\t<div style=\"float:left\">Zzfake Folder</div>",
            #"<option value="fav0">Zzfake Folder</option>"#,
        ]
        for (index, text) in favorited.enumerated() {
            #expect(structural(text) == ["favmark"], "favorited \(index)")
        }
    }

    @Test func favoriteMarksAreAllowedOnlyInPrivatePages() throws {
        let row = #"<div id="posted_1" style="border-color:#000" title="Favorites 0">2026-01-01 00:00</div>"#
        let root = try TemporaryFixtureRoot(files: [
            "manifest.json": #"{"entries":[]}"#,
            "eh/list/front.html": row,
            "constructed/eh/list-watched.html": row,
            // Exempt from favmark (`constructedExemptions`): it stands for the account's favorites.
            "constructed/eh/list-favorites.html": row,
            "local/eh/list/favorites.html": row,
            "local/manifest.local.json": row,
        ])
        defer { root.remove() }
        let flagged = try FixtureScan.structuralViolations(root: root.url, sourceRoot: root.url)
        #expect(fileAndRule(flagged) == ["eh/list/front.html favmark", "constructed/eh/list-watched.html favmark"])
        let violation = { (file: String, rule: String) in HygieneViolation(file: file, rule: rule, line: 1) }
        #expect(FixtureHygiene.isAllowedInPrivatePage(violation("local/eh/list/favorites.html", "favmark")))
        #expect(!FixtureHygiene.isAllowedInPrivatePage(violation("eh/list/favorites.html", "favmark")))
        #expect(!FixtureHygiene.isAllowedInPrivatePage(violation("constructed/local/x.html", "favmark")))
        #expect(!FixtureHygiene.isAllowedInPrivatePage(violation("local/eh/list/favorites.html", "glfnote")))
        #expect(FixtureHygiene.privatePageRules.isSubset(of: Set(FixtureHygiene.structuralRuleNames)))
    }

    // MARK: Account marks

    // Shapes as the site renders them (the list row and gallery page markup the parsers read); ids are fake.

    @Test func flagsAccountMarks() {
        // What any visitor sees: the average rating, tag links without a vote, comment votes without a style, and
        // look-alike class names, ids and words.
        let unmarked = [
            #"<div class="ir" style="background-position:-16px -1px;opacity:1"></div>"#,
            #"<div id="rating_image" class="ir" style="background-position:0px -21px"></div>"#,
            #"<a id="ta_other:fake_tag_1" href="https://e-hentai.org/tag/other:fake+tag+1" class="" onclick="return toggle_tagmenu(1,'other:fake tag 1',this)">fake tag 1</a>"#,
            ##"<div id="td_other:fake_tag_1" class="gt"><a id="ta_other:fake_tag_1" href="#">fake tag 1</a></div>"##,
            ##"[<a id="comment_vote_up_1111111" style="" href="#" onclick="vote_comment_up(1111111); this.blur(); return false">Vote+</a>]"##,
            ##"[<a id="comment_vote_down_1111111" style=" " href="#">Vote-</a>]"##,
            #"<div class="irregular"></div><span class="tupx mytdn"></span><div class="ir-r"></div>"#,
            #"<div id="edit_comment_1">the edit_comment link</div>"#,
        ]
        for (index, text) in unmarked.enumerated() {
            #expect(structural(text) == [], "unmarked \(index)")
        }
        // The account rated the gallery, voted on its tags and comments, or wrote a comment.
        let marked = [
            #"<div class="ir irr" style="background-position:-16px -1px;opacity:1"></div>"#,
            #"<div id="rating_image" class="ir irg" style="background-position:0px -21px"></div>"#,
            #"<div class='ir irb'></div>"#,
            #"<div class=iry style="x"></div>"#,
            #"<a id="ta_other:fake_tag_1" href="https://e-hentai.org/tag/other:fake+tag+1" class="tup" onclick="x">fake tag 1</a>"#,
            ##"<a class="tdn" id="ta_misc:fake_tag_3" href="#">fake tag 3</a>"##,
            ##"[<a id="comment_vote_up_1111111" style="color:blue" href="#">Vote+</a>]"##,
            ##"[<a style='color:blue' href="#" id='comment_vote_down_1111111'>Vote-</a>]"##,
            ##" &nbsp; [<a href="#" onclick="edit_comment(1111111); return false">Edit</a>]"##,
            #"<script>edit_comment (1111111);</script>"#,
        ]
        for (index, text) in marked.enumerated() {
            #expect(structural(text) == ["accountmark"], "marked \(index)")
        }
    }

    @Test func accountMarksAreAllowedOnlyInPrivatePages() throws {
        let row = #"<div id="posted_1">2026-01-01 00:00</div><div class="ir irr" style="background-position:0px -1px"></div>"#
        let root = try TemporaryFixtureRoot(files: [
            "manifest.json": #"{"entries":[]}"#,
            "eh/list/front.html": row,
            "constructed/eh/list-watched.html": row,
            // Exempt from accountmark (`constructedExemptions`): it stands for the account's favorites.
            "constructed/eh/list-favorites.html": row,
            "local/eh/list/favorites.html": row,
            "local/eh/list/watched.html": row,
        ])
        defer { root.remove() }
        let flagged = try FixtureScan.structuralViolations(root: root.url, sourceRoot: root.url)
        #expect(fileAndRule(flagged) == ["eh/list/front.html accountmark", "constructed/eh/list-watched.html accountmark"])
        let violation = { (file: String, rule: String) in HygieneViolation(file: file, rule: rule, line: 1) }
        #expect(FixtureHygiene.isAllowedInPrivatePage(violation("local/eh/list/watched.html", "accountmark")))
        #expect(!FixtureHygiene.isAllowedInPrivatePage(violation("eh/gallery/detail.html", "accountmark")))
    }

    @Test func flagsHomeStatistics() {
        let violations = FixtureHygiene.structuralViolations(in: fakeHome, file: "eh/account/home.html")
        #expect(violations.allSatisfy { $0.rule == "homestats" })
        #expect(violations.map(\.line) == [9, 10, 17, 21, 25, 26, 27, 27, 28])
        // Numbers in element text of every section but Image Limits; not attributes, the masked key, the "&#039;"
        // entity or the footer.
        let numbers = captured("homestats", fakeHome) == ["2.50", "7", "12,345,678", "4321", "25", "4.25", "25", "13.50", "7"]
        #expect(numbers)
        // The Image Limits numbers stay unjudged.
        let imageLimits = captured("homestats", fakeHome).contains { ["12", "5,000", "3"].contains($0) }
        #expect(imageLimits == false)
    }

    @Test func homeStatisticsSurviveMarkupChanges() {
        // A unit right after the number, more classes on the homebox, tags inside the heading, a section the site
        // might add later: all still judged.
        let variants: [(String, [String])] = [
            (#"<h2>EHTracker</h2><div class="homebox"><td>2.50GiB</td></div>"#, ["2.50"]),
            (#"<h2>Total GP Gained</h2><div class="homebox wide" id="gp"><td>12,345,678</td></div>"#, ["12,345,678"]),
            (#"<h2><span>Toplists</span></h2><div class='homebox'><strong>#4321</strong></div>"#, ["4321"]),
            (#"<h2>Hentai@Home</h2><div class="homebox"><td>42 clients</td></div>"#, ["42"]),
            // Other markup between the heading and its homebox.
            (#"<h2>Toplists</h2>\n<p class="note">ranks</p>\n<div class="homebox"><strong>#4321</strong></div>"#, ["4321"]),
        ]
        for (index, (text, expected)) in variants.enumerated() {
            let found = captured("homestats", text) == expected
            #expect(found, "variant \(index)")
        }
        // Image Limits stays out, however its heading is marked up.
        for imageLimits in [
            #"<h2>Image Limits</h2><div class="homebox"><p>at <strong>12</strong> of <strong>5,000</strong></p></div>"#,
            #"<h2><span>Image  Limits</span></h2><div class="homebox x"><strong>12</strong></div>"#,
        ] {
            #expect(structural(imageLimits) == [])
        }
    }

    @Test func maskedHomeStatisticsPass() {
        var masked = fakeHome
        for (value, mask) in [
            (">2.50 GiB<", ">1.11 GiB<"), (">7<", ">1<"), (">12,345,678<", ">11,111,111<"), ("#4321", "#1111"),
            ("<div>25</div>", "<div>11</div>"), ("+4.25", "+1.11"), ("capped at 25", "capped at 11"), ("= 13.50", "= 11.11"),
            ("been 7 days", "been 1 days"),
        ] {
            masked = masked.replacingOccurrences(of: value, with: mask)
        }
        #expect(structural(masked) == [])
        // The same markup outside home.php's sections, e.g. a toplist page without a homebox.
        #expect(structural("<h2>Toplists</h2><table><tr><td><strong>#4321</strong></td><td>x</td></tr></table>") == [])
        #expect(structural("<h2>Total GP Gained</h2><p>12,345,678</p>") == [])
    }

    // MARK: home.php, checked without the rules

    @Test func homePageCheckFindsUnmaskedNumbersOutsideImageLimits() {
        let lines = HomePageCheck.unmaskedNumberLines(in: fakeHome)
        // The footer counts too (its year is fake).
        #expect(lines == [9, 10, 17, 21, 25, 26, 27, 28, 31])
        // With every number outside Image Limits masked (the Image Limits numbers kept), nothing is found.
        var masked = fakeHome
        for (value, mask) in [
            (">2.50 GiB<", ">1.11 GiB<"), (">7<", ">1<"), (">12,345,678<", ">11,111,111<"), ("#4321", "#1111"),
            ("<div>25</div>", "<div>11</div>"), ("+4.25", "+1.11"), ("capped at 25", "capped at 11"), ("= 13.50", "= 11.11"),
            ("been 7 days", "been 1 days"), ("2007-2026", "1111-1111"),
        ] {
            masked = masked.replacingOccurrences(of: value, with: mask)
        }
        let limitsKept = masked.contains("<strong>5,000</strong>")
        #expect(limitsKept)
        #expect(HomePageCheck.unmaskedNumberLines(in: masked) == [])
        // Scripts, styles, comments, attributes and character references are not element text.
        let ignored = """
        <script>var w = 640;</script><style>p { margin: 2px }</style><!-- 2026 -->
        <a href="?tl=31" title="x2">It&#039;s &#x27;1&#x27;</a>
        """
        #expect(HomePageCheck.unmaskedNumberLines(in: ignored) == [])
    }

    /// Independent of the structural rules: every captured `*/account/home.html` shows no digit but "1" in element
    /// text outside the Image Limits section, so a rule regex that drifts from the page cannot hide a number.
    @Test(.enabled(if: !capturedHomePages.isEmpty, "no captured */account/home.html yet, so there is nothing to check"))
    func capturedHomePagesShowNoUnmaskedNumbers() throws {
        var found: [String] = []
        for path in capturedHomePages {
            found += HomePageCheck.unmaskedNumberLines(in: try FixtureFiles.text(path)).map { "\(path):\($0): homepage-number" }
        }
        #expect(found.isEmpty, "\(found)")
    }

    @Test func reportsLineOfMatchStart() {
        let text = "<html>\n<script>\nvar apiuid = 1234567;\n</script>\n<textarea name=\"favnote\">a\nb</textarea>"
        let violations = FixtureHygiene.structuralViolations(in: text, file: "eh/x.html")
        #expect(violations == [
            HygieneViolation(file: "eh/x.html", rule: "apiuid", line: 3),
            HygieneViolation(file: "eh/x.html", rule: "favnote", line: 5),
        ])
    }

    // MARK: Known secrets

    // Expectations below never take a runtime value that holds a secret (raw or encoded) as an operand: they compare
    // Booleans, counts or rule names, so a failure cannot print one.

    @Test func variantsAreOrderedAndDeduplicated() {
        let plain = FixtureHygiene.variants(of: "A&B Fan") == [
            "A&B Fan", "A&amp;B Fan", "A%26B%20Fan", "A%26B+Fan", "A&#38;B Fan", "A&#x26;B Fan",
        ]
        #expect(plain)
        let quotes = FixtureHygiene.variants(of: "<'\"é>") == [
            "<'\"é>",
            "&lt;&#039;&quot;é&gt;",
            "%3C%27%22%C3%A9%3E",
            "&lt;&#39;&quot;é&gt;",
            "&lt;&#x27;&quot;é&gt;",
            "&lt;&apos;&quot;é&gt;",
            #"<'\"\u00e9>"#,
            "&lt;&#039;&#34;é&gt;",
            "&lt;&#039;&#x22;é&gt;",
        ]
        #expect(quotes)
        let slashes = FixtureHygiene.variants(of: #"a/b\c"#) == [#"a/b\c"#, "a%2Fb%5Cc", #"a\/b\\c"#, #"a/b\\c"#]
        #expect(slashes)
        let emoji = FixtureHygiene.variants(of: "😀") == ["😀", "%F0%9F%98%80", #"\ud83d\ude00"#]
        #expect(emoji)
        let unreserved = FixtureHygiene.variants(of: "abc-1._~") == ["abc-1._~"]
        #expect(unreserved)
    }

    @Test func secretCheckUsesDigitBoundaries() {
        let secret = KnownSecret(kind: .numeric, value: "1234567")
        #expect(secretRules("/g/11234567/", secret) == [])
        #expect(secretRules("av-1234567.jpg", secret) == ["secret:numeric"])
    }

    @Test func secretCheckUsesWordBoundaries() {
        let secret = KnownSecret(kind: .word, value: "ann")
        #expect(secretRules("announce", secret) == [])
        #expect(secretRules("by ann,", secret) == ["secret:word"])
    }

    @Test func wordSecretAfterPercentEscapeIsFlagged() {
        let secret = KnownSecret(kind: .word, value: "Sora")
        #expect(secretRules("?f_search=uploader%3ASora", secret) == ["secret:word"])
        #expect(secretRules("%22Sora%22", secret) == ["secret:word"])
        #expect(secretRules("by%20Sora", secret) == ["secret:word"])
        #expect(secretRules("uploader%3ASorano", secret) == [])
    }

    @Test func numericSecretAfterPercentEscapeIsFlagged() {
        let secret = KnownSecret(kind: .numeric, value: "1234567")
        #expect(secretRules("%221234567%22", secret) == ["secret:numeric"])
        #expect(secretRules("uid%201234567", secret) == ["secret:numeric"])
        #expect(secretRules("%2212345678", secret) == [])
    }

    @Test func secretAfterJSONEscapeIsFlagged() {
        #expect(secretRules(#""\u3010Sora\u3011""#, KnownSecret(kind: .word, value: "Sora")) == ["secret:word"])
        #expect(secretRules(#""a\nSora""#, KnownSecret(kind: .word, value: "Sora")) == ["secret:word"])
        #expect(secretRules(#""\u3010Sorano""#, KnownSecret(kind: .word, value: "Sora")) == [])
        #expect(secretRules(#""\u30101234567""#, KnownSecret(kind: .numeric, value: "1234567")) == ["secret:numeric"])
    }

    @Test func secretCheckCoversEncodedVariants() {
        let secret = KnownSecret(kind: .literal, value: "A&B Fan")
        for (index, text) in ["A&B Fan", "A&amp;B Fan", "A%26B%20Fan", "A%26B+Fan"].enumerated() {
            let rules = secretRules(text, secret)
            #expect(rules == ["secret:literal"], "form \(index)")
        }
    }

    @Test func secretCheckCoversApostropheAndJSONVariants() {
        let apostrophe = KnownSecret(kind: .literal, value: "O'Neil Fan")
        for (index, text) in ["O'Neil Fan", "O&#039;Neil Fan", "O&#39;Neil Fan", "O&#x27;Neil Fan", "O&apos;Neil Fan", "O%27Neil+Fan"].enumerated() {
            let rules = secretRules(text, apostrophe)
            #expect(rules == ["secret:literal"], "apostrophe form \(index)")
        }
        let nonASCII = KnownSecret(kind: .literal, value: "春太 Fan")
        for (index, text) in ["春太 Fan", #"{"title":"\u6625\u592a Fan"}"#, "%E6%98%A5%E5%A4%AA%20Fan"].enumerated() {
            let rules = secretRules(text, nonASCII)
            #expect(rules == ["secret:literal"], "non-ASCII form \(index)")
        }
    }

    @Test func secretCheckCoversNumericEntityForms() {
        let secret = KnownSecret(kind: .literal, value: "A&B \"Fan\"")
        for (index, text) in ["A&#38;B &#34;Fan&#34;", "A&#x26;B &#x22;Fan&#x22;"].enumerated() {
            let rules = secretRules(text, secret)
            #expect(rules == ["secret:literal"], "form \(index)")
        }
    }

    @Test func secretCheckCoversJSONWithoutSlashEscapes() {
        let secret = KnownSecret(kind: .literal, value: "a/b ü")
        #expect(secretRules("a/b \\u00fc", secret) == ["secret:literal"])
        // The slash-escaping form is still found too, and the hex digits ignore case.
        #expect(secretRules("{\"t\":\"a\\/b \\u00FC\"}", secret) == ["secret:literal"])
    }

    @Test func secretCheckSkipsShortLiterals() {
        #expect(secretRules("xyz", KnownSecret(kind: .literal, value: "xyz")) == [])
        #expect(secretRules("wxyz", KnownSecret(kind: .literal, value: "wxyz")) == ["secret:literal"])
    }

    @Test func violationsNeverContainTheSecret() {
        let secret = KnownSecret(kind: .literal, value: "A&B Fan")
        let violations = ["A&B Fan", "A&amp;B Fan", "A%26B%20Fan", "A%26B+Fan"].flatMap {
            FixtureHygiene.secretViolations(in: "line\n\($0)", file: "t.html", secrets: [secret])
        }
        #expect(violations.count == 4)
        var dumped = ""
        dump(violations, to: &dumped)
        for rendered in [String(describing: violations), String(reflecting: violations), dumped] {
            let leaked = rendered.contains("A&B") || rendered.contains("A%26B")
            #expect(leaked == false, "a violation rendering shows the secret")
        }
    }

    @Test func knownSecretDescriptionsAreRedacted() {
        let secret = KnownSecret(kind: .literal, value: "A&B Fan")
        var dumped = ""
        dump(secret, to: &dumped)
        for rendered in [String(describing: secret), String(reflecting: secret), dumped] {
            let leaked = rendered.contains("A&B")
            #expect(leaked == false, "a KnownSecret rendering shows its value")
        }
    }

    @Test func secretsFileRoundTrips() {
        let secrets: Set<KnownSecret> = [
            KnownSecret(kind: .numeric, value: "1234567"),
            KnownSecret(kind: .word, value: "Sora"),
            KnownSecret(kind: .literal, value: "A&B Fan"),
        ]
        let rendered = FixtureHygiene.renderSecretsFile(Array(secrets))
        #expect(Set(FixtureHygiene.parseSecretsFile(rendered)) == secrets)
        let noisy = "# comment\n\n" + rendered + "\n   \n# literal\tcommented-out\n"
        #expect(Set(FixtureHygiene.parseSecretsFile(noisy)) == secrets)
    }

    @Test func knownSecretsReadsEnvironmentAndFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "eros-fixture-secrets-\(UUID().uuidString)")
        try "word\tSora\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let secrets = FixtureHygiene.knownSecrets(
            environment: ["EH_IPB_MEMBER_ID": "1234567", "EH_SP": "1"],
            secretsFile: file
        )
        #expect(secrets.count == 2)
        #expect(Set(secrets) == [KnownSecret(kind: .numeric, value: "1234567"), KnownSecret(kind: .word, value: "Sora")])
    }

    @Test func namedCredentialSecretsAreSortedByVariable() {
        let named = FixtureHygiene.namedCredentialSecrets(environment: [
            "EH_USERNAME": " Sora ", "EH_IPB_PASS_HASH": "0123456789abcdef", "EH_IPB_MEMBER_ID": "1234567",
            "EH_SK": "", "EH_SP": "1", "EH_USER_AGENT": "agent",
        ])
        #expect(named.map(\.variable) == ["EH_IPB_MEMBER_ID", "EH_IPB_PASS_HASH", "EH_USERNAME"])
        #expect(named.map(\.secret) == FixtureHygiene.knownSecrets(
            environment: ["EH_USERNAME": "Sora", "EH_IPB_PASS_HASH": "0123456789abcdef", "EH_IPB_MEMBER_ID": "1234567"],
            secretsFile: nil
        ))
        #expect(FixtureHygiene.persistedCredentialVariables == ["EH_IPB_MEMBER_ID", "EH_USERNAME"])
    }

    @Test func knownSecretsToleratesMissingFile() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "eros-missing-\(UUID().uuidString)")
        #expect(FixtureHygiene.knownSecrets(environment: ["EH_USERNAME": ""], secretsFile: missing) == [])
    }

    // MARK: Scan chain

    /// Runs the exact scans used on the checked-in fixtures against a fake root, so an empty fixture set cannot
    /// hide a broken chain.
    @Test func scanChainFlagsFakeFixtures() throws {
        let root = try TemporaryFixtureRoot(files: [
            "eh/.gitkeep": "",
            "eh/list/fake.html": """
            <script>var apikey = "0f1e2d3c4b5a69";</script>
            <p>ipb_pass_hash=0123456789abcdef</p>
            <p>Your IP is 8.8.8.8.</p>
            <a href="?f_search=uploader%3AZqFakeUser9">ZqFakeUser9</a>
            <p>Filtered 11 galleries from this page.</p>
            """,
            "ex/.gitkeep": "var apiuid = 7654321;\n",
            "constructed/fake.html": "<p>token fakeliteral0123</p>\n",
            "constructed/eh/fake-list.html": #"<div class="gt" style="color:#000" title="zqns:zqfaketag">x</div><p>Filtered 11 galleries</p>"#,
            // Exempt from `filteredlist` only: its unmasked count is still flagged.
            "constructed/eh/list-filtered.html": "<p>Filtered 23 galleries from this page.</p>\n",
            "manifest.json": #"{"entries":[],"note":"seen from 8.8.4.4"}"#,
            "local/.gitkeep": "",
            "local/eh/list/favorites.html": #"<div class="glfnote">Note: my private note</div> by ZqFakeUser9"#,
            "local/manifest.local.json": #"{"entries":[],"note":"seen from 8.8.4.4"}"#,
        ])
        defer { root.remove() }
        let secrets = [
            KnownSecret(kind: .word, value: "ZqFakeUser9"),
            KnownSecret(kind: .numeric, value: "7654321"),
            KnownSecret(kind: .literal, value: "fakeliteral0123"),
        ]

        let structural = try FixtureScan.structuralViolations(root: root.url, sourceRoot: root.url)
        #expect(fileAndRule(structural) == [
            "eh/list/fake.html apikey", "eh/list/fake.html cookie", "eh/list/fake.html ipv4", "eh/list/fake.html filteredlist",
            "ex/.gitkeep apiuid", "constructed/eh/fake-list.html tagstyle", "constructed/eh/fake-list.html filteredlist",
            "constructed/eh/list-filtered.html filtered", "manifest.json ipv4",
            "local/eh/list/favorites.html glfnote", "local/manifest.local.json ipv4",
        ])
        let secret = try FixtureScan.secretViolations(secrets, root: root.url, sourceRoot: root.url, repositoryFiles: [])
        #expect(fileAndRule(secret) == [
            "eh/list/fake.html secret:word", "ex/.gitkeep secret:numeric", "constructed/fake.html secret:literal",
            "local/eh/list/favorites.html secret:word",
        ])
        // Private captures are scanned but never counted as checked-in fixtures.
        let checkedIn = try FixtureFiles.captured(root: root.url).contains { $0.hasPrefix("local/") }
        #expect(checkedIn == false)

        var dumped = ""
        dump(structural + secret, to: &dumped)
        let fakeValues = ["0f1e2d3c4b5a69", "0123456789abcdef", "8.8.8.8", "8.8.4.4", "ZqFakeUser9", "7654321", "fakeliteral0123"]
        for rendered in [String(describing: structural + secret), String(reflecting: structural + secret), dumped] {
            let leaked = fakeValues.contains { rendered.contains($0) }
            #expect(leaked == false, "a violation rendering shows a fake value")
        }
    }

    @Test func scanWithoutLocalDirectoryIsFine() throws {
        // No local/ at all: nothing to scan, no error.
        let root = try TemporaryFixtureRoot(files: ["manifest.json": #"{"entries":[]}"#])
        defer { root.remove() }
        #expect(try FixtureFiles.local(root: root.url).isEmpty)
        #expect(try FixtureScan.structuralViolations(root: root.url, sourceRoot: root.url).isEmpty)
        let secret = try FixtureScan.secretViolations(
            [KnownSecret(kind: .word, value: "ZqFakeUser9")], root: root.url, sourceRoot: root.url, repositoryFiles: []
        )
        #expect(secret.isEmpty)
        // A local/ holding only its empty .gitkeep, as on a fresh clone: also nothing.
        let withGitkeep = try TemporaryFixtureRoot(files: ["manifest.json": #"{"entries":[]}"#, "local/.gitkeep": ""])
        defer { withGitkeep.remove() }
        #expect(try FixtureFiles.local(root: withGitkeep.url).isEmpty)
    }

    @Test func checkedInScansLookAtTheSourceTreeLocalDirectory() {
        // The default local root is this source tree's fixture root, where the tracked local/.gitkeep lives.
        let gitkeep = FixtureFiles.sourceRoot.appending(path: "local/.gitkeep").path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: gitkeep))
    }

    /// Both READMEs get the secret scan and not the structural one: they quote the rules' own words.
    @Test func readmesAreSecretScanned() throws {
        // Rule text as a README quotes it: an unmasked apikey, a foreign IPv4, a "Filtered" line and a tag style.
        let quotedRules = """
        Example: var apikey = "0f1e2d3c4b5a69"; seen from 8.8.8.8.
        <p>Filtered 11 galleries from this page.</p> <div class="gt" style="color:#000">x</div>
        """
        let quotedRulesAreFlagged = !structural(quotedRules).isEmpty
        #expect(quotedRulesAreFlagged, "the quote must be what the structural scan reports outside a README")
        let root = try TemporaryFixtureRoot(files: [
            "manifest.json": #"{"entries":[]}"#,
            "README.md": "# Fixtures\n\(quotedRules)\nCaptured as ZqFakeUser9.\n",
            "constructed/README.md": "# Constructed\nby ZqFakeUser9\n\(quotedRules)\n",
        ])
        defer { root.remove() }
        let secrets = [KnownSecret(kind: .word, value: "ZqFakeUser9")]
        let secret = try FixtureScan.secretViolations(secrets, root: root.url, sourceRoot: root.url, repositoryFiles: [])
        #expect(secret.map(\.description) == ["constructed/README.md:2: secret:word", "README.md:4: secret:word"])
        #expect(try FixtureScan.structuralViolations(root: root.url, sourceRoot: root.url).isEmpty)
        // The checked-in scan reads README.md from the source tree: the resource bundle leaves it out.
        let readme = FixtureFiles.sourceRoot.appending(path: "README.md").path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: readme))
    }

    /// The repository's tests, docs and capture targets get the secret check too, reported from
    /// the repository root: the identity is kept in the secrets file, and nothing else would look for it there.
    @Test func secretCheckSearchesRepositoryFiles() throws {
        let root = try TemporaryFixtureRoot(files: ["manifest.json": #"{"entries":[]}"#])
        defer { root.remove() }
        let repository = try TemporaryFixtureRoot(files: [
            "README.md": "# Repository\nnothing private\n",
            "docs/notes/zz.md": "# Notes\nSigned in as ZqFakeUser9.\n",
            "Packages/ErosKit/Tests/EHParsingTests/ZzTests.swift": "// fake\nlet memberID = 7654321\n",
            "Tools/FixtureCapture/targets.json": #"{"eh":{"uploader":"zqfakeuser9"}}"#,
            "docs/clean.md": "member 17654321 and user ZqFakeUser90 are other values\n",
        ])
        defer { repository.remove() }
        let paths = [
            "README.md", "docs/clean.md", "docs/notes/zz.md", "Packages/ErosKit/Tests/EHParsingTests/ZzTests.swift",
            "Tools/FixtureCapture/targets.json",
        ]
        let secrets = [KnownSecret(kind: .word, value: "ZqFakeUser9"), KnownSecret(kind: .numeric, value: "7654321")]
        let violations = try FixtureScan.secretViolations(
            secrets, root: root.url, sourceRoot: root.url, repositoryFiles: paths.map { ($0, repository.url) }
        )
        #expect(violations.map(\.description) == [
            "/docs/notes/zz.md:2: secret:word",
            "/Packages/ErosKit/Tests/EHParsingTests/ZzTests.swift:2: secret:numeric",
            "/Tools/FixtureCapture/targets.json:1: secret:word",
        ])
        let rendered = String(describing: violations) + String(reflecting: violations)
        let leaked = ["ZqFakeUser9", "zqfakeuser9", "7654321"].contains { rendered.contains($0) }
        #expect(leaked == false, "a violation rendering shows a fake value")
    }

    @Test func gitkeepIsSkippedOnlyWhenEmpty() throws {
        let root = try TemporaryFixtureRoot(files: ["eh/.gitkeep": "", "ex/.gitkeep": "not empty\n"])
        defer { root.remove() }
        #expect(try FixtureFiles.captured(root: root.url) == ["ex/.gitkeep"])
    }

    // MARK: Checked-in fixtures

    /// Guarded against a short fixture set: each site must have at least `Fixtures.minimumCapturedFixtures` checked-in
    /// captured files and manifest entries, or the scan below would pass with pages missing. Local-only pages
    /// (`local/`, not in the bundle) are not counted.
    @Test func capturedFixturesPassStructuralChecks() throws {
        let files = try FixtureFiles.captured()
        let entries = try Fixtures.manifest().entries.filter { $0.source == .captured }
        for site in ["eh", "ex"] {
            let fileCount = files.filter { $0.hasPrefix(site + "/") }.count
            let entryCount = entries.filter { $0.path.hasPrefix(site + "/") }.count
            let floor = Fixtures.minimumCapturedFixtures[site] ?? 1
            #expect(fileCount >= floor, "\(fileCount) captured fixture files under \(site)/, fewer than \(floor)")
            #expect(entryCount >= floor, "\(entryCount) captured manifest entries for \(site)/, fewer than \(floor)")
        }
        let violations = try FixtureScan.structuralViolations()
        #expect(violations.isEmpty, "\(violations)")
    }

    /// Also scans `constructed/`: hand-made fixtures must not leak real credentials either; and every other text file
    /// of the repository (tests, docs, capture targets), where git can list them.
    @Test(
        .enabled(if: !localKnownSecrets.isEmpty),
        .enabled(if: FixtureFiles.canListRepository, "git cannot list the repository here (not a Mac, or no checkout)")
    )
    func capturedFixturesContainNoKnownSecrets() throws {
        let violations = try FixtureScan.secretViolations(localKnownSecrets)
        #expect(violations.isEmpty, "\(violations)")
    }

    /// The private pages live under `local/` only: none at its checked-in path under `eh/` or `ex/`, nor listed in
    /// `manifest.json`, whether the capture tool or a hand copied it there.
    @Test func privatePagesAreNotAtCheckedInPaths() throws {
        let found = try FixtureScan.privatePagesAtCheckedInPaths()
        #expect(found.isEmpty, "\(found)")
    }

    @Test func privatePagesAtCheckedInPathsAreFound() throws {
        let manifest = #"{"entries":[{"path":"ex/list/favorites.html","site":"ex","source":"captured","setCookieNames":[]}]}"#
        let root = try TemporaryFixtureRoot(files: [
            "manifest.json": manifest,
            "eh/list/watched.html": "<html></html>",
            "eh/list/Favorites-Cat0.html": "<html></html>",
            "eh/list/front.html": "<html></html>",
            "local/eh/list/watched.html": "<html></html>",
            "local/eh/forum/profile.html": "<html></html>",
        ])
        defer { root.remove() }
        let found = try FixtureScan.privatePagesAtCheckedInPaths(root: root.url)
        #expect(found == ["eh/list/Favorites-Cat0.html", "eh/list/watched.html", "ex/list/favorites.html"])
        // The list covers what the capture plan keeps local: mytags, favorites and watched on each site, and the
        // forum profile.
        let paths = FixtureHygiene.privatePagePaths
        #expect(paths.count == 11 && Set(paths).count == 11)
        let allUnderSites = paths.allSatisfy { $0.hasPrefix("eh/") || $0.hasPrefix("ex/") }
        #expect(allUnderSites)
    }

    /// A configured or present secrets file that yields nothing would make the secret scan skip silently.
    @Test(.enabled(if: localSecretsFileNeedsCheck))
    func localSecretsFileIsUsable() throws {
        let path = localSecretsFile?.url.path(percentEncoded: false) ?? ""
        let exists = FileManager.default.fileExists(atPath: path)
        try #require(exists, "secrets file not found: \(path)")
        let text = try? String(contentsOf: URL(filePath: path), encoding: .utf8)
        let readable = text != nil
        try #require(readable, "secrets file unreadable: \(path)")
        // Only the count reaches the expectation, so a failure cannot print the file's contents.
        let parsedCount = FixtureHygiene.parseSecretsFile(text ?? "").count
        #expect(parsedCount > 0, "no secrets parsed from: \(path)")
    }

    /// The local secrets file keeps the identity too, so scans without `op run` still cover it.
    @Test(.enabled(if: localSecretsFileNeedsCheck))
    func localSecretsFileCoversIdentity() throws {
        let path = localSecretsFile?.url.path(percentEncoded: false) ?? ""
        let text = try? String(contentsOf: URL(filePath: path), encoding: .utf8)
        let readable = text != nil
        try #require(readable, "secrets file unreadable: \(path)")
        // Only Booleans reach the expectations, so a failure cannot print the file's contents.
        let kinds = Set(FixtureHygiene.parseSecretsFile(text ?? "").map(\.kind))
        let hasNumeric = kinds.contains(.numeric)
        let hasWord = kinds.contains(.word)
        #expect(hasNumeric && hasWord, "no numeric and word entry in: \(path); run fixture-capture resanitize once with credentials")
    }
}
