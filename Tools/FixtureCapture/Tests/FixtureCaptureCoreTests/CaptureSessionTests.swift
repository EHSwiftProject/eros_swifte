import EHFixtures
import EHModels
import FixtureCaptureCore
import Foundation
import Testing

/// A unique directory under the system temporary directory holding a fixture root and a secrets file.
private struct SessionWorkspace {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "eros-capture-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var root: URL { url.appending(path: "Fixtures") }
    var manifest: URL { root.appending(path: "manifest.json") }
    var secretsFile: URL { url.appending(path: "fixture-secrets.local") }

    func config(sites: [EHSite] = [.eh], environment: [String: String]? = nil) -> CaptureSessionConfig {
        CaptureSessionConfig(
            sites: sites,
            environment: environment ?? CaptureFakes.environment(sites: Set(sites)),
            targets: CaptureFakes.targets(),
            fixturesRoot: root,
            secretsFile: secretsFile
        )
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

/// True when `text` passes both hygiene checks against `secrets`.
private func isClean(_ text: String, secrets: [KnownSecret]) -> Bool {
    FixtureHygiene.structuralViolations(in: text, file: "f").isEmpty
        && FixtureHygiene.secretViolations(in: text, file: "f", secrets: secrets).isEmpty
}

/// Ways a capture stops, each at one request of the canned EH site.
enum SessionAbort: CaseIterable, Sendable, CustomTestStringConvertible {
    case notCompact, tooManyRequests, banned

    var index: Int {
        switch self {
        case .notCompact: 0
        case .tooManyRequests, .banned: 3
        }
    }

    var response: CaptureResponse {
        switch self {
        case .notCompact: CannedSite.html(CannedSite.listPage(mode: "e"))
        case .tooManyRequests: CannedSite.html("<html><body>slow down</body></html>", status: 429)
        case .banned: CannedSite.html("Your IP address has been temporarily banned for excessive pageloads.")
        }
    }

    var error: CaptureAbort {
        switch self {
        case .notCompact: .notCompactView(site: .eh, mode: .extended)
        case .tooManyRequests: .stoppedByServer(site: .eh, fixturePath: "eh/list/category.html", status: 429)
        case .banned: .banned(site: .eh, fixturePath: "eh/list/category.html")
        }
    }

    var testDescription: String { "\(self)" }
}

@Suite struct CaptureSessionTests {
    @Test func invalidCredentialsMakeNoRequests() async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        let transport = StubTransport { request, _ in CannedSite().respond(request) }
        let config = workspace.config(
            environment: ["EH_IPB_MEMBER_ID": CaptureFakes.memberID, "EH_USERNAME": CaptureFakes.username]
        )
        await #expect(throws: CredentialError.missing(["EH_IPB_PASS_HASH"])) {
            try await runCaptureSession(config, transport: transport)
        }
        #expect(transport.requests.isEmpty)
        #expect(try workspace.listing() == ["Fixtures"])
    }

