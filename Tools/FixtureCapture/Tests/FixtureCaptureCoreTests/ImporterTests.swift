import EHFixtures
import EHModels
import FixtureCaptureCore
import Foundation
import Testing

// Invented values only; expectations compare Booleans, paths, counts and bytes.
private let fakeUser = "ZetaPanda"
private let fakeMemberID = "7654321"
private let fakeSession = "0123456789abcdef0123456789abcdef"
private let fakeLogout = "fedcba9876543210fedcba9876543210"
private let fixedNow = Date(timeIntervalSince1970: 1_793_000_000)

/// A fixture root, a secrets file and a saved page in a unique temporary directory.
private struct ImportWorkspace {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "eros-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var root: URL { url.appending(path: "Fixtures") }
    var secretsFile: URL { url.appending(path: "fixture-secrets.local") }
    var saved: URL { url.appending(path: "saved.html") }

    func save(_ text: String) throws { try Data(text.utf8).write(to: saved) }
    func save(bytes: [UInt8]) throws { try Data(bytes).write(to: saved) }

    /// The secrets file holding the invented username and member id.
    func knowIdentity(user: String = fakeUser, memberID: String = fakeMemberID) throws {
        try Data("word\t\(user)\nnumeric\t\(memberID)\n".utf8).write(to: secretsFile)
    }

    func run(as path: String = "eh/forum/profile.html", environment: [String: String] = [:]) throws -> ImportOutcome {
        try importFixture(
            file: saved, as: path, fixturesRoot: root, secretsFile: secretsFile, environment: environment, now: fixedNow
        )
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path(percentEncoded: false))
    }

    func text(_ path: String) throws -> String { try String(contentsOf: root.appending(path: path), encoding: .utf8) }
    func bytes(_ path: String) throws -> Data { try Data(contentsOf: root.appending(path: path)) }

    func listing() throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: url.path(percentEncoded: false)).sorted()
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// An IPB-style profile page with an invented nickname, member id and session keys.
private func profilePage(nickname: String = fakeUser) -> String {
    """
    <html><head><title>Viewing Profile -- \(nickname)</title>
    <script>var ipb_var_s = "\(fakeSession)";</script></head><body>
    <div id="profilename">\(nickname)</div>
    <a href="https://forums.e-hentai.org/index.php?showuser=\(fakeMemberID)">My profile</a>
    <a href="https://forums.e-hentai.org/index.php?act=Login&amp;CODE=03&amp;k=\(fakeLogout)">Log out</a>
    <a href="https://forums.e-hentai.org/index.php?showforum=3&amp;s=\(fakeSession)">Forum</a>
    <p>Member \(nickname), id \(fakeMemberID).</p>
    </body></html>
    """
}

@Suite struct ImporterTests {
    @Test func importWritesOnlyTheLocalCopy() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        try workspace.save(profilePage())
        // A checked-in manifest that must stay byte for byte.
        let manifestBytes = Data("{\n  \"entries\" : [\n\n  ]\n}\n".utf8)
        try manifestBytes.write(to: workspace.root.appending(path: "manifest.json"))

