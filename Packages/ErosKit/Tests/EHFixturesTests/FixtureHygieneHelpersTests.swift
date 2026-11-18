import EHFixtures
import Foundation
import Testing

/// The helpers the capture tool uses to rewrite exactly what the hygiene checks flag. Expectations compare
/// Booleans, counts, form indices or rule names, never a runtime value holding a secret form.
@Suite struct FixtureHygieneHelpersTests {
    @Test func encodedFormsKeepPositionsAndDuplicates() {
        let ampersand = FixtureHygiene.encodedForms(of: "A&B Fan") == [
            "A&B Fan", "A&amp;B Fan", "A%26B%20Fan", "A%26B+Fan", "A&amp;B Fan", "A&amp;B Fan", "A&amp;B Fan", "A&B Fan",
            "A&#38;B Fan", "A&#x26;B Fan", "A&B Fan",
        ]
        #expect(ampersand)
        let apostrophe = FixtureHygiene.encodedForms(of: "O'Neil") == [
            "O'Neil", "O&#039;Neil", "O%27Neil", "O%27Neil", "O&#39;Neil", "O&#x27;Neil", "O&apos;Neil", "O'Neil",
            "O&#039;Neil", "O&#039;Neil", "O'Neil",
        ]
        #expect(apostrophe)
        #expect(FixtureHygiene.encodedForms(of: "").count == 11)
        for (index, value) in ["A&B Fan", "O'Neil", "<'\"é>", "😀", "abc"].enumerated() {
            let forms = FixtureHygiene.encodedForms(of: value)
            var seen = Set<String>()
            let deduplicated = FixtureHygiene.variants(of: value) == forms.filter { seen.insert($0).inserted }
            #expect(deduplicated, "value \(index)")
        }
    }

    @Test func minimumLiteralLengthIsFour() {
        #expect(FixtureHygiene.minimumLiteralLength == 4)
    }

    @Test func secretMatchesReportTheMatchedForm() {
        let secret = KnownSecret(kind: .literal, value: "A&B Fan")
        let text = "x A&amp;b fan y A%26B+Fan z a&b fan"
        let matches = FixtureHygiene.secretMatches(of: secret, in: text)
        #expect(matches.map(\.form) == [1, 3, 0])
        let matched = matches.map { String(text[$0.range]) } == ["A&amp;b fan", "A%26B+Fan", "a&b fan"]
        #expect(matched)
        // Exactly the occurrences the check reports.
        let reported = FixtureHygiene.secretViolations(in: text, file: "t", secrets: [secret]).count
        #expect(reported == matches.count)
    }

    @Test func secretMatchesUseTheCheckBoundaries() {
        let memberID = KnownSecret(kind: .numeric, value: "1234567")
        let numericText = "/g/11234567/ av-1234567.jpg %221234567%22"
        let numeric = FixtureHygiene.secretMatches(of: memberID, in: numericText)
        #expect(numeric.count == 2)
        let numericMatched = numeric.allSatisfy { numericText[$0.range] == "1234567" && $0.form == 0 }
        #expect(numericMatched)

        let username = KnownSecret(kind: .word, value: "Sora")
        #expect(FixtureHygiene.secretMatches(of: username, in: "Sorano SORA uploader%3ASora").count == 2)
        #expect(FixtureHygiene.secretMatches(of: KnownSecret(kind: .literal, value: "xyz"), in: "xyz").isEmpty)
        #expect(FixtureHygiene.secretMatches(of: KnownSecret(kind: .word, value: ""), in: "abc").isEmpty)
    }

    @Test func secretMatchesMapJSONFormsToTheirIndex() {
        let secret = KnownSecret(kind: .literal, value: "春太 Fan")
        let backslash = "\\"
        let text = "{\"t\":\"" + backslash + "u6625" + backslash + "u592A Fan\"}"
        let matches = FixtureHygiene.secretMatches(of: secret, in: text)
        #expect(matches.map(\.form) == [7])
    }

