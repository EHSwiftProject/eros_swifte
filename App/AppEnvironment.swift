import EHModels
import EHNetwork
import EHParsing
import EHStore
import Foundation
import Nuke
import Observation
import os
import UIKit
import WebKit

/// What the last login did about the forum profile page (the session diagnostics show it; the UI only falls back).
nonisolated enum ForumProfileStep: Equatable, Sendable {
    /// The page was read and the nickname and avatar stored.
    case loaded
    /// The page was read, but the nickname and avatar were not stored (the Keychain write failed, or the member is no
    /// longer the one signed in): the login name and the default avatar stay.
    case notStored
    /// The loader gave nothing, for this reason (a 403, a challenge that did not finish, a timeout, …): the login name
    /// and the default avatar stay.
    case unavailable(ForumProfileFailure)
    /// The login's profile run met a site notice, so the page was not loaded: nothing more was sent.
    case skipped(ResponseIssue)
}

/// The app's object graph: the cookie store, the user agent, the throttle, the client and the services, the WebView
/// session bridge, the account actions the screens call, the app's settings and the router.
///
/// Nothing sends a site request before `start()` has a user agent (user decision 2026-11-05): the screens are shown
/// only once `isReady`, and `start()` itself sends nothing.
@MainActor @Observable final class AppEnvironment {
    // Test switches exist in DEBUG builds only: a Release build reads no test launch argument, environment variable
    // or test host. Their names are the `StaticString`s of `TestSwitches` (`#if DEBUG`), so that
    // `scripts/build-ipa.sh` can find one that leaks into a Release build (see `TestSwitches` for why a `String`
    // literal would slip through). Later DEBUG launch arguments (M2 index §3.4) go there too and are read only under
    // `#if DEBUG` and `isUITestingLaunch` (not `isHostedByTests`).
    #if DEBUG
    /// Whether this process was launched by a UI test (`-EROS_UI_TESTING 1`, `TestSwitches.uiTesting`).
    static var isUITestingLaunch: Bool { UserDefaults.standard.bool(forKey: TestSwitches.uiTesting.description) }

    /// Whether XCTest hosts this process: the unit tests (ErosTests) run inside the app.
    static var isHostedByTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    /// Whether the environment `forLaunch()` made last is the UI testing one; nil before it made one. The app makes
    /// its own at launch, so the hosted tests can check that the app's environment is the offline one: an app that
    /// built it some other way would leave this nil.
    private(set) static var launchedUITesting: Bool?

    /// The settings of a UI test launch (`forLaunch()`): never the app's own defaults.
    static let uiTestingSettingsSuite = "proj.eros.swifte.uitesting"
    #endif

    /// The environment the app launches with (`ErosApp`). DEBUG: a UI test launch, and a process XCTest hosts, get the
    /// UI testing one (in-memory stores, every site request fails offline): running the tests never reads or writes
    /// the Keychain or the app's defaults and never reaches the site (the tests build their own environments). A UI
    /// test launch with `-EROS_FIXTURE_REPLAY 1` has the checked-in fixtures answer instead (`FixtureReplay`): every
    /// request of a session built from `clientConfiguration` carries the replay's header, so the replay takes all of
    /// them, and one it does not match gets a 404 without a body (the offline protocol behind it is never reached).
    /// Records its mode in `launchedUITesting`. A UI test launch keeps its settings in the suite
    /// `uiTestingSettingsSuite`, emptied here first, so every launch starts from the defaults, and opens the link of
    /// `-EROS_UI_TESTING_ROUTE` (`openUITestingRoute()`); its clipboard is never the real one (see the init's
    /// `pasteboard`). Release: the app's own environment, always.
    static func forLaunch() -> AppEnvironment {
        #if DEBUG
        let replays = isUITestingLaunch && UserDefaults.standard.bool(forKey: TestSwitches.fixtureReplay.description)
        var settingsDefaults: UserDefaults?
        if isUITestingLaunch, let suite = UserDefaults(suiteName: uiTestingSettingsSuite) {
            suite.removePersistentDomain(forName: uiTestingSettingsSuite)
            settingsDefaults = suite
        }
        let environment = AppEnvironment(
            uiTesting: isUITestingLaunch || isHostedByTests,
            sessionConfigurator: replays ? FixtureReplayURLProtocol.configurator(serving: .forLaunch()) : .none,
            settingsDefaults: settingsDefaults
        )
        launchedUITesting = environment.uiTesting
        environment.openUITestingRoute()
        return environment
        #else
        return AppEnvironment(uiTesting: false)
        #endif
    }

    /// The whole budget of the background forum profile read, a Cloudflare challenge included (user decision
    /// 2026-11-07). The read runs after the login has returned (the sheet closes at once), on its own: the next login
    /// and logging out end it first. On the real site a challenge that finished by itself took about 8 s once and had
    /// not finished after about 17 s another time.
    static let forumProfileTimeout: Duration = .seconds(60)

    /// The thumbnails' disk cache, in the system Caches directory (`ImagePipelines.thumbnails`); none in UI testing.
    static let thumbnailCacheName = "proj.eros.swifte.thumbnails"

