import EHFixtures
import Foundation

/// Fixture files on disk, as paths relative to a fixture root (by default the bundled `Fixtures.rootURL`).
enum FixtureFiles {
    /// The fixture root in the source tree. `local/` is excluded from the resource bundle, so it is read from here.
    static let sourceRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures")

    /// The fixture READMEs, relative to a fixture root. They quote the rules' own words, so the scans give them the
    /// secret and leak checks but never the structural one. `README.md` is not in the resource bundle (the
    /// `EHFixtures` target excludes it) and is read from the source tree; `constructed/README.md` is in the bundle.
    static let readmes: Set<String> = ["README.md", "constructed/README.md"]

    /// The private pages under `root`'s `local/` that the leak check takes its values from: every
    /// `…/account/mytags.html` (tag and tagset names), and every `…/list/favorites*.html` and
    /// `…/list/watched.html` (gallery links and titles), sorted. Empty without a `local/`.
    static func localPrivatePages(root: URL = sourceRoot) throws -> (myTags: [String], lists: [String]) {
        let paths = try local(root: root)
        let myTags = paths.filter { $0.hasSuffix("/account/mytags.html") }
        let lists = paths.filter { path in
            let parts = path.split(separator: "/")
            guard parts.count >= 3, parts[parts.count - 2] == "list", let name = parts.last else { return false }
            return name == "watched.html" || (name.hasPrefix("favorites") && name.hasSuffix(".html"))
        }
        return (myTags, lists)
    }

    /// Every checked-in captured fixture: all files under `eh/` and `ex/`. Private ones under `local/` are not
    /// counted, so a non-empty guard built on this counts only what is committed.
    static func captured(root: URL = Fixtures.rootURL) throws -> [String] {
        try files(under: "eh", root: root) + files(under: "ex", root: root)
    }

    /// Every file under the git-ignored `local/` of `root` (the private captures and `local/manifest.local.json`),
    /// as `local/…` paths; empty when there is no `local/`, as on a fresh clone apart from its `.gitkeep`.
    static func local(root: URL = sourceRoot) throws -> [String] {
        var isDirectory: ObjCBool = false
        let base = root.appending(path: "local").path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: base, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        return try files(under: "local", root: root)
    }

