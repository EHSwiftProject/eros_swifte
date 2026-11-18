import EHFixtures
import EHModels
import FixtureCaptureCore
import Foundation
import Testing

// Fake values only; expectations compare Booleans, paths and counts.

/// A fixture root in a unique temporary directory, with a secrets file next to it.
private struct ResanitizeWorkspace {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "eros-resanitize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var root: URL { url.appending(path: "Fixtures") }
    var secretsFile: URL { url.appending(path: "fixture-secrets.local") }

    func write(_ path: String, _ text: String) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    func bytes(_ path: String) throws -> Data {
        try Data(contentsOf: root.appending(path: path))
    }

    func manifest(_ entries: [FixtureEntry], at path: String = "manifest.json") throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(path, String(decoding: try encoder.encode(FixtureManifest(entries: entries)), as: UTF8.self) + "\n")
    }

    func resanitize(constructed: Bool = false, environment: [String: String] = [:]) throws -> ResanitizeOutcome {
        try resanitizeFixtures(
            fixturesRoot: root, secretsFile: secretsFile, environment: environment, includeConstructed: constructed
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private func captured(_ path: String, _ site: EHSite = .eh, url: String = "https://e-hentai.org/") -> FixtureEntry {
    FixtureEntry(
        path: path, site: site, source: .captured, method: "GET", url: url, status: 200,
        contentType: "text/html; charset=UTF-8", capturedAt: "2026-11-04T14:37:00Z"
    )
}

/// A list page as an earlier, laxer run wrote it: tags colored.
private let laxList = "<html><body>\(CannedSite.resultLine)<table><tr><td>\(CannedSite.coloredTag)</td></tr></table></body></html>"
/// A list page captured with the account's filters on, its count unmasked.
private let filteredList = "<html><body>\(CannedSite.filteredLine)<table><tr><td>\(CannedSite.plainTag)</td></tr></table></body></html>"
private let laxArchiver = "<html><body>\(CannedSite.fundsParagraph)</body></html>"
private let cleanPage = "<html><body><p>Posted 2024-12-01, 5 pages.</p></body></html>"

@Suite struct ResanitizerTests {
    @Test func rewritesOnlyWhatChangesAndKeepsTheManifests() throws {
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        try workspace.write("eh/list/front.html", laxList)
        try workspace.write("eh/popup/archiver.html", laxArchiver)
        try workspace.write("eh/gallery/detail.html", cleanPage)
        try workspace.write("local/eh/list/favorites.html", laxList)
        try workspace.manifest([
            captured("eh/gallery/detail.html"), captured("eh/list/front.html"), captured("eh/popup/archiver.html"),
        ])
        try workspace.manifest([captured("local/eh/list/favorites.html")], at: PrivateFixtures.manifestPath)
        let manifestBefore = try workspace.bytes("manifest.json")
        let localManifestBefore = try workspace.bytes(PrivateFixtures.manifestPath)
        let untouchedBefore = try workspace.bytes("eh/gallery/detail.html")

        let outcome = try workspace.resanitize()
        #expect(outcome.checked == 4)
        #expect(outcome.changed == ["eh/list/front.html", "eh/popup/archiver.html", "local/eh/list/favorites.html"])
        // The fixed files pass the checks; the clean one and both manifests are byte for byte the same.
        for path in outcome.changed {
            let text = try workspace.read(path)
            let clean = FixtureHygiene.structuralViolations(in: text, file: path).isEmpty
            #expect(clean, "\(path) still fails the structural checks")
        }
        let front = try workspace.read("eh/list/front.html")
        let fixed = !front.contains("radial-gradient") && front.contains(CannedSite.plainTag)
        #expect(fixed)
        #expect(try workspace.bytes("eh/gallery/detail.html") == untouchedBefore)
        #expect(try workspace.bytes("manifest.json") == manifestBefore)
        #expect(try workspace.bytes(PrivateFixtures.manifestPath) == localManifestBefore)
    }

    @Test func runningItAgainChangesNothing() throws {
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        try workspace.write("eh/list/front.html", laxList)
        try workspace.write("eh/popup/archiver.html", laxArchiver)
        try workspace.manifest([captured("eh/list/front.html"), captured("eh/popup/archiver.html")])
        _ = try workspace.resanitize()
        let afterFirst = try [workspace.bytes("eh/list/front.html"), workspace.bytes("eh/popup/archiver.html")]
        let second = try workspace.resanitize()
        #expect(second.changed.isEmpty)
        #expect(try [workspace.bytes("eh/list/front.html"), workspace.bytes("eh/popup/archiver.html")] == afterFirst)
    }

    @Test func resanitizeWithCredentialsAddsIdentity() throws {
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        try workspace.write("eh/page.html", cleanPage)
        try workspace.manifest([captured("eh/page.html")])
        let extra = KnownSecret(kind: .literal, value: "zqextra0123")
        try Data(FixtureHygiene.renderSecretsFile([extra]).utf8).write(to: workspace.secretsFile)
        let pageBefore = try workspace.bytes("eh/page.html")

        let outcome = try workspace.resanitize(environment: CaptureFakes.environment(sites: [.eh]))
        #expect(outcome.changed.isEmpty)
        #expect(try workspace.bytes("eh/page.html") == pageBefore)
        let kept = FixtureHygiene.parseSecretsFile(try String(contentsOf: workspace.secretsFile, encoding: .utf8))
        // The two identity lines are new; the token is not kept.
        #expect(Set(kept) == [
            extra, KnownSecret(kind: .numeric, value: CaptureFakes.memberID),
            KnownSecret(kind: .word, value: CaptureFakes.username),
        ])
        #expect(kept.count == 3)
    }

    @Test func aFreshCaptureIsAlreadyFinal() async throws {
        // Fixtures the capture tool writes are a fixed point: resanitizing them changes nothing.
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        let config = CaptureSessionConfig(
            sites: [.eh], environment: CaptureFakes.environment(sites: [.eh]), targets: CaptureFakes.targets(),
            fixturesRoot: workspace.root, secretsFile: workspace.secretsFile
        )
        let site = CannedSite(favoritesNote: "zq note seen on a private list")
        _ = try await runCaptureSession(config, transport: StubTransport { request, _ in site.respond(request) })
        let secretsBefore = try Data(contentsOf: workspace.secretsFile)
        let outcome = try workspace.resanitize(environment: CaptureFakes.environment(sites: [.eh]))
        #expect(outcome.checked == 37)
        #expect(outcome.changed.isEmpty)
        #expect(try Data(contentsOf: workspace.secretsFile) == secretsBefore)
    }

    @Test func constructedOnlyWhenAsked() throws {
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        try workspace.write("constructed/eh/list-non-compact.html", laxList)
        try workspace.manifest([FixtureEntry(
            path: "constructed/eh/list-non-compact.html", site: .eh, source: .constructed,
            derivedFrom: "eh/list/front.html", note: "fake"
        )])
        // Without --constructed it is left alone, even though it would fail the checks.
        #expect(try workspace.resanitize().changed.isEmpty)
        #expect(try workspace.read("constructed/eh/list-non-compact.html") == laxList)
        #expect(try workspace.resanitize(constructed: true).changed == ["constructed/eh/list-non-compact.html"])
    }

    private func constructedEntry(_ path: String, note: String = "fake") -> FixtureEntry {
        FixtureEntry(path: path, site: .eh, source: .constructed, derivedFrom: "eh/list/front.html", note: note)
    }

    private var profileDiv: String { #"<html><body><div id="profilename">Fake Nickname</div></body></html>"# }

    @Test func constructedExemptTagStyleSurvives() throws {
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        let page = "<html><body>\(CannedSite.coloredTag)</body></html>"
        try workspace.write("constructed/eh/account-mytags.html", page)
        try workspace.manifest([constructedEntry("constructed/eh/account-mytags.html")])
        let outcome = try workspace.resanitize(constructed: true)
        #expect(outcome.changed.isEmpty)
        let kept = try workspace.read("constructed/eh/account-mytags.html") == page
        #expect(kept)
    }

    @Test func capturedTagStyleIsStillStripped() throws {
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        try workspace.write("eh/account/mytags.html", "<html><body>\(CannedSite.coloredTag)</body></html>")
        try workspace.manifest([captured("eh/account/mytags.html")])
        let outcome = try workspace.resanitize(constructed: true)
        #expect(outcome.changed == ["eh/account/mytags.html"])
        let stripped = try workspace.read("eh/account/mytags.html") == "<html><body>\(CannedSite.plainTag)</body></html>"
        #expect(stripped)
    }

    @Test func constructedProfileNameIsNotDiscovered() throws {
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        try workspace.write("constructed/eh/forum-profile.html", profileDiv)
        try workspace.manifest([constructedEntry("constructed/eh/forum-profile.html", note: "Fake Nickname is made up")])
        let manifestBefore = try workspace.bytes("manifest.json")
        let outcome = try workspace.resanitize(constructed: true)
        #expect(outcome.changed.isEmpty)
        let untouched = try workspace.bytes("manifest.json") == manifestBefore
        #expect(untouched)
        let fileExists = FileManager.default.fileExists(atPath: workspace.secretsFile.path(percentEncoded: false))
        let leaked = fileExists && ((try? String(contentsOf: workspace.secretsFile, encoding: .utf8))?.contains("Fake Nickname") ?? false)
        #expect(!leaked)
    }

    @Test func capturedProfileNameIsStillDiscovered() throws {
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        try workspace.write("local/eh/forum/profile.html", profileDiv)
        try workspace.manifest([captured("local/eh/forum/profile.html")], at: PrivateFixtures.manifestPath)
        try workspace.manifest([])
        let outcome = try workspace.resanitize(constructed: true)
        #expect(outcome.changed == ["local/eh/forum/profile.html"])
        let masked = !(try workspace.read("local/eh/forum/profile.html")).contains("Fake Nickname")
        #expect(masked)
        let persisted = try String(contentsOf: workspace.secretsFile, encoding: .utf8).contains("Fake Nickname")
        #expect(persisted)
    }

    @Test func filteredListsCannotBeFixedOffline() throws {
        // Masking the count would not bring back the hidden galleries: the page must be captured again.
        for path in ["eh/list/front.html", "local/eh/list/watched.html"] {
            let workspace = try ResanitizeWorkspace()
            defer { workspace.remove() }
            try workspace.write(path, filteredList)
            if path.hasPrefix("local/") {
                try workspace.manifest([])
                try workspace.manifest([captured(path)], at: PrivateFixtures.manifestPath)
            } else {
                try workspace.manifest([captured(path)])
            }
            let before = try workspace.bytes(path)
            #expect(throws: FixtureWriterError.hygiene([HygieneViolation(file: path, rule: "filteredlist", line: 1)])) {
                try workspace.resanitize()
            }
            #expect(try workspace.bytes(path) == before)
        }
    }

    @Test func constructedFixturesKeepTheirExemptions() throws {
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        func constructed(_ path: String) -> FixtureEntry {
            FixtureEntry(path: path, site: .eh, source: .constructed, derivedFrom: "eh/list/front.html", note: "fake")
        }
        // The one constructed list that stands for a filtered page may say so; its count is masked all the same.
        try workspace.write("constructed/eh/list-filtered.html", filteredList)
        try workspace.manifest([constructed("constructed/eh/list-filtered.html")])
        #expect(try workspace.resanitize(constructed: true).changed == ["constructed/eh/list-filtered.html"])
        let masked = try workspace.read("constructed/eh/list-filtered.html").contains("Filtered 11 galleries from this page")
        #expect(masked)
        // Any other constructed fixture may not.
        try workspace.write("constructed/eh/list-non-compact.html", filteredList)
        try workspace.manifest([
            constructed("constructed/eh/list-filtered.html"), constructed("constructed/eh/list-non-compact.html"),
        ])
        #expect(throws: FixtureWriterError.hygiene([
            HygieneViolation(file: "constructed/eh/list-non-compact.html", rule: "filteredlist", line: 1),
        ])) {
            try workspace.resanitize(constructed: true)
        }
    }

    @Test func urlsAreSanitizedTooAndEntriesKeepTheRest() throws {
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        // A value added to the secrets file after the capture, found in an entry's URL.
        try "literal\tzqlatersecret9\n".write(to: workspace.secretsFile, atomically: true, encoding: .utf8)
        try workspace.write("eh/list/search.html", cleanPage)
        try workspace.manifest([captured("eh/list/search.html", url: "https://e-hentai.org/?f_search=zqlatersecret9")])
        let outcome = try workspace.resanitize()
        #expect(outcome.changed == ["eh/list/search.html"])
        let entries = try JSONDecoder().decode(FixtureManifest.self, from: workspace.bytes("manifest.json")).entries
        let entry = try #require(entries.first)
        #expect(entry.url == "https://e-hentai.org/?f_search=aaaaaaaaaaaaa1")
        #expect(entry.capturedAt == "2026-11-04T14:37:00Z")
        #expect(entry.status == 200 && entry.method == "GET")
        #expect(try workspace.read("eh/list/search.html") == cleanPage)
    }

    @Test func refusesWhenTheResultStillFailsAndWritesNothing() throws {
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        // A known value whose mask is itself cannot be hidden: the check still finds it after sanitizing.
        try "literal\taaaa-aaaa\n".write(to: workspace.secretsFile, atomically: true, encoding: .utf8)
        try workspace.write("eh/list/front.html", laxList + "<p>aaaa-aaaa</p>")
        try workspace.manifest([captured("eh/list/front.html")])
        let before = try workspace.bytes("eh/list/front.html")
        #expect(throws: FixtureWriterError.hygiene([HygieneViolation(file: "eh/list/front.html", rule: "secret:literal", line: 1)])) {
            try workspace.resanitize()
        }
        #expect(try workspace.bytes("eh/list/front.html") == before)
    }

    /// A name that joined the identity after the capture (a second account's username) was never masked: a public
    /// page that shows it as an uploader is refused, and nothing is written.
    @Test func newIdentityShownAsUploaderIsRefused() throws {
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        let link = #"<a href="https://e-hentai.org/uploader/\#(CaptureFakes.secondUsername)">\#(CaptureFakes.secondUsername)</a>"#
        try workspace.write("eh/list/front.html", "<html><body>\(CannedSite.resultLine)<div>\(link)</div></body></html>")
        try workspace.manifest([captured("eh/list/front.html")])
        let pageBefore = try workspace.bytes("eh/list/front.html")
        let manifestBefore = try workspace.bytes("manifest.json")

        let error = #expect(throws: SanitizeError.self) {
            try workspace.resanitize(environment: ["EH_USERNAME": CaptureFakes.secondUsername])
        }
        #expect(error == .ownContent([HygieneViolation(file: "eh/list/front.html", rule: "ownupload", line: 1)]))
        #expect(try workspace.bytes("eh/list/front.html") == pageBefore)
        #expect(try workspace.bytes("manifest.json") == manifestBefore)
        #expect(!FileManager.default.fileExists(atPath: workspace.secretsFile.path(percentEncoded: false)))
        // The same page passes under the first account, whose name it does not show.
        #expect(try workspace.resanitize(environment: ["EH_USERNAME": CaptureFakes.username]).changed.isEmpty)
    }

    /// Private and constructed fixtures are not checked: the private ones show the account by design, and the
    /// constructed ones hold made-up names only.
    @Test func privateAndConstructedFixturesAreNotCheckedForTheIdentity() throws {
        let workspace = try ResanitizeWorkspace()
        defer { workspace.remove() }
        let link = #"<a href="https://e-hentai.org/uploader/\#(CaptureFakes.secondUsername)">x</a>"#
        let page = "<html><body>\(CannedSite.resultLine)<div>\(link)</div></body></html>"
        try workspace.write("local/eh/list/favorites.html", page)
        try workspace.write("constructed/eh/list-favorites.html", page)
        try workspace.manifest([constructedEntry("constructed/eh/list-favorites.html")])
        try workspace.manifest([captured("local/eh/list/favorites.html")], at: PrivateFixtures.manifestPath)
        let outcome = try workspace.resanitize(constructed: true, environment: ["EH_USERNAME": CaptureFakes.secondUsername])
        #expect(outcome.checked == 2)
    }

    @Test func refusesEntriesOutsideTheRootOrMissing() throws {
        for path in ["../outside.html", "eh/list/missing.html"] {
            let workspace = try ResanitizeWorkspace()
            defer { workspace.remove() }
            try workspace.manifest([captured(path)])
            #expect(throws: FixtureWriterError.invalidPath(path)) {
                try workspace.resanitize()
            }
        }
    }
}