    let cookies: CookieStore
    let userAgents: UserAgentStore
    /// The rate limiter behind `throttle`; private, so nothing waits for it without the breaker (`BreakerThrottle`).
    private let limiter: RateLimiter
    /// Both sites' circuit breaker (user decision 2026-11-08): the client and the password login report an IP ban or a
    /// 429 to it, and `throttle` refuses requests to E-Hentai and ExHentai (API and thumbnails included) while it holds
    /// a pause.
    let breaker: SiteBreaker
    /// What every request of the app waits for, URLSession's and the background WebViews' alike:
    /// `BreakerThrottle(base: throttle ?? limiter, breaker: breaker)`, the base being the limiter or the throttle a
    /// hosted test passed. Nothing may go around it.
    let throttle: any RequestThrottle
    /// The client's own configuration: offline first in UI testing (a hosted test's configurator after that). Image
    /// loading (browse B1) must build its sessions from it (`EHClient.makeSessionConfiguration(for:configuration:)`),
    /// or a UI test would reach the network.
    let clientConfiguration: EHClientConfiguration
    let client: EHClient
    let service: EHService
    let account: AccountService
    let bridge: WebSessionBridge
    let profileLoader: ForumProfileLoader
    /// Posts the forum login form in a background WebView (the password login, account A3b).
    let passwordLogin: WebPasswordLogin
    let notices: SiteSettingNoticeCenter
    /// The app's alerts, shown by the `alertHost()` views (the root and every sheet). New alerts go through it.
    let alerts = AlertCenter()
    /// The thumbnail pipeline (covers, thumbnails; `RemoteImage`): `ImagePipelines.thumbnails` with the disk cache
    /// `thumbnailCacheName`, none in UI testing. Logging out, the start of a login and its signing in empty it, disk
    /// included.
    let images: ImagePipeline
    /// The account avatars, through the avatar pipeline (`ImagePipelines.avatars`, memory only). Both pipelines load
    /// through `imageLoader`.
    let avatars: AvatarLoader
    /// The data loader of both image pipelines, over `throttle`, `breaker` and `clientConfiguration`.
    private let imageLoader: EHImageDataLoader
    /// The app's settings, tab configuration and browsing state (`settingsDefaults` of the init).
    let settings: AppSettingsStore
    /// The tag translations: in memory in UI testing, else the database file; nil when it could not be opened.
    let tagTranslations: TagTranslationStore?
    /// The translated names the lists show (`TagNameCache`), read from `tagTranslations`.
    let tagNames: TagNameCache
    /// The tag suggestions of the search fields: `tagTranslations` when translations are shown, else the site.
    let tagSuggestions: TagSuggestionService
    /// The translation of whole search texts for display, read from `tagTranslations`.
    let searchTerms: SearchTermTranslator
    /// The search page's own settings (search Q2), saved in the defaults of `settings`: they live and go with them,
    /// so environments never share them either.
    let searchPreferences: SearchPreferencesStore
    /// The user's own data (the gallery tab's custom groups, browse B6): in memory in UI testing (and whenever XCTest
    /// hosts the process), else the file in Application Support; nil when it could not be opened.
    let userData: UserDataStore?
    /// Downloads the tag database; nil without `tagTranslations`. One for the environment's life: each update gives
    /// it the mirror the settings ask for then (`updateTagDatabase(force:)`), so that updates that overlap through one
    /// mirror are one, and one after a switch of the mirror runs after the other, downloading nothing again (L068a,
    /// M2 re-review F3 M-2, F5 N-2).
    let tagDatabase: TagDatabaseUpdater?
    /// How long after launch the automatic update waits.
    @ObservationIgnored private let tagDatabaseLaunchDelay: Duration
    /// The automatic update `start()` scheduled (for tests).
    @ObservationIgnored private(set) var tagDatabaseLaunchUpdate: Task<Void, Never>?
    /// The selected tab and each tab's navigation path.
    let router = AppRouter()
    /// Offers a site link found in the clipboard when the app comes back from the background (entry E3): `LaunchGate`
    /// reports the scene phases, the root shows the offer (`clipboardOfferAlert()`). Reads the init's `pasteboard`.
    let clipboardLinks: ClipboardLinkMonitor
    /// Where the app's own Copy Link writes (`ItemContextMenu`); see the init's `pasteboard`.
    let pasteboardWriter: any PasteboardWriter
    /// UI testing: in-memory stores, no request reaches the network, the web login page is about:blank.
    let uiTesting: Bool

    /// false until `start()` has a user agent (WebKit's, or the Chrome fallback when reading it failed).
    private(set) var isReady = false
    /// `UserAgentStore.isWebKit`: the web login needs the WebView's own user agent on both sides.
    private(set) var canUseWebLogin = false
    /// The cookie store's snapshot; refreshed after every account action.
    private(set) var session = SessionSnapshot.empty
    /// `CookieStore.isLoggedIn`, refreshed with `session`.
    private(set) var isLoggedIn = false
    /// The forum profile step of the last login; nil before one, while its read is in progress, and after logging out.
    private(set) var forumProfileStep: ForumProfileStep?
    /// The pause of both sites in force (`breaker`), followed from `start()` on: set when one begins or is extended,
    /// nil once it has ended. Browse B3 shows it.
    private(set) var sitePause: SitePause?
    /// Whether a login is in progress: `prepareLogin()`, either `logIn`, or `completeWebLogin(from:)` has begun and
    /// not yet returned or thrown. Only one login runs at a time: while this holds,
    /// every other one is refused at once, and the login sheets cannot be closed.
    private(set) var isLoggingIn = false

    /// The forum profile read the last login started (tests wait for it); see `endSessionWork()`.
    @ObservationIgnored private(set) var forumProfileRead: Task<Void, Never>?
    /// The password login's background WebView run in progress; see `endSessionWork()`.
    @ObservationIgnored private var passwordRun: Task<(cookies: [ParsedCookie], page: URL), any Error>?
    /// The session of the app's own background work: one more at the start of every login and of logging out. Work
    /// begun for an earlier one (a forum profile read, a password login's run) changes nothing once it has moved on.
    @ObservationIgnored private var workSession = 0
    /// Ends once the work the latest `endSessionWork()` call cancelled has ended, and the work of every call before
    /// it; nil when no call is waiting.
    @ObservationIgnored private var sessionWorkEnd: Task<Void, Never>?

    @ObservationIgnored private let userAgentProbe: @MainActor () async throws -> String
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// The background read of the user agent when a fresh one was cached (for tests).
    @ObservationIgnored private(set) var userAgentRefresh: Task<Void, Never>?
    /// A user agent that was read but could not be adopted yet (the cookie store had not loaded).
    @ObservationIgnored private var pendingUserAgent: String?

    /// Tells whether this install has started before (iOS keeps Keychain items across a delete and reinstall).
    @ObservationIgnored private let launchMarker: any LaunchMarker

