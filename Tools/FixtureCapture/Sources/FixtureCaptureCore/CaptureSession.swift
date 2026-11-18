import EHFixtures
import EHModels
import Foundation

/// Everything one capture run needs. `environment` holds the credentials, so printing, debug-printing or dumping a
/// config shows the sites, the names of the set capture variables and the paths, never a value.
public struct CaptureSessionConfig: Sendable {
    /// Sites to capture, in order.
    public var sites: [EHSite]
    /// Where the credentials are read from (see `CaptureCredentials`).
    public var environment: [String: String]
    public var targets: CaptureTargets
    /// Directory holding `manifest.json`.
    public var fixturesRoot: URL
    /// The local secrets file: read for extra secrets, then rewritten with the discovered ones.
    public var secretsFile: URL

    public init(
        sites: [EHSite],
        environment: [String: String],
        targets: CaptureTargets,
        fixturesRoot: URL,
        secretsFile: URL
    ) {
        self.sites = sites
        self.environment = environment
        self.targets = targets
        self.fixturesRoot = fixturesRoot
        self.secretsFile = secretsFile
    }

    private var setVariables: [String] {
        CaptureCredentials.environmentKeys.filter {
            !(environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
}

extension CaptureSessionConfig: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "CaptureSessionConfig(sites: \(sites.map(\.rawValue)), set: \(setVariables), "
            + "fixturesRoot: \(fixturesRoot.path(percentEncoded: false)), secretsFile: \(secretsFile.path(percentEncoded: false)))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "sites": sites.map(\.rawValue), "set": setVariables,
                "fixturesRoot": fixturesRoot.path(percentEncoded: false),
                "secretsFile": secretsFile.path(percentEncoded: false),
            ],
            displayStyle: .struct
        )
    }
}

/// The outcome of a run that wrote its fixtures.
public struct CaptureSummary: Sendable {
    /// Fixtures written per site; sites without any are absent.
    public var written: [EHSite: Int]
    public var skipped: [SkippedStep]
    /// `CaptureReport.warnings` (what a step worked around), then `SecretSet.warnings` (what could not be fully
    /// sanitized); never a value.
    public var warnings: [String]
    /// Of `written`, the private fixtures kept under the git-ignored `local/` (`PrivateFixtures`), per site.
    public var localOnly: [EHSite: Int] = [:]
    /// Old copies of private fixtures at checked-in paths that the writer deleted (`FixtureWriteOutcome`).
    public var removedLeftovers: [String] = []
}

/// One capture run: checks the credentials (before any request), captures `config.sites`, sanitizes every capture
/// against the credentials, the existing secrets file and what the pages reveal, and replaces the captured fixtures
/// of those sites. A run that stops early, or whose output fails a hygiene check, writes nothing.
/// - Throws: `CredentialError` before any request; an error reading the secrets file, also before any request;
///   `CaptureAbort` (including a skipped required step); `SanitizeError`; `FixtureWriterError`; file system errors while writing.
public func runCaptureSession(_ config: CaptureSessionConfig, transport: any CaptureTransport) async throws -> CaptureSummary {
    let credentials = try CaptureCredentials(environment: config.environment, sites: Set(config.sites))
    // Read before capturing, so an unreadable file costs no requests.
    let extraSecrets: [KnownSecret]
    if FileManager.default.fileExists(atPath: config.secretsFile.path(percentEncoded: false)) {
        extraSecrets = FixtureHygiene.parseSecretsFile(try String(contentsOf: config.secretsFile, encoding: .utf8))
    } else {
        extraSecrets = []
    }

    let report = try await Capturer(transport: transport, credentials: credentials, targets: config.targets)
        .run(sites: config.sites)
    // A skipped step that would have saved a fixture outside the optional set leaves the set incomplete: stop before
    // writing anything. Steps that save nothing (the cover download) have no `savedPath` and are not required.
    for site in config.sites {
        let optional = CapturePlan.optionalFixturePaths(for: site)
        let missing = report.skipped.first { skipped in
            skipped.savedPath.map { $0.hasPrefix("\(site.rawValue)/") && !optional.contains($0) } ?? false
        }
        if let path = missing?.savedPath {
            throw CaptureAbort.requiredStepSkipped(site: site, fixturePath: path)
        }
    }
    let (captures, secrets) = try sanitizeCaptures(report.captures, credentials: credentials, extraSecrets: extraSecrets)
    let outcome = try FixtureWriter(fixturesRoot: config.fixturesRoot, secretsFile: config.secretsFile)
        .write(captures, replacingSites: Set(config.sites), secrets: secrets)

    var written: [EHSite: Int] = [:]
    for capture in captures {
        written[capture.entry.site, default: 0] += 1
    }
    return CaptureSummary(
        written: written, skipped: report.skipped, warnings: report.warnings + secrets.warnings,
        localOnly: outcome.localOnly, removedLeftovers: outcome.removedLeftovers
    )
}