    /// All regular files under `directory`, recursively, sorted. Hidden files are included; only `.DS_Store`
    /// (git-ignored, so it never ships) and an empty `.gitkeep` are skipped.
    static func files(under directory: String, root: URL = Fixtures.rootURL) throws -> [String] {
        let manager = FileManager.default
        let base = root.appending(path: directory)
        let subpaths = try manager.subpathsOfDirectory(atPath: base.path(percentEncoded: false))
        return subpaths.sorted().compactMap { subpath in
            var isDirectory: ObjCBool = false
            let fullPath = base.appending(path: subpath).path(percentEncoded: false)
            guard manager.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return nil
            }
            switch (subpath as NSString).lastPathComponent {
            case ".DS_Store":
                return nil
            case ".gitkeep":
                let size = (try? manager.attributesOfItem(atPath: fullPath))?[.size] as? Int
                return size == 0 ? nil : "\(directory)/\(subpath)"
            default:
                return "\(directory)/\(subpath)"
            }
        }
    }

    /// The file decoded as UTF-8; invalid bytes become U+FFFD.
    static func text(_ path: String, root: URL = Fixtures.rootURL) throws -> String {
        String(decoding: try Data(contentsOf: root.appending(path: path)), as: UTF8.self)
    }

    /// The repository (or worktree) root above this file: the nearest directory holding `.git`; nil outside a
    /// checkout.
    static let repositoryRoot: URL? = {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while true {
            if FileManager.default.fileExists(atPath: directory.appending(path: ".git").path(percentEncoded: false)) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == directory.path(percentEncoded: false) { return nil }
            directory = parent
        }
    }()

    /// Whether `repositoryTextFiles` can run here: git runs only on a Mac (not in the iOS simulator), in a checkout.
    static var canListRepository: Bool {
        #if os(macOS)
        repositoryRoot != nil
        #else
        false
        #endif
    }

    /// Every text file of the repository at `root` that git tracks or would add (`git ls-files --cached --others
    /// --exclude-standard`, so never an ignored file such as those under `local/`), as paths relative to `root`,
    /// sorted. Left out: files gone from the work tree, files holding a NUL byte (images and other binaries), and what
    /// the leak check searches with its own rules under `fixturesRoot`, the fixture root in that repository: `eh/`,
    /// `ex/`, `local/`, `constructed/`, `manifest.json` and `README.md`.
    /// - Throws: `RepositoryListingError` when git cannot list the files; read errors unchanged.
    static func repositoryTextFiles(root: URL, fixturesRoot: URL = sourceRoot) throws -> [String] {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = [
            "-C", root.path(percentEncoded: false), "ls-files", "-z", "--cached", "--others", "--exclude-standard",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let listing = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RepositoryListingError.gitFailed(process.terminationStatus) }
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let fixturesPath = fixturesRoot.standardizedFileURL.path(percentEncoded: false)
        guard fixturesPath.hasPrefix(rootPath) else { throw RepositoryListingError.fixturesOutsideRepository }
        var fixtures = String(fixturesPath.dropFirst(rootPath.count))
        while fixtures.hasPrefix("/") { fixtures.removeFirst() }
        if !fixtures.isEmpty, !fixtures.hasSuffix("/") { fixtures += "/" }
        let ownDirectories = ["eh/", "ex/", "local/", "constructed/"].map { fixtures + $0 }
        let ownFiles: Set<String> = [fixtures + "manifest.json", fixtures + "README.md"]
        let paths = Set(listing.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        return try paths.sorted().filter { path in
            guard !ownFiles.contains(path), !ownDirectories.contains(where: path.hasPrefix) else { return false }
            let url = root.appending(path: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return false }
            return !(try Data(contentsOf: url)).contains(0)
        }
        #else
        throw RepositoryListingError.unavailable
        #endif
    }
}

/// Why `FixtureFiles.repositoryTextFiles` could not list the repository.
enum RepositoryListingError: Error, Equatable {
    /// `git ls-files` exited with this status.
    case gitFailed(Int32)
    /// The fixture root is not inside the repository.
    case fixturesOutsideRepository
    /// Not on a Mac: git cannot run here.
    case unavailable
}

/// The scans the checked-in fixture tests run, parameterized by root so the same chain can be run on fakes.
/// `sourceRoot` is the fixture root in the source tree, for what the resource bundle leaves out: the private captures
/// under its `local/` (scanned when it exists) and `README.md`.
enum FixtureScan {
    /// Structural checks over captured fixtures, `constructed/` (less its README and
    /// `FixtureHygiene.constructedExemptions`), `manifest.json` and everything under `local/` (less what a private page
    /// may show, `FixtureHygiene.isAllowedInPrivatePage`).
    static func structuralViolations(
        root: URL = Fixtures.rootURL, sourceRoot: URL = FixtureFiles.sourceRoot
    ) throws -> [HygieneViolation] {
        try scanned(root: root, sourceRoot: sourceRoot).filter { !FixtureFiles.readmes.contains($0.path) }
            .flatMap { path, base in
                FixtureHygiene.structuralViolations(in: try FixtureFiles.text(path, root: base), file: path)
                    .filter { !FixtureHygiene.isExempt($0) && !FixtureHygiene.isAllowedInPrivatePage($0) }
            }
    }

