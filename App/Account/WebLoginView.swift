import EHNetwork
import os
import SwiftUI
import WebKit

/// The site's own login page in a `WKWebView` (`WebLoginSession.webView`).
struct WebLoginView: UIViewRepresentable {
    let session: WebLoginSession

    func makeUIView(context: Context) -> WKWebView {
        session.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

/// The web login sheet: the page (a `ContentUnavailableView` with Try Again over it when it could not load), and a
/// close button; closing it before the login completed writes nothing. While the login completes
/// (`AppEnvironment.isLoggingIn`) it cannot be closed, neither by the button nor by a swipe.
struct WebLoginSheet: View {
    /// Called once the login completed (`.success`) or failed with anything but `LoginError.rejected`.
    let onFinish: @MainActor (Result<Void, any Error>) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var session: WebLoginSession?

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    WebLoginView(session: session)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay {
                            if session.loadFailed {
                                ContentUnavailableView {
                                    Label("Could Not Load the Page", systemImage: "wifi.exclamationmark")
                                } description: {
                                    Text("Check the connection and try again.")
                                } actions: {
                                    Button("Try Again") { session.retry() }
                                        .accessibilityIdentifier("login.web.retry")
                                }
                                .background(.background)
                            }
                        }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Log In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .disabled(environment.isLoggingIn)
                        .accessibilityIdentifier("login.web.close")
                }
            }
        }
        .alertHost()
        .interactiveDismissDisabled(environment.isLoggingIn)
        .onAppear {
            guard session == nil else { return }
            let session = WebLoginSession(environment: environment, onFinish: onFinish)
            self.session = session
            session.start()
        }
        .onDisappear {
            guard let session else { return }
            Task { await session.close() }
        }
    }
}

/// One web login: a WebView on the session store (`WebSessionBridge.dataStore`; the app's configuration,
/// `WKWebViewConfiguration.app()`, so the page gets the UA the app's requests send; no `customUserAgent`, no scripts),
/// started at `EHEndpoints.webLoginStart` (about:blank in UI testing, so automated tests never reach the site).
///
/// When a main-frame load finishes on the completion page (`WebLoginRules.isCompletion`), the store's cookies decide
/// (`AppEnvironment.completeWebLogin(from:)`). A rejected login keeps the page open: the bare index page can also be a
/// Cloudflare challenge or a forum error the user is still working through. Closing before the login
/// completed writes nothing to the cookie store and removes the site cookies the pages left in the WebView store.
///
/// A page that fails to load (no connection, a dead web content process) sets `loadFailed`, and `retry()` loads the
/// start page again. A load that was cancelled or turned into a download does not count, and neither does an HTTP
/// error status: a Cloudflare challenge is a 403 the user finishes on the page. A link that asks for a new window
/// (`target=_blank`) opens in this WebView.
@MainActor @Observable final class WebLoginSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    @ObservationIgnored let webView: WKWebView
    /// The page could not be loaded; the sheet offers Try Again.
    private(set) var loadFailed = false
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private let onFinish: @MainActor (Result<Void, any Error>) -> Void
    @ObservationIgnored private let startURL: URL
    @ObservationIgnored private let extraScheme: String?
    @ObservationIgnored private var isCompleting = false
    @ObservationIgnored private var isCompleted = false
    @ObservationIgnored private var isClosed = false

    /// `startURL` nil: about:blank in UI testing, else `EHEndpoints.webLoginStart`. `schemeHandler` is for tests only:
    /// a custom scheme the WebView serves (its pages open in place too).
    init(
        environment: AppEnvironment, onFinish: @escaping @MainActor (Result<Void, any Error>) -> Void,
        startURL: URL? = nil, schemeHandler: (handler: any WKURLSchemeHandler, scheme: String)? = nil
    ) {
        self.environment = environment
        self.onFinish = onFinish
        self.startURL = startURL ?? (environment.uiTesting ? URL(string: "about:blank")! : EHEndpoints.webLoginStart)
        extraScheme = schemeHandler?.scheme
        let configuration = WKWebViewConfiguration.app()
        configuration.websiteDataStore = environment.bridge.dataStore
        if let schemeHandler {
            configuration.setURLSchemeHandler(schemeHandler.handler, forURLScheme: schemeHandler.scheme)
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Loads the start page.
    func start() {
        webView.load(URLRequest(url: startURL))
    }

    /// Loads the start page again after a failure.
    func retry() {
        loadFailed = false
        start()
    }

    /// A new-window request opens in this WebView: http, https, or `extraScheme` (the tests' scheme).
    nonisolated static func opensInPlace(_ url: URL?, extraScheme: String?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == extraScheme?.lowercased()
    }

    /// The sheet is gone: the WebView stops. Unless the login completed (or is completing), the WebView store loses
    /// both sites' cookies; the cookie store is not touched. A WebView store that does not answer in time is only
    /// logged (`clearWebStore()`): the clear still runs in its turn once it does (`clear(evenWhenGivenUp: true)`).
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        guard !isCompleted, !isCompleting else { return }
        await clearWebStore()
    }

    private static let log = Logger(subsystem: "proj.eros.swifte", category: "WebStore")

    /// ``WebSessionBridge/clear(evenWhenGivenUp:)`` with `evenWhenGivenUp: true`; a failure is logged by its domain
    /// and code only.
    private func clearWebStore() async {
        do {
            try await environment.bridge.clear(evenWhenGivenUp: true)
        } catch {
            Self.log.storeFailure("Clearing the web login's cookies", error)
        }
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // `target=_blank` and `window.open`: the same WebView (and so the same session store) loads it; no new window.
        if navigationAction.targetFrame == nil, !isClosed,
           Self.opensInPlace(navigationAction.request.url, extraScheme: extraScheme) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        loadDidFail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loadDidFail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed else { return }
        loadFailed = true
    }

    /// WebKit's own error domain and its code 102 (`WebKitErrorFrameLoadInterruptedByPolicyChange`, which the Swift
    /// overlay does not name).
    private static let webKitErrorDomain = "WebKitErrorDomain"
    private static let frameLoadInterruptedByPolicyChange = 102

    /// A cancelled load (-999) and one a policy turned into something else (102) are no failure.
    private func loadDidFail(_ error: any Error) {
        guard !isClosed else { return }
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == Self.webKitErrorDomain, error.code == Self.frameLoadInterruptedByPolicyChange { return }
        loadFailed = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed, !isCompleting, !isCompleted, let url = webView.url, WebLoginRules.isCompletion(url) else {
            return
        }
        isCompleting = true
        Task { await complete() }
    }

    private func complete() async {
        do {
            try await environment.completeWebLogin(from: webView)
            isCompleting = false
            isCompleted = true
            onFinish(.success(()))
            return
        } catch LoginError.rejected {
            // Stays open; see the type's documentation.
            isCompleting = false
        } catch {
            isCompleting = false
            onFinish(.failure(error))
        }
        // Closed while the cookies were being checked: what `close()` left for later.
        if isClosed { await clearWebStore() }
    }
}