        let outcome = try workspace.run()
        #expect(outcome.storedPath == "local/eh/forum/profile.html")
        #expect(workspace.exists("local/eh/forum/profile.html"))
        #expect(try workspace.bytes("manifest.json") == manifestBytes)
        #expect(!workspace.exists("eh/forum"))
        let entries = try JSONDecoder().decode(
            FixtureManifest.self, from: workspace.bytes(PrivateFixtures.manifestPath)
        ).entries
        #expect(entries.map(\.path) == ["local/eh/forum/profile.html"])
        let entry = try #require(entries.first)
        #expect(entry.site == .eh && entry.source == .captured && entry.method == "GET" && entry.status == 200)
        #expect(entry.url == ImportableFixtures.placeholderURL(for: "eh/forum/profile.html"))
        #expect(entry.url == "https://forums.e-hentai.org/index.php?showuser=1111111")
        #expect(entry.contentType == "text/html; charset=UTF-8")
        #expect(entry.setCookieNames.isEmpty)
        #expect(entry.capturedAt == Date.ISO8601FormatStyle(timeZone: .gmt).format(fixedNow))
        #expect(entry.note?.hasPrefix("Imported offline") == true)
    }

    @Test func importMasksIdentityAndForumKeys() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        try workspace.save(profilePage())
        _ = try workspace.run()
        let result = try workspace.text("local/eh/forum/profile.html")
        #expect(!result.localizedCaseInsensitiveContains(fakeUser))
        #expect(!result.contains(fakeMemberID))
        #expect(!result.contains(fakeSession))
        #expect(!result.contains(fakeLogout))
        #expect(result.contains("id=\"profilename\""))
        let violations = FixtureHygiene.structuralViolations(in: result, file: "local/eh/forum/profile.html")
            .filter { !FixtureHygiene.isAllowedInPrivatePage($0) }
        #expect(violations.isEmpty)
    }

    @Test func importUsesCredentialsFromTheEnvironment() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.save(profilePage())
        let environment = ["EH_USERNAME": fakeUser, "EH_IPB_MEMBER_ID": fakeMemberID]
        _ = try workspace.run(environment: environment)
        #expect(!(try workspace.text("local/eh/forum/profile.html")).contains(fakeMemberID))
        // The username and member id join the secrets file.
        let secrets = FixtureHygiene.parseSecretsFile(try String(contentsOf: workspace.secretsFile, encoding: .utf8))
        #expect(secrets.contains(KnownSecret(kind: .word, value: fakeUser)))
        #expect(secrets.contains(KnownSecret(kind: .numeric, value: fakeMemberID)))
    }

    @Test func importRequiresIdentitySecrets() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.save(profilePage())
        let before = try workspace.listing()
        // Nothing known.
        #expect(throws: ImportError.identityUnknown) { try workspace.run() }
        // Only a word, only a numeric.
        #expect(throws: ImportError.identityUnknown) { try workspace.run(environment: ["EH_USERNAME": fakeUser]) }
        #expect(throws: ImportError.identityUnknown) { try workspace.run(environment: ["EH_IPB_MEMBER_ID": fakeMemberID]) }
        #expect(try workspace.listing() == before)
    }

    @Test func importRefusesWebArchive() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        try workspace.save(bytes: Array("bplist00".utf8) + Array("<html>".utf8) + [0, 1, 2])
        let before = try workspace.listing()
        #expect(throws: ImportError.unsupportedFormat) { try workspace.run() }
        // Not HTML at all, and too large.
        try workspace.save("just text")
        #expect(throws: ImportError.unsupportedFormat) { try workspace.run() }
        try workspace.save("<html>" + String(repeating: "a", count: 5 * 1024 * 1024))
        #expect(throws: ImportError.unsupportedFormat) { try workspace.run() }
        #expect(try workspace.listing() == before)
    }

    @Test func importRefusesNonUTF8() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        try workspace.save(bytes: Array("<HTML><div id=\"profilename\">x".utf8) + [0xFF, 0xFE] + Array("</div></HTML>".utf8))
        #expect(throws: ImportError.notUTF8) { try workspace.run() }
        #expect(!workspace.exists("local"))
    }

    @Test func importRefusesPagesWithoutProfileName() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        try workspace.save("<html><head><title>Just a moment...</title></head><body><div id=\"challenge-form\"></div></body></html>")
        #expect(throws: ImportError.notAProfilePage) { try workspace.run() }
        #expect(!workspace.exists("local"))
    }

    @Test func importRefusesUnknownTargetPath() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        try workspace.save(profilePage())
        #expect(throws: ImportError.unknownTarget("eh/list/front.html")) { try workspace.run(as: "eh/list/front.html") }
        #expect(throws: ImportError.unknownTarget("eh/list/favorites.html")) { try workspace.run(as: "eh/list/favorites.html") }
        #expect(!workspace.exists("local"))
    }

    @Test func importIsIdempotent() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        try workspace.save(profilePage())
        _ = try workspace.run()
        let page = try workspace.bytes("local/eh/forum/profile.html")
        let manifest = try workspace.bytes(PrivateFixtures.manifestPath)
        let secrets = try Data(contentsOf: workspace.secretsFile)
        _ = try workspace.run()
        #expect(try workspace.bytes("local/eh/forum/profile.html") == page)
        #expect(try workspace.bytes(PrivateFixtures.manifestPath) == manifest)
        #expect(try Data(contentsOf: workspace.secretsFile) == secrets)
    }

    @Test func importKeepsOtherLocalEntries() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        try workspace.save(profilePage())
        let other = FixtureEntry(
            path: "local/eh/list/favorites.html", site: .eh, source: .captured, method: "GET",
            url: "https://e-hentai.org/favorites.php", status: 200, capturedAt: "2026-11-04T00:00:00Z"
        )
        try FileManager.default.createDirectory(
            at: workspace.root.appending(path: "local/eh/list"), withIntermediateDirectories: true
        )
        try Data("<p>fav</p>".utf8).write(to: workspace.root.appending(path: other.path))
        try JSONEncoder().encode(FixtureManifest(entries: [other]))
            .write(to: workspace.root.appending(path: PrivateFixtures.manifestPath))
        _ = try workspace.run()
        let entries = try JSONDecoder().decode(
            FixtureManifest.self, from: workspace.bytes(PrivateFixtures.manifestPath)
        ).entries
        #expect(entries.map(\.path) == ["local/eh/forum/profile.html", "local/eh/list/favorites.html"])
        #expect(try workspace.text("local/eh/list/favorites.html") == "<p>fav</p>")
    }

    @Test func discoveredNicknameJoinsTheSecretsFile() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        let nickname = "QuillFox"
        try workspace.save(profilePage(nickname: nickname))
        _ = try workspace.run()
        let secrets = FixtureHygiene.parseSecretsFile(try String(contentsOf: workspace.secretsFile, encoding: .utf8))
        #expect(secrets.contains(KnownSecret(kind: .word, value: nickname)))
        #expect(secrets.contains(KnownSecret(kind: .word, value: fakeUser)))
        #expect(secrets.contains(KnownSecret(kind: .numeric, value: fakeMemberID)))
        #expect(!(try workspace.text("local/eh/forum/profile.html")).localizedCaseInsensitiveContains(nickname))
    }

    @Test func importRefusesWhenNoKnownNumericIsTheMemberIDInThePage() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        // A numeric that is not in the page (an apiuid, say) does not count as the member id.
        try workspace.knowIdentity(memberID: "1234567")
        try workspace.save(profilePage())
        let before = try workspace.listing()
        let secretsBefore = try Data(contentsOf: workspace.secretsFile)
        #expect(throws: ImportError.identityUnknown) { try workspace.run() }
        #expect(try workspace.listing() == before)
        #expect(try Data(contentsOf: workspace.secretsFile) == secretsBefore)
        // Appearing outside a showuser link does not count either.
        try workspace.save(profilePage().replacingOccurrences(of: "showuser=\(fakeMemberID)", with: "x=1234567"))
        #expect(throws: ImportError.identityUnknown) { try workspace.run() }
    }

    @Test func profileNameVariantsAreEitherMaskedOrRefused() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        let nickname = "QuillFox"
        let link = "<a href=\"index.php?showuser=\(fakeMemberID)\">me</a>"
        // Refused: no div with id=profilename, whatever else the page says about it.
        for marker in [
            "<h1 id=profilename>\(nickname)</h1>", "<div data-id=\"profilename\">\(nickname)</div>",
            "<div id=\"profilename\"> <font size=\"4\"> </font> </div><p>profilename</p>",
        ] {
            try workspace.save("<html><body>\(marker)\(link)</body></html>")
            #expect(throws: ImportError.notAProfilePage) { try workspace.run() }
            #expect(!workspace.exists("local"))
        }
        // Accepted, and the name is masked: case, quote, attribute order and nesting variants.
        for marker in [
            "<DIV ID=\"PROFILENAME\">\(nickname)</DIV>", "<div id=\"profilename\">  \(nickname.uppercased()) </div>",
            "<div id='profilename' class=\"x\">\(nickname)</div>", "<div class=\"x\" id=\"profilename\">\(nickname)</div>",
            "<div id=\"profilename\"><b>\(nickname)</b></div>",
        ] {
            try workspace.save("<html><body>\(marker)<p>Hi \(nickname)</p>\(link)</body></html>")
            _ = try workspace.run()
            let result = try workspace.text("local/eh/forum/profile.html")
            #expect(!result.localizedCaseInsensitiveContains(nickname))
        }
    }

    @Test func nicknameInsideNestedFontIsDiscoveredAndMasked() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        try workspace.save(
            "<html><body><td class=\"row1\"><div id=\"profilename\" style=\"font-size:16px\">"
                + "<font size=\"4\">Fake Nick</font></div><br><div>Fake Nick wrote</div>"
                + "<a href=\"index.php?showuser=\(fakeMemberID)\">me</a></td></body></html>"
        )
        _ = try workspace.run()
        let secrets = FixtureHygiene.parseSecretsFile(try String(contentsOf: workspace.secretsFile, encoding: .utf8))
        #expect(secrets.contains(KnownSecret(kind: .word, value: "Fake Nick")))
        let result = try workspace.text("local/eh/forum/profile.html")
        #expect(!result.contains("Fake"))
        #expect(!result.contains("Nick"))
        #expect(result.contains("<font size=\"4\">"))
        #expect(result.contains("id=\"profilename\""))
    }

    @Test func nicknameAfterOtherAttributesAndWithEntitiesIsDiscovered() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        try workspace.save(
            "<html><div class=\"a\" style=\"x\" id=\"profilename\"><font>Tom &amp; <i>Jerry</i></font></div>"
                + "<a href=\"index.php?showuser=\(fakeMemberID)\">me</a></html>"
        )
        _ = try workspace.run()
        let secrets = FixtureHygiene.parseSecretsFile(try String(contentsOf: workspace.secretsFile, encoding: .utf8))
        #expect(secrets.contains(KnownSecret(kind: .word, value: "Tom & Jerry")))
        #expect(!(try workspace.text("local/eh/forum/profile.html")).contains("Jerry"))
    }

    @Test func emptyNestedProfileNameIsNotAProfilePage() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        try workspace.save(
            "<html><div id=\"profilename\"><font size=\"4\"> \n </font></div>"
                + "<a href=\"index.php?showuser=\(fakeMemberID)\">me</a></html>"
        )
        #expect(throws: ImportError.notAProfilePage) { try workspace.run() }
        #expect(!workspace.exists("local"))
    }

    @Test func namePiecesAreCollectedOnlyWhenTheWholeNameIsSplitAndLongEnough() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        let link = "<a href=\"index.php?showuser=\(fakeMemberID)\">me</a>"
        // Split by markup: "The" is too short to keep, "Great" is kept.
        try workspace.save("<html><div id=\"profilename\">The <b>Great</b></div>\(link)</html>")
        _ = try workspace.run()
        let secrets = FixtureHygiene.parseSecretsFile(try String(contentsOf: workspace.secretsFile, encoding: .utf8))
        #expect(secrets.contains(KnownSecret(kind: .word, value: "Great")))
        #expect(!secrets.contains(KnownSecret(kind: .word, value: "The")))
        #expect(!(try workspace.text("local/eh/forum/profile.html")).contains("Great"))
    }

    @Test func wholeNameInOneFontIsCollectedWithoutPieces() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        try workspace.save(
            "<html><div id=\"profilename\"><font size=\"4\">Wild Marmot</font></div>"
                + "<a href=\"index.php?showuser=\(fakeMemberID)\">me</a></html>"
        )
        _ = try workspace.run()
        let secrets = FixtureHygiene.parseSecretsFile(try String(contentsOf: workspace.secretsFile, encoding: .utf8))
        #expect(secrets.contains(KnownSecret(kind: .word, value: "Wild Marmot")))
        #expect(!secrets.contains(KnownSecret(kind: .word, value: "Wild")))
        #expect(!secrets.contains(KnownSecret(kind: .word, value: "Marmot")))
    }

    @Test func overlongProfileNameMarkupIsNotANameAndManyUnclosedOnesAreFast() throws {
        let workspace = try ImportWorkspace()
        defer { workspace.remove() }
        try workspace.knowIdentity()
        let tooLong = String(repeating: "x", count: 257)
        try workspace.save("<html><div id=\"profilename\">\(tooLong)</div></html>")
        #expect(throws: ImportError.notAProfilePage) { try workspace.run() }
        // About 1 MB of unclosed elements: must not take quadratic time.
        let unclosed = String(repeating: "<div id=\"profilename\">abc ", count: 40_000)
        try workspace.save("<html>\(unclosed)</html>")
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(throws: ImportError.notAProfilePage) { try workspace.run() }
        }
        #expect(elapsed < .seconds(5))
    }
}
