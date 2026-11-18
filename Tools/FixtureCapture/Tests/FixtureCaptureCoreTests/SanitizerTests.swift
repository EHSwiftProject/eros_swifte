import EHFixtures
import EHModels
@testable import FixtureCaptureCore
import Foundation
import Testing

// Fake values only. No expectation takes sanitized or masked text (or anything holding a secret) as an operand:
// each compares a Boolean or a count computed first, so a failure cannot print what leaked.
private let fakeApikey = "0f1e2d3c4b5a69"
private let fakePassHash = "f0e1d2c3b4a5968778695a4b3c2d1e0f"
private let backslash = "\\"

private func sanitizer(_ credentials: [KnownSecret] = [], discovering texts: [String] = []) -> Sanitizer {
    var secrets = SecretSet(credentialSecrets: credentials, extraSecrets: [])
    for text in texts {
        secrets.discover(in: text)
    }
    return Sanitizer(secrets: secrets)
}

private func isClean(_ text: String, file: String = "t.html", secrets: some Sequence<KnownSecret>) -> Bool {
    FixtureHygiene.structuralViolations(in: text, file: file).isEmpty
        && FixtureHygiene.secretViolations(in: text, file: file, secrets: Array(secrets)).isEmpty
}

/// True when `text` contains one of `values`, ignoring case.
private func containsAny(of values: [String], in text: String) -> Bool {
    values.contains { text.range(of: $0, options: .caseInsensitive) != nil }
}

private func credentials(_ extra: [String: String] = [:]) throws -> CaptureCredentials {
    let environment = ["EH_IPB_MEMBER_ID": "1234567", "EH_IPB_PASS_HASH": fakePassHash, "EH_USERNAME": "ZqUser"].merging(extra) { _, new in new }
    return try CaptureCredentials(environment: environment, sites: [.eh])
}

private func raw(
    _ path: String = "eh/page.html",
    url: String = "https://e-hentai.org/",
    status: Int = 200,
    headers: [String: String] = ["Content-Type": "text/html; charset=UTF-8"],
    body: String
) -> RawCapture {
    RawCapture(
        fixturePath: path, site: .eh, method: "GET", url: URL(string: url)!, status: status, headers: headers,
        body: Data(body.utf8), capturedAt: Date(timeIntervalSince1970: 1_793_750_400)
    )
}

@Suite struct SanitizerTests {
    // MARK: Mask

    @Test func maskPreservesLengthAndClass() {
        let classes = Sanitizer.mask("a1B2-c3") == "a1A1-a1"
        #expect(classes)
        let digits = Sanitizer.mask("1234567") == "1111111"
        #expect(digits)
    }

    @Test func maskCoversEveryScript() {
        let cjk = Sanitizer.mask("春太") == "aa"
        #expect(cjk)
        let input = "Ünïcode9"
        let masked = Sanitizer.mask(input)
        let onlyASCIIAlphanumerics = masked.unicodeScalars.allSatisfy { $0.isASCII || !CharacterSet.alphanumerics.contains($0) }
        #expect(onlyASCIIAlphanumerics)
        let sameCount = masked.count == input.count
        #expect(sameCount)
        let latin = masked == "Aaaaaaa1"
        #expect(latin)
        // A decomposed letter is one Character and becomes one mask character; other digits become "1".
        let decomposed = Sanitizer.mask("e" + String(Unicode.Scalar(0x0301)!) + "x") == "aa"
        #expect(decomposed)
        let otherDigits = Sanitizer.mask("٣①") == "11"
        #expect(otherDigits)
        let punctuation = Sanitizer.mask("a-b_c d.e") == "a-a_a a.a"
        #expect(punctuation)
    }

    // MARK: Structural rules

    @Test func apikeyAndApiuidAreMasked() {
        let result = sanitizer().sanitize("var apiuid = 1234567;\nvar apikey = \"\(fakeApikey)\";")
        let masked = result.contains("var apiuid = 1111111;") && result.contains("var apikey = \"1a1a1a1a1a1a11\";")
        #expect(masked)
    }

    @Test func loginCookiesAreMasked() {
        let result = sanitizer().sanitize("document.cookie=\"ipb_pass_hash=\(fakePassHash); sk=zz9x\";")
        let masked = result == "document.cookie=\"ipb_pass_hash=a1a1a1a1a1a1111111111a1a1a1a1a1a; sk=aa1a\";"
        #expect(masked)
    }

    /// The forum's session cookie of a real login response (tooling review m3): masked like the other login cookies.
    @Test func forumSessionCookieIsMasked() {
        let header = "Set-Cookie: ipb_session_id=0f1e2d3c4b5a69780f1e2d3c4b5a6978; path=/; domain=.e-hentai.org"
        let result = sanitizer().sanitize(header)
        let masked = result == "Set-Cookie: ipb_session_id=1a1a1a1a1a1a11111a1a1a1a1a1a1111; path=/; domain=.e-hentai.org"
        #expect(masked)
        let clean = FixtureHygiene.structuralViolations(in: result, file: "t").isEmpty
        #expect(clean)
    }

    // MARK: Torrent keys, tracker links and home.php statistics

    @Test func torrentKeyIsMasked() {
        let page = #"<p>Your current key is: <span style="font-weight:bold">\#(CaptureFakes.torrentKey)</span></p>"#
        let result = sanitizer().sanitize(page)
        let masked = result == #"<p>Your current key is: <span style="font-weight:bold">Aa1aaaaAaa</span></p>"#
        #expect(masked)
        let clean = isClean(result, secrets: CaptureFakes.plantedSecrets)
        #expect(clean, "sanitized text fails the hygiene check")
    }

