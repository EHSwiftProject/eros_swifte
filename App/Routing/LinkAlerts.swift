import SwiftUI

/// Shows "Can't Open Link" while the router holds a URL it could not open (`AppRouter.unopenableURL`, entry E2): an
/// `eros://` link, or another URL handed to the app, that is no site link it opens. One that came before the tabs
/// showed is shown once they do (`initial`). OK forgets the URL (`dismissUnopenable()`).
private struct UnopenableLinkAlertModifier: ViewModifier {
    /// The alert's id, the same every time: `AlertCenter` ignores an id already queued, so the root showing again, or
    /// a second window's root, or another URL coming while the alert is up, never queues it twice.
    private static let alertID = UUID()

    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        let router = environment.router
        let alerts = environment.alerts
        content.onChange(of: router.unopenableURL, initial: true) { _, url in
            guard url != nil else { return }
            alerts.present(HostedAlert(
                id: Self.alertID,
                title: "Can't Open Link",
                message: "Eros-SE opens links to galleries, image pages, tags, uploaders and searches on e-hentai.org and "
                    + "exhentai.org.",
                actions: [.init("OK") { router.dismissUnopenable() }]
            ))
        }
    }
}

/// Shows "Open Link?" while the clipboard monitor offers a site link (`ClipboardLinkMonitor.offer`, entry E3), the link
/// as the message. One offered before the tabs showed is shown once they do (`initial`). Open opens it (`accept()`,
/// through the router), Cancel declines it (`decline()`).
private struct ClipboardOfferAlertModifier: ViewModifier {
    /// The alert's id, the same every time: the monitor offers nothing new while an offer waits for its answer, and
    /// `AlertCenter` ignores an id already queued, so the root showing again, or a second window's root, never queues
    /// it twice.
    private static let alertID = UUID()

    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        let clipboardLinks = environment.clipboardLinks
        let alerts = environment.alerts
        content.onChange(of: clipboardLinks.offer, initial: true) { _, offer in
            guard let offer else { return }
            alerts.present(HostedAlert(
                id: Self.alertID,
                title: "Open Link?",
                message: offer.url.absoluteString,
                actions: [
                    .init("Open") { clipboardLinks.accept() },
                    .init("Cancel", role: .cancel) { clipboardLinks.decline() },
                ]
            ))
        }
    }
}

extension View {
    /// Shows the "Can't Open Link" alert for the URLs the router could not open, as a hosted alert above any sheet.
    /// Once, at the root, with `alertHost()` on the same view.
    func unopenableLinkAlert() -> some View {
        modifier(UnopenableLinkAlertModifier())
    }

    /// Shows the "Open Link?" alert for a site link found in the clipboard, as a hosted alert above any sheet. Once, at
    /// the root, with `alertHost()` on the same view.
    func clipboardOfferAlert() -> some View {
        modifier(ClipboardOfferAlertModifier())
    }
}
