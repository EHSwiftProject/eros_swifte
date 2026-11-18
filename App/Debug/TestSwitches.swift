#if DEBUG
/// The names of every DEBUG-only test switch the app reads: launch arguments (`-NAME 1`, read through
/// `UserDefaults.standard`) and environment variables. Later plans' switches (`-EROS_UI_TESTING_SESSION`,
/// `-EROS_UI_TESTING_ROUTE`, `-EROS_UI_TEST_IMAGE`, …; M2 index §3.4) go here too, read only under `#if DEBUG` and
/// `AppEnvironment.isUITestingLaunch`. Read a name with `.description`.
///
/// Every name is a `StaticString`, never a `String` literal: Swift keeps a `String` of up to 15 UTF-8 bytes inline (a
/// small string), and an optimized arm64 build materializes it with `mov`/`movk` immediates, so its bytes never sit
/// together in the binary. `scripts/build-ipa.sh` finds a switch that leaked into a Release build by grepping the app
/// for `EROS_UI_TEST` and `EROS_FIXTURE`; that only works for names stored whole in `__cstring`, which a
/// `StaticString` always is (`EROS_UI_TESTING` is exactly 15 bytes).
nonisolated enum TestSwitches {
    /// `-EROS_UI_TESTING 1`: the app was launched by a UI test (`AppEnvironment.isUITestingLaunch`).
    static let uiTesting: StaticString = "EROS_UI_TESTING"
    /// `-EROS_FIXTURE_REPLAY 1`, only read with `-EROS_UI_TESTING 1`: the checked-in fixtures answer the app's
    /// requests (`FixtureReplay`, `AppEnvironment.forLaunch()`).
    static let fixtureReplay: StaticString = "EROS_FIXTURE_REPLAY"
    /// Environment variable, read while replaying: JSON `[String: FixtureRoute]`, keys "METHOD URL" (compared as
    /// requests are; `FixtureReplay.forLaunch()`).
    static let fixtureRoutes: StaticString = "EROS_FIXTURE_ROUTES"
    /// `-EROS_FIXTURE_REPLAY_DELAY <seconds>`, read while replaying: every replayed answer comes that much later, so a
    /// UI test can act while a page is still on its way (`FixtureReplay.answerDelay`; the M2 review's check of a title
    /// tap during the first page, B.2-6).
    static let fixtureReplayDelay: StaticString = "EROS_FIXTURE_REPLAY_DELAY"
    /// `-EROS_UI_TESTING_SESSION 1`, only read with `-EROS_UI_TESTING 1` (never by hosted tests): the launch puts a
    /// made-up session in the in-memory cookie store, so a UI test sees the app logged in (browse B8,
    /// `AppEnvironment.launch()`).
    static let uiTestingSession: StaticString = "EROS_UI_TESTING_SESSION"
    /// `-EROS_UI_TESTING_ROUTE <url>`, only read with `-EROS_UI_TESTING 1` (never by hosted tests): the launch opens
    /// the site link `url` as an external open does (`AppRouter.open(_:)`), before the tabs show, so it waits for them
    /// (entry E1, `AppEnvironment.forLaunch()`). A value that is no site link stops the app (`assertionFailure`).
    static let uiTestingRoute: StaticString = "EROS_UI_TESTING_ROUTE"
    /// `-EROS_UI_TESTING_LAUNCH_DELAY <seconds>`, only read with `-EROS_UI_TESTING 1` (never by hosted tests): the
    /// launch waits that long before it is ready, so a UI test can open a link while `LaunchGate` still waits (entry
    /// E2, `AppEnvironment.launch()`).
    static let uiTestingLaunchDelay: StaticString = "EROS_UI_TESTING_LAUNCH_DELAY"
    /// `-EROS_UI_TESTING_CLIPBOARD_URL <url>`, only read with `-EROS_UI_TESTING 1` (never by hosted tests): the URL the
    /// clipboard of UI testing holds (`UITestingPasteboard`, which is never the real clipboard); without it that
    /// clipboard holds none (entry E3, `AppEnvironment`). A value that is no URL stops the app (`assertionFailure`).
    static let uiTestingClipboardURL: StaticString = "EROS_UI_TESTING_CLIPBOARD_URL"
    /// `-EROS_UI_TEST_IMAGE 1`, only read with `-EROS_UI_TESTING 1` (never by hosted tests): the image search page
    /// picks an 8×8 PNG the app draws itself when it opens, so a UI test can search without the Photos library or the
    /// file browser (search Q5; `ImageSearchView`).
    static let uiTestImage: StaticString = "EROS_UI_TEST_IMAGE"
}
#endif