    @Test func torrentLinksAndAnnounceAreMasked() {
        let result = sanitizer().sanitize(CannedSite.torrentsPage)
        let hash = CaptureFakes.infoHash
        let plain = result.contains(#"href="https://ehtracker.org/get/1111111/aa1aaaa1aaa1aaa1aa/\#(hash).torrent""#)
        #expect(plain, "the plain download link is not masked as expected")
        let personal = result.contains(
            "document.location='https://ehtracker.org/get/1111111/aa1aaaa1aaa1aaa1aa/1111111-aaaaaa1aaaaaaa1aaa1/\(hash).torrent'"
        )
        #expect(personal, "the personal download link is not masked as expected")
        let announce = result.contains("http://ehtracker.org/1111111/announce")
        #expect(announce, "the announce URL is not masked as expected")
        // The gallery, the token and the public info hash stay.
        let kept = result.contains("gallerytorrents.php?gid=123&amp;t=abcdef0123") && result.contains(hash)
        #expect(kept)
        let clean = isClean(result, secrets: CaptureFakes.plantedSecrets)
        #expect(clean, "sanitized text fails the hygiene check")
    }

    @Test func encodedTrackerLinksAreMasked() throws {
        let fakes = "\(CaptureFakes.trackerID)/\(CaptureFakes.torrentSegment)/\(CaptureFakes.memberID)-\(CaptureFakes.torrentLinkKey)"
        let link = "https://ehtracker.org/get/\(fakes)/\(CaptureFakes.infoHash).torrent"
        let announce = "http://ehtracker.org/\(CaptureFakes.trackerID)/announce"
        let slash = backslash + "/"
        let json = #"{"link":""# + link.replacingOccurrences(of: "/", with: slash) + #"","announce":""#
            + announce.replacingOccurrences(of: "/", with: slash) + #""}"#
        let percent = "<a href=\"/redirect?to=" + link.replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: "/", with: "%2F") + "&amp;a=" + announce.replacingOccurrences(of: "/", with: "%2f") + "\">x</a>"
        // The inputs really hold the escapes.
        let escaped = json.contains("ehtracker.org" + slash + "get" + slash) && percent.contains("ehtracker.org%2Fget%2F")
        #expect(escaped)
        for (index, text) in [json, percent].enumerated() {
            let rules = Set(FixtureHygiene.structuralViolations(in: text, file: "t").map(\.rule))
            let expected: Set<String> = [FixtureHygiene.torrentLinkRule, FixtureHygiene.trackerRule, FixtureHygiene.trackerURLRule]
            #expect(rules == expected, "form \(index)")
            let result = sanitizer().sanitize(text)
            let clean = isClean(result, secrets: CaptureFakes.plantedSecrets)
            #expect(clean, "form \(index): sanitized text fails the hygiene check")
            let escapesKept = result.contains("ehtracker.org" + slash + "get" + slash) || result.contains("ehtracker.org%2Fget%2F")
            #expect(escapesKept, "form \(index): the separators were rewritten")
        }
        let object = try JSONSerialization.jsonObject(with: Data(sanitizer().sanitize(json).utf8)) as? [String: String]
        let parses = object?["link"]?.hasPrefix("https://ehtracker.org/get/1111111/") == true
        #expect(parses, "sanitized JSON no longer parses")
    }

    @Test func lookalikesOfTrackerLinksAreKept() {
        let text = """
        <a href="https://e-hentai.org/s/0a1b2c3d4e/3456789-12">image</a>
        <a href="https://e-hentai.org/g/3456789/abcdef0123/">gallery</a>
        <a href="https://ehtracker.org/get/">tracker</a> https://e-hentai.org/3456789/announcements
        <p>Your current torrent count is: 5</p><p>Your current key is: <span></span></p>
        <h2>Total GP Gained</h2><p>12,345,678</p>
        """
        let kept = sanitizer().sanitize(text) == text
        #expect(kept)
    }

