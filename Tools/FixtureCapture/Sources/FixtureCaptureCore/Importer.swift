import EHFixtures
import EHModels
import Foundation

/// The pages that are imported offline from a file the user saved in their own browser instead of being captured.
public enum ImportableFixtures {
    /// Fixture paths (plan paths, before `PrivateFixtures.storedPath`) `importFixture` accepts as `--as`. All of them
    /// are in `PrivateFixtures.paths`: an imported page only ever lives under `local/`.
    public static let paths: Set<String> = ["eh/forum/profile.html"]

    /// The URL recorded in the manifest entry of `path`: the real one holds the account's member id, so a
    /// placeholder stands in for it.
    public static func placeholderURL(for path: String) -> String {
        "https://forums.e-hentai.org/index.php?showuser=1111111"
    }
}

/// Why `importFixture` stored nothing. Cases carry no page content.
public enum ImportError: Error, Equatable {
    /// `--as` is not in `ImportableFixtures.paths`.
    case unknownTarget(String)
    /// A web archive or binary property list, not HTML, or larger than 5 MB.
    case unsupportedFormat
    /// The page is not valid UTF-8.
    case notUTF8
    /// No `<div id="profilename">name</div>` (the shape nickname discovery reads): a challenge or login page, or a
    /// layout whose name could not be found and masked.
    case notAProfilePage
    /// The environment and the secrets file know no word secret, or no numeric one that shows in the page's
    /// `showuser=` links (the member id), so the account's identity could not be masked reliably.
    case identityUnknown
}

/// What `importFixture` stored.
public struct ImportOutcome: Sendable, Equatable {
    /// Where the page is stored, relative to the fixture root (`local/eh/forum/profile.html`).
    public var storedPath: String
    /// `SecretSet.warnings`; never a value.
    public var warnings: [String]
}

private let maximumImportBytes = 5 * 1024 * 1024

/// Sanitizes a page the user saved in their own browser and stores it as a private fixture under `local/`, with its
/// entry in `local/manifest.local.json`. Sends nothing. Checks, in order: the target path, the file format, UTF-8,
/// the profile marker, the known identity (at least one numeric and one word secret from `environment` and
/// `secretsFile`); then removes personal data as a capture does (the nickname in `#profilename` becomes a word secret
/// and joins the secrets file), passes the shared `FixtureGate` and writes through `FixtureWriter.add`.
/// - Throws: `ImportError`, `SanitizeError`, `FixtureWriterError`, file system errors. Nothing is written on a throw
///   before the gate; none carries page content.
public func importFixture(
    file: URL,
    as path: String,
    fixturesRoot: URL,
    secretsFile: URL,
    environment: [String: String],
    now: Date = Date()
) throws -> ImportOutcome {
    guard ImportableFixtures.paths.contains(path), PrivateFixtures.isPrivate(path) else {
        throw ImportError.unknownTarget(path)
    }
    if let size = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? Int,
       size > maximumImportBytes {
        throw ImportError.unsupportedFormat
    }
    let data = try Data(contentsOf: file)
    let signature = Data("bplist".utf8)
    guard data.count <= maximumImportBytes, !data.starts(with: signature),
          String(decoding: data, as: UTF8.self).range(of: "<html", options: .caseInsensitive) != nil else {
        throw ImportError.unsupportedFormat
    }
    guard let text = String(validating: data, as: UTF8.self) else { throw ImportError.notUTF8 }
    // The same rule that discovers the nickname: a page whose name could not be found would leak it.
    guard !SecretSet.profileNames(in: text).isEmpty else { throw ImportError.notAProfilePage }

    // The same secrets a capture would use: credentials (when set) and the secrets file.
    let credentials = FixtureHygiene.namedCredentialSecrets(environment: environment)
    let extras = FileManager.default.fileExists(atPath: secretsFile.path(percentEncoded: false))
        ? FixtureHygiene.parseSecretsFile(try String(contentsOf: secretsFile, encoding: .utf8)) : []
    var secrets = SecretSet(
        namedCredentials: credentials.map { (name: $0.variable, secret: $0.secret) }, extraSecrets: extras
    )
    let known = Set(secrets.all.map(\.kind))
    guard known.contains(.numeric), known.contains(.word) else { throw ImportError.identityUnknown }
    // The page is the account's own, so a known member id shows in its `showuser=` links. A numeric secret that does
    // not (an apiuid, a tracker number) cannot mask the member id.
    let showsKnownMemberID = secrets.all.contains { secret in
        secret.kind == .numeric && text.range(
            of: "showuser=\(NSRegularExpression.escapedPattern(for: secret.value))(?![0-9])", options: .regularExpression
        ) != nil
    }
    guard showsKnownMemberID else { throw ImportError.identityUnknown }

    secrets.discover(in: text)
    guard secrets.ipv4InOrder.count <= IPv4StandIns.capacity else { throw SanitizeError.tooManyIPAddresses }
    let sanitizer = Sanitizer(secrets: secrets)
    let body = sanitizer.sanitize(text)
    guard !sanitizer.ranOutOfStandIns else { throw SanitizeError.tooManyIPAddresses }

    let entry = FixtureEntry(
        path: path, site: .eh, source: .captured, method: "GET", url: ImportableFixtures.placeholderURL(for: path),
        status: 200, contentType: "text/html; charset=UTF-8", setCookieNames: [],
        capturedAt: Date.ISO8601FormatStyle(timeZone: .gmt).format(now),
        note: "Imported offline from a page the user saved in their own browser; the showuser value is a placeholder."
    )
    try FixtureWriter(fixturesRoot: fixturesRoot, secretsFile: secretsFile)
        .add(SanitizedCapture(entry: entry, body: Data(body.utf8)), secrets: secrets)
    return ImportOutcome(storedPath: PrivateFixtures.storedPath(path), warnings: secrets.warnings)
}
