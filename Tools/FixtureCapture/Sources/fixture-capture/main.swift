import EHFixtures
import EHModels
import EHNetwork
import EHParsing
import FixtureCaptureCore
import Foundation

// fixture-capture: captures read-only E-Hentai/ExHentai fixtures. Output names variables, paths, fixture paths and
// statuses only; never a cookie, credential or value found in a page.

/// Exit statuses, as documented in README.md.
private enum ExitStatus {
    static let success: Int32 = 0
    /// The capture stopped, or its output was refused; nothing was written.
    static let stopped: Int32 = 1
    /// Bad arguments, credentials or configuration; nothing was sent (probe-sp: also a refused probe).
    static let configuration: Int32 = 2
    /// probe-structure only: a page's structure differs from the M0 sample.
    static let differs: Int32 = 4
}

private let usage = """
    Usage: fixture-capture capture [--sites eh,ex] [--targets PATH] [--output DIR] [--secrets-file PATH] [--dry-run]
           fixture-capture resanitize [--output DIR] [--secrets-file PATH] [--constructed]
           fixture-capture import <FILE> --as eh/forum/profile.html [--output DIR] [--secrets-file PATH]
           fixture-capture probe-structure --site eh|ex --user-agent UA [--output DIR]
           fixture-capture probe-sp --site eh|ex --sp N[,N[,N]]

    capture: captures read-only E-Hentai/ExHentai fixtures with the credentials in the environment.
    resanitize: sends nothing; sanitizes the fixtures already written again with the current rules (after the rules
    got stricter) and rewrites only those that change. Credentials in the environment are used when set.
    import: sends nothing; sanitizes a page you saved in your own browser (HTML source only, not a web archive) and
    stores it under local/ (git-ignored) with its entry in local/manifest.local.json. Delete the saved original after.
    probe-structure: three read-only GETs on one site (front page, its first gallery, that gallery's first image page)
    with the given user agent and no cf_clearance or cf_duid; prints which page structure markers differ from the M0
    samples. Exit 0: all the same; 4: some differ. Nothing is written.
    probe-sp: read-only GETs of uconfig.php on one site, once without an sp cookie and once with each given profile
    number (at most 3; redirects are not followed, so at most 4 HTTP requests), without cf_clearance or cf_duid;
    prints, per request, the sp sent, the status, the profile the page selects, the names of the cookies Set-Cookie
    sets and the sp it sets (a 3xx is such a line too). EH_SP must not be set. Nothing is written.
    Paths are relative to the current directory, which should be the repository root. See
    Tools/FixtureCapture/README.md.

    Options:
      --sites eh,ex        Sites to capture, in this order (default: eh,ex)
      --targets PATH       Capture targets (default: Tools/FixtureCapture/targets.json)
      --output DIR         Fixture root holding manifest.json (default: Packages/ErosKit/Tests/Fixtures)
      --secrets-file PATH  Local secrets file (default: .fixture-secrets.local)
      --dry-run            capture only: print the plan; send nothing and check no credentials
      --site eh|ex         probe-structure and probe-sp: the site to probe (one per run; for probe-structure EH_SP
                           selects its profile)
      --user-agent UA      probe-structure only: the User-Agent to send
      --sp N[,N[,N]]       probe-sp only: 1 to 3 profile numbers, comma-separated, each once
      --as PATH            import only: the fixture the page becomes (eh/forum/profile.html)
      --constructed        resanitize only: also the constructed fixtures
      -h, --help           Show this help
    """

private struct Options {
    enum Command { case capture, resanitize, probe, probeProfiles, importPage }
    var command = Command.capture
    var includeConstructed = false
    var sites: [EHSite] = [.eh, .ex]
    var targets = "Tools/FixtureCapture/targets.json"
    var output = "Packages/ErosKit/Tests/Fixtures"
    var secretsFile = ".fixture-secrets.local"
    var dryRun = false
    var help = false
    var site: EHSite?
    var userAgent: String?
    var profileNumbers: [Int]?
    var importFile: String?
    var importAs: String?
}

/// A usage problem. The message names options, never the values given to them.
private struct UsageError: Error {
    let message: String
}