    @Test func homeStatisticsAreMaskedAndImageLimitsKept() {
        let result = sanitizer().sanitize(CannedSite.homeSections)
        let limitsKept = result.contains("<strong>12</strong> towards a limit of <strong>\(CaptureFakes.imageLimit)</strong>")
        #expect(limitsKept, "the image limits changed")
        let masked = result.contains(#"<td class="c1">1.11 GiB</td>"#) && result.contains(">11,111,111</td>")
            && result.contains("<strong>#1111</strong>") && result.contains("toplist.php?tl=31")
        #expect(masked, "the statistics are not masked as expected")
        let clean = isClean(result, secrets: CaptureFakes.plantedSecrets)
        #expect(clean, "sanitized text fails the hygiene check")
    }

    @Test func discoveryFindsTorrentKeysAndTrackerValuesButNotStatistics() {
        var secrets = SecretSet(credentialSecrets: [], extraSecrets: [])
        secrets.discover(in: CannedSite.torrentsPage)
        secrets.discover(in: CannedSite.homeSections)
        // The tracker number is no gallery id on these pages (the popup's own gallery is 123), so it is searched for.
        let found: Set<KnownSecret> = [
            KnownSecret(kind: .literal, value: CaptureFakes.torrentKey),
            KnownSecret(kind: .literal, value: CaptureFakes.torrentLinkKey),
            KnownSecret(kind: .numeric, value: CaptureFakes.memberID),
            KnownSecret(kind: .literal, value: CaptureFakes.torrentSegment),
            KnownSecret(kind: .numeric, value: CaptureFakes.trackerID),
        ]
        let discovered = found.isSubset(of: secrets.all) && found.isSubset(of: secrets.persistable)
        #expect(discovered)
        // Statistics are short, common numbers: only masked in place.
        let statistics = [CaptureFakes.gpTotal, CaptureFakes.toplistRank, "2.50", "12"]
        let searched = secrets.all.contains { statistics.contains($0.value) }
        #expect(searched == false)
        #expect(secrets.warnings.isEmpty)
        // A discovered value is removed wherever else it shows up.
        let sanitizer = Sanitizer(secrets: secrets)
        let elsewhere = sanitizer.sanitize("?key=\(CaptureFakes.torrentKey)&n=1") == "?key=Aa1aaaaAaa&n=1"
            && sanitizer.sanitize("id \(CaptureFakes.trackerID), \(CaptureFakes.torrentSegment)") == "id 1111111, aa1aaaa1aaa1aaa1aa"
        #expect(elsewhere)
    }

    @Test func exemptRulesAreLeftAlone() {
        let text = "<td>" + CannedSite.coloredTag + "</td><p>fake-apikey-0000</p>"
        let kept = sanitizer().sanitize(text, exempting: [FixtureHygiene.tagStyleRule]).contains("color:#123456")
        #expect(kept)
        let removed = !sanitizer().sanitize(text).contains("color:#123456")
        #expect(removed)
        var secrets = SecretSet(credentialSecrets: [], extraSecrets: [])
        secrets.discover(in: #"<div id="profilename">Fake Nickname</div>"#)
        let replaced = !Sanitizer(secrets: secrets).sanitize(text + "Fake Nickname", exempting: [FixtureHygiene.tagStyleRule])
            .contains("Fake Nickname")
        #expect(replaced)
    }

    @Test func tagStylesAreRemovedWhole() {
        let text = "<td>" + CannedSite.coloredTag + #"<div style="color:#000" class="gtl">x</div>"# + CannedSite.plainTag + "</td>"
        let result = sanitizer().sanitize(text)
        let expected = "<td>" + CannedSite.plainTag + #"<div class="gtl">x</div>"# + CannedSite.plainTag + "</td>"
        #expect(result == expected)
        // Other styles stay.
        let rating = #"<div class="ir" style="background-position:-16px -1px;opacity:0.93333"></div>"#
        let kept = sanitizer().sanitize(rating) == rating
        #expect(kept)
    }

    @Test func filteredCountAndFundsAreMasked() {
        let text = CannedSite.filteredLine + CannedSite.fundsParagraph + "<p>Download Cost: 1,234 GP</p>"
        let result = sanitizer().sanitize(text)
        let masked = result.contains("Filtered 11 galleries from this page") && result.contains("Found about 12,345 results")
            && result.contains("1,111,111 GP [") && result.contains("111 Credits") && result.contains("Download Cost: 1,234 GP")
        #expect(masked)
        let again = sanitizer().sanitize(result) == result
        #expect(again, "sanitizing masked text changes it")
    }

    @Test func ordinaryAnnounceLinksAndWordsAreNotSecrets() throws {
        // Comment-like links on a detail page, and a plain word after the key label: masked where they stand, but
        // never taken as secrets, so the years, counts and words elsewhere stay as they are.
        let detail = CannedSite.detailPage(host: "e-hentai.org", imagePages: true)
        let injected = detail.replacingOccurrences(of: "</body>", with: """
            <div class="c6">see https://example.org/2024/announce and https://example.org/5/announce,
            https://example.org/2024-12/announce, https://example.org/12345-abcd/announce</div>
            <p>Your current key is: Download</p></body>
            """)
        let other = "<p>Posted 2024-12-01, 5 pages, 12345 views, abcd. Download the archive.</p>"
        var baseline = SecretSet(credentialSecrets: [], extraSecrets: [])
        baseline.discover(in: detail)
        var secrets = SecretSet(credentialSecrets: [], extraSecrets: [])
        secrets.discover(in: injected)
        secrets.discover(in: other)
        let noNewSecrets = secrets.all == baseline.all && secrets.persistable == baseline.persistable
        #expect(noNewSecrets, "an ordinary link or word became a secret")
        let sanitizer = Sanitizer(secrets: secrets)
        let otherKept = sanitizer.sanitize(other) == other
        #expect(otherKept, "another page changed")
        // In place, the injected values are masked and the page is clean.
        let result = sanitizer.sanitize(injected)
        let masked = result.contains("https://example.org/1111/announce") && result.contains("https://example.org/1/announce")
            && result.contains("https://example.org/1111-11/announce") && result.contains("https://example.org/11111-aaaa/announce")
        #expect(masked)
        let clean = isClean(result, secrets: secrets.all)
        #expect(clean)
    }

    @Test func shortTrackerValuesAreOnlyMaskedInPlace() {
        // On the tracker itself too: a uid under 5 digits or a key under 8 characters is not searched for elsewhere.
        var secrets = SecretSet(credentialSecrets: [], extraSecrets: [])
        let page = "<a href=\"http://ehtracker.org/1111111/1234-zqkey12/announce\">x</a>"
        secrets.discover(in: page)
        let searched = secrets.all.contains { $0.value == "1234" || $0.value == "zqkey12" }
        #expect(searched == false)
        let leaked = secrets.warnings.contains { $0.contains("1234") || $0.contains("zqkey12") }
        #expect(leaked == false)
        let masked = Sanitizer(secrets: secrets).sanitize(page) == "<a href=\"http://ehtracker.org/1111111/1111-aaaaa11/announce\">x</a>"
        #expect(masked)
    }

    @Test func trackerNumberThatIsAGalleryIDIsOnlyMaskedInPlace() {
        let tracker = KnownSecret(kind: .numeric, value: CaptureFakes.trackerID)
        let gallery = "<a href=\"https://e-hentai.org/g/\(CaptureFakes.trackerID)/abcdef0123/\">older version</a>"
        let parameter = #"{"gmetadata":[{"gid":\#(CaptureFakes.trackerID),"token":"abcdef0123"}]}"#
        // The gallery id may be seen before or after the torrent popup, in a link or as a JSON key.
        for (index, texts) in [
            [CannedSite.torrentsPage, gallery], [gallery, CannedSite.torrentsPage], [CannedSite.torrentsPage, parameter],
        ].enumerated() {
            var secrets = SecretSet(credentialSecrets: [], extraSecrets: [])
            for text in texts { secrets.discover(in: text) }
            let searched = secrets.all.contains(tracker) || secrets.persistable.contains(tracker)
            #expect(searched == false, "order \(index)")
            // Still masked inside the tracker URLs, and the gallery link keeps its gid.
            let sanitizer = Sanitizer(secrets: secrets)
            let inPlace = sanitizer.sanitize(CannedSite.torrentsPage).contains("http://ehtracker.org/1111111/announce")
                && sanitizer.sanitize(gallery) == gallery
            #expect(inPlace, "order \(index)")
        }
        // A credential with the same value stays a secret.
        var withCredential = SecretSet(credentialSecrets: [tracker], extraSecrets: [])
        withCredential.discover(in: CannedSite.torrentsPage)
        withCredential.discover(in: gallery)
        #expect(withCredential.all.contains(tracker))
    }

    @Test func shortTorrentKeysAreOnlyMaskedInPlace() {
        // A value shorter than 8 characters after the label is masked where it stands, not searched for elsewhere.
        var secrets = SecretSet(credentialSecrets: [], extraSecrets: [])
        let page = "<p>Your current key is: <span>zq9ab</span></p>"
        secrets.discover(in: page)
        let searched = secrets.all.contains { $0.value == "zq9ab" }
        #expect(searched == false)
        #expect(secrets.warnings.count == 1)
        let leaked = secrets.warnings.contains { $0.contains("zq9ab") }
        #expect(leaked == false)
        let masked = Sanitizer(secrets: secrets).sanitize(page) == "<p>Your current key is: <span>aa1aa</span></p>"
        #expect(masked)
        // No value within two tags: nothing at all, not the next heading's first word.
        var empty = SecretSet(credentialSecrets: [], extraSecrets: [])
        empty.discover(in: "<p>Your current key is: <span></span></p>\n<h2>Total GP Gained</h2>")
        #expect(empty.all.isEmpty)
        #expect(empty.warnings.isEmpty)
    }

    @Test func boldWordAfterKeyLabelIsOnlyMaskedInPlace() {
        // A word in the tag the key is shown in is no key: no digit and no capital after the first letter, so it is
        // masked where it stands and never searched for elsewhere, whatever tag it sits in.
        for (word, mask) in [("Downloads", "Aaaaaaaaa"), ("Unavailable", "Aaaaaaaaaaa")] {
            for tag in ["strong", "span", "b"] {
                let page = "<p>Your current key is: <\(tag)>\(word)</\(tag)></p>"
                var secrets = SecretSet(credentialSecrets: [], extraSecrets: [])
                secrets.discover(in: page)
                #expect(secrets.all.isEmpty, "\(word) in \(tag)")
                #expect(secrets.warnings.count == 1, "\(word) in \(tag)")
                let leaked = secrets.warnings.contains { $0.contains(word) }
                #expect(leaked == false)
                let masked = Sanitizer(secrets: secrets).sanitize(page) == "<p>Your current key is: <\(tag)>\(mask)</\(tag)></p>"
                #expect(masked, "\(word) in \(tag)")
            }
        }
        // Keys are still secrets: 10 characters with letters and digits, and 10 letters without a digit but with
        // capitals after the first.
        for key in [CaptureFakes.torrentKey, "ZqFakeKeyX"] {
            var keyed = SecretSet(credentialSecrets: [], extraSecrets: [])
            keyed.discover(in: "<p>Your current key is: <strong>\(key)</strong></p>")
            #expect(keyed.all == [KnownSecret(kind: .literal, value: key)], "\(key)")
            #expect(keyed.warnings.isEmpty, "\(key)")
        }
    }

    @Test func forumKeysInScriptsAndFormsAreMaskedAndSearchedFor() {
        let key = "0123456789abcdef0123456789ABCDEF"
        let maskedKey = "1111111111aaaaaa1111111111AAAAAA"
        let page = """
        <script>var ipb_var_s = "\(key)"; var ipb_md5_check = "\(key)";</script>
        <form><input type="hidden" name="auth_key" value="\(key)"></form>
        """
        var secrets = SecretSet(credentialSecrets: [], extraSecrets: [])
        secrets.discover(in: page)
        // A token: searched for in this run, never kept in the secrets file.
        let token = KnownSecret(kind: .literal, value: key)
        let searched = secrets.all.contains(token)
        #expect(searched)
        let kept = secrets.persistable.contains(token)
        #expect(kept == false, "a forum key would be written to the secrets file")
        #expect(secrets.warnings.isEmpty)
        let sanitizer = Sanitizer(secrets: secrets)
        let result = sanitizer.sanitize(page)
        let masked = result == page.replacingOccurrences(of: key, with: maskedKey)
        #expect(masked)
        let clean = FixtureHygiene.structuralViolations(in: result, file: "t").isEmpty
        #expect(clean)
        // A form no structural rule knows, on another page of the run: the secret search catches it.
        let elsewhere = #"<a href="/redirect?to=index.php%3Fs%3D\#(key)%26act%3DLogin">x</a>"#
        let alsoMasked = sanitizer.sanitize(elsewhere) == elsewhere.replacingOccurrences(of: key, with: maskedKey)
        #expect(alsoMasked)
    }

    @Test func memberIDIsPersistedOnceAsIdentity() throws {
        let credentials = try CaptureCredentials(environment: CaptureFakes.environment(sites: [.eh]), sites: [.eh])
        var secrets = SecretSet(
            namedCredentials: credentials.namedSecrets.map { (name: $0.name, secret: $0.secret) }, extraSecrets: []
        )
        secrets.discover(in: CannedSite.torrentsPage)
        // The personal link's uid is the member id: one numeric entry, however many ways it was found.
        let rendered = FixtureHygiene.renderSecretsFile(secrets.persistable.sorted { ($0.kind.rawValue, $0.value) < ($1.kind.rawValue, $1.value) })
        let lines = rendered.split(separator: "\n").filter { $0 == "numeric\t\(CaptureFakes.memberID)" }
        #expect(lines.count == 1)
        let keyPersisted = secrets.persistable.contains(KnownSecret(kind: .literal, value: CaptureFakes.torrentLinkKey))
        #expect(keyPersisted)
    }

    @Test func everyStructuralRuleIsFixedBySanitizing() {
        // The shapes added in M1: a forum session key, a tag element with an unquoted class, and funds after a
        // `&nbsp;` label without a closing `</p>`.
        let forumKey = #"<a href="https://forums.e-hentai.org/index.php?s=0123456789abcdef0123456789abcdef&amp;act=Login">x</a>"#
        let unquotedClass = #"<div class=gt style="color:#123456">zqfaketag</div>"#
        let nbspFunds = "<div>Current&nbsp;Funds: <strong>12,345</strong> GP</div>"
        // A favorited gallery's row, and the stars of a gallery the account rated (check only, like the "Filtered"
        // line).
        let favoritedRow = #"<div id="posted_1" style="border-color:#000" title="Favorites 0">2026-01-01 00:00</div>"#
        let ratedStars = #"<div class="ir irr" style="background-position:0px -1px;opacity:1"></div>"#
        let added = [
            (forumKey, FixtureHygiene.forumKeyRule), (unquotedClass, FixtureHygiene.tagStyleRule),
            (nbspFunds, FixtureHygiene.fundsRule), (ratedStars, FixtureHygiene.accountMarkRule),
        ]
        for (fragment, rule) in added {
            let flagged = FixtureHygiene.structuralViolations(in: fragment, file: "t").map(\.rule) == [rule]
            #expect(flagged, "\(rule)")
        }
        let text = """
        <script>var apikey = "\(fakeApikey)"; var apiuid = 1234567;</script><p>ipb_pass_hash=\(fakePassHash) 8.8.8.8</p>
        <textarea name="favnote">my note</textarea><div class="glfnote">Note: my note</div>
        <a href="https://example.org/2024/announce">an ordinary announce link</a>
        \(CannedSite.coloredTag)\(CannedSite.filteredLine)\(CannedSite.fundsParagraph)
        \(forumKey)\(unquotedClass)\(nbspFunds)\(favoritedRow)\(ratedStars)
        \(CannedSite.torrentsPage)
        \(CannedSite.homeSections)
        """
        let before = Set(FixtureHygiene.structuralViolations(in: text, file: "t").map(\.rule))
        #expect(before == Set(FixtureHygiene.structuralRuleNames), "the sample does not exercise every structural rule")
        let after = FixtureHygiene.structuralViolations(in: sanitizer(discovering: [text]).sanitize(text), file: "t")
        // Except the check-only rules: no sanitizing brings back what the filters hid, and a page showing the
        // account's favorites, ratings or votes is refused rather than rewritten.
        #expect(after.map(\.rule) == [
            FixtureHygiene.filteredListRule, FixtureHygiene.favoriteMarkRule, FixtureHygiene.accountMarkRule,
        ], "\(after)")
        let line = sanitizer().sanitize(CannedSite.filteredLine)
        #expect(line == "<p>Found about 12,345 results. Filtered 11 galleries from this page.</p>")
    }