    /// UI tests (launch argument -EROS_UI_TESTING 1): InMemoryVault and InMemoryNoticeLedger, nothing touches the Keychain.
    /// Hosted tests pass a MockSession's configurator, a custom-scheme handler for the forum pages the background
    /// WebViews load (the env builds its ForumProfileLoader and WebPasswordLogin with its own bridge, so all share one
    /// CookieStore) and a stub UA probe; the app passes none.
    ///
    /// `forumSchemeHandler` serves three pages on its scheme: `<scheme>://forums/index.php?showuser=<id>` (the
    /// profile), `<scheme>://forums/index.php?act=Login&CODE=00` (the login page) and `…&CODE=01` (the login form).
    ///
    /// Also for hosted tests: `vault` replaces the vault of the mode, `throttle` the rate limiter as what every request
    /// waits for behind the breaker, `breaker` the environment's own breaker (one with a clock the test moves),
    /// `responseCache` the mode's response cache, `thumbnailCacheName` the name of the thumbnails' disk cache (UI
    /// testing has none otherwise). In UI testing every URLSession request fails at once
    /// unless `sessionConfigurator` answers it first, there is no response cache unless one is given, and
    /// without `forumSchemeHandler` the forum profile page is about:blank and the password login fails at once
    /// (unreachable) without a request.
    ///
    /// `tagDatabaseSession` is the session the tag database downloads with (hosted tests pass a stub): the shared
    /// session in the app, and in UI testing a session of `clientConfiguration`, which only replays or fails.
    /// `tagDatabaseLaunchDelay` is how long `start()` lets the app run before it updates the tag database, when the
    /// setting is on (or the store was rebuilt). `tagTranslationStore` replaces the store of the mode (hosted tests
    /// give one on a file of their own).
    ///
    /// `settingsDefaults` holds `settings` and `searchPreferences` (and is never removed). Without one: in UI testing,
    /// and in DEBUG whenever XCTest hosts the process, a suite of the environment's own with a random name, removed
    /// when the environment goes (environments never share settings, none touches the app's defaults, and none leaves
    /// a file behind); otherwise `UserDefaults.standard`.
    ///
    /// `pasteboard` is the clipboard `clipboardLinks` reads, and `pasteboardWriter` too when it can be written. Without
    /// one: in UI testing, and in DEBUG whenever XCTest hosts the process, one `UITestingPasteboard` for both, never
    /// the real clipboard (it holds the URL of `-EROS_UI_TESTING_CLIPBOARD_URL` in a UI test launch, none otherwise);
    /// otherwise the general pasteboard.
    ///
    /// `webStore` and `webStoreTimeout` are the WebView session store's calls and their time (`WebSessionBridge`):
    /// hosted tests give a store that hangs, and a short time; the app gives neither. Without a time:
    /// `webStoreTimeout(uiTesting:)`.
    init(
        uiTesting: Bool, sessionConfigurator: SessionConfigurator = .none,
        forumSchemeHandler: (handler: any WKURLSchemeHandler, scheme: String)? = nil,
        userAgentCache: (any UserAgentCache)? = nil, systemVersion: String = UIDevice.current.systemVersion,
        userAgentProbe: @escaping @MainActor () async throws -> String = { try await WebKitUserAgentProbe.read() },
        vault: (any CredentialVault)? = nil, throttle: (any RequestThrottle)? = nil, breaker: SiteBreaker? = nil,
        responseCache: ResponseCache? = nil, launchMarker: (any LaunchMarker)? = nil, thumbnailCacheName: String? = nil,
        settingsDefaults: UserDefaults? = nil, tagDatabaseSession: URLSession? = nil,
        tagDatabaseLaunchDelay: Duration = .seconds(10), tagTranslationStore: TagTranslationStore? = nil,
        pasteboard: (any PasteboardSource)? = nil, webStore: (any WebStoreAccess)? = nil,
        webStoreTimeout: Duration? = nil
    ) {
        self.uiTesting = uiTesting
        settings = settingsDefaults.map { AppSettingsStore(defaults: $0) } ?? Self.ownSettings(uiTesting: uiTesting)
        searchPreferences = SearchPreferencesStore(defaults: settings.defaults)
        self.launchMarker = launchMarker
            ?? (uiTesting ? InMemoryLaunchMarker(hasLaunched: true) : UserDefaultsLaunchMarker())
        self.userAgentProbe = userAgentProbe
        cookies = CookieStore(vault: vault ?? (uiTesting ? InMemoryVault() : KeychainVault()))
        userAgents = UserAgentStore(
            cache: userAgentCache ?? (uiTesting ? InMemoryUserAgentCache() : Self.versionedUserAgentCache()),
            systemVersion: systemVersion
        )
        limiter = RateLimiter()
        let breaker = breaker ?? SiteBreaker()
        self.breaker = breaker
        self.throttle = BreakerThrottle(base: throttle ?? limiter, breaker: breaker)

        let configurator = uiTesting ? Self.offlineFirst(then: sessionConfigurator) : sessionConfigurator
        // Only `.ignoreCertificateErrors` without a custom proxy throws; strict trust never does.
        let configuration = (try? EHClientConfiguration(sessionConfigurator: configurator)) ?? .standard
        clientConfiguration = configuration
        let cache = responseCache ?? (uiTesting ? nil : try? ResponseCache.standard())
        client = EHClient(
            configuration: configuration, cookies: cookies, userAgents: userAgents, throttle: self.throttle,
            cache: cache, breaker: breaker
        )
        notices = SiteSettingNoticeCenter()
        service = EHService(
            client: client, presenter: notices,
            ledger: uiTesting ? InMemoryNoticeLedger() : UserDefaultsNoticeLedger()
        )
        account = AccountService(client: client, cookies: cookies)
        bridge = WebSessionBridge(
            store: cookies, userAgents: userAgents, webStore: webStore,
            storeTimeout: webStoreTimeout ?? Self.webStoreTimeout(uiTesting: uiTesting)
        )
        let profileURL: @Sendable (Int) -> URL
        if let scheme = forumSchemeHandler?.scheme {
            profileURL = { URL(string: "\(scheme)://forums/index.php?showuser=\($0)")! }
        } else if uiTesting {
            profileURL = { _ in URL(string: "about:blank")! }
        } else {
            profileURL = EHEndpoints.forumProfile(memberID:)
        }
        profileLoader = ForumProfileLoader(
            bridge: bridge, throttle: self.throttle, timeout: Self.forumProfileTimeout, profileURL: profileURL,
            schemeHandler: forumSchemeHandler, breaker: breaker
        )
        if let scheme = forumSchemeHandler?.scheme {
            passwordLogin = WebPasswordLogin(
                bridge: bridge, throttle: self.throttle,
                loginPageURL: URL(string: "\(scheme)://forums/index.php?act=Login&CODE=00")!,
                formURL: URL(string: "\(scheme)://forums/index.php?act=Login&CODE=01")!,
                schemeHandler: forumSchemeHandler, breaker: breaker
            )
        } else {
            passwordLogin = WebPasswordLogin(
                bridge: bridge, throttle: self.throttle, offline: uiTesting, breaker: breaker
            )
        }
        imageLoader = EHImageDataLoader(
            client: client, throttle: self.throttle, breaker: breaker, configuration: clientConfiguration
        )
        images = ImagePipelines.thumbnails(
            dataLoader: imageLoader, diskCacheName: thumbnailCacheName ?? (uiTesting ? nil : Self.thumbnailCacheName)
        )
        avatars = AvatarLoader(pipeline: ImagePipelines.avatars(dataLoader: imageLoader))
        let translations: TagTranslationStore?
        if let tagTranslationStore {
            translations = tagTranslationStore
        } else {
            do {
                translations = try TagTranslationStore(inMemory: uiTesting)
            } catch {
                Self.logTagDatabaseFailure("Opening the tag translation store", error)
                translations = nil
            }
        }
        tagTranslations = translations
        tagNames = TagNameCache(store: translations)
        tagSuggestions = TagSuggestionService(service: service, translations: translations, settings: settings)
        searchTerms = SearchTermTranslator(translations: translations)
        userData = Self.openUserData(uiTesting: uiTesting)
        let clipboard = Self.clipboard(uiTesting: uiTesting, given: pasteboard)
        pasteboardWriter = clipboard.writer
        let settingsStore = settings
        clipboardLinks = ClipboardLinkMonitor(
            pasteboard: clipboard.source, router: router,
            isEnabled: { settingsStore.settings.detectsClipboardLinks }
        )
        let tagDatabaseSession = tagDatabaseSession
            ?? (uiTesting
                ? URLSession(configuration: EHClient.makeSessionConfiguration(for: .eh, configuration: configuration))
                : .shared)
        tagDatabase = translations.map { TagDatabaseUpdater(store: $0, session: tagDatabaseSession) }
        self.tagDatabaseLaunchDelay = tagDatabaseLaunchDelay
    }