    @Test func structuralRuleNamesAreInCheckOrder() {
        #expect(FixtureHygiene.structuralRuleNames == [
            "apikey", "apiuid", "cookie", "ipv4", "favnote", "glfnote", "torrentkey", "torrentlink", "tracker", "homestats",
            "trackerurl", "announce", "tagstyle", "filtered", "funds", "filteredlist", "forumkey", "favmark", "accountmark",
        ])
        #expect(FixtureHygiene.structuralRuleNames == [
            FixtureHygiene.apikeyRule, FixtureHygiene.apiuidRule, FixtureHygiene.cookieRule, FixtureHygiene.ipv4Rule,
            FixtureHygiene.favnoteRule, FixtureHygiene.glfnoteRule, FixtureHygiene.torrentKeyRule,
            FixtureHygiene.torrentLinkRule, FixtureHygiene.trackerRule, FixtureHygiene.homeStatsRule,
            FixtureHygiene.trackerURLRule, FixtureHygiene.announceRule, FixtureHygiene.tagStyleRule,
            FixtureHygiene.filteredRule, FixtureHygiene.fundsRule, FixtureHygiene.filteredListRule,
            FixtureHygiene.forumKeyRule, FixtureHygiene.favoriteMarkRule, FixtureHygiene.accountMarkRule,
        ])
        // Violations report the same names.
        let reported = FixtureHygiene.structuralViolations(in: "var apiuid = 7654321;", file: "t").map(\.rule)
        #expect(reported == [FixtureHygiene.apiuidRule])
    }

    @Test func renderSecretsFileDropsValuesThatCannotReadBack() {
        let lineSeparator = String(Character(Unicode.Scalar(0x2028)!))
        let unrenderable = [
            KnownSecret(kind: .literal, value: "first line\nsecond line"),
            KnownSecret(kind: .literal, value: "carriage\rreturn"),
            KnownSecret(kind: .literal, value: "crlf line\r\nnext line"),
            KnownSecret(kind: .literal, value: "tab\tseparated"),
            KnownSecret(kind: .literal, value: "unicode" + lineSeparator + "separator"),
        ]
        let kept = [KnownSecret(kind: .literal, value: "single line"), KnownSecret(kind: .word, value: "Sora")]
        let rendered = FixtureHygiene.renderSecretsFile(unrenderable + kept)
        // KnownSecret descriptions are redacted, so comparing them is safe to print.
        #expect(FixtureHygiene.parseSecretsFile(rendered) == kept)
        let lineCount = rendered.split(whereSeparator: \.isNewline).count
        #expect(lineCount == 3 + kept.count, "header plus one line per kept secret")
    }

    @Test func violatingCapturesAreWhatTheCheckFlags() {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let text = """
        var apikey = "0f1e2d3c"; var apikey = "1a1a1a1a"; var apiuid = 7654321; var apiuid = 1111111;
        ipb_pass_hash=0123abcd sk=aa1a 8.8.8.8 203.0.113.5 1.2.3.400
        <textarea name="favnote">my note</textarea><textarea name="favnote"> </textarea>
        <div class="glfnote"></div><div class="glfnote">Note: [favnote]</div><div class="glfnote">Note: x</div>
        <p>Your current key is: <b>Zq9fakeKey</b></p><p>Your current key is: <b>Aa1aaaaAaa</b></p>
        http://ehtracker.org/3456789/announce http://ehtracker.org/1111111/announce
        https://ehtracker.org/get/3456789/zq1fake2seg3/7654321-zqfakekey1/\(hash).torrent
        https://ehtracker.org/get/1111111/aa1aaaa1aaa1/1111111-aaaaaaaaa1/\(hash).torrent
        <h2>Toplists</h2><div class="homebox"><td><strong>#4321</strong></td><td><strong>#1111</strong></td></div>
        """
        func captured(_ rule: String) -> [String] {
            FixtureHygiene.violatingCaptures(ofRule: rule, in: text).map { String(text[$0]) }
        }
        let expected: [String: [String]] = [
            "apikey": ["0f1e2d3c"], "apiuid": ["7654321"], "cookie": ["0123abcd"], "ipv4": ["8.8.8.8"],
            "favnote": ["my note"], "glfnote": ["Note: x"], "torrentkey": ["Zq9fakeKey"],
            "torrentlink": ["7654321", "zqfakekey1"], "tracker": ["3456789", "3456789", "zq1fake2seg3"], "homestats": ["4321"],
            "trackerurl": ["3456789", "3456789", "zq1fake2seg3", "7654321-zqfakekey1"], "announce": [], "tagstyle": [], "filtered": [],
            "funds": [], "filteredlist": [], "forumkey": [], "favmark": [], "accountmark": [],
        ]
        for rule in FixtureHygiene.structuralRuleNames {
            let matches = captured(rule) == expected[rule]
            #expect(matches, "captures for \(rule)")
        }
        // One violation per offending match: a match may judge several groups (the uid and key of one link, the
        // number and key segment of another), so it can return more captures than it reports violations.
        let flagged = FixtureHygiene.structuralViolations(in: text, file: "t").map(\.rule)
        // `trackerurl` judges each path segment of a match of its scope on its own, so it reports one per segment.
        #expect(flagged == [
            "apikey", "apiuid", "cookie", "ipv4", "favnote", "glfnote", "torrentkey", "torrentlink", "tracker", "tracker",
            "homestats", "trackerurl", "trackerurl", "trackerurl", "trackerurl",
        ])
        let lines = FixtureHygiene.structuralViolations(in: text, file: "t").map(\.line)
        #expect(lines == [1, 1, 2, 2, 3, 4, 5, 7, 6, 7, 9, 6, 7, 7, 7])
    }
}
