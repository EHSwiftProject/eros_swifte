import EHFixtures

/// Personal preference pages: the user's tag settings, favorites and watched results. The user decided on
/// 2026-11-04 that they are not committed. They are captured, sanitized and checked like every other page (secrets
/// found on them still mask the other pages), but `FixtureWriter` stores them under the git-ignored `local/`
/// directory of the fixture root and lists them in `local/manifest.local.json`, never in `manifest.json`.
public enum PrivateFixtures {
    /// The git-ignored directory under the fixture root that holds the private fixtures. It always exists (a tracked
    /// empty `.gitkeep` keeps it), so the fixture target can exclude it.
    public static let directory = "local"

    /// The manifest of the private fixtures, relative to the fixture root; the same format as `manifest.json`, with
    /// paths relative to the fixture root (`local/eh/list/favorites.html`).
    public static let manifestPath = "local/manifest.local.json"

    /// The fixture paths that are private: on each site, mytags, the three favorites lists and watched, plus the
    /// forum profile page, which is never captured but imported offline (`ImportableFixtures`; the user decided on
    /// 2026-11-05 that the real one stays on this machine). The one list `EHFixtures` keeps
    /// (`FixtureHygiene.privatePagePaths`), so that the checked-in scan, which fails when one of them is found at its
    /// checked-in path however it got there, guards the same pages the writer keeps local.
    public static let paths: [String] = FixtureHygiene.privatePagePaths

    /// Whether the plan fixture `path` is private.
    public static func isPrivate(_ path: String) -> Bool {
        paths.contains(path)
    }

    /// Where the plan fixture `path` is stored, relative to the fixture root: `local/<path>` when it is private,
    /// else `path` itself.
    public static func storedPath(_ path: String) -> String {
        isPrivate(path) ? "\(directory)/\(path)" : path
    }
}