private func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var remaining = arguments[...]
    guard let command = remaining.popFirst() else { throw UsageError(message: "missing command") }
    if command == "-h" || command == "--help" {
        options.help = true
        return options
    }
    switch command {
    case "capture": options.command = .capture
    case "resanitize": options.command = .resanitize
    case "probe-structure": options.command = .probe
    case "probe-sp": options.command = .probeProfiles
    case "import": options.command = .importPage
    default:
        throw UsageError(
            message: "unknown command; the commands are capture, resanitize, import, probe-structure and probe-sp"
        )
    }

    while let argument = remaining.popFirst() {
        // Only the part before "=" of an option is ever repeated in a message.
        var name = argument
        var inline: String?
        if argument.hasPrefix("-"), let equals = argument.firstIndex(of: "=") {
            name = String(argument[..<equals])
            inline = String(argument[argument.index(after: equals)...])
        }
        func value() throws -> String {
            if let inline {
                guard !inline.isEmpty, !inline.hasPrefix("--") else { throw UsageError(message: "\(name) needs a value") }
                return inline
            }
            // The next option is not a value: "--targets --dry-run" lacks the path.
            guard let next = remaining.first, !next.isEmpty, !next.hasPrefix("--") else {
                throw UsageError(message: "\(name) needs a value")
            }
            remaining.removeFirst()
            return next
        }
        func flag() throws {
            guard inline == nil else { throw UsageError(message: "\(name) takes no value") }
        }
        let captureOnly: Set<String> = ["--sites", "--targets", "--dry-run"]
        if options.command != .capture, captureOnly.contains(name) {
            throw UsageError(message: "\(name) is for capture only")
        }
        if options.command != .probe, name == "--user-agent" {
            throw UsageError(message: "--user-agent is for probe-structure only")
        }
        if options.command != .probe, options.command != .probeProfiles, name == "--site" {
            throw UsageError(message: "--site is for probe-structure and probe-sp only")
        }
        if options.command != .probeProfiles, name == "--sp" {
            throw UsageError(message: "--sp is for probe-sp only")
        }
        if options.command == .probe, name == "--secrets-file" {
            throw UsageError(message: "--secrets-file is not used by probe-structure")
        }
        if options.command == .probeProfiles, name == "--secrets-file" || name == "--output" {
            throw UsageError(message: "\(name) is not used by probe-sp")
        }
        if options.command != .importPage, name == "--as" {
            throw UsageError(message: "--as is for import only")
        }
        if options.command != .resanitize, name == "--constructed" {
            throw UsageError(message: "--constructed is for resanitize only")
        }
        switch name {
        case "--sites": options.sites = try parseSites(value())
        case "--targets": options.targets = try value()
        case "--constructed":
            try flag()
            options.includeConstructed = true
        case "--site":
            guard let site = EHSite(rawValue: try value()) else { throw UsageError(message: "--site takes eh or ex") }
            options.site = site
        case "--user-agent": options.userAgent = try value()
        case "--sp": options.profileNumbers = try parseProfileNumbers(value())
        case "--as": options.importAs = try value()
        case "--output": options.output = try value()
        case "--secrets-file": options.secretsFile = try value()
        case "--dry-run":
            try flag()
            options.dryRun = true
        case "-h", "--help":
            try flag()
            options.help = true
        default:
            // import takes the saved file as its one positional argument.
            if options.command == .importPage, !name.hasPrefix("-"), options.importFile == nil {
                options.importFile = argument
            } else {
                throw UsageError(message: name.hasPrefix("-") ? "unknown option \(name)" : "unexpected argument")
            }
        }
    }
    if options.command == .importPage, options.help == false, options.importFile == nil || options.importAs == nil {
        throw UsageError(message: "import needs a file and --as")
    }
    if options.command == .probe, options.help == false, options.site == nil || options.userAgent == nil {
        throw UsageError(message: "probe-structure needs --site and --user-agent")
    }
    if options.command == .probeProfiles, options.help == false, options.site == nil || options.profileNumbers == nil {
        throw UsageError(message: "probe-sp needs --site and --sp")
    }
    return options
}

/// The numbers of `--sp`: positive integers in ASCII digits, comma-separated, each once. How many is left to
/// `probeProfiles`, which refuses more than 3.
private func parseProfileNumbers(_ value: String) throws -> [Int] {
    var numbers: [Int] = []
    for part in value.split(separator: ",", omittingEmptySubsequences: false) {
        let digits = part.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let number = Int(digits), number > 0, !numbers.contains(number) else {
            throw UsageError(message: "--sp takes 1 to 3 positive profile numbers, comma-separated, each once")
        }
        numbers.append(number)
    }
    return numbers
}

