import EHModels
import Foundation
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The clipboard the clipboard monitor reads (entry E3): the general pasteboard in the app, a fixed one in UI testing
/// (`AppEnvironment`), a fake in the tests. Only `string` may make the system ask the user whether to allow pasting.
@MainActor protocol PasteboardSource: AnyObject {
    /// Changes whenever the clipboard's contents do; reading it never makes the system ask.
    var changeCount: Int { get }
    /// Whether the clipboard probably holds a web URL, as a URL or inside plain text (the system's pattern detection,
    /// `UIPasteboard.detectPatterns(for: [\.probableWebURL])`); asking never makes the system ask the user.
    func mayHoldWebURL() async -> Bool
    /// Whether the clipboard holds text (a URL item reads as its text too); reading it never makes the system ask.
    var hasStrings: Bool { get }
    /// The clipboard's text; reading it may make the system ask the user whether to allow pasting.
    var string: String? { get }
}

/// Where the app's own Copy Link writes (`ItemMenuAction.copyLink`): the general pasteboard
/// in the app, a fixed one that keeps nothing in UI testing (`AppEnvironment.pasteboardWriter`), a fake in the tests.
@MainActor protocol PasteboardWriter: AnyObject {
    /// Puts `url` on the clipboard, as a URL and as plain text.
    func writeURL(_ url: URL)
}

extension UIPasteboard: PasteboardSource {
    func mayHoldWebURL() async -> Bool {
        await withCheckedContinuation { continuation in
            // Sendable: the system may call it off the main thread.
            detectPatterns(for: [\UIPasteboard.DetectedValues.probableWebURL]) { @Sendable result in
                continuation.resume(returning: (try? result.get())?.isEmpty == false)
            }
        }
    }
}

extension UIPasteboard: PasteboardWriter {
    func writeURL(_ url: URL) {
        setItems([[UTType.url.identifier: url, UTType.utf8PlainText.identifier: url.absoluteString]])
    }
}

/// A site link found in the clipboard, offered to the user (`ClipboardLinkMonitor.offer`): the link, and the URL it
/// was read from, which the offer shows.
nonisolated struct ClipboardOffer: Identifiable, Equatable {
    let link: EHLink
    let url: URL
    var id: URL { url }
}

/// Offers to open a site link the user copied, when the app comes back from the background (entry E3; Flutter looked
/// on every resume, `main.dart:131-140`, `ehsetting_service.dart:1066-1131`). `LaunchGate` reports every scene's phase
/// (`scenePhaseChanged(to:)`); the root shows `offer` (`clipboardOfferAlert()`), whose buttons answer it (`accept()`,
/// `decline()`).
///
/// When it looks: a scene that comes back from the background passes `.inactive` on its
/// way (`.background`, `.inactive`, `.active`), as it does on its way there.
/// - `.background` marks that the app was away;
/// - `.inactive` leaves the mark as it is: with no `.background` before it (Control Center, the system's own paste
///   prompt) the next `.active` is no return; after one it is the way back, and nothing is read yet;
/// - `.active` looks once when the mark is set, and clears it. A launch never looks (no `.background` comes first).
///
/// How it looks, each step ending it when it does not hold:
/// 1. `offer` is nil and no look is in progress: while an offer waits for its answer, nothing is read;
/// 2. `isEnabled()` (the setting): when it is off, the clipboard is not touched at all;
/// 3. `changeCount` is not the one noted last, which it then becomes;
/// 4. `mayHoldWebURL()`, the system's pattern detection, which never makes it ask (user decision 2026-11-17: links in
///    plain text count, as in the Flutter app, which searched the clipboard's text);
/// 5. `hasStrings`, then the clipboard's text (`string`), read once: the only read that may make the system ask, and
///    nothing is read in its place when it gives nothing (the user did not allow pasting); it holds a site link: of
///    the URLs `NSDataDetector` finds in it (the whole text, or links inside a sentence), the first that
///    `EHLink(url:)` takes;
/// 6. that link is not the one offered last (a gallery with or without `?p=` is the same link): it becomes `offer`.
/// Steps 4 to 6 come after a suspension; an answer that comes once the clipboard has changed again is dropped.
///
/// The app's own Copy Link notes its write (`noteOwnWrite()`), so its link is not offered back. What the clipboard held
/// is never logged or written anywhere: the change count and the link offered last are kept in memory only, so after a
/// new launch the same link may be offered once more. Flutter offered the same link on every return (research §13.3);
/// this does not.
///
/// The app's windows share the monitor (`AppEnvironment.clipboardLinks`), and every scene reports its own phases: a
/// second window coming back finds the mark cleared, an offer waiting (step 1) or the change count noted (step 3).
@MainActor @Observable final class ClipboardLinkMonitor {
    /// The link offered and not yet answered.
    private(set) var offer: ClipboardOffer?

