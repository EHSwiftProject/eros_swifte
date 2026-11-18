#if DEBUG
import EHModels
import EHNetwork
import EHParsing
import SwiftUI
import WebKit

/// What the session diagnostics show: cookie names, Booleans, profile numbers and the user agent (not a secret; A4
/// compares it with the one the structure check used). Never a cookie value.
nonisolated struct SessionDiagnosticsReport: Equatable, Sendable {
    struct Site: Equatable, Sendable {
        let site: EHSite
        /// The names in the site's jar, sorted.
        let cookieNames: [String]
        /// The jar's `sp` as a number; nil without one (or not a number).
        let profileNumber: Int?
        /// `AccountService.profileDiagnostics(for:)` described; nil before a run.
        let profileRun: String?
    }

    let sites: [Site]
    let isLoggedIn: Bool
    let isWebKit: Bool
    /// `UserAgentStore.current`, what every URLSession request sends.
    let userAgent: String
    /// Whether a session WebView's `navigator.userAgent` could be read for the consistency check.
    let webViewUserAgentRead: Bool
    /// nil when the WebView store did not answer in time (`WebSessionBridge.storeTimeout`).
    let consistency: SessionConsistency?
    /// `AppEnvironment.forumProfileStep` described.
    let forumProfile: String
}

/// Builds the report and describes results; values never leave the stores.
@MainActor enum SessionDiagnostics {
    static func collect(_ environment: AppEnvironment) async -> SessionDiagnosticsReport {
        await environment.refreshSession()
        let snapshot = environment.session
        var sites: [SessionDiagnosticsReport.Site] = []
        for site in EHSite.allCases {
            let jar = snapshot.cookies[site] ?? [:]
            let run = await environment.account.profileDiagnostics(for: site)
            sites.append(SessionDiagnosticsReport.Site(
                site: site, cookieNames: jar.keys.sorted(),
                profileNumber: jar[CookieNames.profile].flatMap { Int($0) }, profileRun: run.map(describe)
            ))
        }
        let webUserAgent = await sessionWebViewUserAgent(dataStore: environment.bridge.dataStore)
        let consistency = try? await environment.bridge.consistency(webUserAgent: webUserAgent ?? "")
        return SessionDiagnosticsReport(
            sites: sites, isLoggedIn: environment.isLoggedIn, isWebKit: await environment.userAgents.isWebKit,
            userAgent: await environment.userAgents.current, webViewUserAgentRead: webUserAgent != nil,
            consistency: consistency, forumProfile: describe(environment.forumProfileStep)
        )
    }

    /// `navigator.userAgent` of a WebView on the session store that loads nothing (no request), configured as the
    /// session WebViews are (`WKWebViewConfiguration.app()`); nil when unreadable.
    static func sessionWebViewUserAgent(dataStore: WKWebsiteDataStore) async -> String? {
        let configuration = WKWebViewConfiguration.app()
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let value = try? await webView.evaluateJavaScript("navigator.userAgent", contentWorld: .defaultClient)
        guard let userAgent = value as? String, !userAgent.isEmpty else { return nil }
        return userAgent
    }

    static func describe(_ diagnostics: ProfileDiagnostics) -> String {
        let after = diagnostics.profileCookieAfter.map(String.init) ?? "none"
        return "\(describe(diagnostics.outcome)), server set sp: \(yesNo(diagnostics.serverSetProfileCookie)), "
            + "sp after: \(after)"
    }

    static func describe(_ outcome: ProfileOutcome) -> String {
        switch outcome {
        case .alreadySelected(let number): "alreadySelected(\(number))"
        case .selected(let number): "selected(\(number))"
        case .created(let number): "created(\(number))"
        case .noProfiles: "noProfiles"
        case .failed: "failed"
        case .stopped(let issue): "stopped(\(name(of: issue)))"
        }
    }

    static func describe(_ step: ForumProfileStep?) -> String {
        switch step {
        case nil: "none"
        case .loaded: "loaded"
        case .notStored: "notStored"
        case .unavailable(let reason): "unavailable (\(name(of: reason)))"
        case .skipped(let issue): "skipped (\(name(of: issue)))"
        }
    }

