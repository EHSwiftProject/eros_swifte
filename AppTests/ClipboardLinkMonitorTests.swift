import EHModels
import EHNetwork
import Foundation
import Nuke
import SwiftUI
import Testing
import UIKit

@testable import Eros

/// A clipboard for the tests, never the real one: it counts how often it is read, and changes its contents (one more
/// change each time) as another app's copy (`copy(_:)`, `copyText(_:)`, `copyURLOnly(_:)`) or the app's own Copy Link
/// (`writeURL(_:)`) does. Its pattern detection stands in for the system's: a web URL in its text or its URL item.
/// With `refusesPaste`, a read of the text gives nil, as when the user does not allow pasting.
@MainActor final class FakePasteboard: PasteboardSource, PasteboardWriter {
    private(set) var changeCountReads = 0
    /// Calls of `mayHoldWebURL()`, which never make the system ask.
    private(set) var detectionReads = 0
    /// Reads of `hasStrings`, which never make the system ask.
    private(set) var hasStringsReads = 0
    /// Reads of `string`: the one that may make the system ask (`PasteboardSource` has no URL to read).
    private(set) var stringReads = 0
    /// What `writeURL(_:)` was given, in order.
    private(set) var written: [URL] = []
    /// The user does not allow pasting: `string` gives nil.
    var refusesPaste = false
    private var count = 0
    private var text: String?
    private var urlItem: URL?

    var changeCount: Int {
        changeCountReads += 1
        return count
    }

    func mayHoldWebURL() async -> Bool {
        detectionReads += 1
        guard let content = text ?? urlItem?.absoluteString else { return false }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: content, range: NSRange(content.startIndex..., in: content)) ?? []
        return matches.contains { ["http", "https"].contains($0.url?.scheme?.lowercased() ?? "") }
    }

    /// Whether it holds text: a URL item reads as its text too (`aURLOnlyItemReadsAsText` measures the system's).
    var hasStrings: Bool {
        hasStringsReads += 1
        return text != nil || urlItem != nil
    }

    var string: String? {
        stringReads += 1
        return refusesPaste ? nil : text ?? urlItem?.absoluteString
    }

    /// The reads that may make the system ask.
    var contentReads: Int { stringReads }

    /// Every read.
    var reads: Int { changeCountReads + detectionReads + hasStringsReads + contentReads }

    /// Another app copies `url`, as a URL and as its text, as a link's Copy does (nil: something with neither).
    func copy(_ url: URL?) {
        urlItem = url
        text = url?.absoluteString
        count += 1
    }

    /// Another app copies plain text only (a chat or a note).
    func copyText(_ text: String) {
        urlItem = nil
        self.text = text
        count += 1
    }

    /// Another app copies a URL item without text.
    func copyURLOnly(_ url: URL) {
        urlItem = url
        text = nil
        count += 1
    }

    func writeURL(_ url: URL) {
        written.append(url)
        urlItem = url
        text = url.absoluteString
        count += 1
    }
}

/// A setting a test turns on later.
@MainActor private final class Setting {
    var isOn = false
}

/// The clipboard link monitor (entry E3) over a `FakePasteboard`, with the router attached as the tabs would. Every
/// link here is made up.
@MainActor @Suite struct ClipboardLinkMonitorTests {
    private static let id = GalleryID(gid: 1234, token: "0123456789")
    private static let galleryURL = URL(string: "https://e-hentai.org/g/1234/0123456789/")!
    private static let otherGalleryURL = URL(string: "https://exhentai.org/g/5678/abcdef0123/")!
    /// The gallery of `galleryURL`, on its second page of thumbnails.
    private static let secondPageURL = URL(string: "https://e-hentai.org/g/1234/0123456789/?p=2")!
    private static let nonSiteURL = URL(string: "https://example.com/")!
    /// How the system reports a return from the background: the scene passes `.inactive` on its way back.
    private static let returning: [ScenePhase] = [.background, .inactive, .active]
    /// How long a hosted view may take to act on a change (as long as the UI tests wait for the tabs).
    private static let viewUpdate: Duration = .seconds(30)

    /// A monitor over `pasteboard` whose setting is `enabled`, and its router, attached to the default tabs.
    private static func monitor(
        _ pasteboard: FakePasteboard, enabled: Bool = true
    ) -> (monitor: ClipboardLinkMonitor, router: AppRouter) {
        let router = AppRouter()
        router.attach(shownTabs: [.gallery, .favorites, .toplists, .download, .settings], owner: UUID())
        return (ClipboardLinkMonitor(pasteboard: pasteboard, router: router, isEnabled: { enabled }), router)
    }