    @ObservationIgnored private let pasteboard: any PasteboardSource
    @ObservationIgnored private let router: AppRouter
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    /// Set by `.background`, cleared by the next `.active`, which looks.
    @ObservationIgnored private var wasInBackground = false
    /// The change count of the last look, or of the app's own write (`noteOwnWrite()`); nil before either.
    @ObservationIgnored private var lastChangeCount: Int?
    /// The link offered last, answered or not.
    @ObservationIgnored private var lastOfferedLink: EHLink?
    /// The look in progress, from step 4 on (tests wait for it); nil when none.
    @ObservationIgnored private(set) var lookInProgress: Task<Void, Never>?

    /// `router` opens an accepted link; `isEnabled` is read on every look (the setting).
    init(pasteboard: any PasteboardSource, router: AppRouter, isEnabled: @escaping @MainActor () -> Bool) {
        self.pasteboard = pasteboard
        self.router = router
        self.isEnabled = isEnabled
    }

    /// A scene's new phase: `.background` marks the app away, `.inactive` changes nothing, `.active` looks once when
    /// the app was away (see the type).
    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            wasInBackground = true
        case .active:
            guard wasInBackground else { return }
            wasInBackground = false
            look()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// The app has just written the clipboard itself (Copy Link): its change count is noted, so the next look leaves
    /// the app's own link alone. Noted whether or not the setting is on, so turning it on later does not offer it
    /// either; the change count never makes the system ask.
    func noteOwnWrite() {
        lastChangeCount = pasteboard.changeCount
    }

    /// Opens the offered link (`AppRouter.open(_:)`) and forgets the offer.
    func accept() {
        guard let offer else { return }
        router.open(offer.link)
        self.offer = nil
    }

    /// Forgets the offer; the link stays the one offered last.
    func decline() {
        offer = nil
    }

    /// The six steps of the type's documentation: the first three at once, the rest in `lookInProgress`.
    private func look() {
        guard offer == nil, lookInProgress == nil, isEnabled() else { return }
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        lookInProgress = Task {
            defer { lookInProgress = nil }
            await read(changeCount)
        }
    }

    /// Steps 4 to 6 for the clipboard of `changeCount`.
    private func read(_ changeCount: Int) async {
        guard await pasteboard.mayHoldWebURL(), pasteboard.changeCount == changeCount, offer == nil,
              pasteboard.hasStrings, let text = pasteboard.string,
              let (link, url) = Self.firstSiteLink(in: text), link != lastOfferedLink
        else { return }
        lastOfferedLink = link
        offer = ClipboardOffer(link: link, url: url)
    }

    /// Of the URLs `NSDataDetector` finds in `text`, in order, the first that is a site link (`EHLink(url:)`), and
    /// that URL; nil when none is. The scan stops at that link (as Flutter's `firstMatch`), so a long text with many
    /// links copied from a page is not read to its end on the main actor.
    nonisolated static func firstSiteLink(in text: String) -> (link: EHLink, url: URL)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        var found: (link: EHLink, url: URL)?
        let range = NSRange(text.startIndex..., in: text)
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
            guard let url = match?.url, let link = EHLink(url: url) else { return }
            found = (link, url)
            stop.pointee = true
        }
        return found
    }
}

#if DEBUG
/// The clipboard of UI testing, and of every process XCTest hosts (`AppEnvironment`): never the real one. Its change
/// count is always 1; its URL is the one a UI test launch gives with `-EROS_UI_TESTING_CLIPBOARD_URL <url>`
/// (`TestSwitches.uiTestingClipboardURL`), none otherwise, and its text that URL's; a write keeps nothing.
@MainActor final class UITestingPasteboard: PasteboardSource, PasteboardWriter {
    let changeCount = 1
    let url: URL?
    var string: String? { url?.absoluteString }
    var hasStrings: Bool { url != nil }
    /// Whether it holds a URL (`url`).
    var hasURLs: Bool { url != nil }

    init(url: URL?) {
        self.url = url
    }

    func mayHoldWebURL() async -> Bool {
        hasURLs
    }

    func writeURL(_ url: URL) {}
}
#endif
