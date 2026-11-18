import EHFixtures
import Foundation

/// What `resanitizeFixtures` did.
public struct ResanitizeOutcome: Sendable, Equatable {
    /// Fixtures read and sanitized again.
    public var checked: Int
    /// Fixture paths (relative to the fixture root) whose body or manifest entry changed, sorted. Paths only.
    public var changed: [String]
    /// `SecretSet.warnings`: what could not be fully sanitized; never a value.
    public var warnings: [String]
}

/// Sanitizes the fixtures already on disk again with the current rules, without any request: after the rules get
/// stricter, existing fixtures are fixed offline instead of captured again. Reads the captured fixtures listed in
/// `manifest.json`, the private ones listed in `local/manifest.local.json` and, with `includeConstructed`, the
/// constructed ones; discovers secrets in the captured and private ones as a capture does (never in constructed ones, which hold made-up
/// values only; those are rewritten with the exemptions of `FixtureHygiene.constructedExemptions` kept) (on top of the credentials in `environment`, if any,
/// and the secrets file); then rewrites only what changed. Nothing is written unless every fixture and both
/// manifests pass the same checks as `FixtureWriter` (including `HomePageCheck` on `home.php`), less what
/// `FixtureHygiene.constructedExemptions` allows constructed fixtures, and unless the captured, non-private ones pass
/// `OwnContentCheck` against the identity (the words among the secrets, and the member id in `environment`). Manifest entries keep every field, `capturedAt`
/// included; a manifest is only rewritten when one of its entries' URL or `Location` changed. Running it again changes
/// nothing: masked text is masked already. A list page with a "Filtered" line (`filteredlist`) cannot be fixed here:
/// it must be captured again with filters disabled.
/// - Throws: `FixtureWriterError.invalidPath` for an entry that is not a regular file inside the root,
///   `FixtureWriterError.hygiene` when the result still fails a check, `SanitizeError` (`.ownContent` when a public
///   page shows the identity or cannot be checked for it), file system errors.
public func resanitizeFixtures(
    fixturesRoot: URL,
    secretsFile: URL,
    environment: [String: String],
    includeConstructed: Bool
) throws -> ResanitizeOutcome {
    let manifestURL = fixturesRoot.appending(path: "manifest.json")
    let localManifestURL = fixturesRoot.appending(path: PrivateFixtures.manifestPath)
    let manifest = try FixtureWriter.readManifest(at: manifestURL)
    let localManifest = try FixtureWriter.readManifest(at: localManifestURL)

    // The entries to sanitize again, each with the manifest it belongs to (false: manifest.json, true: local).
    let selected: [(entry: FixtureEntry, isLocal: Bool)] =
        manifest.entries.filter { $0.source == .captured || (includeConstructed && $0.source == .constructed) }
            .map { ($0, false) }
            + localManifest.entries.map { ($0, true) }
    var bodies: [String] = []
    for (entry, _) in selected {
        let url = fixturesRoot.appending(path: entry.path)
        guard isInsideRoot(entry.path), FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
              FixtureWriter.isRegularFileOrNothing(url) else {
            throw FixtureWriterError.invalidPath(entry.path)
        }
        guard let body = String(validating: try Data(contentsOf: url), as: UTF8.self) else {
            throw SanitizeError.notUTF8(entry.path)
        }
        bodies.append(body)
    }

    // The same secrets a capture would use: credentials (when set), the secrets file, and what the texts reveal.
    // Named, so the username and member id (when set) join the secrets file.
    let credentials = FixtureHygiene.namedCredentialSecrets(environment: environment)
    let extras = FileManager.default.fileExists(atPath: secretsFile.path(percentEncoded: false))
        ? FixtureHygiene.parseSecretsFile(try String(contentsOf: secretsFile, encoding: .utf8)) : []
    var secrets = SecretSet(
        namedCredentials: credentials.map { (name: $0.variable, secret: $0.secret) }, extraSecrets: extras
    )
    // Constructed fixtures are made up by definition: an identity "discovered" in one is fake, so they only take
    // part in replacing secrets, never in finding them.
    for ((entry, _), body) in zip(selected, bodies) where entry.source != .constructed {
        secrets.discover(in: body)
        if let url = entry.url { secrets.discover(in: url) }
        if let location = entry.location { secrets.discover(in: location) }
    }
    guard secrets.ipv4InOrder.count <= IPv4StandIns.capacity else { throw SanitizeError.tooManyIPAddresses }
    // As a capture does, before anything is masked: a name that joined the identity after these pages were captured
    // (another account's username, a former name added to the secrets file) was never masked, and the public gallery
    // id would lead back to it. Names masked before (`aaaa…`) no longer match.
    let identity = OwnIdentity(
        secrets: secrets,
        memberIDs: credentials.filter { $0.variable == CaptureCredentials.memberIDVariable }.map(\.secret.value)
    )
    let checked = zip(selected, bodies).filter { !$0.0.isLocal && $0.0.entry.source != .constructed }
        .map { (path: $0.0.entry.path, body: Data($0.1.utf8)) }
    let ownContent = OwnContentCheck.findings(in: checked, identity: identity)
    guard ownContent.isEmpty else { throw SanitizeError.ownContent(ownContent) }
    let sanitizer = Sanitizer(secrets: secrets)

    var changed: [String] = []
    var newBodies: [(path: String, body: String)] = []
    var entryUpdates: [String: FixtureEntry] = [:]
    for ((entry, _), body) in zip(selected, bodies) {
        // Exemptions belong to constructed fixtures only, as in `FixtureHygiene.isExempt`.
        let exempt = entry.source == .constructed ? FixtureHygiene.constructedExemptions[entry.path] ?? [] : []
        let sanitized = sanitizer.sanitize(body, exempting: exempt)
        var updated = entry
        updated.url = entry.url.map(sanitizer.sanitize)
        updated.location = entry.location.map(sanitizer.sanitize)
        if sanitized != body { newBodies.append((entry.path, sanitized)) }
        if updated != entry { entryUpdates[entry.path] = updated }
        if sanitized != body || updated != entry { changed.append(entry.path) }
    }
    guard !sanitizer.ranOutOfStandIns else { throw SanitizeError.tooManyIPAddresses }

    func updating(_ manifest: FixtureManifest) -> FixtureManifest {
        FixtureManifest(entries: manifest.entries.map { entryUpdates[$0.path] ?? $0 })
    }
    let newManifest = updating(manifest)
    let newLocalManifest = updating(localManifest)
    let rewritesManifest = newManifest != manifest
    let rewritesLocalManifest = newLocalManifest != localManifest
    let manifestData = try FixtureWriter.encode(newManifest)
    let localManifestData = try FixtureWriter.encode(newLocalManifest)

    // Every fixture as it will be on disk, and both manifests, pass the shared gate before writing. A constructed
    // fixture may break what `FixtureHygiene.constructedExemptions` allows it; a captured or private one never.
    let constructed = Set(selected.filter { $0.entry.source == .constructed }.map(\.entry.path))
    let rewritten = Dictionary(newBodies.map { ($0.path, $0.body) }, uniquingKeysWith: { first, _ in first })
    var texts = zip(selected, bodies).map { item, body in
        GateText(file: item.entry.path, text: rewritten[item.entry.path] ?? body, isConstructed: constructed.contains(item.entry.path))
    }
    texts.append(GateText(file: "manifest.json", text: String(decoding: manifestData, as: UTF8.self)))
    if !localManifest.entries.isEmpty || FileManager.default.fileExists(atPath: localManifestURL.path(percentEncoded: false)) {
        texts.append(GateText(file: PrivateFixtures.manifestPath, text: String(decoding: localManifestData, as: UTF8.self)))
    }
    try FixtureGate.check(texts, secrets: Array(secrets.all))

    for (path, body) in newBodies {
        try Data(body.utf8).write(to: fixturesRoot.appending(path: path), options: .atomic)
    }
    if rewritesManifest { try manifestData.write(to: manifestURL, options: .atomic) }
    if rewritesLocalManifest { try localManifestData.write(to: localManifestURL, options: .atomic) }
    // Newly discovered values join the secrets file, as after a capture; with nothing new it is left alone.
    let persistable = secrets.persistable
    if !persistable.isSubset(of: Set(extras)) {
        let sorted = persistable.sorted { ($0.kind.rawValue, $0.value) < ($1.kind.rawValue, $1.value) }
        try FixtureWriter.writePrivately(Data(FixtureHygiene.renderSecretsFile(sorted).utf8), to: secretsFile)
    }
    return ResanitizeOutcome(checked: selected.count, changed: changed.sorted(), warnings: secrets.warnings)
}

/// A relative path without empty, `.` or `..` components, so it cannot leave the fixture root.
private func isInsideRoot(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !path.hasPrefix("/") && !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}
