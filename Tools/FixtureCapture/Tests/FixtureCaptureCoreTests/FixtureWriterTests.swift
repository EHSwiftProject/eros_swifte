import EHFixtures
import EHModels
import FixtureCaptureCore
import Foundation
import Testing

// Fake values only; assertions about file contents compare Booleans.
private let fakeApikey = "0f1e2d3c4b5a69"
private let fakePassHash = "f0e1d2c3b4a5968778695a4b3c2d1e0f"

/// A unique directory under the system temporary directory holding a fixture root and a secrets file.
private struct Workspace {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "eros-fixture-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var root: URL { url.appending(path: "Fixtures") }
    var manifest: URL { root.appending(path: "manifest.json") }
    var secretsFile: URL { url.appending(path: "fixture-secrets.local") }
    var writer: FixtureWriter { FixtureWriter(fixturesRoot: root, secretsFile: secretsFile) }

    /// Writes `entries` as the manifest and `files` (contents keyed by path relative to the root).
    func seed(entries: [FixtureEntry], files: [String: String]) throws {
        try JSONEncoder().encode(FixtureManifest(entries: entries)).write(to: manifest)
        for (path, contents) in files {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path(percentEncoded: false))
    }

    /// Every path under the workspace, files and directories, sorted.
    func listing() throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: url.path(percentEncoded: false)).sorted()
    }

    func entries() throws -> [FixtureEntry] {
        try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: manifest)).entries
    }

    var localManifest: URL { root.appending(path: PrivateFixtures.manifestPath) }

    func localEntries() throws -> [FixtureEntry] {
        try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: localManifest)).entries
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private func entry(_ path: String, _ site: EHSite, _ source: FixtureSource = .captured) -> FixtureEntry {
    switch source {
    case .captured:
        FixtureEntry(
            path: path, site: site, source: .captured, method: "GET", url: "https://\(site.host)/", status: 200,
            contentType: "text/html; charset=UTF-8", capturedAt: "2026-11-04T00:00:00Z"
        )
    case .constructed:
        FixtureEntry(path: path, site: site, source: .constructed, note: "hand-made")
    }
}

private func capture(_ path: String, _ site: EHSite = .eh, body: String = "<p>ok</p>") -> SanitizedCapture {
    SanitizedCapture(entry: entry(path, site), body: Data(body.utf8))
}

private let noSecrets = SecretSet(credentialSecrets: [], extraSecrets: [])

@Suite struct FixtureWriterTests {
    // MARK: Private fixtures (local only)

    @Test func privateListIsThePreferencePagesAndTheForumProfile() {
        let pages = ["account/mytags.html", "list/favorites.html", "list/favorites-cat0.html", "list/favorites-search.html",
                     "list/watched.html"]
        let preferencePages = Set(["eh", "ex"].flatMap { site in pages.map { "\(site)/\($0)" } })
        #expect(preferencePages.count == 10)
        #expect(ImportableFixtures.paths == ["eh/forum/profile.html"])
        #expect(Set(PrivateFixtures.paths) == preferencePages.union(ImportableFixtures.paths))
        #expect(PrivateFixtures.paths.count == 11)
        // The same list the checked-in scan guards (`privatePagesAreNotAtCheckedInPaths` in EHFixturesTests).
        #expect(PrivateFixtures.paths == FixtureHygiene.privatePagePaths)
        #expect(PrivateFixtures.storedPath("eh/list/favorites.html") == "local/eh/list/favorites.html")
        #expect(PrivateFixtures.storedPath("eh/forum/profile.html") == "local/eh/forum/profile.html")
        #expect(PrivateFixtures.storedPath("eh/list/front.html") == "eh/list/front.html")
        // Every private path but the imported ones is a step of the plan.
        let planned = Set(EHSite.allCases.flatMap { site in
            CapturePlan.steps(for: site, targets: CaptureFakes.site(site, contentWarning: true)).compactMap(\.fixturePath)
        })
        #expect(Set(PrivateFixtures.paths).subtracting(ImportableFixtures.paths).isSubset(of: planned))
        #expect(planned.isDisjoint(with: ImportableFixtures.paths))
    }

