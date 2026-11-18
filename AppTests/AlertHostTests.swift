import EHModels
import EHNetwork
import Observation
import SwiftUI
import Testing
import UIKit

@testable import Eros

/// `alertHost()` and `siteSettingNoticeAlert()` on real windows: the alerts the system shows.
///
/// Each test has a minute (`.timeLimit`): some wait for a question's answer (`SiteSettingNoticeCenter.confirm`), and
/// one whose answer never comes must fail at the limit, not hang the run (the test process is then ended and started
/// again for the tests after it).
@MainActor @Suite(.timeLimit(.minutes(1))) struct AlertHostTests {
    /// What a test's sheet is bound to.
    @MainActor @Observable final class SheetSwitch {
        var isOn = true
    }

    private struct SheetRoot: View {
        let model: SheetSwitch

        var body: some View {
            Color.clear
                .alertHost()
                .sheet(isPresented: Binding(get: { model.isOn }, set: { model.isOn = $0 })) {
                    Text("Fake sheet").alertHost()
                }
        }
    }

    @Test func alertShowsAboveAnOpenSheet() async throws {
        let environment = AppEnvironment(uiTesting: true)
        let host = try Self.show(
            Color.clear.alertHost().sheet(isPresented: .constant(true)) { Text("Fake sheet").alertHost() },
            environment: environment
        )
        defer { Self.hide(host) }
        #expect(await eventually { host.presentedViewController != nil })
        // Both hosts have appeared before the alert goes in.
        #expect(await eventually { environment.alerts.activeHost == 2 })
        environment.alerts.present(HostedAlert(title: "Fake alert", actions: [.init("OK")]))
        #expect(await eventually {
            (host.presentedViewController?.presentedViewController as? UIAlertController)?.title == "Fake alert"
        })
    }

    @Test func rootTakesTheAlertBackWhenTheSheetCloses() async throws {
        let environment = AppEnvironment(uiTesting: true)
        let model = SheetSwitch()
        let host = try Self.show(SheetRoot(model: model), environment: environment)
        defer { Self.hide(host) }
        #expect(await eventually { host.presentedViewController != nil })
        #expect(await eventually { environment.alerts.activeHost == 2 })
        environment.alerts.present(HostedAlert(title: "Fake alert", actions: [.init("OK")]))
        #expect(await eventually {
            (host.presentedViewController?.presentedViewController as? UIAlertController)?.title == "Fake alert"
        })
        model.isOn = false
        #expect(await eventually {
            (host.presentedViewController as? UIAlertController)?.title == "Fake alert"
        })
    }

    @Test func siteSettingQuestionBecomesAHostedAlert() async throws {
        let environment = AppEnvironment(uiTesting: true)
        let host = try Self.show(Color.clear.alertHost().siteSettingNoticeAlert(), environment: environment)
        defer { Self.hide(host) }
        let answer = Task { await environment.notices.confirm(.compactView(current: .thumbnail), site: .eh) }
        #expect(await eventually { environment.alerts.current?.title == "Switch to the Compact view?" })
        let current = try #require(environment.alerts.current)
        #expect(current.actions.map(\.title) == ["Continue", "Cancel"])
        current.actions[1].perform()
        #expect(await !answer.value)
        #expect(await eventually { environment.alerts.current == nil })
    }

    @Test func secondQuestionIsShownAfterTheFirstIsAnswered() async throws {
        let environment = AppEnvironment(uiTesting: true)
        let host = try Self.show(Color.clear.alertHost().siteSettingNoticeAlert(), environment: environment)
        defer { Self.hide(host) }
        let first = Task { await environment.notices.confirm(.compactView(current: .thumbnail), site: .eh) }
        #expect(await eventually { environment.alerts.current != nil })
        let firstID = try #require(environment.alerts.current?.id)
        let second = Task { await environment.notices.confirm(.compactView(current: .thumbnail), site: .ex) }
        #expect(await eventually { environment.notices.waitingCount == 2 })
        #expect(environment.alerts.current?.id == firstID)

        // The pending question changes into the next one without passing nil.
        try #require(environment.alerts.current).actions[0].perform()
        #expect(await first.value)
        #expect(await eventually {
            environment.alerts.current != nil && environment.alerts.current?.id != firstID
        })
        #expect(environment.alerts.queuedCount == 1)
        #expect(environment.alerts.current?.message?.contains("ExHentai") == true)

        try #require(environment.alerts.current).actions[1].perform()
        #expect(await !second.value)
        #expect(await eventually { environment.alerts.current == nil })
    }

    @Test func withdrawnQuestionTakesTheAlertDown() async throws {
        let environment = AppEnvironment(uiTesting: true)
        let host = try Self.show(Color.clear.alertHost().siteSettingNoticeAlert(), environment: environment)
        defer { Self.hide(host) }
        let answer = Task { await environment.notices.confirm(.compactView(current: .thumbnail), site: .eh) }
        #expect(await eventually { environment.alerts.current != nil })
        answer.cancel()
        #expect(await !answer.value)
        #expect(await eventually { environment.alerts.current == nil })
    }

    /// Two windows' roots both follow the site setting questions: one question is one alert, not one per window, and
    /// its buttons answer it (M2 review A-M1).
    @Test func twoRootsPutUpOneAlertForAQuestion() async throws {
        let environment = AppEnvironment(uiTesting: true)
        let first = try Self.show(Color.clear.alertHost().siteSettingNoticeAlert(), environment: environment)
        defer { Self.hide(first) }
        let second = try Self.show(Color.clear.alertHost().siteSettingNoticeAlert(), environment: environment)
        defer { Self.hide(second) }
        #expect(await eventually { environment.alerts.activeHost == 2 })
        let answer = Task { await environment.notices.confirm(.compactView(current: .thumbnail), site: .eh) }
        #expect(await eventually { environment.alerts.current != nil })
        // Time for the other root to put up an alert of its own, if it would.
        try await Task.sleep(for: .milliseconds(300))
        #expect(environment.alerts.queuedCount == 1)
        try #require(environment.alerts.current).actions[0].perform()
        #expect(await answer.value)
        #expect(await eventually { environment.alerts.current == nil })
    }

    /// The login's failure goes through the app's alerts like any other alert without a text field: with another one
    /// up, both wait in the queue and show one after the other, instead of fighting for the sheet (M2 review A-M2).
    @Test func loginFailureTakesItsTurn() async throws {
        let environment = AppEnvironment(uiTesting: true)
        let host = try Self.show(Color.clear.alertHost(), environment: environment)
        defer { Self.hide(host) }
        #expect(await eventually { environment.alerts.activeHost == 1 })
        let other = HostedAlert(title: "Fake alert", actions: [.init("OK")])
        environment.alerts.present(other)
        environment.alerts.present(try #require(LoginFailureMessage.alert(for: LoginError.rejected)))
        #expect(LoginFailureMessage.alert(for: CancellationError()) == nil)
        #expect(environment.alerts.queuedCount == 2)
        #expect(await eventually { (host.presentedViewController as? UIAlertController)?.title == "Fake alert" })

        // What the first alert's button does: its action, then its alert leaves the queue; the login's failure is
        // next. (The system alert's own button cannot be tapped from here: taking the alert controller down from
        // outside does not tell SwiftUI, which then puts up nothing more. UI tests tap the buttons.)
        other.actions[0].perform()
        environment.alerts.dismiss(other.id)
        let next = try #require(environment.alerts.current)
        #expect(next.title == "Login Failed")
        #expect(next.message == LoginFailureMessage.text(for: LoginError.rejected))
        #expect(next.actions.map(\.title) == ["OK"])
        #expect(next.actions.map(\.role) == [.cancel])
        #expect(environment.alerts.queuedCount == 1)
    }

    // MARK: - Helpers

    /// `view` as the root of a window of its own on the host app's scene; returns the root controller.
    private static func show(_ view: some View, environment: AppEnvironment) throws -> UIViewController {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let controller = UIHostingController(rootView: view.environment(environment))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        windows[ObjectIdentifier(controller)] = window
        return controller
    }

    private static func hide(_ controller: UIViewController) {
        guard let window = windows.removeValue(forKey: ObjectIdentifier(controller)) else { return }
        window.isHidden = true
        window.rootViewController = nil
    }

    private static var windows: [ObjectIdentifier: UIWindow] = [:]
}
