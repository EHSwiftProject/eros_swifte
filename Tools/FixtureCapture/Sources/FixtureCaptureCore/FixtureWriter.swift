import Darwin
import EHFixtures
import EHModels
import Foundation

/// Why `FixtureWriter` wrote nothing.
public enum FixtureWriterError: Error, Equatable {
    /// A body or a manifest about to be written failed a hygiene check.
    case hygiene([HygieneViolation])
    /// A capture that may not be written, or a fixture that may not be replaced or removed, by path. A path must be
    /// `<site>/…` (relative, without empty, `.` or `..` components, under its own site's directory), or
    /// `local/<site>/…` for a private one, and name a regular file or nothing yet; new paths must differ ignoring
    /// case; a new capture must be `.captured` and of a site being replaced. `local` itself must be a directory.
    case invalidPath(String)
}

/// What `FixtureWriter.write` did besides writing the checked-in fixtures and the manifest.
public struct FixtureWriteOutcome: Sendable, Equatable {
    /// Private fixtures (`PrivateFixtures`) written under `local/`, per site; sites without any are absent.
    public var localOnly: [EHSite: Int] = [:]
    /// Copies of private fixtures at their old checked-in paths (from runs before they became private) that were
    /// deleted, sorted. Paths only.
    public var removedLeftovers: [String] = []

    public init(localOnly: [EHSite: Int] = [:], removedLeftovers: [String] = []) {
        self.localOnly = localOnly
        self.removedLeftovers = removedLeftovers
    }
}

/// Writes sanitized captures into a fixture root (`eh/`, `ex/`, `constructed/`, `manifest.json`, and the git-ignored
/// `local/` with `local/manifest.local.json` for `PrivateFixtures`) and the discovered secrets into the local
/// secrets file. Nothing is written unless every body and both resulting manifests pass both hygiene checks, and
/// every `home.php` also passes `HomePageCheck`.
public struct FixtureWriter: Sendable {
    private let fixturesRoot: URL
    private let secretsFile: URL

    /// - Parameters:
    ///   - fixturesRoot: Directory holding `manifest.json`, e.g. `Packages/ErosKit/Tests/Fixtures`.
    ///   - secretsFile: The local secrets file, e.g. `.fixture-secrets.local` at the repository root.
    public init(fixturesRoot: URL, secretsFile: URL) {
        self.fixturesRoot = fixturesRoot
        self.secretsFile = secretsFile
    }