    /// Known-secret checks over captured fixtures, `constructed/` (its README too), `manifest.json`, everything under
    /// `local/`, `README.md` and `repositoryFiles`: the repository's other text files (tests, docs, the capture
    /// targets), where a username, member id or nickname written by hand would otherwise go unnoticed. Repository files
    /// are reported by their path from the repository root with a leading "/", as `leakViolations` reports them.
    /// - Parameter repositoryFiles: The other repository files to search, relative to `base`; nil for every text file
    ///   of this checkout (`FixtureFiles.repositoryTextFiles`), which then must be found.
    static func secretViolations(
        _ secrets: [KnownSecret], root: URL = Fixtures.rootURL, sourceRoot: URL = FixtureFiles.sourceRoot,
        repositoryFiles: [(path: String, base: URL)]? = nil
    ) throws -> [HygieneViolation] {
        let fixtures = (try scanned(root: root, sourceRoot: sourceRoot) + sourceReadme(sourceRoot)).map { item in
            (report: item.path, path: item.path, base: item.base)
        }
        let repository = try (repositoryFiles ?? checkoutTextFiles(sourceRoot: sourceRoot)).map { item in
            (report: "/" + item.path, path: item.path, base: item.base)
        }
        return try (fixtures + repository).flatMap { item in
            FixtureHygiene.secretViolations(
                in: try FixtureFiles.text(item.path, root: item.base), file: item.report, secrets: secrets
            )
        }
    }

    /// The private pages (`FixtureHygiene.privatePagePaths`) at a checked-in path of `root`: a file at that path
    /// (compared ignoring case, as on a default APFS volume), or a `manifest.json` entry for it. Sorted, each once, as
    /// they are found (a file's own spelling, an entry's path). Only `local/` may hold them.
    static func privatePagesAtCheckedInPaths(root: URL = FixtureFiles.sourceRoot) throws -> [String] {
        let isPrivate = Set(FixtureHygiene.privatePagePaths.map { $0.lowercased() })
        let files = try ["eh", "ex"].flatMap { directory in
            let base = root.appending(path: directory).path(percentEncoded: false)
            return FileManager.default.fileExists(atPath: base) ? try FixtureFiles.files(under: directory, root: root) : []
        }
        let manifestData = try Data(contentsOf: root.appending(path: "manifest.json"))
        let entries = try JSONDecoder().decode(FixtureManifest.self, from: manifestData).entries.map(\.path)
        return Set((files + entries).filter { isPrivate.contains($0.lowercased()) }).sorted()
    }

