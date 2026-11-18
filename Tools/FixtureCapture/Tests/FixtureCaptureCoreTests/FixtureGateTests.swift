import EHFixtures
import FixtureCaptureCore
import Foundation
import Testing

// Fake values only; expectations compare rule names and counts.

private let fakeNumeric = "7391846"
private let fakeApikey = "0123456789abcdef0123"

@Suite struct FixtureGateTests {
    @Test func gateRunsStructuralSecretAndHomeChecks() {
        let texts = [
            GateText(file: "eh/list/a.html", text: "<p>x</p>\n<script>var apikey = \"\(fakeApikey)\";</script>"),
            GateText(file: "eh/list/b.html", text: "<p>id \(fakeNumeric)</p>"),
            GateText(file: "eh/account/home.html", text: "<h2>Stats</h2><div class=\"homebox\"><strong>4,321</strong></div>"),
        ]
        let rules = Set(FixtureGate.violations(in: texts, secrets: [KnownSecret(kind: .numeric, value: fakeNumeric)]).map(\.rule))
        #expect(rules.isSuperset(of: ["apikey", "secret:numeric", "homepage-number"]))
    }

    @Test func exemptionsApplyOnlyToConstructedTexts() {
        let page = "<p>Filtered 7 galleries</p>"
        let file = "constructed/eh/list-filtered.html"
        let constructed = FixtureGate.violations(in: [GateText(file: file, text: page, isConstructed: true)], secrets: [])
        let captured = FixtureGate.violations(in: [GateText(file: file, text: page, isConstructed: false)], secrets: [])
        #expect(constructed.filter { $0.rule == FixtureHygiene.filteredListRule }.isEmpty)
        #expect(captured.filter { $0.rule == FixtureHygiene.filteredListRule }.count == 1)
    }

    /// A private page under `local/` shows the account's favorites by design; anywhere else that is refused, except
    /// in a constructed fixture `FixtureHygiene.constructedExemptions` lists for `favmark`.
    @Test func favoriteMarksPassOnlyOnPrivatePages() {
        let row = #"<div id="posted_1" style="border-color:#000" title="Favorites 0">2026-01-01 00:00</div>"#
        let texts = [
            GateText(file: "local/eh/list/favorites.html", text: row),
            GateText(file: "eh/list/front.html", text: row),
            GateText(file: "constructed/eh/list-watched.html", text: row, isConstructed: true),
            GateText(file: "constructed/eh/list-favorites.html", text: row, isConstructed: true),
            // The exempt path, but not a constructed text.
            GateText(file: "constructed/eh/list-favorites.html", text: row),
        ]
        let flagged = FixtureGate.violations(in: texts, secrets: []).map { "\($0.file) \($0.rule)" }
        #expect(flagged == [
            "eh/list/front.html favmark", "constructed/eh/list-watched.html favmark",
            "constructed/eh/list-favorites.html favmark",
        ])
    }

    @Test func checkThrowsHygieneWithTheViolations() {
        let texts = [GateText(file: "eh/list/a.html", text: "<script>var apikey = \"\(fakeApikey)\";</script>")]
        let expected = FixtureGate.violations(in: texts, secrets: [])
        #expect(!expected.isEmpty)
        #expect(throws: FixtureWriterError.hygiene(expected)) { try FixtureGate.check(texts, secrets: []) }
        #expect(throws: Never.self) { try FixtureGate.check([GateText(file: "eh/list/ok.html", text: "<p>x</p>")], secrets: []) }
    }

    @Test func violationsNeverContainValues() {
        let texts = [GateText(file: "eh/list/b.html", text: "<p>id \(fakeNumeric)</p>\n<script>var apikey = \"\(fakeApikey)\";</script>")]
        let found = FixtureGate.violations(in: texts, secrets: [KnownSecret(kind: .numeric, value: fakeNumeric)])
        #expect(found.count >= 2)
        let printed = String(describing: found)
        #expect(!printed.contains(fakeNumeric))
        #expect(!printed.contains(fakeApikey))
    }
}