    /// Replaces the captured fixtures of `sites` with `captures`: their entries and files are removed, the new ones
    /// written, and constructed fixtures and other sites kept. A private capture (`PrivateFixtures.isPrivate`) is
    /// written to `local/<path>` and listed in `local/manifest.local.json`, never in `manifest.json`; that manifest
    /// is only written when it has entries or already exists. Imported pages (`ImportableFixtures`) already under
    /// `local/` stay, with their entries, whatever the sites. Whatever the sites, a private page at its old
    /// checked-in path must not exist: any such file is deleted and its `manifest.json` entry dropped, and the
    /// outcome lists the paths. Paths are compared ignoring case, as on a default APFS volume. Then writes
    /// `secrets.persistable` to the secrets file with mode 0600; with nothing to persist, the secrets file is left
    /// as it is (or not created). The manifests list entries by path and are encoded the same way every time.
    /// - Throws: `FixtureWriterError` before touching the disk; file system errors while writing.
    @discardableResult
    public func write(
        _ captures: [SanitizedCapture], replacingSites sites: Set<EHSite>, secrets: SecretSet
    ) throws -> FixtureWriteOutcome {
        let localDirectory = fixturesRoot.appending(path: PrivateFixtures.directory)
        guard Self.isDirectoryOrNothing(localDirectory) else {
            throw FixtureWriterError.invalidPath(PrivateFixtures.directory)
        }

        // New captures, each at the path it is stored at.
        var newPaths = Set<String>()
        var stored: [SanitizedCapture] = []
        var outcome = FixtureWriteOutcome()
        for capture in captures {
            let entry = capture.entry
            let path = PrivateFixtures.storedPath(entry.path)
            guard entry.source == .captured, sites.contains(entry.site), Self.isCapturedPath(entry.path, site: entry.site),
                  newPaths.insert(Self.pathKey(path)).inserted,
                  Self.isRegularFileOrNothing(fixturesRoot.appending(path: path)) else {
                throw FixtureWriterError.invalidPath(entry.path)
            }
            var storedEntry = entry
            storedEntry.path = path
            stored.append(SanitizedCapture(entry: storedEntry, body: capture.body))
            if path != entry.path { outcome.localOnly[entry.site, default: 0] += 1 }
        }
        let isLocal: (FixtureEntry) -> Bool = { $0.path.hasPrefix(PrivateFixtures.directory + "/") }

        // manifest.json: the replaced sites' captured entries go, and so does any entry for a private page.
        let manifestURL = fixturesRoot.appending(path: "manifest.json")
        let existing = try Self.readManifest(at: manifestURL)
        let replaced = existing.entries.filter { entry in
            (entry.source == .captured && sites.contains(entry.site)) || PrivateFixtures.isPrivate(entry.path)
        }
        for entry in replaced {
            guard Self.isCapturedPath(entry.path, site: entry.site),
                  Self.isRegularFileOrNothing(fixturesRoot.appending(path: entry.path)) else {
                throw FixtureWriterError.invalidPath(entry.path)
            }
        }
        let replacedKeys = Set(replaced.map { Self.pathKey($0.path) })
        let kept = existing.entries.filter { entry in
            !replacedKeys.contains(Self.pathKey(entry.path)) && !newPaths.contains(Self.pathKey(entry.path))
        }
        let manifest = FixtureManifest(entries: (kept + stored.map(\.entry).filter { !isLocal($0) }).sorted { $0.path < $1.path })
        let manifestData = try Self.encode(manifest)

        // local/manifest.local.json: the replaced sites' entries go; other sites' stay. So do the pages imported
        // offline (`ImportableFixtures`): a capture never produces them, so a recapture must not delete them.
        let localManifestURL = fixturesRoot.appending(path: PrivateFixtures.manifestPath)
        let existingLocal = try Self.readManifest(at: localManifestURL)
        let localReplaced = existingLocal.entries.filter { sites.contains($0.site) && !Self.isImportedPath($0.path) }
        for entry in localReplaced {
            guard Self.isLocalPath(entry.path, site: entry.site),
                  Self.isRegularFileOrNothing(fixturesRoot.appending(path: entry.path)) else {
                throw FixtureWriterError.invalidPath(entry.path)
            }
        }
        let localReplacedKeys = Set(localReplaced.map { Self.pathKey($0.path) })
        let localKept = existingLocal.entries.filter {
            !localReplacedKeys.contains(Self.pathKey($0.path)) && !newPaths.contains(Self.pathKey($0.path))
        }
        let localManifest = FixtureManifest(entries: (localKept + stored.map(\.entry).filter(isLocal)).sorted { $0.path < $1.path })
        let writesLocalManifest = !localManifest.entries.isEmpty
            || FileManager.default.fileExists(atPath: localManifestURL.path(percentEncoded: false))
        let localManifestData = try Self.encode(localManifest)

        // Private pages at their old checked-in paths, on any site, with or without a manifest entry.
        let leftovers = PrivateFixtures.paths.filter { path in
            let url = fixturesRoot.appending(path: path)
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))) != nil
        }
        for path in leftovers where !Self.isRegularFileOrNothing(fixturesRoot.appending(path: path)) {
            throw FixtureWriterError.invalidPath(path)
        }

        var texts = stored.map { GateText(file: $0.entry.path, text: String(decoding: $0.body, as: UTF8.self)) }
        texts.append(GateText(file: "manifest.json", text: String(decoding: manifestData, as: UTF8.self)))
        if writesLocalManifest {
            texts.append(GateText(file: PrivateFixtures.manifestPath, text: String(decoding: localManifestData, as: UTF8.self)))
        }
        try FixtureGate.check(texts, secrets: Array(secrets.all))

        let manager = FileManager.default
        for capture in stored {
            let url = fixturesRoot.appending(path: capture.entry.path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try capture.body.write(to: url, options: .atomic)
        }
        // Checked above to be regular files or missing; never a directory or a link.
        let removed = (replaced + localReplaced).map(\.path).filter { !newPaths.contains(Self.pathKey($0)) } + leftovers
        for path in Set(removed) {
            let url = fixturesRoot.appending(path: path)
            if manager.fileExists(atPath: url.path(percentEncoded: false)) {
                try manager.removeItem(at: url)
            }
        }
        outcome.removedLeftovers = leftovers.sorted()
        try manifestData.write(to: manifestURL, options: .atomic)
        if writesLocalManifest {
            try manager.createDirectory(at: localDirectory, withIntermediateDirectories: true)
            try localManifestData.write(to: localManifestURL, options: .atomic)
        }

        try persist(secrets)
        return outcome
    }

    /// Adds or replaces one private capture under `local/` and its entry in `local/manifest.local.json`; other
    /// entries and files are kept. `capture.entry.path` is the plan path (`PrivateFixtures.isPrivate`), stored at
    /// `local/<path>` like `write` does. Shares the path checks, the manifest merge and encoding, the gate and the
    /// secrets file with `write`; nothing is written unless the body and the resulting manifest pass the gate.
    /// - Throws: `FixtureWriterError` before touching the disk; file system errors while writing.
    public func add(_ capture: SanitizedCapture, secrets: SecretSet) throws {
        let localDirectory = fixturesRoot.appending(path: PrivateFixtures.directory)
        guard Self.isDirectoryOrNothing(localDirectory) else {
            throw FixtureWriterError.invalidPath(PrivateFixtures.directory)
        }
        let entry = capture.entry
        let path = PrivateFixtures.storedPath(entry.path)
        guard PrivateFixtures.isPrivate(entry.path), entry.source == .captured,
              Self.isLocalPath(path, site: entry.site),
              Self.isRegularFileOrNothing(fixturesRoot.appending(path: path)) else {
            throw FixtureWriterError.invalidPath(entry.path)
        }
        var storedEntry = entry
        storedEntry.path = path

        let localManifestURL = fixturesRoot.appending(path: PrivateFixtures.manifestPath)
        let existingLocal = try Self.readManifest(at: localManifestURL)
        for other in existingLocal.entries where Self.pathKey(other.path) == Self.pathKey(path) {
            // A differently spelled path (case, normalization) is the same file here: it is replaced too.
            guard Self.isLocalPath(other.path, site: other.site),
                  Self.isRegularFileOrNothing(fixturesRoot.appending(path: other.path)) else {
                throw FixtureWriterError.invalidPath(other.path)
            }
        }
        let kept = existingLocal.entries.filter { Self.pathKey($0.path) != Self.pathKey(path) }
        let localManifest = FixtureManifest(entries: (kept + [storedEntry]).sorted { $0.path < $1.path })
        let localManifestData = try Self.encode(localManifest)

        try FixtureGate.check(
            [GateText(file: path, text: String(decoding: capture.body, as: UTF8.self)),
             GateText(file: PrivateFixtures.manifestPath, text: String(decoding: localManifestData, as: UTF8.self))],
            secrets: Array(secrets.all)
        )

        let url = fixturesRoot.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try capture.body.write(to: url, options: .atomic)
        try localManifestData.write(to: localManifestURL, options: .atomic)
        try persist(secrets)
    }

    /// Writes `secrets.persistable` to the secrets file with mode 0600; with nothing to persist, the file is left as
    /// it is (or not created).
    private func persist(_ secrets: SecretSet) throws {
        guard !secrets.persistable.isEmpty else { return }
        let persistable = secrets.persistable.sorted { ($0.kind.rawValue, $0.value) < ($1.kind.rawValue, $1.value) }
        try Self.writePrivately(Data(FixtureHygiene.renderSecretsFile(persistable).utf8), to: secretsFile)
    }

    /// Whether `path` (as stored, under `local/`) is a page imported offline, which a recapture keeps.
    private static func isImportedPath(_ path: String) -> Bool {
        ImportableFixtures.paths.contains { pathKey(PrivateFixtures.storedPath($0)) == pathKey(path) }
    }

    /// How paths are compared: ignoring case and Unicode normalization, as a default (case-insensitive) APFS volume
    /// does, so "eh/A.html" and "eh/a.html" are one file.
    static func pathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// True when nothing is at `url` yet, or a regular file (not a directory, link or other special file).
    static func isRegularFileOrNothing(_ url: URL) -> Bool {
        // attributesOfItem does not follow symbolic links.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)) else {
            return !FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                && (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))) == nil
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    /// A captured fixture lives under its own site's directory: `<site>/…`, relative, with no empty, `.` or `..`
    /// component, so it can neither escape the root nor land outside the directories the hygiene tests scan.
    private static func isCapturedPath(_ path: String, site: EHSite) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count >= 2 && components[0] == site.rawValue
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// A private fixture lives under `local/<site>/…`, with the same rules for the rest of the path.
    private static func isLocalPath(_ path: String, site: EHSite) -> Bool {
        let prefix = PrivateFixtures.directory + "/"
        return path.hasPrefix(prefix) && isCapturedPath(String(path.dropFirst(prefix.count)), site: site)
    }

    /// True when nothing is at `url` yet, or a real directory (not a link to one).
    private static func isDirectoryOrNothing(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)) else {
            return !FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                && (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))) == nil
        }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    /// The manifest at `url`, or an empty one when there is no file.
    static func readManifest(at url: URL) throws -> FixtureManifest {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return FixtureManifest() }
        return try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: url))
    }

    /// Pretty-printed with sorted keys and unescaped slashes, ending in a newline: the same bytes for the same
    /// manifest.
    static func encode(_ manifest: FixtureManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Writes `data` to `url` without the file ever having other permissions than 0600: a new temporary file
    /// `<name>.<UUID>.tmp` in the same directory (git-ignored with `.fixture-secrets.local*`) is created with mode
    /// 0600, filled, and renamed over `url`. A stale file at `url`, whatever its
    /// mode, is replaced rather than reused.
    static func writePrivately(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appending(path: "\(url.lastPathComponent).\(UUID().uuidString).tmp")
            .path(percentEncoded: false)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var renamed = false
        defer { if !renamed { unlink(temporary) } }
        do {
            // The umask can only clear bits; set the mode explicitly anyway.
            guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw posixError()
                    }
                    offset += written
                }
            }
        } catch {
            close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else { throw posixError() }
        guard rename(temporary, url.path(percentEncoded: false)) == 0 else { throw posixError() }
        renamed = true
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