    /// The scene's phases, then the look they started (its reads after the system's detection), if any.
    private static func report(_ phases: [ScenePhase], to monitor: ClipboardLinkMonitor) async {
        for phase in phases { monitor.scenePhaseChanged(to: phase) }
        await monitor.lookInProgress?.value
    }

    @Test func disabledNeverTouchesThePasteboard() async {
        let pasteboard = FakePasteboard()
        pasteboard.copy(Self.galleryURL)
        let (monitor, _) = Self.monitor(pasteboard, enabled: false)
        await Self.report(Self.returning, to: monitor)
        await Self.report(Self.returning, to: monitor)
        #expect(pasteboard.reads == 0)
        #expect(monitor.offer == nil)
    }

    /// A launch shows the app without a `.background` before it: nothing is read.
    @Test func coldStartDoesNotCheck() async {
        let pasteboard = FakePasteboard()
        pasteboard.copy(Self.galleryURL)
        let (monitor, _) = Self.monitor(pasteboard)
        monitor.scenePhaseChanged(to: .active)
        #expect(pasteboard.reads == 0)

        let (other, _) = Self.monitor(pasteboard)
        await Self.report([.inactive, .active], to: other)
        #expect(pasteboard.reads == 0)
        #expect(monitor.offer == nil)
        #expect(other.offer == nil)
    }

    /// `.inactive` without `.background` before it (Control Center, the system's paste prompt) is no return either.
    @Test func inactiveAloneIsNoReturn() async {
        let pasteboard = FakePasteboard()
        pasteboard.copy(Self.galleryURL)
        let (monitor, _) = Self.monitor(pasteboard)
        await Self.report([.active, .inactive, .active, .inactive, .active], to: monitor)
        #expect(pasteboard.reads == 0)
        #expect(monitor.offer == nil)
    }

    /// On its way back the scene is `.inactive` first: nothing is read until it is `.active`.
    @Test func notCheckedBeforeActive() async {
        let pasteboard = FakePasteboard()
        pasteboard.copy(Self.galleryURL)
        let (monitor, _) = Self.monitor(pasteboard)
        await Self.report([.background, .inactive], to: monitor)
        #expect(pasteboard.reads == 0)
        #expect(monitor.offer == nil)

        monitor.scenePhaseChanged(to: .active)
        await monitor.lookInProgress?.value
        #expect(pasteboard.contentReads == 1)
        #expect(monitor.offer != nil)
    }

    @Test func noURLsMeansNoRead() async {
        let pasteboard = FakePasteboard()
        pasteboard.copy(nil)
        let (monitor, _) = Self.monitor(pasteboard)
        await Self.report(Self.returning, to: monitor)
        #expect(pasteboard.changeCountReads == 1)
        #expect(pasteboard.detectionReads == 1)
        #expect(pasteboard.contentReads == 0)
        #expect(monitor.offer == nil)
    }

    /// A link copied as plain text only (many chats and notes write no URL item) is offered too (user decision
    /// 2026-11-17, as the Flutter app searched the clipboard's text).
    @Test func plainTextLinkIsOffered() async {
        let pasteboard = FakePasteboard()
        pasteboard.copyText(Self.galleryURL.absoluteString)
        let (monitor, _) = Self.monitor(pasteboard)
        await Self.report(Self.returning, to: monitor)
        #expect(monitor.offer == ClipboardOffer(link: .gallery(Self.id, site: .eh), url: Self.galleryURL))
        #expect(pasteboard.contentReads == 1)
    }

    /// A link inside a sentence: the first URL in the text is the one offered.
    @Test func linkInsideTextIsOffered() async {
        let pasteboard = FakePasteboard()
        pasteboard.copyText("Look at this one: \(Self.galleryURL.absoluteString) and then \(Self.otherGalleryURL)")
        let (monitor, _) = Self.monitor(pasteboard)
        await Self.report(Self.returning, to: monitor)
        #expect(monitor.offer == ClipboardOffer(link: .gallery(Self.id, site: .eh), url: Self.galleryURL))

        // A URL item without text is read as its URL.
        let urlOnly = FakePasteboard()
        urlOnly.copyURLOnly(Self.otherGalleryURL)
        let (other, _) = Self.monitor(urlOnly)
        await Self.report(Self.returning, to: other)
        #expect(other.offer?.url == Self.otherGalleryURL)
    }