private func parseSites(_ value: String) throws -> [EHSite] {
    var sites: [EHSite] = []
    for part in value.split(separator: ",", omittingEmptySubsequences: false) {
        guard let site = EHSite(rawValue: part.trimmingCharacters(in: .whitespaces)), !sites.contains(site) else {
            throw UsageError(message: "--sites takes eh, ex or both, comma-separated, each once")
        }
        sites.append(site)
    }
    return sites
}

private func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func fileURL(_ path: String) -> URL {
    URL(filePath: path, relativeTo: .currentDirectory()).absoluteURL
}

/// The coding path of a decoding error, e.g. "eh.gallery"; keys only, no values.
private func codingPath(of error: Error) -> String? {
    let path: [any CodingKey]
    switch error as? DecodingError {
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
        path = context.codingPath
    case .keyNotFound(let key, let context):
        path = context.codingPath + [key]
    default:
        return nil
    }
    guard !path.isEmpty else { return nil }
    return path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
}

/// True for `https://<site host>/g/<gid>/<token>/`, so a placeholder left in targets.json costs no requests.
private func isGalleryURL(_ url: URL, on site: EHSite) -> Bool {
    guard url.scheme == "https", url.host()?.lowercased() == site.host,
          let gallery = LinkExtractor.galleries(in: url.path()).first else { return false }
    return url.path() == "/g/\(gallery.gid)/\(gallery.token)/"
}

// MARK: Dry run

