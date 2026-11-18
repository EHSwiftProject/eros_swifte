import Observation
import SwiftUI

/// One alert for the hosts to show. A button runs its action, then the alert goes.
struct HostedAlert: Identifiable {
    struct Action {
        let title: String
        let role: ButtonRole?
        let perform: @MainActor () -> Void

        init(_ title: String, role: ButtonRole? = nil, perform: @escaping @MainActor () -> Void = {}) {
            self.title = title
            self.role = role
            self.perform = perform
        }
    }

    let id: UUID
    let title: String
    let message: String?
    let actions: [Action]

    init(id: UUID = UUID(), title: String, message: String? = nil, actions: [Action]) {
        self.id = id
        self.title = title
        self.message = message
        self.actions = actions
    }
}

/// The app's alerts in a queue, one at a time. Every view that can show an alert (the root and the content root of
/// every sheet, see `alertHost()`) attaches as a host; only the latest host still on screen shows `current`, so an alert
/// appears above an open sheet and falls back to the root once the sheet is gone.
///
/// Alerts of the app go through `AppEnvironment.alerts`; only an alert with a text field is a SwiftUI `.alert` of its
/// own.
@MainActor @Observable final class AlertCenter {
    /// The oldest alert not yet answered or dismissed.
    var current: HostedAlert? { queue.first }
    /// The alerts waiting, `current` included.
    var queuedCount: Int { queue.count }
    /// The latest attached host still present: only it shows `current`.
    var activeHost: Int? { hosts.last }

    private var queue: [HostedAlert] = []
    private var hosts: [Int] = []
    @ObservationIgnored private var lastHost = 0

    /// Shown once every alert before it is gone; an id already queued is ignored.
    func present(_ alert: HostedAlert) {
        guard !queue.contains(where: { $0.id == alert.id }) else { return }
        queue.append(alert)
    }

    /// Takes the alert down, or out of the queue, without running an action; an unknown id does nothing.
    func dismiss(_ id: HostedAlert.ID) {
        queue.removeAll { $0.id == id }
    }

    /// A view that can show alerts appeared; the returned id goes to `detachHost(_:)`.
    func attachHost() -> Int {
        lastHost += 1
        hosts.append(lastHost)
        return lastHost
    }

    /// That view is gone.
    func detachHost(_ id: Int) {
        hosts.removeAll { $0 == id }
    }
}

private struct AlertHostModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @State private var hostID: Int?

    func body(content: Content) -> some View {
        let alerts = environment.alerts
        let isShowing = alerts.current != nil && hostID != nil && alerts.activeHost == hostID
        content
            .onAppear {
                if hostID == nil { hostID = alerts.attachHost() }
            }
            .onDisappear {
                if let hostID { alerts.detachHost(hostID) }
                hostID = nil
            }
            .alert(
                alerts.current?.title ?? "",
                // Only the buttons answer: the alert goes through `dismiss(_:)`, never through this binding.
                isPresented: Binding(get: { isShowing }, set: { _ in }),
                presenting: alerts.current
            ) { alert in
                ForEach(Array(alert.actions.enumerated()), id: \.offset) { _, action in
                    Button(action.title, role: action.role) {
                        action.perform()
                        alerts.dismiss(alert.id)
                    }
                }
            } message: { alert in
                if let message = alert.message { Text(message) }
            }
    }
}

extension View {
    /// Lets this view show the app's alerts (`AppEnvironment.alerts`). Put it on the root and on the content root of
    /// every sheet; the latest one on screen shows the current alert.
    func alertHost() -> some View {
        modifier(AlertHostModifier())
    }
}