    // MARK: - Tag database

    private static let log = Logger(subsystem: "proj.eros.swifte", category: "TagDatabase")
    private static let userDataLog = Logger(subsystem: "proj.eros.swifte", category: "UserData")
    private static let webStoreLog = Logger(subsystem: "proj.eros.swifte", category: "WebStore")

    /// The tag database opened without its full-text index (the suggestions then search more slowly; logged at
    /// launch): which kind of problem, and SQLite's result code; nothing of the database or its path.
    private static func logFullTextSearch(_ problem: FullTextSearchProblem) {
        switch problem {
        case .unsupported:
            log.error("Tag search index unavailable: unsupported")
        case .failed(let resultCode):
            log.error("Tag search index unavailable: failed, SQLite result \(resultCode, privacy: .public)")
        }
    }

    /// The mirror an update goes through: `TagDatabaseUpdater.defaultMirrorPrefix` while `usesTagDatabaseMirror` is
    /// on, read when the update starts; nil (GitHub) otherwise.
    var tagDatabaseMirror: URL? {
        settings.settings.usesTagDatabaseMirror ? TagDatabaseUpdater.defaultMirrorPrefix : nil
    }

    /// Downloads and imports the latest tag database (`force`: even when the version is the stored one), through the
    /// mirror the settings ask for now (`tagDatabaseMirror`), then forgets the cached names when the database changed
    /// (an up-to-date answer keeps them: the lists on screen would fall back to the original names until their views
    /// prefetched again). The import waits in the store's actor, off the main thread.
    ///
    /// Calls that overlap (the update at launch and Update Now) through one mirror are one update:
    /// `TagDatabaseUpdater.update(force:mirrorPrefix:)` lets a call wait for the one in flight (one download, one
    /// import) and hands both its result, so the app keeps no task of its own for it (L068a). With the mirror switched
    /// between them, the later call waits for the earlier one to end and then goes its own way (M2 re-review F5 N-2):
    /// after a success it finds the version imported and downloads nothing. Each caller that gets `.updated` forgets
    /// the names; the second time finds little or nothing to forget. A damaged database (`TagDatabaseError.damaged`)
    /// is logged here, by its kind only.
    /// - Throws: `TagDatabaseUnavailable` without a store; the updater's errors.
    func updateTagDatabase(force: Bool) async throws -> TagDatabaseUpdateResult {
        guard let tagDatabase else { throw TagDatabaseUnavailable() }
        let result: TagDatabaseUpdateResult
        do {
            result = try await tagDatabase.update(force: force, mirrorPrefix: tagDatabaseMirror)
        } catch TagDatabaseError.damaged {
            Self.logTagDatabaseFailure("Updating the tag database", TagDatabaseError.damaged)
            throw TagDatabaseError.damaged
        }
        if case .updated = result { tagNames.removeAll() }
        return result
    }

    /// Logs a failure of the tag database's store: a damaged file by that kind alone, as `TagDatabaseError.damaged`
    /// says what happens next (it is rebuilt at the next launch); any other error by its domain and code
    /// (`storeFailure`). Never a path, SQL or a tag.
    static func logTagDatabaseFailure(_ action: String, _ error: any Error) {
        if error as? TagDatabaseError == .damaged {
            log.error("\(action, privacy: .public) failed: damaged; rebuilt at the next launch")
        } else {
            log.storeFailure(action, error)
        }
    }