    /// The local leak check (`FixtureHygiene.localLeakViolations`): the values of the private pages under
    /// `sourceRoot`'s `local/` (`FixtureFiles.localPrivatePages`), searched for in every file under `constructed/`
    /// (its README too), `manifest.json`, `README.md` and `repositoryFiles`. A constructed fixture may show only what
    /// the checked-in fixture its manifest entry names as `derivedFrom` shows (under `eh/`, `ex/` or `constructed/`);
    /// every other file, and a constructed one without such a source, may show none, except that in `repositoryFiles`
    /// a bare tag that some captured fixture shows is an ordinary word (code and docs use the site's common words; a
    /// namespaced tag name, a tagset name, a title and a link still count there). The captured fixtures are not
    /// searched: what they show is public by definition, and `favmark` and `accountmark` check them for the account's
    /// favorites, ratings and votes instead. Neither is `local/`, where the values come from. Empty without private pages. Repository files are
    /// reported by their path from the repository root with a leading "/" (as in `.gitignore`), so `/README.md` is
    /// the repository's and `README.md` the fixture root's.
    /// - Parameter repositoryFiles: The other repository files to search, relative to `base`; nil for every text file
    ///   of this checkout (`FixtureFiles.repositoryTextFiles`), which then must be found.
    static func leakViolations(
        root: URL = Fixtures.rootURL, sourceRoot: URL = FixtureFiles.sourceRoot,
        repositoryFiles: [(path: String, base: URL)]? = nil
    ) throws -> [HygieneViolation] {
        let pages = try FixtureFiles.localPrivatePages(root: sourceRoot)
        guard !pages.myTags.isEmpty || !pages.lists.isEmpty else { return [] }
        let manifestData = try Data(contentsOf: root.appending(path: "manifest.json"))
        let entries = try JSONDecoder().decode(FixtureManifest.self, from: manifestData).entries
        let constructed = try FixtureFiles.files(under: "constructed", root: root)
        let captured = try FixtureFiles.captured(root: root)
        let sources = Set(captured + constructed)
        var derivedFrom: [String: String] = [:]
        for entry in entries {
            if let source = entry.derivedFrom, sources.contains(source), source != entry.path {
                derivedFrom[entry.path] = derivedFrom[entry.path] ?? source
            }
        }
        var files = try constructed.map { path in
            FixtureHygiene.LeakSearchFile(
                file: path, text: try FixtureFiles.text(path, root: root),
                derivedFromText: try derivedFrom[path].map { try FixtureFiles.text($0, root: root) }
            )
        }
        let manifestText = String(decoding: manifestData, as: UTF8.self)
        files.append(FixtureHygiene.LeakSearchFile(file: "manifest.json", text: manifestText))
        var others = sourceReadme(sourceRoot).map { readme in
            (report: readme.path, path: readme.path, base: readme.base, isRepository: false)
        }
        let repository = try repositoryFiles ?? checkoutTextFiles(sourceRoot: sourceRoot)
        others += repository.map { (report: "/" + $0.path, path: $0.path, base: $0.base, isRepository: true) }
        files += try others.map { item in
            FixtureHygiene.LeakSearchFile(
                file: item.report, text: try FixtureFiles.text(item.path, root: item.base),
                allowsPublicWords: item.isRepository
            )
        }
        return FixtureHygiene.localLeakViolations(
            myTags: try pages.myTags.map { try FixtureFiles.text($0, root: sourceRoot) },
            lists: try pages.lists.map { try FixtureFiles.text($0, root: sourceRoot) },
            publicTexts: try captured.map { try FixtureFiles.text($0, root: root) },
            searching: files
        )
    }

    /// Every text file of this checkout outside the fixture root `sourceRoot`'s own files
    /// (`FixtureFiles.repositoryTextFiles`), each with the repository root.
    /// - Throws: `RepositoryListingError` when there is no checkout or git cannot list it.
    private static func checkoutTextFiles(sourceRoot: URL) throws -> [(path: String, base: URL)] {
        guard let root = FixtureFiles.repositoryRoot else { throw RepositoryListingError.fixturesOutsideRepository }
        return try FixtureFiles.repositoryTextFiles(root: root, fixturesRoot: sourceRoot).map { ($0, root) }
    }

    /// The paths to scan, each with the root it is relative to.
    private static func scanned(root: URL, sourceRoot: URL) throws -> [(path: String, base: URL)] {
        let paths = try FixtureFiles.captured(root: root) + FixtureFiles.files(under: "constructed", root: root)
            + ["manifest.json"]
        return paths.map { ($0, root) } + (try FixtureFiles.local(root: sourceRoot)).map { ($0, sourceRoot) }
    }

    /// `README.md` under `sourceRoot` when it is there, as it always is in the source tree (a fake root may have none).
    private static func sourceReadme(_ sourceRoot: URL) -> [(path: String, base: URL)] {
        let readme = sourceRoot.appending(path: "README.md").path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: readme) ? [("README.md", sourceRoot)] : []
    }
}

/// A throwaway fixture root (`eh/`, `ex/`, `constructed/` plus the given files) in a unique temporary directory.
struct TemporaryFixtureRoot {
    let url: URL

    /// - Parameter files: contents keyed by path relative to the root.
    init(files: [String: String]) throws {
        let manager = FileManager.default
        url = manager.temporaryDirectory.appending(path: "eros-fixture-root-\(UUID().uuidString)")
        for directory in ["eh", "ex", "constructed"] {
            try manager.createDirectory(at: url.appending(path: directory), withIntermediateDirectories: true)
        }
        for (path, contents) in files {
            let fileURL = url.appending(path: path)
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