    @Test(arguments: [[EHSite.eh], [EHSite.ex], [EHSite.eh, EHSite.ex]])
    func missingUsernameMakesNoRequests(sites: [EHSite]) async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        let transport = StubTransport { request, _ in CannedSite().respond(request) }
        var environment = CaptureFakes.environment(sites: Set(sites))
        environment["EH_USERNAME"] = nil
        let config = workspace.config(environment: environment)
        await #expect(throws: CredentialError.missing(["EH_USERNAME"])) {
            try await runCaptureSession(config, transport: transport)
        }
        #expect(transport.requests.isEmpty)
        #expect(try workspace.listing() == ["Fixtures"])
    }

    @Test(arguments: SessionAbort.allCases)
    func abortLeavesFixturesUntouched(abort: SessionAbort) async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        let entry = FixtureEntry(
            path: "eh/list/front.html", site: .eh, source: .captured, method: "GET", url: "https://e-hentai.org/",
            status: 200, contentType: "text/html", capturedAt: "2026-11-01T00:00:00Z"
        )
        try JSONEncoder().encode(FixtureManifest(entries: [entry])).write(to: workspace.manifest)
        let sample = workspace.root.appending(path: "eh/list/front.html")
        try FileManager.default.createDirectory(at: sample.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<p>old</p>".write(to: sample, atomically: true, encoding: .utf8)
        let manifestBefore = try Data(contentsOf: workspace.manifest)
        let listingBefore = try workspace.listing()

        let site = CannedSite()
        let transport = StubTransport { request, index in
            index == abort.index ? abort.response : site.respond(request)
        }
        await #expect(throws: abort.error) {
            try await runCaptureSession(workspace.config(), transport: transport)
        }
        #expect(transport.requests.count == abort.index + 1)
        #expect(try Data(contentsOf: workspace.manifest) == manifestBefore)
        #expect(try workspace.listing() == listingBefore)
        #expect(try String(contentsOf: sample, encoding: .utf8) == "<p>old</p>")
    }

    @Test func ownUploadRefusesTheRunAndWritesNothing() async throws {
        let findings = try await ownContentRefusal(of: CannedSite(detailUploaderIsSelf: true))
        #expect(findings == ["eh/gallery/detail.html ownupload", "eh/gallery/detail-p1.html ownupload"])
    }

    /// Runs a capture of `site` over a fixture root that already holds one captured page; the run must refuse with
    /// `.ownContent` and leave the manifest, the directory, the page and the secrets file as they were.
    /// - Returns: The findings as "<file> <rule>", or nil (with an issue recorded) when the run did not refuse so.
    private func ownContentRefusal(of site: CannedSite) async throws -> Set<String>? {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        let entry = FixtureEntry(
            path: "eh/list/front.html", site: .eh, source: .captured, method: "GET", url: "https://e-hentai.org/",
            status: 200, contentType: "text/html", capturedAt: "2026-11-01T00:00:00Z"
        )
        try JSONEncoder().encode(FixtureManifest(entries: [entry])).write(to: workspace.manifest)
        let sample = workspace.root.appending(path: "eh/list/front.html")
        try FileManager.default.createDirectory(at: sample.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<p>old</p>".write(to: sample, atomically: true, encoding: .utf8)
        let manifestBefore = try Data(contentsOf: workspace.manifest)
        let listingBefore = try workspace.listing()

        let transport = StubTransport { request, _ in site.respond(request) }
        let error = await #expect(throws: SanitizeError.self) {
            try await runCaptureSession(workspace.config(), transport: transport)
        }
        #expect(try Data(contentsOf: workspace.manifest) == manifestBefore)
        #expect(try workspace.listing() == listingBefore)
        #expect(try String(contentsOf: sample, encoding: .utf8) == "<p>old</p>")
        #expect(!FileManager.default.fileExists(atPath: workspace.secretsFile.path(percentEncoded: false)))
        guard case .ownContent(let findings) = error else {
            Issue.record("expected an own-content refusal")
            return nil
        }
        return Set(findings.map { "\($0.file) \($0.rule)" })
    }

    /// The canned detail page reads (it has `var token` and `#gn`); without `var token` it cannot be checked, so the
    /// run is refused even though it shows someone else as the uploader.
    @Test func uncheckablePageRefusesTheRunAndWritesNothing() async throws {
        let findings = try await ownContentRefusal(of: CannedSite(detailIsUnparsable: true))
        #expect(findings == ["eh/gallery/detail.html owncheck", "eh/gallery/detail-p1.html owncheck"])
    }

    @Test func ownTorrentRefusesTheRunAndWritesNothing() async throws {
        let findings = try await ownContentRefusal(of: CannedSite(torrentUploaderIsSelf: true))
        #expect(findings == ["eh/popup/torrents.html owntorrent"])
    }

    @Test func ownContentErrorShowsNoValues() async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        let site = CannedSite(detailUploaderIsSelf: true)
        let transport = StubTransport { request, _ in site.respond(request) }
        let error = await #expect(throws: SanitizeError.self) {
            try await runCaptureSession(workspace.config(), transport: transport)
        }
        let shown = error.map { String(describing: $0) } ?? ""
        let leaks = shown.contains(CaptureFakes.username) || shown.contains(CaptureFakes.memberID)
        #expect(!shown.isEmpty)
        #expect(!leaks)
    }

    @Test func exSessionDropMidRunWritesNothing() async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        let site = CannedSite(site: .ex)
        let transport = StubTransport { request, index in
            index == 1 ? CannedSite.html("", url: request.url) : site.respond(request)
        }
        await #expect(throws: CaptureAbort.exAccessDenied) {
            try await runCaptureSession(workspace.config(sites: [.ex]), transport: transport)
        }
        #expect(transport.requests.count == 2)
        #expect(try workspace.listing() == ["Fixtures"])
    }

    @Test func successfulRunWritesSanitizedFixtures() async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        var dirtyLocal: [String] = []
        let transport = StubTransport { request, _ in CannedSite().respond(request) }
        let summary = try await runCaptureSession(workspace.config(), transport: transport)

        #expect(summary.written[.eh] == 37)
        #expect(summary.written[.ex] == nil)
        #expect(summary.skipped.map(\.fixturePath) == ["eh/gallery/content-warning.html"])

        // 5 of the 37 are private: written under local/ and listed only in local/manifest.local.json.
        #expect(summary.localOnly == [.eh: 5])
        #expect(summary.removedLeftovers.isEmpty)
        let entries = try workspace.entries()
        #expect(entries.count == 32)
        #expect(entries.allSatisfy { $0.site == .eh && $0.source == .captured && !PrivateFixtures.isPrivate($0.path) })
        let localEntries = try workspace.localEntries()
        #expect(Set(localEntries.map(\.path)) == Set(PrivateFixtures.paths.filter { $0.hasPrefix("eh/") && !ImportableFixtures.paths.contains($0) }.map { "local/" + $0 }))
        for entry in localEntries {
            let text = try String(contentsOf: workspace.root.appending(path: entry.path), encoding: .utf8)
            if !isClean(text, secrets: CaptureFakes.plantedSecrets) { dirtyLocal.append(entry.path) }
        }
        let localManifestText = try String(contentsOf: workspace.localManifest, encoding: .utf8)
        if !isClean(localManifestText, secrets: CaptureFakes.plantedSecrets) { dirtyLocal.append(PrivateFixtures.manifestPath) }
        #expect(dirtyLocal.isEmpty, "local files failing hygiene: \(dirtyLocal)")
        let secrets = CaptureFakes.plantedSecrets
        var dirty: [String] = []
        for entry in entries {
            let text = try String(contentsOf: workspace.root.appending(path: entry.path), encoding: .utf8)
            if !isClean(text, secrets: secrets) { dirty.append(entry.path) }
        }
        let manifestText = try String(contentsOf: workspace.manifest, encoding: .utf8)
        if !isClean(manifestText, secrets: secrets) { dirty.append("manifest.json") }
        #expect(dirty.isEmpty, "files failing hygiene: \(dirty)")

        // The planted values reached the fixtures in masked form, not as removed text.
        let front = try String(contentsOf: workspace.root.appending(path: "eh/list/front.html"), encoding: .utf8)
        let maskedMemberID = front.contains("var apiuid = 1111111;")
        #expect(maskedMemberID, "the front page does not show the masked member id")
        // This link (the profile link) holds only the member id (no apiuid), so only the credential secret set can mask it.
        let detail = try String(contentsOf: workspace.root.appending(path: "eh/gallery/detail.html"), encoding: .utf8)
        let maskedUploaderLink = detail.contains("showuser=1111111") && !detail.contains(CaptureFakes.memberID)
        #expect(maskedUploaderLink, "the detail page does not show the masked member id in the profile link")
        // My Tags coloring and the funds do not reach a fixture; the tag itself stays.
        let tagStyleGone = !front.contains("radial-gradient") && front.contains(#"<div class="gt" title="zqns:zqfaketag">"#)
        #expect(tagStyleGone, "a tag kept its My Tags style")
        // The lists were requested with filters disabled, so none says it hid anything, and the manifest shows how.
        let unfiltered = !front.contains("Filtered") && front.contains(CannedSite.resultLine)
        #expect(unfiltered, "the front page was captured with the account's filters on")
        let frontURL = entries.first { $0.path == "eh/list/front.html" }?.url
        #expect(frontURL == "https://e-hentai.org/?f_sft=on&f_sfu=on&f_sfl=on")
        let archiver = try String(contentsOf: workspace.root.appending(path: "eh/popup/archiver.html"), encoding: .utf8)
        let fundsMasked = archiver.contains("1,111,111 GP") && archiver.contains("111 Credits") && archiver.contains("Download Cost: 1,234 GP")
        #expect(fundsMasked)
        let home = try String(contentsOf: workspace.root.appending(path: "eh/account/home.html"), encoding: .utf8)
        let standIn = home.contains("203.0.113.1")
        #expect(standIn, "the home page does not show the address stand-in")
        // Discovered values and the identity (member id, username) are kept in the local secrets file; tokens are not.
        let secretsFile = try String(contentsOf: workspace.secretsFile, encoding: .utf8)
        let kept = FixtureHygiene.parseSecretsFile(secretsFile)
        let keepsDiscovered = kept.contains(KnownSecret(kind: .literal, value: CaptureFakes.apikey))
        let keepsIdentity = kept.contains(KnownSecret(kind: .numeric, value: CaptureFakes.memberID))
            && kept.contains(KnownSecret(kind: .word, value: CaptureFakes.username))
        let keepsTokens = kept.contains { $0.value == CaptureFakes.passHash || $0.value == CaptureFakes.igneous }
        #expect(keepsDiscovered, "the secrets file lacks a discovered value")
        #expect(keepsIdentity, "the secrets file lacks the member id or username")
        #expect(!keepsTokens, "the secrets file holds a login token")
    }

    @Test func listsTheSiteStillFiltersAreRefusedAndNothingIsWritten() async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        // The site ignores the Disable Filters parameters: every list at / still says it hid galleries.
        let site = CannedSite(honorsDisabledFilters: false)
        let transport = StubTransport { request, _ in site.respond(request) }
        let error = await #expect(throws: FixtureWriterError.self) {
            try await runCaptureSession(workspace.config(), transport: transport)
        }
        guard case .hygiene(let violations) = error else {
            Issue.record("expected a hygiene error")
            return
        }
        #expect(Set(violations.map(\.rule)) == [FixtureHygiene.filteredListRule])
        #expect(Set(violations.map(\.file)) == [
            "eh/list/front.html", "eh/list/front-next.html", "eh/list/front-seek.html", "eh/list/category.html",
            "eh/list/search.html", "eh/list/search-advanced.html",
        ])
        #expect(try workspace.listing() == ["Fixtures"])
    }

    @Test func secretsFoundOnPrivatePagesStillMaskOtherPages() async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        // The note appears only on the private favorites list, and in passing on home.php.
        let note = "zq note seen on a private list"
        let site = CannedSite(homeExtra: "<p>\(note)</p>", favoritesNote: note)
        let transport = StubTransport { request, _ in site.respond(request) }
        let summary = try await runCaptureSession(workspace.config(), transport: transport)
        #expect(summary.localOnly == [.eh: 5])
        let home = try String(contentsOf: workspace.root.appending(path: "eh/account/home.html"), encoding: .utf8)
        let favorites = try String(contentsOf: workspace.root.appending(path: "local/eh/list/favorites.html"), encoding: .utf8)
        let secret = KnownSecret(kind: .literal, value: note)
        let clean = isClean(home, secrets: [secret]) && isClean(favorites, secrets: [secret])
        #expect(clean, "a note found on a private page reached a fixture")
        let kept = FixtureHygiene.parseSecretsFile(try String(contentsOf: workspace.secretsFile, encoding: .utf8))
        #expect(kept.contains(secret))
    }

    @Test func leftoverPrivatePagesAreReported() async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        // A run from before the pages became private left one behind, untracked and outside the manifest.
        let leftover = workspace.root.appending(path: "eh/list/watched.html")
        try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<p>old</p>".write(to: leftover, atomically: true, encoding: .utf8)
        let transport = StubTransport { request, _ in CannedSite().respond(request) }
        let summary = try await runCaptureSession(workspace.config(), transport: transport)
        #expect(summary.removedLeftovers == ["eh/list/watched.html"])
        #expect(!FileManager.default.fileExists(atPath: leftover.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: workspace.root.appending(path: "local/eh/list/watched.html").path(percentEncoded: false)))
    }

    @Test func existingSecretsFileIsApplied() async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        let oldNickname = "OldNicknameZq"
        try "# local\nword\t\(oldNickname)\n".write(to: workspace.secretsFile, atomically: true, encoding: .utf8)
        let transport = StubTransport { request, _ in CannedSite(homeExtra: "<p>aka \(oldNickname)</p>").respond(request) }
        _ = try await runCaptureSession(workspace.config(), transport: transport)
        let home = try String(contentsOf: workspace.root.appending(path: "eh/account/home.html"), encoding: .utf8)
        let clean = isClean(home, secrets: [KnownSecret(kind: .word, value: oldNickname)])
        #expect(clean, "a value from the existing secrets file reached a fixture")
    }

    @Test(arguments: [EHSite.eh, EHSite.ex])
    func everyRequiredPathIsWritten(site: EHSite) async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        let canned = CannedSite(site: site)
        let transport = StubTransport { request, _ in canned.respond(request) }
        _ = try await runCaptureSession(workspace.config(sites: [site]), transport: transport)
        let written = Set(try workspace.entries().map(\.path)).union(try workspace.localEntries().map { String($0.path.dropFirst("local/".count)) })
        let planned = Set(CapturePlan.steps(for: site, targets: CaptureFakes.targets()[site]).compactMap(\.fixturePath))
        let missing = planned.subtracting(CapturePlan.optionalFixturePaths(for: site)).subtracting(written)
        #expect(missing.isEmpty, "required paths not written: \(missing.sorted())")
        #expect(CapturePlan.optionalFixturePaths(for: site) == [
            "\(site.rawValue)/gallery/content-warning.html", "\(site.rawValue)/list/image-lookup-redirect.html",
            "\(site.rawValue)/list/image-lookup.html",
        ])
    }

    @Test func skippedRequiredStepAbortsAndWritesNothing() async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        let entry = FixtureEntry(
            path: "eh/list/front.html", site: .eh, source: .captured, method: "GET", url: "https://e-hentai.org/",
            status: 200, contentType: "text/html", capturedAt: "2026-11-01T00:00:00Z"
        )
        try JSONEncoder().encode(FixtureManifest(entries: [entry])).write(to: workspace.manifest)
        let manifestBefore = try Data(contentsOf: workspace.manifest)
        let listingBefore = try workspace.listing()
        let site = CannedSite(detailHasImagePages: false)
        let transport = StubTransport { request, _ in site.respond(request) }
        await #expect(throws: CaptureAbort.requiredStepSkipped(site: .eh, fixturePath: "eh/image/page.html")) {
            try await runCaptureSession(workspace.config(), transport: transport)
        }
        #expect(try Data(contentsOf: workspace.manifest) == manifestBefore)
        #expect(try workspace.listing() == listingBefore)
    }

    @Test func skippedCoverDownloadIsNotARequiredStep() async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        let site = CannedSite(detailHasCover: false)
        let transport = StubTransport { request, _ in site.respond(request) }
        let summary = try await runCaptureSession(workspace.config(), transport: transport)
        let coverSkipped = summary.skipped.contains { $0.savedPath == nil && $0.fixturePath.contains("cover") }
        #expect(coverSkipped, "the cover step was not skipped")
        #expect(summary.written[.eh] != nil)
    }

    @Test func sanitizerWarningsReachTheSummaryWithoutValues() async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        try "literal\tabc\n".write(to: workspace.secretsFile, atomically: true, encoding: .utf8)
        let transport = StubTransport { request, _ in CannedSite().respond(request) }
        let summary = try await runCaptureSession(workspace.config(), transport: transport)
        #expect(summary.warnings.contains { $0.hasPrefix("an extra secret is shorter than 4 characters") })
        #expect(summary.warnings.allSatisfy { !$0.contains("abc") })
    }

    @Test func discoveredProfileNameIsPersisted() async throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        let transport = StubTransport { request, _ in CannedSite().respond(request) }
        _ = try await runCaptureSession(workspace.config(), transport: transport)
        let text = try String(contentsOf: workspace.secretsFile, encoding: .utf8)
        let persisted = text.contains("word\t\(CaptureFakes.profileName)")
        #expect(persisted, "the secrets file lacks the discovered profile name")
    }

    @Test func configPrintsWithoutValues() throws {
        let workspace = try SessionWorkspace()
        defer { workspace.remove() }
        let config = workspace.config()
        var dumped = ""
        dump(config, to: &dumped)
        let printed = String(describing: config) + String(reflecting: config) + dumped
        let leaks = printed.contains(CaptureFakes.memberID) || printed.contains(CaptureFakes.passHash)
        #expect(!leaks, "printing a session config shows a credential")
        let namesVariables = printed.contains("EH_IPB_PASS_HASH")
        #expect(namesVariables, "printing a session config does not name the set variables")
    }
}