    /// The first URL in the text that is a site link is the one offered: another site's link before it is passed over
    /// (Flutter looked for a gallery link anywhere in the text).
    @Test func aSiteLinkAfterAnotherIsOffered() async {
        let pasteboard = FakePasteboard()
        pasteboard.copyText("Mirror: https://example.com/fake/1 and the original: \(Self.galleryURL.absoluteString)")
        let (monitor, _) = Self.monitor(pasteboard)
        await Self.report(Self.returning, to: monitor)
        #expect(monitor.offer == ClipboardOffer(link: .gallery(Self.id, site: .eh), url: Self.galleryURL))
        #expect(pasteboard.contentReads == 1)
    }

    /// A look reads the clipboard's content at most once: when the user does not allow pasting (the text reads as
    /// nil), nothing else is read in its place, so the system does not ask twice; and the same clipboard is not read
    /// again on the next return. Without text (`hasStrings`, which never asks), nothing is read at all.
    @Test func aRefusedPasteIsNotAskedAgain() async {
        let pasteboard = FakePasteboard()
        pasteboard.copy(Self.galleryURL)
        pasteboard.refusesPaste = true
        let (monitor, _) = Self.monitor(pasteboard)
        await Self.report(Self.returning, to: monitor)
        #expect(pasteboard.stringReads == 1)
        #expect(monitor.offer == nil)
        await Self.report(Self.returning, to: monitor)
        #expect(pasteboard.contentReads == 1)
    }

    /// Text in which the system's detection finds no web URL is not read: reading it could make the system ask.
    @Test func noPatternMeansNoRead() async {
        let pasteboard = FakePasteboard()
        pasteboard.copyText("fake words, no link")
        let (monitor, _) = Self.monitor(pasteboard)
        await Self.report(Self.returning, to: monitor)
        #expect(pasteboard.detectionReads == 1)
        #expect(pasteboard.contentReads == 0)
        #expect(monitor.offer == nil)
    }

    @Test func siteLinkIsOfferedOnReturn() async {
        let pasteboard = FakePasteboard()
        pasteboard.copy(Self.galleryURL)
        let (monitor, router) = Self.monitor(pasteboard)
        await Self.report(Self.returning, to: monitor)
        #expect(monitor.offer == ClipboardOffer(link: .gallery(Self.id, site: .eh), url: Self.galleryURL))
        #expect(monitor.offer?.id == Self.galleryURL)
        #expect(pasteboard.contentReads == 1)
        // Offering opens nothing.
        #expect(router.lastDelivery == nil)
    }

    /// A link is offered once: the same gallery with `?p=2` is the same link, another gallery is not.
    @Test func sameLinkIsOfferedOnce() async {
        let pasteboard = FakePasteboard()
        pasteboard.copy(Self.galleryURL)
        let (monitor, router) = Self.monitor(pasteboard)
        await Self.report(Self.returning, to: monitor)
        #expect(monitor.offer != nil)
        monitor.decline()
        #expect(monitor.offer == nil)
        #expect(router.lastDelivery == nil)

        pasteboard.copy(Self.secondPageURL)
        await Self.report(Self.returning, to: monitor)
        #expect(pasteboard.contentReads == 2)
        #expect(monitor.offer == nil)

        pasteboard.copy(Self.otherGalleryURL)
        await Self.report(Self.returning, to: monitor)
        let other = GalleryID(gid: 5678, token: "abcdef0123")
        #expect(monitor.offer == ClipboardOffer(link: .gallery(other, site: .ex), url: Self.otherGalleryURL))
    }

    @Test func nonSiteLinkIsNotOffered() async {
        let pasteboard = FakePasteboard()
        pasteboard.copy(Self.nonSiteURL)
        let (monitor, _) = Self.monitor(pasteboard)
        await Self.report(Self.returning, to: monitor)
        #expect(pasteboard.contentReads == 1)
        #expect(monitor.offer == nil)
    }

    @Test func unchangedClipboardIsNotReadAgain() async {
        let pasteboard = FakePasteboard()
        pasteboard.copy(Self.galleryURL)
        let (monitor, _) = Self.monitor(pasteboard)
        await Self.report(Self.returning, to: monitor)
        monitor.decline()
        await Self.report(Self.returning, to: monitor)
        // The first look read the change count twice: once more after the detection, to drop an answer for a
        // clipboard that changed meanwhile. The second read it once and stopped there.
        #expect(pasteboard.changeCountReads == 3)
        #expect(pasteboard.detectionReads == 1)
        #expect(pasteboard.contentReads == 1)
        #expect(monitor.offer == nil)
    }

