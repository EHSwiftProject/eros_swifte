import Testing

@testable import Eros

/// `TabReselectionTracker` (Flutter `TabHomeController.onTap` and `doubleTapBar`, tabhome_controller.dart:235-285)
/// and `TabReselectionCenter`.
@Suite struct TabReselectionTests {
    private let start = ContinuousClock.now

    @Test func firstReselectScrollsToTop() {
        var tracker = TabReselectionTracker()
        #expect(tracker.tap(.gallery, current: .gallery, at: start) == .scrollToTop)
    }

    @Test func secondReselectWithin800msRefreshes() {
        var tracker = TabReselectionTracker()
        _ = tracker.tap(.toplists, current: .toplists, at: start)
        #expect(tracker.tap(.toplists, current: .toplists, at: start + .milliseconds(799)) == .scrollToTopAndRefresh)

        var late = TabReselectionTracker()
        _ = late.tap(.toplists, current: .toplists, at: start)
        #expect(late.tap(.toplists, current: .toplists, at: start + .milliseconds(800)) == .scrollToTop)
        // That one opened a window of its own.
        #expect(late.tap(.toplists, current: .toplists, at: start + .milliseconds(900)) == .scrollToTopAndRefresh)
        #expect(TabReselectionTracker.window == .milliseconds(800))
    }

    @Test func aThirdTapStartsOver() {
        var tracker = TabReselectionTracker()
        _ = tracker.tap(.gallery, current: .gallery, at: start)
        #expect(tracker.tap(.gallery, current: .gallery, at: start + .milliseconds(100)) == .scrollToTopAndRefresh)
        #expect(tracker.tap(.gallery, current: .gallery, at: start + .milliseconds(200)) == .scrollToTop)
        #expect(tracker.tap(.gallery, current: .gallery, at: start + .milliseconds(300)) == .scrollToTopAndRefresh)
    }

    @Test func switchingTabsIsNotAReselect() {
        var tracker = TabReselectionTracker()
        _ = tracker.tap(.gallery, current: .gallery, at: start)
        #expect(tracker.tap(.favorites, current: .gallery, at: start + .milliseconds(100)) == nil)
        // The window the gallery opened is gone: this is a first reselect.
        #expect(tracker.tap(.favorites, current: .favorites, at: start + .milliseconds(200)) == .scrollToTop)
        #expect(tracker.tap(.gallery, current: .favorites, at: start + .milliseconds(300)) == nil)
        #expect(tracker.tap(.gallery, current: .gallery, at: start + .milliseconds(400)) == .scrollToTop)
    }

    @Test func settingsIgnoresReselects() {
        var tracker = TabReselectionTracker()
        #expect(tracker.tap(.settings, current: .settings, at: start) == nil)
        #expect(tracker.tap(.settings, current: .settings, at: start + .milliseconds(100)) == nil)
        // Nor does it leave a window behind.
        _ = tracker.tap(.gallery, current: .settings, at: start + .milliseconds(200))
        #expect(tracker.tap(.gallery, current: .gallery, at: start + .milliseconds(300)) == .scrollToTop)
    }

    @MainActor @Test func centerNumbersEveryEvent() {
        let center = TabReselectionCenter()
        #expect(center.latest == nil)
        center.send(.scrollToTop, for: .gallery)
        let first = center.latest
        center.send(.scrollToTop, for: .gallery)
        #expect(first?.tab == .gallery)
        #expect(first?.action == .scrollToTop)
        // The same action twice is two events.
        #expect(center.latest != first)
        #expect(center.latest?.serial == (first?.serial ?? 0) + 1)
    }
}