    @Test func captureKeepsImportedLocalPages() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.seed(entries: [], files: [:])
        // An imported profile page and an older private capture, both under local/.
        try workspace.writer.add(capture("eh/forum/profile.html", body: "<p>profile</p>"), secrets: noSecrets)
        try workspace.writer.write(
            [capture("eh/list/favorites.html", body: "<p>old</p>")], replacingSites: [.eh], secrets: noSecrets
        )
        try workspace.writer.write([capture("ex/list/favorites.html", .ex)], replacingSites: [.ex], secrets: noSecrets)
        #expect(try workspace.localEntries().count == 3)
        try workspace.writer.write([capture("eh/list/front.html")], replacingSites: [.eh], secrets: noSecrets)
        // Recapturing eh: the imported page stays with its entry; the other eh private capture is replaced.
        #expect(workspace.exists("local/eh/forum/profile.html"))
        #expect(!workspace.exists("local/eh/list/favorites.html"))
        #expect(workspace.exists("local/ex/list/favorites.html"))
        #expect(try workspace.localEntries().map(\.path) == ["local/eh/forum/profile.html", "local/ex/list/favorites.html"])
    }

    @Test func addReplacesOneLocalEntryAndKeepsTheRest() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.writer.write(
            [capture("eh/list/favorites.html"), capture("eh/list/front.html")], replacingSites: [.eh], secrets: noSecrets
        )
        let manifestBefore = try Data(contentsOf: workspace.manifest)
        try workspace.writer.add(capture("eh/forum/profile.html", body: "<p>one</p>"), secrets: noSecrets)
        try workspace.writer.add(capture("eh/forum/profile.html", body: "<p>two</p>"), secrets: noSecrets)
        #expect(try String(contentsOf: workspace.root.appending(path: "local/eh/forum/profile.html"), encoding: .utf8) == "<p>two</p>")
        #expect(try workspace.localEntries().map(\.path) == ["local/eh/forum/profile.html", "local/eh/list/favorites.html"])
        #expect(try Data(contentsOf: workspace.manifest) == manifestBefore)
    }

    @Test func addRefusesAPageThatIsNotPrivate() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let before = try workspace.listing()
        #expect(throws: FixtureWriterError.invalidPath("eh/list/front.html")) {
            try workspace.writer.add(capture("eh/list/front.html"), secrets: noSecrets)
        }
        #expect(try workspace.listing() == before)
    }

    @Test func privateCapturesGoToLocalAndItsOwnManifest() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let outcome = try workspace.writer.write(
            [capture("eh/list/front.html"), capture("eh/list/favorites.html", body: "<p>fav</p>"),
             capture("eh/account/mytags.html")],
            replacingSites: [.eh], secrets: noSecrets
        )
        #expect(outcome.localOnly == [.eh: 2])
        #expect(outcome.removedLeftovers.isEmpty)
        #expect(workspace.exists("local/eh/list/favorites.html"))
        #expect(workspace.exists("local/eh/account/mytags.html"))
        #expect(!workspace.exists("eh/list/favorites.html"))
        #expect(!workspace.exists("eh/account/mytags.html"))
        #expect(try String(contentsOf: workspace.root.appending(path: "local/eh/list/favorites.html"), encoding: .utf8) == "<p>fav</p>")
        // manifest.json lists no private path; local/manifest.local.json, in the same format, lists them.
        #expect(try workspace.entries().map(\.path) == ["eh/list/front.html"])
        let local = try workspace.localEntries()
        #expect(local.map(\.path) == ["local/eh/account/mytags.html", "local/eh/list/favorites.html"])
        #expect(local.allSatisfy { $0.site == .eh && $0.source == .captured && $0.url == "https://e-hentai.org/" })
    }

    @Test func noLocalManifestWithoutPrivateCaptures() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let outcome = try workspace.writer.write([capture("eh/list/front.html")], replacingSites: [.eh], secrets: noSecrets)
        #expect(outcome == FixtureWriteOutcome())
        #expect(!workspace.exists(PrivateFixtures.manifestPath))
        #expect(!workspace.exists("local"))
    }

    @Test func oldCheckedInCopiesOfPrivatePagesAreRemoved() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        // An earlier run left eh/list/favorites.html with a manifest entry, and ex/list/watched.html without one.
        try workspace.seed(
            entries: [entry("eh/list/favorites.html", .eh), entry("ex/list/front.html", .ex), entry("ex/account/mytags.html", .ex)],
            files: ["eh/list/favorites.html": "<p>old</p>", "ex/list/front.html": "<p>ex</p>", "ex/list/watched.html": "<p>old</p>",
                    "ex/account/mytags.html": "<p>old</p>"]
        )
        let outcome = try workspace.writer.write(
            [capture("eh/list/favorites.html", body: "<p>new</p>")], replacingSites: [.eh], secrets: noSecrets
        )
        // Whatever the sites being replaced, no private page is left at a checked-in path.
        #expect(outcome.removedLeftovers == ["eh/list/favorites.html", "ex/account/mytags.html", "ex/list/watched.html"])
        for path in PrivateFixtures.paths {
            #expect(!workspace.exists(path), "\(path) is still there")
        }
        #expect(workspace.exists("local/eh/list/favorites.html"))
        // The other site's ordinary fixture stays; no private entry stays in manifest.json.
        #expect(workspace.exists("ex/list/front.html"))
        #expect(try workspace.entries().map(\.path) == ["ex/list/front.html"])
        #expect(try workspace.localEntries().map(\.path) == ["local/eh/list/favorites.html"])
    }

    @Test func leftoverThatIsNotARegularFileIsRefused() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try FileManager.default.createDirectory(at: workspace.root.appending(path: "eh/list/watched.html"), withIntermediateDirectories: true)
        try workspace.seed(entries: [], files: [:])
        let listingBefore = try workspace.listing()
        #expect(throws: FixtureWriterError.invalidPath("eh/list/watched.html")) {
            try workspace.writer.write([capture("eh/list/front.html")], replacingSites: [.eh], secrets: noSecrets)
        }
        #expect(try workspace.listing() == listingBefore)
    }

    @Test func localEntriesOfOtherSitesAreKept() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.writer.write(
            [capture("ex/list/favorites.html", .ex), capture("ex/list/front.html", .ex)], replacingSites: [.ex], secrets: noSecrets
        )
        try workspace.writer.write(
            [capture("eh/list/watched.html"), capture("eh/list/front.html")], replacingSites: [.eh], secrets: noSecrets
        )
        #expect(try workspace.localEntries().map(\.path) == ["local/eh/list/watched.html", "local/ex/list/favorites.html"])
        // Recapturing eh without its private page drops the old local copy.
        try workspace.writer.write([capture("eh/list/front.html")], replacingSites: [.eh], secrets: noSecrets)
        #expect(!workspace.exists("local/eh/list/watched.html"))
        #expect(workspace.exists("local/ex/list/favorites.html"))
        #expect(try workspace.localEntries().map(\.path) == ["local/ex/list/favorites.html"])
        #expect(try workspace.entries().map(\.path) == ["eh/list/front.html", "ex/list/front.html"])
    }

    @Test func privateCapturesPassTheSameHygieneCheck() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let leaky = capture("eh/list/favorites.html", body: "<p>x</p>\n<script>var apikey = \"\(fakeApikey)\";</script>")
        #expect(throws: FixtureWriterError.hygiene([
            HygieneViolation(file: "local/eh/list/favorites.html", rule: "apikey", line: 2),
        ])) {
            try workspace.writer.write([capture("eh/list/front.html"), leaky], replacingSites: [.eh], secrets: noSecrets)
        }
        #expect(try workspace.listing() == ["Fixtures"])
    }

    @Test func localThatIsNotADirectoryIsRefused() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try "x".write(to: workspace.root.appending(path: "local"), atomically: true, encoding: .utf8)
        #expect(throws: FixtureWriterError.invalidPath("local")) {
            try workspace.writer.write([capture("eh/list/favorites.html")], replacingSites: [.eh], secrets: noSecrets)
        }
    }

    // MARK: home.php, checked without the rules

    @Test func homePageNumbersNoRuleMasksAreRefused() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        // Three tags around the key: past what torrentkey skips, so only the rule-independent check sees its digit.
        let home = """
            <h2>Image Limits</h2><div class="homebox"><p>at <strong>12</strong> of <strong>5,000</strong></p></div>
            <h2>EHTracker</h2><div class="homebox">
            <p>Your current key is: <span><b><i>Zq9fakeKey</i></b></span></p>
            </div>
            """
        let structural = FixtureHygiene.structuralViolations(in: home, file: "eh/account/home.html")
        #expect(structural.isEmpty, "the rules are expected to miss this one")
        #expect(throws: FixtureWriterError.hygiene([
            HygieneViolation(file: "eh/account/home.html", rule: HomePageCheck.rule, line: 3),
        ])) {
            try workspace.writer.write([capture("eh/account/home.html", body: home)], replacingSites: [.eh], secrets: noSecrets)
        }
        #expect(try workspace.listing() == ["Fixtures"])
        // The same numbers on another page are not this check's business.
        try workspace.writer.write([capture("eh/list/front.html", body: home)], replacingSites: [.eh], secrets: noSecrets)
        #expect(workspace.exists("eh/list/front.html"))
    }

    @Test func homePageWithMarkupBeforeItsHomeboxIsMaskedAndWritten() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let home = """
            <h2>Image Limits</h2><div class="homebox"><p>at <strong>12</strong> of <strong>5,000</strong></p></div>
            <h2>Toplists</h2>
            <p class="note">ranks</p>
            <div class="homebox"><strong>#4321</strong></div>
            """
        let raw = RawCapture(
            fixturePath: "eh/account/home.html", site: .eh, method: "GET", url: URL(string: "https://e-hentai.org/home.php")!,
            status: 200, headers: ["Content-Type": "text/html; charset=UTF-8"], body: Data(home.utf8),
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        let credentials = try CaptureCredentials(
            environment: ["EH_IPB_MEMBER_ID": "1234567", "EH_IPB_PASS_HASH": fakePassHash, "EH_USERNAME": "ZqUser"],
            sites: [.eh]
        )
        let sanitized = try sanitizeCaptures([raw], credentials: credentials, extraSecrets: [])
        try workspace.writer.write(sanitized.captures, replacingSites: [.eh], secrets: sanitized.secrets)
        let written = try String(contentsOf: workspace.root.appending(path: "eh/account/home.html"), encoding: .utf8)
        let masked = written.contains("<strong>#1111</strong>") && written.contains("<strong>5,000</strong>")
        #expect(masked)
    }

    // MARK: Checked-in fixtures

    @Test func refusesToWriteWhenHygieneFails() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.seed(entries: [entry("eh/list/a.html", .eh)], files: ["eh/list/a.html": "<p>a</p>"])
        let manifestBefore = try Data(contentsOf: workspace.manifest)
        let listingBefore = try workspace.listing()

        let leaky = capture("eh/list/new.html", body: "<p>x</p>\n<script>var apikey = \"\(fakeApikey)\";</script>")
        #expect(throws: FixtureWriterError.hygiene([HygieneViolation(file: "eh/list/new.html", rule: "apikey", line: 2)])) {
            try workspace.writer.write([capture("eh/list/b.html"), leaky], replacingSites: [.eh], secrets: noSecrets)
        }
        #expect(try workspace.listing() == listingBefore)
        #expect(try Data(contentsOf: workspace.manifest) == manifestBefore)
    }

    @Test func refusesKnownSecretInManifest() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        var leaky = entry("eh/list/a.html", .eh)
        leaky.url = "https://e-hentai.org/?showuser=1234567"
        let secrets = SecretSet(credentialSecrets: [KnownSecret(kind: .numeric, value: "1234567")], extraSecrets: [])
        let error = #expect(throws: FixtureWriterError.self) {
            try workspace.writer.write([SanitizedCapture(entry: leaky, body: Data("<p>a</p>".utf8))], replacingSites: [.eh], secrets: secrets)
        }
        guard case .hygiene(let violations) = error else {
            Issue.record("expected a hygiene error")
            return
        }
        #expect(violations.map(\.file) == ["manifest.json"])
        #expect(violations.map(\.rule) == ["secret:numeric"])
        #expect(try workspace.listing() == ["Fixtures"])
    }

    @Test func refusesPathsOutsideTheSiteDirectory() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        for path in ["", "/tmp/x.html", "../x.html", "eh/../ex/x.html", "eh/./x.html", "eh//x.html", "ex/x.html", "eh", "constructed/x.html"] {
            #expect(throws: FixtureWriterError.invalidPath(path)) {
                try workspace.writer.write([capture(path)], replacingSites: [.eh], secrets: noSecrets)
            }
        }
        #expect(throws: FixtureWriterError.invalidPath("eh/x.html")) {
            try workspace.writer.write([capture("eh/x.html"), capture("eh/x.html")], replacingSites: [.eh], secrets: noSecrets)
        }
        #expect(try workspace.listing() == ["Fixtures"])
    }

    @Test func refusesCapturesThatAreNotCapturedOrNotReplaced() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let constructed = SanitizedCapture(entry: entry("eh/c.html", .eh, .constructed), body: Data("<p>c</p>".utf8))
        #expect(throws: FixtureWriterError.invalidPath("eh/c.html")) {
            try workspace.writer.write([constructed], replacingSites: [.eh], secrets: noSecrets)
        }
        #expect(throws: FixtureWriterError.invalidPath("ex/x.html")) {
            try workspace.writer.write([capture("eh/a.html"), capture("ex/x.html", .ex)], replacingSites: [.eh], secrets: noSecrets)
        }
        #expect(try workspace.listing() == ["Fixtures"])
    }

    @Test func deletesOnlyRegularFiles() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        // A directory listed as a captured fixture is refused, not deleted recursively.
        try workspace.seed(entries: [entry("eh/list", .eh)], files: ["eh/list/inner.html": "<p>i</p>"])
        let listingBefore = try workspace.listing()
        #expect(throws: FixtureWriterError.invalidPath("eh/list")) {
            try workspace.writer.write([capture("eh/other.html")], replacingSites: [.eh], secrets: noSecrets)
        }
        #expect(try workspace.listing() == listingBefore)

        // So is a symbolic link; its target survives.
        let target = workspace.url.appending(path: "target.html")
        try "<p>t</p>".write(to: target, atomically: true, encoding: .utf8)
        try workspace.seed(entries: [entry("eh/link.html", .eh)], files: [:])
        try FileManager.default.createSymbolicLink(at: workspace.root.appending(path: "eh/link.html"), withDestinationURL: target)
        #expect(throws: FixtureWriterError.invalidPath("eh/link.html")) {
            try workspace.writer.write([capture("eh/other.html")], replacingSites: [.eh], secrets: noSecrets)
        }
        #expect(FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
        #expect(!workspace.exists("eh/other.html"))
    }

    @Test func pathsDifferingOnlyInCaseAreTheSamePath() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.seed(entries: [entry("eh/a.html", .eh)], files: ["eh/a.html": "<p>old</p>"])
        try workspace.writer.write([capture("eh/A.html", body: "<p>new</p>")], replacingSites: [.eh], secrets: noSecrets)
        #expect(try workspace.entries() == [entry("eh/A.html", .eh)])
        #expect(try String(contentsOf: workspace.root.appending(path: "eh/A.html"), encoding: .utf8) == "<p>new</p>")

        #expect(throws: FixtureWriterError.invalidPath("eh/X.html")) {
            try workspace.writer.write([capture("eh/x.html"), capture("eh/X.html")], replacingSites: [.eh], secrets: noSecrets)
        }
    }

    @Test func emptyPersistableLeavesTheSecretsFileAlone() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let secretsPath = workspace.secretsFile.path(percentEncoded: false)
        // Credentials alone are never persisted, so there is nothing to write.
        let credentialsOnly = SecretSet(credentialSecrets: [KnownSecret(kind: .literal, value: fakePassHash)], extraSecrets: [])
        try workspace.writer.write([capture("eh/a.html")], replacingSites: [.eh], secrets: credentialsOnly)
        #expect(!FileManager.default.fileExists(atPath: secretsPath), "an empty secrets file was created")

        try "# kept\nliteral\tkeepme0123\n".write(to: workspace.secretsFile, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: workspace.secretsFile)
        try workspace.writer.write([capture("eh/b.html")], replacingSites: [.eh], secrets: credentialsOnly)
        let unchanged = try Data(contentsOf: workspace.secretsFile) == before
        #expect(unchanged, "an existing secrets file was overwritten")
    }

    @Test func replacesCapturedEntriesForCapturedSitesOnly() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.seed(
            entries: [entry("eh/list/a.html", .eh), entry("ex/list/b.html", .ex), entry("constructed/c.html", .eh, .constructed)],
            files: ["eh/list/a.html": "<p>a</p>", "ex/list/b.html": "<p>b</p>", "constructed/c.html": "<p>c</p>"]
        )
        try workspace.writer.write([capture("eh/list/d.html", body: "<p>d</p>")], replacingSites: [.eh], secrets: noSecrets)

        #expect(try workspace.entries() == [
            entry("constructed/c.html", .eh, .constructed), entry("eh/list/d.html", .eh), entry("ex/list/b.html", .ex),
        ])
        #expect(!workspace.exists("eh/list/a.html"))
        #expect(workspace.exists("ex/list/b.html"))
        #expect(workspace.exists("constructed/c.html"))
        #expect(try String(contentsOf: workspace.root.appending(path: "eh/list/d.html"), encoding: .utf8) == "<p>d</p>")
    }

    @Test func recapturingAPathKeepsItsNewFile() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.seed(entries: [entry("eh/list/a.html", .eh)], files: ["eh/list/a.html": "<p>old</p>"])
        try workspace.writer.write([capture("eh/list/a.html", body: "<p>new</p>")], replacingSites: [.eh], secrets: noSecrets)
        #expect(try workspace.entries() == [entry("eh/list/a.html", .eh)])
        #expect(try String(contentsOf: workspace.root.appending(path: "eh/list/a.html"), encoding: .utf8) == "<p>new</p>")
    }

    @Test func manifestIsStable() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let captures = [capture("eh/z.html"), capture("eh/list/a.html"), capture("ex/m.html", .ex)]
        try workspace.writer.write(captures, replacingSites: [.eh, .ex], secrets: noSecrets)
        let first = try Data(contentsOf: workspace.manifest)
        try workspace.writer.write(captures, replacingSites: [.eh, .ex], secrets: noSecrets)
        let second = try Data(contentsOf: workspace.manifest)
        #expect(first == second)
        #expect(first.last == UInt8(ascii: "\n"))
        let text = String(decoding: first, as: UTF8.self)
        #expect(text.contains("\"https://e-hentai.org/\""), "slashes are not escaped")
        #expect(text.contains("\n  "), "pretty-printed")
        #expect(try workspace.entries().map(\.path) == ["eh/list/a.html", "eh/z.html", "ex/m.html"])
    }

    @Test func secretsFileKeepsIdentityButNoTokens() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        // A stale, world-readable secrets file must be replaced, not reused.
        try "stale\n".write(to: workspace.secretsFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: workspace.secretsFile.path(percentEncoded: false))

        let credentials = try CaptureCredentials(
            environment: ["EH_IPB_MEMBER_ID": "1234567", "EH_IPB_PASS_HASH": fakePassHash, "EH_USERNAME": "ZqUser"],
            sites: [.eh]
        )
        let raw = RawCapture(
            fixturePath: "eh/home.html", site: .eh, method: "GET", url: URL(string: "https://e-hentai.org/home.php")!,
            status: 200, headers: ["Content-Type": "text/html; charset=UTF-8"],
            body: Data("<script>var apiuid = 1234567;\nvar apikey = \"\(fakeApikey)\";</script>".utf8),
            capturedAt: Date(timeIntervalSince1970: 1_793_750_400)
        )
        let sanitized = try sanitizeCaptures([raw], credentials: credentials, extraSecrets: [])
        try workspace.writer.write(sanitized.captures, replacingSites: [.eh], secrets: sanitized.secrets)

        let attributes = try FileManager.default.attributesOfItem(atPath: workspace.secretsFile.path(percentEncoded: false))
        let permissions = (attributes[.posixPermissions] as? Int).map { $0 & 0o777 }
        #expect(permissions == 0o600)
        let text = try String(contentsOf: workspace.secretsFile, encoding: .utf8)
        let hasPassHash = text.contains(fakePassHash)
        #expect(hasPassHash == false, "the secrets file holds a login token")
        let hasMemberID = text.contains("numeric\t1234567\n")
        #expect(hasMemberID, "the member id is not persisted")
        let hasUsername = text.contains("word\tZqUser\n")
        #expect(hasUsername, "the username is not persisted")
        let hasApikey = text.contains("literal\t\(fakeApikey)\n")
        #expect(hasApikey, "the discovered apikey is not persisted")
        let parsed = Set(FixtureHygiene.parseSecretsFile(text)) == [
            KnownSecret(kind: .literal, value: fakeApikey), KnownSecret(kind: .numeric, value: "1234567"),
            KnownSecret(kind: .word, value: "ZqUser"),
        ]
        #expect(parsed)
        // Only the fixture, the manifest and the secrets file were written; no temporary file is left behind.
        #expect(try workspace.listing() == ["Fixtures", "Fixtures/eh", "Fixtures/eh/home.html", "Fixtures/manifest.json", "fixture-secrets.local"])
    }
}