    /// Why the profile page gave nothing: the case name and a status code, never anything of the page.
    static func name(of failure: ForumProfileFailure) -> String {
        switch failure {
        case .rules: "rules"
        case .notAProfilePage: "notAProfilePage"
        case .page(let outcome): name(of: outcome)
        case .notice(let issue): "notice \(name(of: issue))"
        }
    }

    static func name(of outcome: BackgroundPageOutcome) -> String {
        switch outcome {
        case .loaded: "loaded"
        case .httpStatus(let status): "httpStatus \(status)"
        case .challenged: "challenged"
        case .challengeTimedOut: "challengeTimedOut"
        case .timedOut: "timedOut"
        case .throttled: "throttled"
        case .tooManyNavigations: "tooManyNavigations"
        case .failed: "failed"
        }
    }

    /// granted or denied; a site notice by its name (ExHentai's empty page counts as denied); other errors by kind.
    static func describe(activation result: Result<ExAccess, any Error>) -> String {
        switch result {
        case .success(.granted): return "granted"
        case .success(.denied): return "denied"
        case .failure(let error):
            if case EHNetworkError.issue(.exAccessDenied)? = error as? EHNetworkError { return "denied" }
            return describe(error)
        }
    }

    /// `site`'s front page as the site answers it now (A4 checks each login's session with it).
    ///
    /// The cached answer is evicted first, then the page is asked with `refresh: true`: a reload alone is not enough,
    /// because a 401, 403 or 503 still falls back to a cached page (`EHClient.send`). With nothing cached under the
    /// URL, the page can only come from the network, or the request fails. `EHService.galleryList` does not say where
    /// its page came from, so "source: network" follows from the eviction. One request (two when the user agrees to
    /// switch the site to the Compact view).
    static func loadFrontPage(site: EHSite, environment: AppEnvironment) async -> String {
        let query = ListQuery(source: .front)
        await environment.client.evictCache(for: EHRequests.list(query, site: site))
        let result = await Result(awaiting: {
            try await environment.service.galleryList(query, site: site, refresh: true)
        })
        await environment.refreshSession()
        return describe(frontPage: result)
    }

    /// The number of galleries, whether the page is in the Compact view, and where it came from (always the network:
    /// see `loadFrontPage(site:environment:)`).
    static func describe(frontPage result: Result<GalleryListPage, any Error>) -> String {
        switch result {
        case .success(let page):
            let compact = switch page.displayMode {
            case nil: "no selector"
            case .compact?: "yes"
            case let mode?: "no (\(mode))"
            }
            return "\(page.items.count) items, Compact: \(compact), source: network"
        case .failure(let error):
            switch error as? ListServiceError {
            case .displayModeNotCompact(let mode)?: return "Compact: no (\(mode)), switch declined"
            case .displayModeStillNotCompact(let mode)?: return "Compact: still no (\(mode))"
            case nil: return describe(error)
            }
        }
    }

    /// An error by its kind; none of these carries a cookie value.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as EHNetworkError:
            switch error {
            case .issue(let issue): name(of: issue)
            case .httpStatus(let status): "HTTP \(status)"
            case .transport(let code): "transport error \(code.rawValue)"
            case .cancelled: "cancelled"
            case .paused(let pause): "paused (\(name(of: pause.reason)))"
            case .sessionEnded: "session ended"
            }
        case is CookieStoreError: "cookie store not loaded"
        case let error as KeychainError: "Keychain error \(error.status)"
        case is CancellationError: "cancelled"
        default: "error: \(type(of: error))"
        }
    }

    static func name(of issue: ResponseIssue) -> String {
        switch issue {
        case .banned: "banned"
        case .tooManyRequests: "tooManyRequests"
        case .bandwidthExceeded: "bandwidthExceeded"
        case .exAccessDenied: "exAccessDenied"
        case .keyMismatch: "keyMismatch"
        }
    }

    static func name(of reason: PauseReason) -> String {
        switch reason {
        case .banned: "banned"
        case .tooManyRequests: "tooManyRequests"
        }
    }

    static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
}

