import SwiftUI

@main
struct ErosApp: App {
    /// Offline and in memory for UI tests and when XCTest hosts the app (`AppEnvironment.forLaunch()`).
    @State private var environment = AppEnvironment.forLaunch()

    /// A URL the app is asked to open (an `eros://` link, entry E2) goes to the router whether or not `LaunchGate` is
    /// ready: before the tabs show, a link waits for them, and a URL it cannot open waits for its alert.
    var body: some Scene {
        WindowGroup {
            LaunchGate()
                .environment(environment)
                .task { await environment.start() }
                .onOpenURL { environment.router.open(url: $0) }
        }
    }
}

/// The system progress view until the environment has a user agent (the first launch reads it, which takes a
/// moment), then the tabs: no screen can send a site request before that.
///
/// It reports its scene's phases to the clipboard monitor (`ClipboardLinkMonitor.scenePhaseChanged(to:)`, entry E3),
/// whether the tabs show yet or not; with two windows each reports its own, and the monitor looks once for both.
private struct LaunchGate: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .onChange(of: scenePhase) { _, phase in
                environment.clipboardLinks.scenePhaseChanged(to: phase)
            }
    }

    @ViewBuilder private var content: some View {
        if environment.isReady {
            RootTabView()
        } else {
            ProgressView()
        }
    }
}