private func printPlan(sites: [EHSite], targets: CaptureTargets, environment: [String: String]) {
    // The dry run reads no credential.
    let plans = sites.map { site in (site, CapturePlan.steps(for: site, targets: targets[site])) }
    let counts = plans.map { site, steps in
        "\(steps.count) steps for \(site.rawValue) (\(steps.compactMap(\.fixturePath).count) fixtures)"
    }
    print("Plan: " + counts.joined(separator: ", "))
    for (_, steps) in plans {
        for step in steps {
            // Private pages are written to the git-ignored local/ directory.
            print("\(step.method) \(step.urlTemplate) -> \(step.fixturePath.map(PrivateFixtures.storedPath) ?? "(not saved)")")
        }
    }
    let set = CaptureCredentials.environmentKeys.filter {
        !(environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    print("Environment variables set: " + (set.isEmpty ? "none" : set.joined(separator: ", ")))
}

// MARK: Messages

private func modeName(_ mode: ListDisplayMode) -> String {
    switch mode {
    case .minimal: "the Minimal"
    case .minimalPlus: "the Minimal+"
    case .compact: "the Compact"
    case .extended: "the Extended"
    case .thumbnail: "the Thumbnail"
    // The page's own code is not repeated.
    case .unrecognized: "an unrecognized"
    }
}

private func explain(_ abort: CaptureAbort) -> String {
    let nothing = "Nothing was retried and no fixtures were written."
    // The plan's rule after a 429, 509, 5xx or ban, in the output an agent running the tool reads.
    let cooldown = "Wait at least one hour and ask the user before running any fixture-capture command against the "
        + "site again."
    switch abort {
    case .notCompactView(let site, let mode):
        let found = mode.map { "the \(site.host) front page is in \(modeName($0)) display mode, not Compact" }
            ?? "could not detect the display mode of the \(site.host) front page"
        return "Stopped: \(found). The tool never changes site settings. Switch the display mode to Compact yourself "
            + "on the site (Settings, Front Page Settings), or set EH_SP to the number of a site profile that uses "
            + "Compact, then run again. No fixtures were written."
    case .stoppedByServer(let site, let fixturePath, let status):
        return "Stopped: \(site.host) answered HTTP \(status) for \(fixturePath): the server is limiting requests or "
            + "failing. \(cooldown) \(nothing)"
    case .banned(let site, let fixturePath):
        return "Stopped: the answer for \(fixturePath) from \(site.host) is a ban notice. Do not run the tool again "
            + "until the ban has expired, and in any case: \(cooldown) \(nothing)"
    case .unexpectedStatus(let site, let fixturePath, let status):
        return "Stopped: unexpected HTTP \(status) from \(site.host) for \(fixturePath). Check targets.json and the "
            + "account. \(nothing)"
    case .exAccessDenied:
        return "Stopped: an exhentai.org page came back empty or not HTML, so these cookies do not grant ExHentai "
            + "access, or no longer do. Check EH_IPB_MEMBER_ID, EH_IPB_PASS_HASH and EH_IGNEOUS (taken from a browser "
            + "that can open ExHentai). \(nothing)"
    case .transport(let site, let fixturePath, let message):
        return "Stopped: the request for \(fixturePath) to \(site.host) failed: \(message) \(nothing)"
    case .requiredStepSkipped(let site, let fixturePath):
        return "Stopped: the step for \(fixturePath) on \(site.host) was skipped because something it depends on is "
            + "missing, so the fixture set would be incomplete. Check targets.json and the pages the earlier steps "
            + "read. \(nothing)"
    }
}

private func explain(_ error: CredentialError) -> String {
    switch error {
    case .missing(let names):
        "Missing environment variables: \(names.joined(separator: ", ")). Provide them with op run "
            + "(see Tools/FixtureCapture/README.md and capture.env.example)."
    case .invalidIgneous:
        "EH_IGNEOUS holds the value ExHentai gives sessions it does not let in. Copy the igneous cookie of a "
            + "browser that can open ExHentai."
    case .cfClearanceWithoutUserAgent:
        "EH_CF_CLEARANCE is set without EH_USER_AGENT. Set EH_USER_AGENT to the exact user agent of the browser "
            + "the clearance came from."
    case .sharedProfileNumber:
        "EH_SP selects one site's profile: capture one site at a time (--sites eh, then --sites ex)."
    }
}

private func explain(_ error: FixtureWriterError) -> String {
    switch error {
    case .hygiene(let violations):
        (["Refused to write: the sanitized output still fails the hygiene checks. No fixtures were written."]
            + violations.map { "  \($0.file):\($0.line): \($0.rule)" }
            + (violations.contains { $0.rule == HomePageCheck.rule }
                ? ["  \(HomePageCheck.rule): home.php still shows numbers outside Image Limits that no rule masked; the "
                    + "page layout has probably changed. Look at those lines (without copying values) and adjust the "
                    + "homestats or torrentkey rule in EHFixtures/FixtureHygiene.swift."]
                : [])
            + (violations.contains { $0.rule == FixtureHygiene.filteredListRule }
                ? ["  \(FixtureHygiene.filteredListRule): these list pages say the account's filters hid galleries, "
                    + "which no sanitizing can undo. Capture them again: the plan requests lists with filters disabled. "
                    + "If a fresh capture still shows the line, the site's Disable Filters link has probably changed; "
                    + "compare its parameter names (without copying values) with CapturePlan.filterParameters."]
                : [])
            + (violations.contains { $0.rule == FixtureHygiene.favoriteMarkRule }
                ? ["  \(FixtureHygiene.favoriteMarkRule): these pages show the account's favorites (a favorited "
                    + "gallery in a list or as a target, or a category the account renamed), which is never "
                    + "rewritten. Pick targets outside the favorites in targets.json, or capture the lists again later."]
                : [])
            + (violations.contains { $0.rule == FixtureHygiene.accountMarkRule }
                ? ["  \(FixtureHygiene.accountMarkRule): these pages show the account's own rating, tag votes, comment "
                    + "votes or comments, which is never rewritten. Pick targets in targets.json the account has not "
                    + "rated, voted on or commented, or capture the lists again later."]
                : [])).joined(separator: "\n")
    case .invalidPath(let path):
        "Refused to write: \(path) may not be written or replaced (outside its site directory, a duplicate, or not "
            + "a regular file). No fixtures were written."
    }
}

private func explain(_ error: SanitizeError) -> String {
    switch error {
    case .notUTF8(let path):
        "Stopped: the body of \(path) is not valid UTF-8. No fixtures were written."
    case .tooManyIPAddresses:
        "Stopped: the captured pages hold more than 254 distinct foreign IPv4 addresses, more than the "
            + "203.0.113.0/24 stand-ins. No fixtures were written."
    case .ownContent(let findings):
        OwnContentCheck.explanation(of: findings)
    }
}

// MARK: Resanitize

/// The resanitize command: no request, no capture variables needed.
private func resanitize(_ options: Options, environment: [String: String]) -> Int32 {
    var isDirectory: ObjCBool = false
    let output = fileURL(options.output)
    guard FileManager.default.fileExists(atPath: output.path(percentEncoded: false), isDirectory: &isDirectory),
          isDirectory.boolValue else {
        printError("error: the output directory \(options.output) does not exist; run from the repository root")
        return ExitStatus.configuration
    }
    let secretsFile = fileURL(options.secretsFile)
    if FileManager.default.fileExists(atPath: secretsFile.path(percentEncoded: false)),
       (try? String(contentsOf: secretsFile, encoding: .utf8)) == nil {
        printError("error: cannot read the secrets file \(options.secretsFile) as UTF-8 text")
        return ExitStatus.configuration
    }
    do {
        let outcome = try resanitizeFixtures(
            fixturesRoot: output, secretsFile: secretsFile, environment: environment,
            includeConstructed: options.includeConstructed
        )
        print("Resanitized \(outcome.checked) fixtures; \(outcome.changed.count) changed")
        for path in outcome.changed { print("Changed \(path)") }
        for warning in outcome.warnings { print("Warning: \(warning)") }
        return ExitStatus.success
    } catch let error as FixtureWriterError {
        printError(explain(error))
        return ExitStatus.stopped
    } catch let error as SanitizeError {
        printError(explain(error))
        return ExitStatus.stopped
    } catch {
        // File system and decoding errors; their descriptions name files, not page contents.
        printError("Stopped: \(type(of: error)): \(error.localizedDescription) Check the fixture directory with git status.")
        return ExitStatus.stopped
    }
}

// MARK: Import

/// The import command: no request, no capture variables needed. Output names paths and rules, never page content.
private func importCommand(_ options: Options, environment: [String: String]) -> Int32 {
    guard let file = options.importFile, let target = options.importAs else { return ExitStatus.configuration }
    var isDirectory: ObjCBool = false
    let output = fileURL(options.output)
    guard FileManager.default.fileExists(atPath: output.path(percentEncoded: false), isDirectory: &isDirectory),
          isDirectory.boolValue else {
        printError("error: the output directory \(options.output) does not exist; run from the repository root")
        return ExitStatus.configuration
    }
    let secretsFile = fileURL(options.secretsFile)
    if FileManager.default.fileExists(atPath: secretsFile.path(percentEncoded: false)),
       (try? String(contentsOf: secretsFile, encoding: .utf8)) == nil {
        printError("error: cannot read the secrets file \(options.secretsFile) as UTF-8 text")
        return ExitStatus.configuration
    }
    guard FileManager.default.isReadableFile(atPath: fileURL(file).path(percentEncoded: false)) else {
        printError("error: cannot read the file to import")
        return ExitStatus.configuration
    }
    do {
        let outcome = try importFixture(
            file: fileURL(file), as: target, fixturesRoot: output, secretsFile: secretsFile, environment: environment
        )
        print("Imported \(outcome.storedPath)")
        for warning in outcome.warnings { print("Warning: \(warning)") }
        return ExitStatus.success
    } catch let error as ImportError {
        printError(explain(error))
        return ExitStatus.configuration
    } catch let error as FixtureWriterError {
        printError(explain(error))
        return ExitStatus.configuration
    } catch let error as SanitizeError {
        printError(explain(error))
        return ExitStatus.configuration
    } catch {
        printError("Stopped: \(type(of: error)): \(error.localizedDescription) Check the fixture directory with git status.")
        return ExitStatus.stopped
    }
}

private func explain(_ error: ImportError) -> String {
    switch error {
    case .unknownTarget:
        "error: --as takes one of: \(ImportableFixtures.paths.sorted().joined(separator: ", "))."
    case .unsupportedFormat:
        "Save the page source as HTML only (not a web archive), then import it again."
    case .notUTF8:
        "error: the saved page is not valid UTF-8. Save the page source as HTML only, then import it again."
    case .notAProfilePage:
        "error: the saved page is not a forum profile page (no profile name). Open your own profile page while "
            + "logged in and save that page's source."
    case .identityUnknown:
        "error: no username and member id are known (EH_USERNAME and EH_IPB_MEMBER_ID in the environment, or "
            + "word and numeric lines in the secrets file), so the page cannot be masked reliably. Nothing was written."
    }
}

// MARK: Probe

/// The environment the probes read credentials from: without `EH_CF_CLEARANCE` and `EH_CF_DUID`. The clearance
/// cookies belong to the browser that earned them; the probes send neither, so they need no `EH_USER_AGENT` either.
private func probeEnvironment(_ environment: [String: String]) -> [String: String] {
    environment.filter { $0.key != "EH_CF_CLEARANCE" && $0.key != "EH_CF_DUID" }
}

/// The probe-structure command: three read-only requests on one site; prints names and statuses only.
private func probeStructureCommand(_ options: Options, environment: [String: String]) async -> Int32 {
    guard let site = options.site, let userAgent = options.userAgent else { return ExitStatus.configuration }
    var isDirectory: ObjCBool = false
    let output = fileURL(options.output)
    guard FileManager.default.fileExists(atPath: output.path(percentEncoded: false), isDirectory: &isDirectory),
          isDirectory.boolValue else {
        printError("error: the output directory \(options.output) does not exist; run from the repository root")
        return ExitStatus.configuration
    }
    do {
        let credentials = try CaptureCredentials(environment: probeEnvironment(environment), sites: [site])
        let transport = URLSessionCaptureTransport(rateLimiter: RateLimiter())
        // Each page is printed as soon as it is compared, so a later stop keeps the earlier lines.
        let results = try await probeStructure(
            site: site, userAgent: userAgent, credentials: credentials, fixturesRoot: output, transport: transport,
            onResult: { result in
                let outcome = result.differences.isEmpty ? "same" : "differs: " + result.differences.joined(separator: ",")
                print("\(site.rawValue) \(result.kind.rawValue) status=\(result.status) \(outcome)")
            }
        )
        return results.allSatisfy { $0.differences.isEmpty } ? ExitStatus.success : ExitStatus.differs
    } catch let error as CredentialError {
        printError("error: \(explain(error))")
        return ExitStatus.configuration
    } catch let abort as CaptureAbort {
        printError(explain(abort))
        return ExitStatus.stopped
    } catch let error as StructureProbeError {
        switch error {
        case .sampleUnreadable(let path):
            printError("Stopped: the M0 sample \(path) cannot be read or parsed. Nothing was sent.")
        case .notReadOnly(let kind):
            printError("Stopped: the request for the \(kind.rawValue) page would not have been read-only; it was not sent.")
        case .noLink(let kind):
            printError("Stopped: the \(kind.rawValue) page held no link to the next page of the probe.")
        }
        return ExitStatus.stopped
    } catch {
        printError("Stopped: \(type(of: error)).")
        return ExitStatus.stopped
    }
}

// MARK: Profile probe

private func explain(_ error: ProfileProbeError) -> String {
    switch error {
    case .tooManyProfileNumbers:
        "error: --sp takes at most 3 profile numbers (at most 4 requests per site). Nothing was sent."
    case .sharedProfileVariable:
        "error: EH_SP is set, but probe-sp chooses the sp cookie of each request itself. Run it without EH_SP (for "
            + "example op run ... -- env -u EH_SP swift run ...). Nothing was sent."
    case .notReadOnly:
        "error: a request of the probe would not have been read-only. Nothing was sent."
    }
}

/// The probe-sp command: at most 4 read-only HTTP requests on one site; prints numbers, statuses and cookie names only.
private func probeProfilesCommand(_ options: Options, environment: [String: String]) async -> Int32 {
    guard let site = options.site, let numbers = options.profileNumbers else { return ExitStatus.configuration }
    do {
        let credentials = try CaptureCredentials(environment: probeEnvironment(environment), sites: [site])
        let transport = URLSessionCaptureTransport(rateLimiter: RateLimiter())
        // Each line is written unbuffered as soon as it is read, so a later stop (or a kill) keeps the earlier lines.
        _ = try await probeProfiles(
            site: site, numbers: numbers, credentials: credentials, transport: transport,
            onResult: { result in FileHandle.standardOutput.write(Data((result.outputLine + "\n").utf8)) }
        )
        return ExitStatus.success
    } catch let error as CredentialError {
        printError("error: \(explain(error))")
        return ExitStatus.configuration
    } catch let error as ProfileProbeError {
        printError(explain(error))
        return ExitStatus.configuration
    } catch let abort as CaptureAbort {
        printError(explain(abort))
        return ExitStatus.stopped
    } catch {
        printError("Stopped: \(type(of: error)).")
        return ExitStatus.stopped
    }
}

// MARK: Main

private func run(_ arguments: [String]) async -> Int32 {
    let options: Options
    do {
        options = try parse(arguments)
    } catch {
        let message = (error as? UsageError)?.message ?? "invalid arguments"
        printError("error: \(message)\n\n\(usage)")
        return ExitStatus.configuration
    }
    if options.help {
        print(usage)
        return ExitStatus.success
    }

    let environment = ProcessInfo.processInfo.environment
    if options.command == .resanitize {
        return resanitize(options, environment: environment)
    }
    if options.command == .importPage {
        return importCommand(options, environment: environment)
    }
    if options.command == .probe {
        return await probeStructureCommand(options, environment: environment)
    }
    if options.command == .probeProfiles {
        return await probeProfilesCommand(options, environment: environment)
    }
    let targets: CaptureTargets
    guard let targetsData = try? Data(contentsOf: fileURL(options.targets)) else {
        printError("error: cannot read the targets file \(options.targets)")
        return ExitStatus.configuration
    }
    do {
        targets = try JSONDecoder().decode(CaptureTargets.self, from: targetsData)
    } catch {
        let location = codingPath(of: error).map { " at \($0)" } ?? ""
        printError("error: cannot parse the targets file \(options.targets)\(location)")
        return ExitStatus.configuration
    }

    if options.dryRun {
        printPlan(sites: options.sites, targets: targets, environment: environment)
        return ExitStatus.success
    }

    for site in options.sites {
        let target = targets[site]
        guard isGalleryURL(target.gallery, on: site) else {
            printError("error: \(site.rawValue).gallery in \(options.targets) is not a gallery URL on \(site.host) "
                + "(https://\(site.host)/g/<gid>/<token>/); fill in the placeholder first")
            return ExitStatus.configuration
        }
        if let warning = target.contentWarningGallery, !isGalleryURL(warning, on: site) {
            printError("error: \(site.rawValue).contentWarningGallery in \(options.targets) is not a gallery URL on "
                + "\(site.host); use one or null")
            return ExitStatus.configuration
        }
    }
    var isDirectory: ObjCBool = false
    let output = fileURL(options.output)
    guard FileManager.default.fileExists(atPath: output.path(percentEncoded: false), isDirectory: &isDirectory),
          isDirectory.boolValue else {
        printError("error: the output directory \(options.output) does not exist; run from the repository root")
        return ExitStatus.configuration
    }
    let secretsFile = fileURL(options.secretsFile)
    if FileManager.default.fileExists(atPath: secretsFile.path(percentEncoded: false)),
       (try? String(contentsOf: secretsFile, encoding: .utf8)) == nil {
        printError("error: cannot read the secrets file \(options.secretsFile) as UTF-8 text")
        return ExitStatus.configuration
    }

    let config = CaptureSessionConfig(
        sites: options.sites, environment: environment, targets: targets, fixturesRoot: output, secretsFile: secretsFile
    )
    do {
        let transport = URLSessionCaptureTransport(rateLimiter: RateLimiter())
        let summary = try await runCaptureSession(config, transport: transport)
        let counts = options.sites.enumerated().map { index, site in
            let count = summary.written[site, default: 0]
            return index == 0 ? "\(count) fixtures for \(site.rawValue)" : "\(count) for \(site.rawValue)"
        }
        print("Captured " + counts.joined(separator: ", "))
        let local = options.sites.compactMap { site in summary.localOnly[site].map { "\($0) for \(site.rawValue)" } }
        if !local.isEmpty {
            print("Of these, kept local-only under \(options.output)/\(PrivateFixtures.directory)/ (git-ignored, "
                + "not committed): " + local.joined(separator: ", "))
        }
        for path in summary.removedLeftovers {
            print("Removed \(path): a personal preference page, now kept local-only")
        }
        for skipped in summary.skipped {
            print("Skipped \(skipped.fixturePath): \(skipped.reason)")
        }
        for warning in summary.warnings {
            print("Warning: \(warning)")
        }
        return ExitStatus.success
    } catch let error as CredentialError {
        printError("error: \(explain(error))")
        return ExitStatus.configuration
    } catch let abort as CaptureAbort {
        printError(explain(abort))
        return ExitStatus.stopped
    } catch let error as FixtureWriterError {
        printError(explain(error))
        return ExitStatus.stopped
    } catch let error as SanitizeError {
        printError(explain(error))
        return ExitStatus.stopped
    } catch {
        // File system errors; their descriptions name files, not page contents.
        printError("Stopped: \(type(of: error)): \(error.localizedDescription) Check the fixture directory with git status.")
        return ExitStatus.stopped
    }
}

exit(await run(Array(CommandLine.arguments.dropFirst())))
