import EHModels
import EHNetwork
import Foundation
import WebKit

/// Reads the device's WebKit user agent, the one every site request sends and every WebView reports (user decision
/// 2026-11-05), without loading a page or sending any request.
@MainActor enum WebKitUserAgentProbe {
    /// How the UA is read, as `UserAgentCacheVersion` keeps it: 2 since every WebView of the app asks for mobile
    /// content (`WKWebViewConfiguration.app()`). Before, an iPad whose read took the empty-document path got and cached
    /// the Mac UA its WebViews then loaded pages with (M2 review A-I1).
    nonisolated static let readingVersion = 2

    nonisolated enum ProbeError: Error, Equatable {
        /// No answer within the timeout.
        case timedOut
        /// `navigator.userAgent` was not a non-empty string, or the web content process ended.
        case unreadable
    }

    /// navigator.userAgent of a fresh WKWebView (non-persistent store, no customUserAgent) that loads nothing; when the
    /// empty view cannot evaluate script, it first loads an empty HTML string (no request either way).
    ///
    /// Throws `ProbeError.timedOut` once `timeout` has passed, without waiting any longer for WebKit (a call into a
    /// hung web content process may never return), and `CancellationError` when the caller is cancelled.
    static func read(timeout: Duration = .seconds(5)) async throws -> String {
        try await read(timeout: timeout, startsWithEmptyDocument: false, navigationObserver: nil)
    }

    /// `read(timeout:)` with two hooks for tests: `startsWithEmptyDocument` takes the empty-HTML path at once, and
    /// `navigationObserver` sees the request of every navigation the web view asks to make. Only `about:` navigations
    /// are allowed; any other is cancelled.
    static func read(
        timeout: Duration, startsWithEmptyDocument: Bool, navigationObserver: (@MainActor (URLRequest) -> Void)?
    ) async throws -> String {
        let navigator = Navigator(observer: navigationObserver)
        let webView = makeWebView()
        webView.navigationDelegate = navigator
        return try await withDeadline(timeout) {
            if !startsWithEmptyDocument, let value = try? await userAgent(of: webView) {
                return value
            }
            try await navigator.loadEmptyDocument(in: webView)
            return try await userAgent(of: webView)
        }
    }

    /// A web view on a non-persistent store of its own (the one exception to the shared session store, preflight L24)
    /// and the configuration of every WebView of the app (`WKWebViewConfiguration.app()`: mobile content, no
    /// `customUserAgent`, no `applicationNameForUserAgent` of its own). It reports the UA every session WebView sends
    /// and reports, the same with or without a loaded document; on the iPad that holds only because of the mobile
    /// content mode (WebKit's default there loads every page as a desktop browser, with the Mac UA).
    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration.app()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }

    /// Reads `navigator.userAgent` in the client's own content world (no page script can see or change it).
    private static func userAgent(of webView: WKWebView) async throws -> String {
        let value = try await webView.evaluateJavaScript("navigator.userAgent", contentWorld: .defaultClient)
        guard let userAgent = value as? String, !userAgent.isEmpty else { throw ProbeError.unreadable }
        return userAgent
    }

    /// `operation`'s result, `ProbeError.timedOut` once `timeout` has passed, or `CancellationError` when the caller
    /// is cancelled, whichever comes first (`WebKitDeadline`); `operation` is cancelled once the race is decided, and
    /// not waited for.
    private static func withDeadline(
        _ timeout: Duration, _ operation: @escaping @MainActor @Sendable () async throws -> String
    ) async throws -> String {
        do {
            return try await WebKitDeadline.run(timeout, operation)
        } catch is WebKitDeadline.TimedOut {
            throw ProbeError.timedOut
        }
    }

    /// The probe web view's navigation delegate: allows only `about:` navigations and reports when the empty document
    /// has loaded.
    private final class Navigator: NSObject, WKNavigationDelegate {
        private let observer: (@MainActor (URLRequest) -> Void)?
        private var pending: CheckedContinuation<Void, any Error>?

        init(observer: (@MainActor (URLRequest) -> Void)?) {
            self.observer = observer
        }

        /// Loads an empty HTML string with no base URL (about:blank: nothing is requested) and waits until it has
        /// loaded; cancellation ends the wait.
        func loadEmptyDocument(in webView: WKWebView) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    pending = continuation
                    webView.loadHTMLString("", baseURL: nil)
                }
            } onCancel: {
                Task { @MainActor in self.settle(CancellationError()) }
            }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            observer?(navigationAction.request)
            return navigationAction.request.url?.scheme?.lowercased() == "about" ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            settle(nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            settle(error)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
        ) {
            settle(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            settle(ProbeError.unreadable)
        }

        private func settle(_ error: (any Error)?) {
            guard let pending else { return }
            self.pending = nil
            if let error {
                pending.resume(throwing: error)
            } else {
                pending.resume()
            }
        }
    }
}

extension WKWebViewConfiguration {
    /// The configuration every WebView of the app starts from (the UA probe, the session WebViews of the web login
    /// and of `BackgroundPage`, the session diagnostics): WebKit's defaults, but mobile content (user decision
    /// 2026-11-17). On the iPad WebKit's default (`.recommended`) loads pages as a desktop browser and sends the Mac
    /// UA, while a WebView that loads nothing reports the iPad's; with `.mobile` every WebView of the app sends and
    /// reports the one UA the probe reads, which URLSession sends too (design §5.2; the iPhone's are mobile anyway).
    /// It is WebKit's own content-mode preference, Safari's "Request Desktop Website" switch: no `customUserAgent`,
    /// nothing injected.
    static func app() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        return configuration
    }
}

/// The app's UA cache (`UserDefaultsUserAgentCache`) with the version of how the UA was read
/// (`WebKitUserAgentProbe.readingVersion`), under its own key: a UA saved by an older way of reading, or without a
/// version, is not loaded, so the next launch reads the UA again before any request (once, after an update that
/// changed the reading), and saving writes the version.
///
/// A new version also drops the UA-bound Cloudflare cookies once (`cf_clearance`, `cf_duid`, …): with nothing loaded
/// there is no UA to compare with, so the UA read is adopted as a changed one (`adoptWebKitUserAgent`), on every
/// device. On the iPad that is wanted (a clearance the web login brought may be bound to the Mac UA); on an iPhone,
/// whose UA did not change, a clearance still good goes too, and the next challenge needs the web login again. Raising
/// `WebKitUserAgentProbe.readingVersion` is therefore a decision of its own (2 since M2's review, 2026-11-17; M2 was
/// not released).
actor UserAgentCacheVersion: UserAgentCache {
    nonisolated static let versionKey = "eros.webKitUserAgentReadingVersion"

    private let base: any UserAgentCache
    private let defaults: UserDefaults
    private let version: Int

    /// The version is kept in the suite `suiteName` (nil, or one UserDefaults refuses: the standard defaults, where
    /// the app's `UserDefaultsUserAgentCache` keeps the UA).
    init(base: any UserAgentCache, suiteName: String? = nil, version: Int = WebKitUserAgentProbe.readingVersion) {
        self.base = base
        defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.version = version
    }

    func load() async -> WebKitUserAgent? {
        guard defaults.integer(forKey: Self.versionKey) == version else { return nil }
        return await base.load()
    }

    func save(_ userAgent: WebKitUserAgent) async {
        await base.save(userAgent)
        defaults.set(version, forKey: Self.versionKey)
    }
}
