import EHNetwork
import Foundation
import Testing
import WebKit

@testable import Eros

/// The web login's WebView on the custom scheme `eros-test://`: a failed load, a cancelled one, and new-window links.
///
/// Each test has five minutes (`.timeLimit`): some hold a page or a WebKit store call until they let it go, and one
/// that never lets go must fail at the limit, not hang the run (the test process is then ended and started again
/// for the tests after it); five, as WebKit's processes are slow on a busy host (an account flow test once took
/// 143 s under a heavy load), and as `scripts/test.sh` gives a test by default.
@MainActor @Suite(.warmsUpWebContent, .timeLimit(.minutes(5))) struct WebLoginSessionTests {
    /// A navigation action that asks for a new window (no target frame) for `request`.
    private final class NewWindowAction: WKNavigationAction {
        private let newRequest: URLRequest

        init(_ url: URL) {
            newRequest = URLRequest(url: url)
            super.init()
        }

        override var request: URLRequest { newRequest }
        override var targetFrame: WKFrameInfo? { nil }
    }

    private func makeSession(
        _ handler: ForumPageHandler
    ) -> WebLoginSession {
        WebLoginSession(
            environment: AppEnvironment(uiTesting: true), onFinish: { _ in },
            startURL: ForumPageHandler.loginPage, schemeHandler: (handler, ForumPageHandler.scheme)
        )
    }

    @Test func failedLoadOffersRetry() async {
        let calls = CallCounter()
        let handler = ForumPageHandler { _ in
            calls.next() == 1
                ? PageAnswer(body: "", failure: .notConnectedToInternet)
                : PageAnswer(body: "<html><body>Login</body></html>")
        }
        let session = makeSession(handler)
        defer { Task { await session.close() } }
        session.start()
        #expect(await eventually { session.loadFailed })

        session.retry()
        #expect(!session.loadFailed)
        #expect(await eventually { handler.requests.count == 2 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!session.loadFailed)
    }

    @Test func cancelledLoadIsNoFailure() async {
        let handler = ForumPageHandler { _ in nil }
        let session = makeSession(handler)
        defer { Task { await session.close() } }
        session.start()
        #expect(await eventually { handler.requests.count == 1 })
        session.webView.stopLoading()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!session.loadFailed)
    }

    /// A web content process that ends (it crashed, or the system took its memory) is a failed load: the sheet
    /// offers Try Again. Once the sheet is closed it no longer counts.
    @Test func anEndedContentProcessOffersRetry() async {
        let handler = ForumPageHandler { _ in PageAnswer(body: "<html><body>Login</body></html>") }
        let session = makeSession(handler)
        session.start()
        #expect(await eventually { handler.requests.count == 1 })
        #expect(!session.loadFailed)
        session.webViewWebContentProcessDidTerminate(session.webView)
        #expect(session.loadFailed)

        session.retry()
        await session.close()
        session.webViewWebContentProcessDidTerminate(session.webView)
        #expect(!session.loadFailed)
    }

    /// The web login's page gets the UA the probe reads, the one URLSession sends afterwards with the cookies the page
    /// set (a Cloudflare clearance is bound to it): on the iPad too, where WebKit would otherwise send the Mac UA (M2
    /// review A-I1).
    @Test func thePageGetsTheProbesUserAgent() async throws {
        let probed = try await WebKitUserAgentProbe.read()
        let handler = ForumPageHandler { _ in PageAnswer(body: "<html><body>Login</body></html>") }
        let session = makeSession(handler)
        defer { Task { await session.close() } }
        session.start()
        #expect(await eventually(within: WebContentWarmUp.firstAnswerLimit) { handler.requests.count == 1 })
        let request = try #require(handler.received.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == probed)
        #expect(session.webView.configuration.defaultWebpagePreferences.preferredContentMode == .mobile)
        #expect(await eventually { !session.webView.isLoading })
        let reported = try await session.webView.evaluateJavaScript("navigator.userAgent", contentWorld: .defaultClient)
        #expect(reported as? String == probed)
    }

    @Test func newWindowLinksOpenInPlace() async {
        let handler = ForumPageHandler { _ in PageAnswer(body: "<html><body>Page</body></html>") }
        let session = makeSession(handler)
        defer { Task { await session.close() } }
        let target = ForumPageHandler.profile(1)
        let result = session.webView(
            session.webView, createWebViewWith: WKWebViewConfiguration(), for: NewWindowAction(target),
            windowFeatures: WKWindowFeatures()
        )
        #expect(result == nil)
        #expect(await eventually { handler.requests.contains(target) })
    }

    @Test func onlyWebLinksOpenInPlace() {
        func opens(_ string: String?, _ extra: String? = nil) -> Bool {
            WebLoginSession.opensInPlace(string.flatMap { URL(string: $0) }, extraScheme: extra)
        }
        #expect(opens("https://forums.e-hentai.org/x"))
        #expect(opens("http://example.com/"))
        #expect(!opens("javascript:void(0)"))
        #expect(!opens("file:///etc/hosts"))
        #expect(!opens("data:text/html,x"))
        #expect(!opens("about:blank"))
        #expect(!opens(nil))
        #expect(opens("eros-test://forums/x", "eros-test"))
        #expect(!opens("eros-test://forums/x", nil))
    }
}