    @Test func forumSessionKeysAreMasked() {
        let key = "0123456789abcdef0123456789ABCDEF"
        let text = """
        <a href="https://forums.e-hentai.org/index.php?s=\(key)&amp;act=Login&amp;CODE=03&amp;k=\(key)">Log out</a>
        <form action="index.php?act=x&auth_key=\(key)"><input name="md5check" value="1"></form> ?md5check=\(key)
        """
        let result = sanitizer().sanitize(text)
        // The value is masked; the parameter names, "&" and "&amp;" stay.
        let masked = result == text.replacingOccurrences(of: key, with: "1111111111aaaaaa1111111111AAAAAA")
        #expect(masked)
        let clean = FixtureHygiene.structuralViolations(in: result, file: "t").isEmpty
        #expect(clean)
        let again = sanitizer().sanitize(result) == result
        #expect(again, "sanitizing masked text changes it")
    }

    // MARK: Known secrets

    @Test func memberIDInsideAvatarURLIsReplaced() {
        let result = sanitizer([KnownSecret(kind: .numeric, value: "1234567")]).sanitize("av-1234567.jpg?showuser=1234567")
        let replaced = result == "av-1111111.jpg?showuser=1111111"
        #expect(replaced)
    }

    @Test func memberIDAdjacentToDigitsIsKept() {
        let text = "/g/11234567/abcdef0123/"
        let kept = sanitizer([KnownSecret(kind: .numeric, value: "1234567")]).sanitize(text) == text
        #expect(kept)
    }