    /// While an offer waits for its answer the monitor does not look again, not even at the change count.
    @Test func pendingOfferBlocksNewChecks() async {
        let pasteboard = FakePasteboard()
        pasteboard.copy(Self.galleryURL)
        let (monitor, _) = Self.monitor(pasteboard)
        await Self.report(Self.returning, to: monitor)
        let offer = monitor.offer
        #expect(offer != nil)

        pasteboard.copy(Self.otherGalleryURL)
        await Self.report(Self.returning, to: monitor)
        // Both of the first look's (see `unchangedClipboardIsNotReadAgain`), none of the second's.
        #expect(pasteboard.changeCountReads == 2)
        #expect(pasteboard.contentReads == 1)
        #expect(monitor.offer == offer)
    }

    @Test func acceptOpensTheRoute() async {
        let pasteboard = FakePasteboard()
        pasteboard.copy(Self.galleryURL)
        let (monitor, router) = Self.monitor(pasteboard)
        router.selectedTab = .settings
        await Self.report(Self.returning, to: monitor)
        monitor.accept()
        #expect(router.lastDelivery == RouteDelivery(tab: .gallery, route: .gallery(Self.id, .eh)))
        #expect(router.selectedTab == .gallery)
        #expect(monitor.offer == nil)
    }

    /// The app's own Copy Link (`ItemContextMenu`: write, then `noteOwnWrite()`) is never offered back, and costs no
    /// read of `url`. Another app's copy afterwards is.
    @Test func ownCopyIsNotOffered() async {
        let pasteboard = FakePasteboard()
        let (monitor, _) = Self.monitor(pasteboard)
        ItemMenuAction.copyLink(Self.id, site: .eh, to: pasteboard)
        #expect(pasteboard.written == [Self.galleryURL])
        monitor.noteOwnWrite()
        await Self.report(Self.returning, to: monitor)
        #expect(monitor.offer == nil)
        #expect(pasteboard.contentReads == 0)

        pasteboard.copy(Self.otherGalleryURL)
        await Self.report(Self.returning, to: monitor)
        #expect(pasteboard.contentReads == 1)
        #expect(monitor.offer?.url == Self.otherGalleryURL)
    }

    /// The app's own Copy Link while the setting is off, then the setting turned on: the next return offers nothing
    /// and reads no `url` (`noteOwnWrite()` notes the change count whatever the setting). Another app's copy after
    /// that is offered, so the monitor does look.
    @Test func ownCopyWhileDisabledIsNotOfferedOnceEnabled() async {
        let pasteboard = FakePasteboard()
        let setting = Setting()
        let router = AppRouter()
        router.attach(shownTabs: [.gallery, .favorites, .toplists, .download, .settings], owner: UUID())
        let monitor = ClipboardLinkMonitor(pasteboard: pasteboard, router: router, isEnabled: { setting.isOn })
        ItemMenuAction.copyLink(Self.id, site: .eh, to: pasteboard)
        #expect(pasteboard.written == [Self.galleryURL])
        monitor.noteOwnWrite()

        setting.isOn = true
        await Self.report(Self.returning, to: monitor)
        #expect(monitor.offer == nil)
        #expect(pasteboard.contentReads == 0)

        pasteboard.copy(Self.otherGalleryURL)
        await Self.report(Self.returning, to: monitor)
        #expect(pasteboard.contentReads == 1)
        #expect(monitor.offer?.url == Self.otherGalleryURL)
    }

    /// The setting turned on later: the clipboard is looked at on the next return, not before.
    @Test func enablingTakesEffectOnTheNextReturn() async {
        let pasteboard = FakePasteboard()
        pasteboard.copy(Self.galleryURL)
        let setting = Setting()
        let router = AppRouter()
        let monitor = ClipboardLinkMonitor(pasteboard: pasteboard, router: router, isEnabled: { setting.isOn })
        await Self.report(Self.returning, to: monitor)
        setting.isOn = true
        #expect(pasteboard.reads == 0)
        await Self.report(Self.returning, to: monitor)
        #expect(pasteboard.contentReads == 1)
        #expect(monitor.offer != nil)
    }

    // MARK: - The environment and the alert

