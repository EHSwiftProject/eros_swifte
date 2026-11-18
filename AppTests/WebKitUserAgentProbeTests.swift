import Foundation
import Testing
import WebKit

@testable import Eros

/// Runs inside the Eros app on the simulator. The probe loads nothing from the network, so neither does this suite.
@MainActor @Suite struct WebKitUserAgentProbeTests {
    @Test func probeReadsTheWebKitUserAgent() async throws {
        let first = try await WebKitUserAgentProbe.read()
        #expect(!first.isEmpty)
        #expect(first.contains("AppleWebKit"))
        #expect(!first.contains("Chrome"))
        let second = try await WebKitUserAgentProbe.read()
        #expect(second == first)
        // The empty-document path reads the same value.
        let fallback = try await WebKitUserAgentProbe.read(
            timeout: .seconds(5), startsWithEmptyDocument: true, navigationObserver: nil
        )
        #expect(fallback == first)
    }

    @Test func probeLoadsNoPage() async throws {
        let recorder = NavigationRecorder()
        _ = try await WebKitUserAgentProbe.read(
            timeout: .seconds(5), startsWithEmptyDocument: false, navigationObserver: recorder.record
        )
        #expect(!recorder.sawNetworkRequest)

        // The empty-document path navigates once, to about:blank, which the recorder sees.
        let fallback = NavigationRecorder()
        _ = try await WebKitUserAgentProbe.read(
            timeout: .seconds(5), startsWithEmptyDocument: true, navigationObserver: fallback.record
        )
        #expect(!fallback.sawNetworkRequest)
        #expect(!fallback.urls.isEmpty)
        #expect(fallback.urls.allSatisfy { $0?.scheme == "about" })
    }
}

/// Every navigation request a probe's web view was asked to allow.
@MainActor private final class NavigationRecorder {
    private(set) var urls: [URL?] = []

    var sawNetworkRequest: Bool {
        urls.contains { ["http", "https"].contains($0?.scheme?.lowercased() ?? "") }
    }

    func record(_ request: URLRequest) {
        urls.append(request.url)
    }
}
