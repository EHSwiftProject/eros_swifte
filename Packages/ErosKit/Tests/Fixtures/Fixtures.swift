import Foundation

public enum FixtureError: Error, Equatable {
    /// No regular file at this path under the fixture root.
    case notFound(String)
}

/// Loads fixtures from this target's resource bundle. Paths are relative to the fixture root, e.g. "eh/list/front.html".
public enum Fixtures {
    /// Directory holding `eh/`, `ex/`, `constructed/` and `manifest.json`.
    public static var rootURL: URL {
        // Locate via manifest.json: with the current toolchain SwiftPM builds a Contents/Resources bundle on macOS
        // and a flat one on iOS, and this works for both.
        Bundle.module.url(forResource: "manifest", withExtension: "json")?.deletingLastPathComponent()
            ?? Bundle.module.resourceURL
            ?? Bundle.module.bundleURL
    }

    /// - Throws: `FixtureError.notFound(path)` when `path` is missing or a directory; read errors unchanged.
    public static func data(_ path: String) throws -> Data {
        let url = rootURL.appending(path: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw FixtureError.notFound(path)
        }
        return try Data(contentsOf: url)
    }

    /// The fixture decoded as UTF-8; invalid bytes become U+FFFD.
    public static func string(_ path: String) throws -> String {
        String(decoding: try data(path), as: UTF8.self)
    }

    /// The fewest checked-in captured fixtures each site must have (`manifest.json`, `eh/`, `ex/`; the local-only
    /// pages under `local/` do not count): the M0 floors of plan Task 14 and roadmap M0 exit criterion 3, without a
    /// content warning target (one more each with one).
    public static let minimumCapturedFixtures: [String: Int] = ["eh": 32, "ex": 26]

    public static func manifest() throws -> FixtureManifest {
        try JSONDecoder().decode(FixtureManifest.self, from: data("manifest.json"))
    }
}