/// Session diagnostics (DEBUG builds only): what A4 checks after each login.
///
/// Opening the page sends nothing. The three buttons send site requests (Activate ExHentai, the two front pages);
/// they are for A4, with the user's consent. One runs at a time. The toolbar's overflow menu repeats the EH front page
/// for the UI tests of its overflow path.
struct SessionDiagnosticsView: View {
    private enum Action: Equatable {
        case activate
        case frontPage(EHSite)
    }

    @Environment(AppEnvironment.self) private var environment
    @State private var report: SessionDiagnosticsReport?
    @State private var running: Action?
    @State private var activation: String?
    @State private var frontPages: [EHSite: String] = [:]

    var body: some View {
        Form {
            if let report {
                reportSections(report)
            } else {
                ProgressView()
            }
            Section("Network") {
                Button("Activate ExHentai") { run(.activate) }
                    .disabled(running != nil)
                    .accessibilityIdentifier("diagnostics.activate")
                if let activation {
                    LabeledContent("ExHentai", value: activation)
                }
                ForEach(EHSite.allCases, id: \.self) { site in
                    Button(site == .eh ? "Load EH Front Page" : "Load EX Front Page") { run(.frontPage(site)) }
                        .disabled(running != nil)
                        .accessibilityIdentifier("diagnostics.front.\(site.rawValue)")
                    if let result = frontPages[site] {
                        LabeledContent("\(site.rawValue.uppercased()) front page", value: result)
                            .accessibilityIdentifier("diagnostics.front.\(site.rawValue).result")
                    }
                }
            }
        }
        .navigationTitle("Session Diagnostics")
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await reload() }
                }
                .accessibilityIdentifier("diagnostics.refresh")
            }
            // Always in the overflow menu: UI tests check `tapToolbarItem`'s way through the menu with it.
            ToolbarOverflowMenu {
                Button("Load EH Front Page", systemImage: "list.bullet") { run(.frontPage(.eh)) }
                    .disabled(running != nil)
                    .accessibilityIdentifier("diagnostics.overflow.front.eh")
            }
        }
        .task { await reload() }
    }

    @ViewBuilder
    private func reportSections(_ report: SessionDiagnosticsReport) -> some View {
        Section("Session") {
            LabeledContent("isLoggedIn", value: SessionDiagnostics.yesNo(report.isLoggedIn))
            LabeledContent("Forum profile", value: report.forumProfile)
        }
        ForEach(report.sites, id: \.site) { site in
            Section(site.site.rawValue.uppercased()) {
                LabeledContent("Cookies", value: Self.list(site.cookieNames))
                LabeledContent("sp", value: site.profileNumber.map(String.init) ?? "none")
                LabeledContent("Profile run", value: site.profileRun ?? "none")
            }
        }
        Section("User Agent") {
            LabeledContent("isWebKit", value: SessionDiagnostics.yesNo(report.isWebKit))
            Text(report.userAgent)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
        Section("SessionConsistency") {
            if let consistency = report.consistency {
                LabeledContent("missingInWebView", value: Self.list(consistency.missingInWebView))
                LabeledContent("missingInStore", value: Self.list(consistency.missingInStore))
                LabeledContent("differingValues", value: Self.list(consistency.differingValues))
                LabeledContent("userAgentMatches", value: SessionDiagnostics.yesNo(consistency.userAgentMatches))
            } else {
                LabeledContent("WebView store", value: "did not answer in time")
            }
            if !report.webViewUserAgentRead {
                LabeledContent("WebView user agent", value: "unreadable")
            }
        }
    }

    private static func list(_ names: [String]) -> String {
        names.isEmpty ? "[]" : names.joined(separator: ", ")
    }

    private func reload() async {
        report = await SessionDiagnostics.collect(environment)
    }

    private func run(_ action: Action) {
        guard running == nil else { return }
        running = action
        Task {
            defer { running = nil }
            switch action {
            case .activate:
                let result = await Result(awaiting: { try await environment.activateExHentai() })
                activation = SessionDiagnostics.describe(activation: result)
            case .frontPage(let site):
                frontPages[site] = await SessionDiagnostics.loadFrontPage(site: site, environment: environment)
            }
            await reload()
        }
    }
}

extension Result where Failure == any Error {
    /// The result of an async throwing `body`.
    fileprivate init(awaiting body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
#endif
