import SwiftUI

private struct SiteSettingNoticeAlertModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    /// The hosted alert of the question on screen.
    @State private var shown: HostedAlert.ID?

    func body(content: Content) -> some View {
        let notices = environment.notices
        let alerts = environment.alerts
        content.onChange(of: notices.pending, initial: true) { _, pending in
            // The pending question may change into the next one without passing nil: take the old alert down first.
            if let shown, shown != pending?.alertID { alerts.dismiss(shown) }
            shown = nil
            guard let pending else { return }
            // Its id is the question's, so the roots of two windows put up one alert; its buttons answer that question
            // only (`resolve(id:proceed:)`).
            let alert = HostedAlert(
                id: pending.alertID,
                title: SiteSettingNoticeText.title(for: pending.change),
                message: SiteSettingNoticeText.message(for: pending.change, site: pending.site),
                actions: [
                    .init("Continue") { notices.resolve(id: pending.id, proceed: true) },
                    .init("Cancel", role: .cancel) { notices.resolve(id: pending.id, proceed: false) },
                ]
            )
            shown = alert.id
            alerts.present(alert)
        }
    }
}

extension View {
    /// Shows the site setting questions (`SiteSettingNoticeCenter.pending`) as hosted alerts, above any sheet. Once, at
    /// the root, with `alertHost()` on the same view.
    func siteSettingNoticeAlert() -> some View {
        modifier(SiteSettingNoticeAlertModifier())
    }
}