    /// After `tagDatabaseLaunchDelay`, updates the tag database (not forced) when the setting is still on; a failure is
    /// only logged. A store that rebuilt a damaged file at this launch (`afterRebuild`: one an earlier store marked,
    /// or one SQLite could not open) is updated whatever the setting, by the rule of U5 option A: a damaged tag
    /// database is rebuilt at the next launch and downloaded again, once (M2 re-review F5 N-3). Damage that an update
    /// from the settings meets is told ahead in its footer (`TagDatabaseSettings.damagedText`); damage the launch
    /// update meets is logged (by `updateTagDatabase(force:)`, as the settings' is too); damage a read meets (the tag
    /// names, search, suggestions, the settings' version) is neither shown nor logged, only marked for the next launch.
    /// Only that launch: the next one opens the rebuilt file.
    ///
    /// Known behaviour: when that download fails, the app ends before it is done, or the rebuilt file cannot be opened
    /// at that launch (no store then, and the next launch finds no file or an empty one, which is no rebuild), nothing
    /// downloads the database again by itself unless Update on Launch is on; the settings show it as Not Downloaded
    /// until the user taps Update Now (M8 may keep a lasting "to download" mark instead).
    private func scheduleTagDatabaseLaunchUpdate(afterRebuild rebuilt: Bool) {
        guard rebuilt || settings.settings.updatesTagDatabaseOnLaunch else { return }
        let delay = tagDatabaseLaunchDelay
        tagDatabaseLaunchUpdate = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled, rebuilt || self.settings.settings.updatesTagDatabaseOnLaunch else {
                return
            }
            do {
                _ = try await self.updateTagDatabase(force: false)
            } catch TagDatabaseError.damaged {
                // Logged by `updateTagDatabase(force:)`.
            } catch {
                Self.log.storeFailure("Updating the tag database at launch", error)
            }
        }
    }

    // MARK: - Launch

    /// `sitePause` starts following the breaker, and a tag database opened without its search index is logged
    /// (`logFullTextSearch(_:)`); one rebuilt from damage is downloaded again once the app is ready
    /// (`scheduleTagDatabaseLaunchUpdate(afterRebuild:)`). On the first launch of an install the session an earlier
    /// install left in the Keychain is deleted first (`clearSessionOnFirstLaunch()`), and when that fails the store is
    /// not loaded at all (it stays unloaded and writes nothing; the next login tries the clear again); otherwise
    /// cookies.load() (a load error continues with an empty snapshot; a DEBUG UI test launch may then put its made-up
    /// session in, `setUITestingSession()`), userAgents.load(); needsCapture → userAgentProbe() and
    /// adoptWebKitUserAgent before isReady; otherwise isReady at once and the probe runs again in the background (a
    /// changed value is adopted the same way). A failed probe: isReady true in the fallback state (see below). A DEBUG
    /// UI test launch may hold off isReady a while longer (`waitForUITestingLaunchDelay()`).
    ///
    /// Fallback (preflight M8, user decision 2026-11-05): the Chrome user agent, no web login (`canUseWebLogin`
    /// false), no Cloudflare cookies synced; the next launch reads again. Sends no site request. Runs once; later calls
    /// wait for the first.
    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { await launch() }
        startTask = task
        await task.value
    }

    private func launch() async {
        await followSitePause()
        if let problem = await tagTranslations?.fullTextSearchProblem { Self.logFullTextSearch(problem) }
        let rebuiltTagDatabase = await tagTranslations?.wasRebuiltFromDamage == true
        if rebuiltTagDatabase { Self.log.notice("Tag database rebuilt after damage; downloading it again") }
        // A Keychain that cannot be read or cleared yet keeps its session: the store stays unloaded and writes
        // nothing (a later login retries the clear).
        if (try? await clearSessionOnFirstLaunch()) != nil, await !cookies.isLoaded { try? await cookies.load() }
        #if DEBUG
        await setUITestingSession()
        #endif
        await userAgents.load()
        if await userAgents.needsCapture {
            await captureUserAgent()
        } else {
            userAgentRefresh = Task { await captureUserAgent() }
        }
        await refreshSession()
        #if DEBUG
        await waitForUITestingLaunchDelay()
        #endif
        isReady = true
        scheduleTagDatabaseLaunchUpdate(afterRebuild: rebuiltTagDatabase)
    }

    /// Copies every update of the breaker into `sitePause`, from its state now on. The task holds the environment
    /// weakly; it ends with the breaker's stream (when the breaker goes, with the environment).
    private func followSitePause() async {
        let updates = await breaker.updates()
        Task { [weak self] in
            for await pause in updates {
                guard let self else { return }
                self.sitePause = pause
            }
        }
    }

    /// Reads the WebKit user agent and adopts it; a failed read changes nothing.
    private func captureUserAgent() async {
        guard let value = try? await userAgentProbe() else { return }
        await adopt(value)
    }

    /// `adoptWebKitUserAgent` (the UA-bound Cloudflare cookies go when it changed). When the cookie store has not
    /// loaded the value is kept and adopted once a login has loaded the store.
    private func adopt(_ value: String) async {
        do {
            _ = try await adoptWebKitUserAgent(value, userAgents: userAgents, cookies: cookies)
            pendingUserAgent = nil
        } catch {
            pendingUserAgent = value
        }
        await refreshSession()
    }

    // MARK: - Account

    /// Reads the cookie store and the user agent state into `session`, `isLoggedIn` and `canUseWebLogin`.
    func refreshSession() async {
        session = await cookies.snapshot()
        isLoggedIn = await cookies.isLoggedIn
        canUseWebLogin = await userAgents.isWebKit
    }

    /// What every login starts with: `endSessionWork()` (a forum profile read or password login run still going is
    /// cancelled and waited for, so neither touches the WebView store afterwards), then a cookie store whose load
    /// failed at launch is loaded again (its error is thrown when it fails again), then the WebView store loses both
    /// sites' cookies, so nothing of an earlier account rides along into this one, the avatar loader forgets what it
    /// loaded or failed to load, and the thumbnail pipeline empties its memory and disk caches. Throws
    /// `CancellationError` at once while another login is in progress (`isLoggingIn`; that one goes on), and when
    /// logging out began meanwhile.
    func prepareLogin() async throws {
        try await loggingIn { _ = try await startLoginSession() }
    }

    /// The password login (account A3b): `prepareLogin()`, then the background WebView posts the forum form
    /// (`WebPasswordLogin`), then the WebView store's site cookies decide (`AccountService.completePasswordLogin`).
    /// Signed in, the forum profile read starts on its own (`startForumProfileRead`): this returns without it.
    ///
    /// The WebView run is the environment's: logging out cancels it and waits for it, and this then throws
    /// `CancellationError` (as for a login `AccountService` finds superseded); no other login starts while it runs
    /// (`isLoggingIn`), so two runs never share the WebView store. On the Chrome fallback the UA-bound Cloudflare
    /// cookies are left out (as `WebSessionBridge.pull()` does): they belong to the WebView's user agent, not to the one
    /// URLSession sends. `WebPasswordLoginError` is thrown as it is (`.needsWebLogin`: the login screen hands over to
    /// the web login), so is a site notice the form's answer was (`EHNetworkError.issue`, an IP ban; both sites pause
    /// then) and a pause that kept the pages from loading (`EHNetworkError.paused`).
    func logIn(username: String, password: String) async throws {
        try await loggingIn {
            let session = try await startLoginSession()
            let login = passwordLogin
            let run = Task { try await login.run(username: username, password: password) }
            passwordRun = run
            defer { if passwordRun == run { passwordRun = nil } }
            let posted = try await withTaskCancellationHandler {
                try await run.value
            } onCancel: {
                run.cancel()
            }
            guard session == workSession else { throw CancellationError() }
            var cookies = posted.cookies
            if await !userAgents.isWebKit {
                cookies.removeAll { WebLoginRules.isNotPushedToWebView($0.name) }
            }
            let outcome = try await signingIn {
                try await account.completePasswordLogin(cookies: cookies, from: posted.page, username: username)
            }
            await startForumProfileRead(after: outcome, session: session)
        }
    }

    /// The cookie login: the values are checked first (`CookieCredentials.validate()`: `LoginError.invalidMemberID`,
    /// `.invalidPassHash` at once, before the login begins or anything touches a store), then `prepareLogin()`,
    /// `AccountService.logIn(with:)`; signed in, the forum profile read starts on its own (`startForumProfileRead`):
    /// this returns without it.
    func logIn(memberID: String, passHash: String) async throws {
        let credentials = CookieCredentials(memberID: memberID, passHash: passHash)
        try credentials.validate()
        try await loggingIn {
            let session = try await startLoginSession()
            let outcome = try await signingIn { try await account.logIn(with: credentials) }
            await startForumProfileRead(after: outcome, session: session)
        }
    }

    /// bridge.siteCookies() → account.completeWebLogin(cookies:from:), `webView`'s page as the fallback source; signed
    /// in, the forum profile read starts on its own (`startForumProfileRead`): this returns without it, so the web
    /// login's WebView goes with its sheet. Refused at once (`CancellationError`) while another login is in progress.
    ///
    /// The WebView store is not cleared here (it holds this login's cookies): the web login clears it before it
    /// opens the page (`prepareLogin()`). A WebView store that does not answer in time throws `WebStoreTimeout`
    /// (`WebSessionBridge.storeTimeout`), and the login ends.
    func completeWebLogin(from webView: WKWebView) async throws {
        try await loggingIn {
            let session = workSession
            try await loadCookiesIfNeeded()
            let siteCookies = try await bridge.siteCookies()
            let page = webView.url ?? EHEndpoints.forumsBaseURL
            let outcome = try await signingIn {
                try await account.completeWebLogin(cookies: siteCookies, from: page)
            }
            await startForumProfileRead(after: outcome, session: session)
        }
    }

    /// `endSessionWork()` (a forum profile read or password login run still going is cancelled and waited for),
    /// account.logOut() (the cookie store and the response cache), then the avatars and the thumbnails (memory and
    /// disk: EX thumbnails need the account's cookies; design §5.2) are forgotten and the image loads in flight ended,
    /// then `forumProfileStep` goes and `session` is refreshed, so the screens show the logout at once (and load anew
    /// only after the images went, as `signingIn(_:)` does), and only then the WebView store loses everything it holds
    /// (`WebSessionBridge.removeAllData()`, within `WebSessionBridge.storeTimeout`: a store that does not answer in
    /// time is only logged, and its removal still runs in its turn once it does, after any call that hung before it,
    /// such as the push of a forum profile read the logout cancelled; the next login's clear comes after it). When the
    /// vault could not be deleted (the account then stays signed in), the images go, the WebView store is cleared
    /// and `session` refreshed all the same, and the error is thrown afterwards.
    func logOut() async throws {
        await endSessionWork()
        do {
            try await account.logOut()
        } catch {
            removeAllImages()
            await removeAllWebData()
            await refreshSession()
            throw error
        }
        removeAllImages()
        forumProfileStep = nil
        await refreshSession()
        await removeAllWebData()
    }

    /// `bridge.removeAllData()`; a failure (the store did not answer in time) is logged by its domain and code only.
    private func removeAllWebData() async {
        do {
            try await bridge.removeAllData()
        } catch {
            Self.webStoreLog.storeFailure("Removing the WebView data when logging out", error)
        }
    }

    /// account.activateExHentai(), then `session` refreshed (the EX jar may hold a new igneous).
    func activateExHentai() async throws -> ExAccess {
        try await recordingSession { try await account.activateExHentai() }
    }

    /// `login` as the one login in progress: while another runs (`isLoggingIn`) it is refused at once with
    /// `CancellationError` (`LoginFailureMessage` shows no alert for it) and the one running goes on untouched;
    /// otherwise `isLoggingIn` holds until `login` has returned or thrown.
    private func loggingIn<Value>(_ login: () async throws -> Value) async throws -> Value {
        guard !isLoggingIn else { throw CancellationError() }
        isLoggingIn = true
        defer { isLoggingIn = false }
        return try await login()
    }

    /// The account step of a login (`login`: `AccountService` writes the new session), then `session` refreshed
    /// whether it threw or not. Either way the image loads in flight are ended and the image caches emptied once more
    /// (`removeAllImages()`), before `session` shows the outcome: between the start of the login (which emptied them)
    /// and this step the earlier account's cookies were in the jars for as long as the web login's sheet or the
    /// password login's WebView run took, and a thumbnail asked for meanwhile went out with them. A login that throws
    /// may have written the new account already (its profile run rethrows a `CookieStoreError` after
    /// `CookieStore.finishLogin`); after one that changed nothing (rejected, refused credentials) emptying them only
    /// costs loading the thumbnails again. Thumbnails the new account asked for during the profile run are dropped too.
    private func signingIn(_ login: () async throws -> LoginOutcome) async throws -> LoginOutcome {
        try await recordingSession {
            defer { removeAllImages() }
            return try await login()
        }
    }

    /// `operation`, then `session` refreshed whether it threw or not.
    private func recordingSession<Value>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            let value = try await operation()
            await refreshSession()
            return value
        } catch {
            await refreshSession()
            throw error
        }
    }

    // MARK: - Session work

    /// `prepareLogin()`, returning the work session the login runs in; `CancellationError` when logging out began
    /// while it waited (the logout stands), `WebStoreTimeout` when the WebView store did not answer in time
    /// (`WebSessionBridge.storeTimeout`; the login ends, and the next one can begin). No other login can begin
    /// meanwhile (`loggingIn(_:)`).
    private func startLoginSession() async throws -> Int {
        await endSessionWork()
        let session = workSession
        try await loadCookiesIfNeeded()
        try await bridge.clear()
        // The account may change: its avatars (failed ones included) and thumbnails are the old account's.
        removeAllImages()
        guard session == workSession else { throw CancellationError() }
        return session
    }

    /// Ends the image loads in flight (`EHImageDataLoader.supersedeLoads()`: what comes back for them is dropped, so
    /// nothing fetched with the ending session's cookies lands in a cache afterwards), then forgets every avatar
    /// (`AvatarLoader.removeAll()`) and empties the thumbnail pipeline's memory and disk caches. Called when logging out,
    /// when a login starts, and once a login has signed in (`signingIn(_:)`).
    private func removeAllImages() {
        imageLoader.supersedeLoads()
        avatars.removeAll()
        images.cache.removeAll()
    }

    /// Begins a new work session: the forum profile read and the password login run in progress, if any, are
    /// cancelled and waited for. Both end at once when cancelled, whatever WebKit is doing (`ForumProfileLoader` and
    /// `WebPasswordLogin` wait for no WebKit call once their caller is cancelled, `WebKitDeadline`), so once this
    /// returns neither starts anything on the WebView store, the cookie store or `forumProfileStep` again; a WebKit
    /// store call either had in flight still ends later, before the next one on that store (`WebSessionBridge` runs
    /// them in order), and what either still had in flight is refused by its session (`workSession`,
    /// `CookieStore.epoch`).
    ///
    /// Calls may overlap (Log Out tapped again before the first logout has refreshed `isLoggedIn`; a login started
    /// while a logout waits). The first call takes the tasks, so a later one finds none of its own; it waits for the
    /// earlier calls' end (`sessionWorkEnd`, chained), so every caller returns only once all the work that any call
    /// before it cancelled has ended. Otherwise a second logout could clear the WebView store
    /// while the read the first one cancelled had yet to end, and that read could still push the old jar into it.
    private func endSessionWork() async {
        workSession += 1
        let read = forumProfileRead
        let run = passwordRun
        forumProfileRead = nil
        passwordRun = nil
        read?.cancel()
        run?.cancel()
        let earlier = sessionWorkEnd
        let end = Task {
            await earlier?.value
            await read?.value
            _ = await run?.result
        }
        sessionWorkEnd = end
        await end.value
        if sessionWorkEnd == end { sessionWorkEnd = nil }
    }

    #if DEBUG
    /// Tests only: makes `read` the forum profile read in progress, as a login does. The real read ends at once when
    /// cancelled (`ForumProfileLoader.load`); a stand-in that ignores its cancellation lets a test hold
    /// `endSessionWork()` for as long as it needs.
    func adoptForumProfileRead(_ read: Task<Void, Never>) {
        forumProfileRead = read
    }
    #endif

    /// After a login that signed in in work session `session`: the forum profile page once, as the environment's
    /// own task (`forumProfileRead`), unless the profile run met a site notice (`.stopped`: the login stands, but
    /// nothing more is sent). Nothing starts when a later session has begun meanwhile: that one stands.
    private func startForumProfileRead(after outcome: LoginOutcome, session: Int) async {
        guard session == workSession else { return }
        if case .stopped(let issue)? = outcome.profile {
            forumProfileStep = .skipped(issue)
            return
        }
        let epoch = await cookies.epoch
        guard session == workSession else { return }
        forumProfileStep = nil
        forumProfileRead = Task {
            await readForumProfile(memberID: outcome.memberID, session: session, epoch: epoch)
        }
    }

    /// The forum profile page of `memberID`: a page read gives the nickname and the avatar (`.loaded` once they are
    /// stored, `.notStored` when they could not be). A failure leaves the login name and the default avatar
    /// (`AccountDisplay.resolve`) and records why; nothing is retried. Once the work session is no longer `session`
    /// (logged out, another login), nothing is recorded and `session` is not refreshed; the page's cookies are kept
    /// out by the cookie store's `epoch` and the member check, its nickname by the member check.
    private func readForumProfile(memberID: Int, session: Int, epoch: UInt64) async {
        let result = await profileLoader.load(memberID: memberID, epoch: epoch)
        guard session == workSession else { return }
        switch result {
        case .failure(let reason):
            forumProfileStep = .unavailable(reason)
        case .success(let profile):
            // Writes nothing (false) when another account has signed in (or this one out) meanwhile.
            let stored = (try? await account.updateForumProfile(profile, memberID: memberID)) ?? false
            guard session == workSession else { return }
            forumProfileStep = stored ? .loaded : .notStored
            await refreshSession()
        }
    }

    /// On the first launch of an install, deletes the session an earlier install left in the Keychain (`reset()` also
    /// loads the store, empty), then writes the marker. When deleting throws nothing changes and the marker stays unset.
    private func clearSessionOnFirstLaunch() async throws {
        guard await !launchMarker.hasLaunched() else { return }
        try await cookies.reset()
        await launchMarker.markLaunched()
    }

    /// `cookies.load()` when the launch could not load the store; a user agent read meanwhile is adopted afterwards.
    private func loadCookiesIfNeeded() async throws {
        guard await !cookies.isLoaded else { return }
        try await clearSessionOnFirstLaunch()
        if await !cookies.isLoaded { try await cookies.load() }
        if let pendingUserAgent { await adopt(pendingUserAgent) }
        await refreshSession()
    }

    // MARK: - UI testing

    #if DEBUG
    /// A UI test launch with `-EROS_UI_TESTING_SESSION 1` (`TestSwitches.uiTestingSession`; never a hosted test, never
    /// Release): a made-up E-Hentai session (`ipb_member_id` 1, `ipb_pass_hash` 32 zeros) in the cookie store, so the
    /// app starts logged in. Only on the UI testing environment, whose vault is in memory: nothing reaches the
    /// Keychain.
    private func setUITestingSession() async {
        guard uiTesting, Self.isUITestingLaunch,
              UserDefaults.standard.bool(forKey: TestSwitches.uiTestingSession.description) else { return }
        try? await cookies.set(
            [CookieNames.memberID: "1", CookieNames.passHash: String(repeating: "0", count: 32)], for: [.eh]
        )
    }

    /// A UI test launch with `-EROS_UI_TESTING_ROUTE <url>` (`TestSwitches.uiTestingRoute`; never a hosted test, never
    /// Release): opens the site link `url` (`EHLink(url:)`) as an external open does. `forLaunch()` calls it before
    /// any view exists, so the route waits for the tabs (`AppRouter.pending`). Without the switch (or empty) it does
    /// nothing; a value that is no URL, or no site link, stops the app with the value and why, so the UI test fails at
    /// once and says so.
    private func openUITestingRoute() {
        let name = TestSwitches.uiTestingRoute.description
        guard uiTesting, Self.isUITestingLaunch, let text = UserDefaults.standard.string(forKey: name), !text.isEmpty
        else { return }
        guard let url = URL(string: text) else {
            assertionFailure("\(name) is not a URL: \(text)")
            return
        }
        guard let link = EHLink(url: url) else {
            assertionFailure("\(name) is not a site link: \(text)")
            return
        }
        router.open(link)
    }

    /// A UI test launch with `-EROS_UI_TESTING_LAUNCH_DELAY <seconds>` (`TestSwitches.uiTestingLaunchDelay`; never a
    /// hosted test, never Release): `launch()` waits that long more before `isReady`, so a UI test can open an
    /// `eros://` link while `LaunchGate` still shows its progress view (entry E2). Without the switch, or with a value
    /// that is no number above 0, nothing waits.
    private func waitForUITestingLaunchDelay() async {
        guard uiTesting, Self.isUITestingLaunch else { return }
        let seconds = UserDefaults.standard.double(forKey: TestSwitches.uiTestingLaunchDelay.description)
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// A UI test launch with `-EROS_UI_TESTING_CLIPBOARD_URL <url>` (`TestSwitches.uiTestingClipboardURL`; never a
    /// hosted test, never Release): the URL the UI testing clipboard holds (`UITestingPasteboard`, entry E3). nil
    /// without the switch (or empty); a value that is no URL stops the app with the value, so the UI test fails at
    /// once and says so.
    private static func uiTestingClipboardURL(uiTesting: Bool) -> URL? {
        let name = TestSwitches.uiTestingClipboardURL.description
        guard uiTesting, isUITestingLaunch, let text = UserDefaults.standard.string(forKey: name), !text.isEmpty
        else { return nil }
        guard let url = URL(string: text) else {
            assertionFailure("\(name) is not a URL: \(text)")
            return nil
        }
        return url
    }
    #endif

    /// The clipboard an environment reads (`clipboardLinks`) and the one it writes (`pasteboardWriter`): `pasteboard`
    /// when given (the one it writes too when it can be written); otherwise, in UI testing and in DEBUG whenever
    /// XCTest hosts the process, one `UITestingPasteboard` for both, never the real clipboard; otherwise the general
    /// pasteboard. A Release build makes no UI testing environment (`forLaunch()`).
    private static func clipboard(
        uiTesting: Bool, given pasteboard: (any PasteboardSource)?
    ) -> (source: any PasteboardSource, writer: any PasteboardWriter) {
        let givenWriter = pasteboard as? any PasteboardWriter
        #if DEBUG
        if uiTesting || isHostedByTests {
            let fixed = UITestingPasteboard(url: uiTestingClipboardURL(uiTesting: uiTesting))
            return (pasteboard ?? fixed, givenWriter ?? fixed)
        }
        #endif
        return (pasteboard ?? UIPasteboard.general, givenWriter ?? UIPasteboard.general)
    }

    /// The time of the WebView session store's calls: `WebSessionBridge.defaultStoreTimeout` (10 s) in the app; in
    /// DEBUG, `uiTestingStoreTimeout` in UI testing, which the hosted tests and the UI tests run. They test other
    /// things than the time (the tests about the time give their own), and the host they run on is often loaded far
    /// beyond a phone: a real `WKHTTPCookieStore` call there took over 10 s and failed logins that the tests only went
    /// through.
    static func webStoreTimeout(uiTesting: Bool) -> Duration {
        #if DEBUG
        if uiTesting { return uiTestingStoreTimeout }
        #endif
        return WebSessionBridge.defaultStoreTimeout
    }

    #if DEBUG
    /// The WebView store's time in UI testing (`webStoreTimeout(uiTesting:)`), and in the hosted tests that make a
    /// bridge of their own (`WebSessionBridge.roomyTestTimeout`): one value for both.
    nonisolated static let uiTestingStoreTimeout: Duration = .seconds(60)
    #endif

    /// The app's UA cache: the standard defaults, with the version of how the UA is read (`UserAgentCacheVersion`).
    private static func versionedUserAgentCache() -> UserAgentCacheVersion {
        UserAgentCacheVersion(base: UserDefaultsUserAgentCache())
    }

    /// The settings of an environment made without `settingsDefaults` (see the init): in UI testing and in a process
    /// XCTest hosts, a store that owns a suite with a random name and removes it when it goes (with the environment);
    /// otherwise the app's own defaults.
    private static func ownSettings(uiTesting: Bool) -> AppSettingsStore {
        var isolated = uiTesting
        #if DEBUG
        isolated = isolated || isHostedByTests
        #endif
        guard isolated else { return AppSettingsStore(defaults: .standard) }
        return AppSettingsStore(ownedSuiteNamed: "proj.eros.swifte.tests.\(UUID().uuidString)")
    }

    /// The user data store: in memory in UI testing and in a process XCTest hosts (no test touches the app's file),
    /// otherwise the file in Application Support; nil, with the error logged, when it could not be opened.
    private static func openUserData(uiTesting: Bool) -> UserDataStore? {
        var inMemory = uiTesting
        #if DEBUG
        inMemory = inMemory || isHostedByTests
        #endif
        do {
            return try UserDataStore(inMemory: inMemory)
        } catch {
            userDataLog.storeFailure("Opening the user data store", error)
            return nil
        }
    }

    /// A configurator that puts `OfflineURLProtocol` first, then applies `configurator` (a test's mock goes before it).
    private static func offlineFirst(then configurator: SessionConfigurator) -> SessionConfigurator {
        SessionConfigurator(usesCustomProxy: configurator.usesCustomProxy) { configuration in
            configuration.protocolClasses = [OfflineURLProtocol.self] + (configuration.protocolClasses ?? [])
            configurator.apply(to: configuration)
        }
    }
}

/// There is no tag translation store to update.
nonisolated struct TagDatabaseUnavailable: Error {}

/// Fails every request at once without touching the network: UI tests must never reach the site.
nonisolated private final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