    /// Every environment of the tests reads and writes a clipboard of its own, never the real one: the app's (the
    /// UI testing one, `forLaunch()` in a process XCTest hosts) too, and one made with `uiTesting: false` (the app's
    /// own, outside tests) while XCTest hosts the process. A hosted test's holds no URL.
    @Test func testEnvironmentsNeverUseTheRealClipboard() async throws {
        let environment = AppEnvironment(uiTesting: true, userAgentProbe: { "FakeWebKit/1" })
        let writer = try #require(environment.pasteboardWriter as? UITestingPasteboard)
        #expect(writer.url == nil)
        #expect(!writer.hasURLs)
        #expect(writer.changeCount == 1)
        writer.writeURL(Self.galleryURL)
        #expect(writer.url == nil)
        #expect(writer.changeCount == 1)

        let given = FakePasteboard()
        let withFake = AppEnvironment(uiTesting: true, userAgentProbe: { "FakeWebKit/1" }, pasteboard: given)
        #expect(withFake.pasteboardWriter === given)

        // Not the UI testing environment, but hosted by XCTest: still the fixed clipboard. The stores the init can be
        // given instead of the app's own (Keychain, defaults, response cache) are given here, and the thumbnails' disk
        // cache gets a name of its own and goes when the test ends; the settings and the user data are a hosted
        // test's anyway. The clipboard notice ledger (`UserDefaultsNoticeLedger()`) still uses `.standard`, but writes
        // only on an acknowledgement, which this test never triggers. Only the tag translations open the app's file,
        // in the test host's container.
        #expect(AppEnvironment.isHostedByTests)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "eros-tests-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hosted = AppEnvironment(
            uiTesting: false, userAgentCache: InMemoryUserAgentCache(), userAgentProbe: { "FakeWebKit/1" },
            vault: InMemoryVault(), responseCache: ResponseCache(directory: directory),
            launchMarker: InMemoryLaunchMarker(hasLaunched: true),
            thumbnailCacheName: "eros-tests-thumbnails-\(UUID().uuidString)"
        )
        let cache = hosted.images.configuration.dataCache as? DataCache
        defer { if let cache { try? FileManager.default.removeItem(at: cache.path) } }
        #expect(!hosted.uiTesting)
        #expect(!(hosted.pasteboardWriter is UIPasteboard))
        let hostedWriter = try #require(hosted.pasteboardWriter as? UITestingPasteboard)
        #expect(hostedWriter.url == nil)
    }

    /// The root shows "Open Link?" for an offer (`clipboardOfferAlert()`): the link as the message, Open opens it,
    /// Cancel declines; the next offer uses the same alert id.
    @Test func offerRaisesTheAlert() async throws {
        let pasteboard = FakePasteboard()
        let environment = AppEnvironment(uiTesting: true, userAgentProbe: { "FakeWebKit/1" }, pasteboard: pasteboard)
        await environment.start()
        environment.settings.settings.detectsClipboardLinks = true
        let monitor = environment.clipboardLinks
        let router = environment.router
        let alerts = environment.alerts
        // Before the tabs show: the alert comes once they do.
        pasteboard.copy(Self.galleryURL)
        await Self.report(Self.returning, to: monitor)
        #expect(monitor.offer != nil)

        let host = try HostedViews.show(RootTabView(), environment: environment)
        defer { HostedViews.hide(host) }
        #expect(await eventually(within: Self.viewUpdate) { alerts.current != nil })
        let alert = try #require(alerts.current)
        #expect(alert.title == "Open Link?")
        #expect(alert.message == Self.galleryURL.absoluteString)
        #expect(alert.actions.map(\.title) == ["Open", "Cancel"])
        #expect(alert.actions.map(\.role) == [nil, .cancel])
        #expect(alerts.queuedCount == 1)

        // What the host's button does: the action, then the alert goes.
        alert.actions[0].perform()
        alerts.dismiss(alert.id)
        #expect(monitor.offer == nil)
        #expect(router.lastDelivery == RouteDelivery(tab: .gallery, route: .gallery(Self.id, .eh)))

        pasteboard.copy(Self.otherGalleryURL)
        await Self.report(Self.returning, to: monitor)
        #expect(await eventually(within: Self.viewUpdate) { alerts.current != nil })
        let second = try #require(alerts.current)
        #expect(second.id == alert.id)
        #expect(second.message == Self.otherGalleryURL.absoluteString)
        second.actions[1].perform()
        alerts.dismiss(second.id)
        #expect(monitor.offer == nil)
        #expect(router.path(for: .gallery).wrappedValue.count == 1)
    }
}