    @Test func usernameReplacedOnlyAsWholeWord() {
        let result = sanitizer([KnownSecret(kind: .word, value: "ann")]).sanitize("Posted by ann, announce")
        let replaced = result == "Posted by aaa, announce"
        #expect(replaced)
    }

    @Test func redactsEncodedVariants() {
        let secret = KnownSecret(kind: .literal, value: "A&B Fan")
        let forms = ["A&B Fan", "A&amp;B Fan", "A%26B%20Fan", "A%26B+Fan"]
        let result = sanitizer([secret]).sanitize(forms.joined(separator: "\n"))
        let leaked = forms.contains { result.contains($0) }
        #expect(leaked == false, "an encoded form of the secret survived")
        let clean = isClean(result, secrets: [secret])
        #expect(clean, "sanitized text fails the hygiene check")
        // Each form is replaced by the same encoding of the mask.
        let paired = result == "A&A Aaa\nA&amp;A Aaa\nA%26A%20Aaa\nA%26A+Aaa"
        #expect(paired)
    }

    @Test func htmlEscapedSecretStaysAValidEntity() {
        let result = sanitizer([KnownSecret(kind: .literal, value: "A&B Fan")]).sanitize("<p>A&amp;B Fan</p>")
        let valid = result == "<p>A&amp;A Aaa</p>"
        #expect(valid, "the HTML form must map to an HTML-escaped mask")
    }

    @Test func jsonEscapedSecretStaysValidJSON() {
        let secret = KnownSecret(kind: .literal, value: "春太 Fan")
        let json = "{\"title\":\"" + backslash + "u6625" + backslash + "u592a Fan\",\"n\":1}"
        // The input really holds JSON escapes, and the check finds the secret in it.
        let isEscaped = json.contains(backslash + "u6625") && !json.contains("春")
        #expect(isEscaped)
        let flaggedBefore = !FixtureHygiene.secretViolations(in: json, file: "t.json", secrets: [secret]).isEmpty
        #expect(flaggedBefore)

        let result = sanitizer([secret]).sanitize(json)
        let object = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any]
        let parses = object != nil
        #expect(parses, "sanitized JSON no longer parses")
        let titleMasked = (object?["title"] as? String) == "aa Aaa"
        #expect(titleMasked)
        let leaked = containsAny(of: FixtureHygiene.encodedForms(of: secret.value), in: result)
        #expect(leaked == false, "an encoded form of the secret survived")
        let clean = isClean(result, file: "t.json", secrets: [secret])
        #expect(clean, "sanitized JSON fails the hygiene check")
    }

    @Test func newEncodedFormsAreMasked() throws {
        let quoted = KnownSecret(kind: .literal, value: "A&B \"Fan\"")
        let slashed = KnownSecret(kind: .literal, value: "a/b ü")
        let sanitizer = sanitizer([quoted, slashed])
        // Decimal and hex character references: each becomes the same spelling of the mask, so the markup stays.
        let decimal = sanitizer.sanitize(#"<p title="A&#38;B &#34;Fan&#34;">x</p>"#) == #"<p title="A&#38;A &#34;Aaa&#34;">x</p>"#
        #expect(decimal)
        let hex = sanitizer.sanitize(#"<p title="A&#x26;B &#x22;Fan&#x22;">x</p>"#) == #"<p title="A&#x26;A &#x22;Aaa&#x22;">x</p>"#
        #expect(hex)
        // JSON without escaped slashes: still valid JSON with the masked value.
        let json = "{\"t\":\"a/b " + backslash + "u00fc\",\"n\":1}"
        let result = sanitizer.sanitize(json)
        let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        let parses = (object?["t"] as? String) == "a/a a" && (object?["n"] as? Int) == 1
        #expect(parses, "sanitized JSON no longer parses or lost its value")
        let clean = isClean(result, file: "t.json", secrets: [quoted, slashed])
        #expect(clean, "sanitized JSON fails the hygiene check")
    }

    @Test func replacementIgnoresCase() {
        let secret = KnownSecret(kind: .word, value: "Sora")
        let result = sanitizer([secret]).sanitize("SORA met sora and Sorano")
        let replaced = result == "Aaaa met Aaaa and Sorano"
        #expect(replaced)
        let clean = isClean(result, secrets: [secret])
        #expect(clean, "sanitized text fails the hygiene check")
    }

    // MARK: Favorite notes

    @Test func favnotesAreReplaced() {
        let sanitizer = sanitizer()
        let textarea = sanitizer.sanitize(#"<textarea name="favnote" rows="4">my note</textarea>"#)
            == #"<textarea name="favnote" rows="4">[favnote]</textarea>"#
        #expect(textarea)
        let multiline = sanitizer.sanitize("<textarea name=\"favnote\">first line\nsecond line</textarea>")
            == #"<textarea name="favnote">[favnote]</textarea>"#
        #expect(multiline)
        let glfnote = sanitizer.sanitize(#"<div class="glfnote">Note: my note</div>"#)
            == #"<div class="glfnote">Note: [favnote]</div>"#
        #expect(glfnote)
        let comment = #"<textarea name="commenttext_new"></textarea>"#
        let commentKept = sanitizer.sanitize(comment) == comment
        #expect(commentKept)
    }

    @Test func emptyNotesAreKept() {
        let sanitizer = sanitizer()
        let texts = [
            #"<div class="glfnote"></div>"#,
            "<div class=\"glfnote\"> \n\t</div>",
            #"<textarea name="favnote" rows="4"></textarea>"#,
            "<textarea name=\"favnote\">\n  </textarea>",
        ]
        for (index, text) in texts.enumerated() {
            let kept = sanitizer.sanitize(text) == text
            #expect(kept, "empty note \(index) was rewritten")
        }
    }

    @Test func noteWithEntityKeepsMarkupValid() {
        // The page HTML-escapes the note; only its unescaped value is a secret, so the entity survives as "&amp;".
        let page = #"<textarea name="favnote">Tom &amp; Jerry</textarea><p title="Tom &amp; Jerry">x</p>"#
        var secrets = SecretSet(credentialSecrets: [], extraSecrets: [])
        secrets.discover(in: page)
        let onlyUnescaped = secrets.all == [KnownSecret(kind: .literal, value: "Tom & Jerry")]
        #expect(onlyUnescaped)
        let result = Sanitizer(secrets: secrets).sanitize(page)
        let valid = result == #"<textarea name="favnote">[favnote]</textarea><p title="Aaa &amp; Aaaaa">x</p>"#
        #expect(valid)
        let brokenEntity = result.contains("&aaa;")
        #expect(brokenEntity == false)
    }

    @Test func noteWithNumericEntitiesIsUnescapedOnce() {
        // `&#38;` and `&#x26;` are "&" as `&amp;` is, and decoding happens once: `&amp;#38;` is "&#38;", not "&".
        let page = #"<textarea name="favnote">Tom &#38; &#34;Jerry&#34;</textarea><p title="Tom &amp; &quot;Jerry&quot;">x</p>"#
        var secrets = SecretSet(credentialSecrets: [], extraSecrets: [])
        secrets.discover(in: page)
        let onlyUnescaped = secrets.all == [KnownSecret(kind: .literal, value: "Tom & \"Jerry\"")]
        #expect(onlyUnescaped)
        let result = Sanitizer(secrets: secrets).sanitize(page)
        let valid = result == #"<textarea name="favnote">[favnote]</textarea><p title="Aaa &amp; &quot;Aaaaa&quot;">x</p>"#
        #expect(valid)
        let once = htmlUnescaped("&amp;#38; &#38;amp; &#x26;lt;") == "&#38; &amp; &lt;"
        #expect(once)
    }

    @Test func multilineNotesRoundTripThroughTheSecretsFile() {
        let page = "<textarea name=\"favnote\">first line here\n  second\tline here  \nok</textarea>"
        var secrets = SecretSet(credentialSecrets: [], extraSecrets: [])
        secrets.discover(in: page)
        let whole = KnownSecret(kind: .literal, value: "first line here\n  second\tline here  \nok")
        let pieces: Set<KnownSecret> = [
            KnownSecret(kind: .literal, value: "first line here"),
            KnownSecret(kind: .literal, value: "second"),
            KnownSecret(kind: .literal, value: "line here"),
        ]
        let searched = secrets.all.contains(whole) && pieces.isSubset(of: secrets.all)
        #expect(searched)
        let rendered = FixtureHygiene.renderSecretsFile(secrets.persistable.sorted { $0.value < $1.value })
        let parsed = Set(FixtureHygiene.parseSecretsFile(rendered))
        // Every line comes back on its own, and nothing comes back cut short.
        let roundTrips = parsed == pieces
        #expect(roundTrips)
        // "ok" is too short to search for on its own; the warning says so without the value.
        #expect(secrets.warnings.count == 1)
        let leaked = secrets.warnings.contains { $0.contains("ok") }
        #expect(leaked == false)
    }

    // MARK: IPv4

    @Test func ipv4MappedConsistently() {
        var secrets = SecretSet(credentialSecrets: [], extraSecrets: [])
        secrets.discover(in: "client 10.1.2.3 via 203.0.113.9")
        secrets.discover(in: "dns 8.8.8.8, client 10.1.2.3")
        let order = secrets.ipv4InOrder == ["10.1.2.3", "8.8.8.8"]
        #expect(order)
        let sanitizer = Sanitizer(secrets: secrets)
        let first = sanitizer.sanitize("client 10.1.2.3 via 203.0.113.9") == "client 203.0.113.1 via 203.0.113.9"
        let second = sanitizer.sanitize("dns 8.8.8.8, client 10.1.2.3.") == "dns 203.0.113.2, client 203.0.113.1."
        #expect(first)
        #expect(second)
    }

    @Test func maskedSecretsLeaveNoForeignIPv4() {
        // Masking "node-10.0.0.5" yields "11.1.1.1", a new foreign address; it gets the next stand-in.
        let secret = KnownSecret(kind: .literal, value: "node-10.0.0.5")
        var secrets = SecretSet(credentialSecrets: [], extraSecrets: [secret])
        let text = "host node-10.0.0.5 and 8.8.8.8"
        secrets.discover(in: text)
        let sanitizer = Sanitizer(secrets: secrets)
        let result = sanitizer.sanitize(text)
        let clean = isClean(result, secrets: secrets.all)
        #expect(clean, "sanitized text fails the hygiene check")
        let mapped = result == "host aaaa-203.0.113.3 and 203.0.113.2"
        #expect(mapped)
        // The same leftover gets the same stand-in in another text.
        let again = sanitizer.sanitize("[node-10.0.0.5]") == "[aaaa-203.0.113.3]"
        #expect(again)
        let warned = secrets.warnings.contains { $0.contains("dotted quad") }
        #expect(warned)
        let leaked = secrets.warnings.contains { $0.contains("10.0.0.5") }
        #expect(leaked == false)
    }

    @Test func cfClearanceWithDottedQuadLeavesNoForeignIPv4() throws {
        let clearance = "x-1.0.1.1-y"
        let page = "<script>document.cookie=\"cf_clearance=\(clearance); path=/\";</script>\n{\"token\":\"\(clearance)\"}"
        let result = try sanitizeCaptures(
            [raw(body: page)],
            credentials: credentials(["EH_CF_CLEARANCE": clearance, "EH_USER_AGENT": "TestAgent/1.0"]),
            extraSecrets: []
        )
        try #require(result.captures.count == 1)
        let body = String(decoding: result.captures[0].body, as: UTF8.self)
        let noForeignIPv4 = FixtureHygiene.violatingCaptures(ofRule: FixtureHygiene.ipv4Rule, in: body).isEmpty
        #expect(noForeignIPv4)
        let clean = isClean(body, secrets: result.secrets.all)
        #expect(clean, "sanitized body fails the hygiene check")
        let warned = result.secrets.warnings.contains { $0.contains("EH_CF_CLEARANCE") && $0.contains("dotted quad") }
        #expect(warned)
        let leaked = result.secrets.warnings.contains { $0.contains(clearance) }
        #expect(leaked == false)
    }

    // MARK: Discovery

    @Test func discoverFindsApikeyUsernameAndNotes() {
        let page = """
        <script>var apiuid = 1234567;
        var apikey = "\(fakeApikey)";</script>
        <div id="profilename">Zq&amp;User</div>
        <textarea name="favnote" rows="4">  my secret note  </textarea>
        <div class="glfnote">Note: another fav note</div>
        """
        let memberID = KnownSecret(kind: .numeric, value: "1234567")
        let passHash = KnownSecret(kind: .literal, value: fakePassHash)
        let extra = KnownSecret(kind: .literal, value: "zqextra0123")
        let username = KnownSecret(kind: .word, value: "FakeLoginName")
        var secrets = SecretSet(
            namedCredentials: [
                (name: "EH_IPB_MEMBER_ID", secret: memberID), (name: "EH_IPB_PASS_HASH", secret: passHash),
                (name: "EH_USERNAME", secret: username),
            ],
            extraSecrets: [extra]
        )
        secrets.discover(in: page)

        let discovered: Set<KnownSecret> = [
            KnownSecret(kind: .literal, value: fakeApikey),
            KnownSecret(kind: .word, value: "Zq&User"),
            KnownSecret(kind: .literal, value: "my secret note"),
            KnownSecret(kind: .literal, value: "another fav note"),
        ]
        let allFound = discovered.union([memberID, passHash, extra]).isSubset(of: secrets.all)
        #expect(allFound)
        let persisted = discovered.union([extra]).isSubset(of: secrets.persistable)
        #expect(persisted)
        // The member id and username are kept (the apiuid is the member id, so it adds nothing); the token is not.
        let identityKept = [memberID, username].allSatisfy { secrets.persistable.contains($0) }
        #expect(identityKept)
        let noToken = secrets.persistable.allSatisfy { $0.value != passHash.value }
        #expect(noToken)
        #expect(secrets.warnings.isEmpty)
    }

    @Test func discoveryIgnoresCase() {
        let page = #"<SCRIPT>var apikey = "0F1E2D3C4B5A69";</SCRIPT><DIV ID="ProfileName">ZqUser</DIV>"#
        var secrets = SecretSet(credentialSecrets: [], extraSecrets: [])
        secrets.discover(in: page)
        let found = secrets.all.isSuperset(of: [
            KnownSecret(kind: .literal, value: "0F1E2D3C4B5A69"), KnownSecret(kind: .word, value: "ZqUser"),
        ])
        #expect(found)
        // The replacement is the mask of the discovered value, whatever the case of the occurrence.
        let replaced = Sanitizer(secrets: secrets).sanitize("token=0f1e2d3c4b5a69 by zquser") == "token=1A1A1A1A1A1A11 by AaAaaa"
        #expect(replaced)
    }

    @Test func shortSecretsWarnWithoutValue() {
        var secrets = SecretSet(credentialSecrets: [], extraSecrets: [KnownSecret(kind: .literal, value: "zq9")])
        secrets.discover(in: #"<textarea name="favnote">abc</textarea>"#)
        let noteAdded = secrets.all.contains(KnownSecret(kind: .literal, value: "abc"))
        #expect(noteAdded == false)
        #expect(secrets.warnings.count == 2)
        let leaked = secrets.warnings.contains { $0.contains("abc") || $0.contains("zq9") }
        #expect(leaked == false, "a warning repeats a secret")
        // The short note is still redacted where it stands.
        let redacted = Sanitizer(secrets: secrets).sanitize(#"<textarea name="favnote">abc</textarea>"#)
            == #"<textarea name="favnote">[favnote]</textarea>"#
        #expect(redacted)
    }

    @Test func shortCredentialWarningNamesTheVariable() throws {
        let result = try sanitizeCaptures([], credentials: credentials(["EH_SK": "zq9"]), extraSecrets: [])
        let named = result.secrets.warnings.contains { $0.contains("EH_SK") }
        #expect(named)
        let leaked = result.secrets.warnings.contains { $0.contains("zq9") }
        #expect(leaked == false, "a warning repeats a credential")
    }

    // MARK: sanitizeCaptures

    @Test func manifestURLsAreSanitized() throws {
        let capture = raw(
            "eh/forums/profile.html",
            url: "https://forums.e-hentai.org/index.php?showuser=1234567",
            status: 302,
            headers: [
                "Content-Type": "text/html; charset=UTF-8",
                "location": "https://forums.e-hentai.org/index.php?act=members&name=ZqUser",
                "Set-Cookie": "sk=zz9x; path=/; domain=.e-hentai.org, "
                    + "ipb_session_id=abcd; expires=Wed, 21 Oct 2026 07:28:00 GMT; path=/\nsk=zz9y; path=/",
            ],
            body: "<p>moved</p>"
        )
        let result = try sanitizeCaptures([capture], credentials: credentials(["EH_USERNAME": "ZqUser"]), extraSecrets: [])
        try #require(result.captures.count == 1)
        let entry = result.captures[0].entry
        let urlMasked = entry.url == "https://forums.e-hentai.org/index.php?showuser=1111111"
        #expect(urlMasked)
        let locationClean = entry.location.map { !containsAny(of: ["ZqUser"], in: $0) } ?? false
        #expect(locationClean)
        #expect(entry.path == "eh/forums/profile.html")
        #expect(entry.site == .eh)
        #expect(entry.source == .captured)
        #expect(entry.method == "GET")
        #expect(entry.status == 302)
        #expect(entry.contentType == "text/html; charset=UTF-8")
        #expect(entry.setCookieNames == ["ipb_session_id", "sk"])
        #expect(entry.capturedAt == "2026-11-04T00:00:00Z")
    }

    @Test func sanitizedPagePassesHygiene() throws {
        let jsonUser = backslash + "u3010Zq&User" + backslash + "u3011"
        let page = """
        <html><head><script>var apiuid = 1234567;
        var apikey = "\(fakeApikey)";</script></head>
        <body><div id="profilename">Zq&amp;User</div>
        <a href="https://forums.e-hentai.org/index.php?showuser=1234567">Zq&amp;User</a>
        <img src="https://forums.e-hentai.org/uploads/av-1234567.jpg">
        <textarea name="favnote" rows="4">my secret note</textarea>
        <div class="glfnote">Note: my secret note</div>
        <p>Your IP is 8.8.8.8. Image from http://10.20.30.40:8080/h/abc</p>
        <script>document.cookie = "ipb_pass_hash=\(fakePassHash); path=/";</script>
        <a href="?f_search=uploader%3AZq%26User">more</a> {"by":"\(jsonUser)","note":"my secret note"}
        </body></html>
        """
        let result = try sanitizeCaptures(
            [raw(url: "https://e-hentai.org/?u=1234567&ip=8.8.8.8", body: page)],
            credentials: credentials(),
            extraSecrets: []
        )
        try #require(result.captures.count == 1)
        let body = String(decoding: result.captures[0].body, as: UTF8.self)
        let url = result.captures[0].entry.url ?? ""
        let bodyClean = isClean(body, secrets: result.secrets.all)
        #expect(bodyClean, "sanitized body fails the hygiene check")
        let urlClean = isClean(url, secrets: result.secrets.all)
        #expect(urlClean, "sanitized URL fails the hygiene check")
        let mapped = body.contains("Your IP is 203.0.113.1.") && body.contains("http://203.0.113.2:8080/h/abc")
        #expect(mapped)

        // Independent of discovery: every fake value planted above, in every spelling used, is gone.
        let planted = [
            fakeApikey, fakePassHash, "1234567", "Zq&User", "Zq&amp;User", "Zq%26User", "my secret note",
            "8.8.8.8", "10.20.30.40",
        ]
        let leaked = containsAny(of: planted, in: body) || containsAny(of: planted, in: url)
        #expect(leaked == false, "a planted fake value survived sanitizing")
    }

    @Test func rejectsBodiesThatAreNotUTF8() throws {
        let capture = RawCapture(
            fixturePath: "eh/bad.bin", site: .eh, method: "GET", url: URL(string: "https://e-hentai.org/")!,
            status: 200, headers: [:], body: Data([0x3C, 0xFF, 0xFE, 0x3E]), capturedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(throws: SanitizeError.notUTF8("eh/bad.bin")) {
            try sanitizeCaptures([capture], credentials: credentials(), extraSecrets: [])
        }
    }

    @Test func rejectsMoreThan254Addresses() throws {
        let addresses = (0...254).map { "10.0.1.\($0)" }
        #expect(throws: SanitizeError.tooManyIPAddresses) {
            try sanitizeCaptures([raw(body: addresses.joined(separator: " "))], credentials: credentials(), extraSecrets: [])
        }
        let fits = try sanitizeCaptures(
            [raw(body: addresses.dropLast().joined(separator: " "))], credentials: credentials(), extraSecrets: []
        )
        let last = String(decoding: fits.captures[0].body, as: UTF8.self).hasSuffix("203.0.113.254")
        #expect(last)
    }

    @Test func leftoverAddressesCountTowardTheLimit() throws {
        // "300.400.500.600" is no address, so nothing is discovered in the secret; masked, it becomes the foreign
        // "111.111.111.111". With 254 discovered addresses the range is used up and it cannot get a stand-in.
        let secret = KnownSecret(kind: .literal, value: "v-300.400.500.600")
        let leftover = " {\"t\":\"v-300.400.500.600\"}"
        let full = (1...254).map { "10.0.2.\($0)" }.joined(separator: " ")
        #expect(throws: SanitizeError.tooManyIPAddresses) {
            try sanitizeCaptures([raw(body: full + leftover)], credentials: credentials(), extraSecrets: [secret])
        }
        // One address fewer leaves room for it.
        let roomy = (1...253).map { "10.0.2.\($0)" }.joined(separator: " ")
        let fits = try sanitizeCaptures([raw(body: roomy + leftover)], credentials: credentials(), extraSecrets: [secret])
        let body = String(decoding: fits.captures[0].body, as: UTF8.self)
        let standIn = body.hasSuffix(" {\"t\":\"a-203.0.113.254\"}")
        #expect(standIn)
        let clean = isClean(body, secrets: fits.secrets.all)
        #expect(clean, "sanitized body fails the hygiene check")
    }

    // MARK: Renderings

    @Test func rawCaptureDescriptionsAreRedacted() {
        let capture = raw(
            url: "https://e-hentai.org/?showuser=1234567",
            headers: ["Set-Cookie": "ipb_pass_hash=\(fakePassHash)"],
            body: "var apikey = \"\(fakeApikey)\";"
        )
        var dumped = ""
        dump(capture, to: &dumped)
        for rendering in [String(describing: capture), String(reflecting: capture), dumped] {
            let leaked = containsAny(of: ["1234567", fakePassHash, fakeApikey], in: rendering)
            #expect(leaked == false, "a raw capture rendering shows a secret")
        }
    }

    @Test func secretSetSanitizerAndResultDescriptionsAreRedacted() throws {
        let page = """
        <script>var apiuid = 1234567; var apikey = "\(fakeApikey)";</script>
        <div id="profilename">ZqPageUser</div>
        <textarea name="favnote">my secret note</textarea>
        <p>8.8.8.8 and 10.20.30.40</p>
        """
        let result = try sanitizeCaptures(
            [raw(url: "https://e-hentai.org/?u=1234567", body: page)],
            credentials: credentials(["EH_USERNAME": "ZqUser", "EH_SK": "fakesk0123"]),
            extraSecrets: [KnownSecret(kind: .literal, value: "zqextra0123")]
        )
        let sanitizer = Sanitizer(secrets: result.secrets)
        _ = sanitizer.sanitize("leftover node-10.0.0.5")
        let fakeValues = [
            fakeApikey, fakePassHash, "1234567", "ZqUser", "ZqPageUser", "fakesk0123", "zqextra0123", "my secret note",
            "8.8.8.8", "10.20.30.40",
        ]
        let subjects: [(String, Any)] = [
            ("SecretSet", result.secrets),
            ("Sanitizer", sanitizer),
            ("SanitizedCapture", result.captures[0]),
            ("sanitizeCaptures result", result),
        ]
        for (label, subject) in subjects {
            var dumped = ""
            dump(subject, to: &dumped)
            for rendering in [String(describing: subject), String(reflecting: subject), dumped] {
                let leaked = containsAny(of: fakeValues, in: rendering)
                #expect(leaked == false, "a \(label) rendering shows a fake value")
            }
        }
    }
}
