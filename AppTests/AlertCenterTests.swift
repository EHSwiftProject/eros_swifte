import Foundation
import Testing

@testable import Eros

/// The alert queue, without a screen.
@MainActor @Suite struct AlertCenterTests {
    private func alert(_ title: String) -> HostedAlert {
        HostedAlert(title: title, actions: [.init("OK")])
    }

    @Test func alertsAreShownInTurn() {
        let center = AlertCenter()
        let a = alert("A"), b = alert("B")
        center.present(a)
        center.present(b)
        #expect(center.current?.id == a.id)
        #expect(center.queuedCount == 2)
        center.dismiss(a.id)
        #expect(center.current?.id == b.id)
        center.dismiss(b.id)
        #expect(center.current == nil)
        #expect(center.queuedCount == 0)
    }

    @Test func dismissingAQueuedAlertRemovesIt() {
        let center = AlertCenter()
        let a = alert("A"), b = alert("B")
        center.present(a)
        center.present(b)
        center.dismiss(b.id)
        #expect(center.current?.id == a.id)
        #expect(center.queuedCount == 1)
        center.dismiss(UUID())
        #expect(center.current?.id == a.id)
        #expect(center.queuedCount == 1)
    }

    @Test func sameAlertIsQueuedOnce() {
        let center = AlertCenter()
        let a = alert("A")
        center.present(a)
        center.present(a)
        #expect(center.queuedCount == 1)
    }

    @Test func latestHostShowsTheAlerts() {
        let center = AlertCenter()
        let a = center.attachHost()
        let b = center.attachHost()
        #expect(center.activeHost == b)
        center.detachHost(b)
        #expect(center.activeHost == a)
        center.detachHost(a)
        #expect(center.activeHost == nil)
    }

    /// Remove All's and Clear's questions keep one id each: tapping twice before the first shows queues one question,
    /// not two (M2 re-review M-5); each has its destructive button and Cancel.
    @Test func aQuestionTappedTwiceIsQueuedOnce() {
        let center = AlertCenter()
        var removed = 0
        center.present(QuickSearchListView.removeAllAlert { removed += 1 })
        center.present(QuickSearchListView.removeAllAlert { removed += 1 })
        #expect(center.queuedCount == 1)
        center.present(SearchSuggestionsContent.clearAlert {})
        center.present(SearchSuggestionsContent.clearAlert {})
        #expect(center.queuedCount == 2)

        let removeAll = center.current
        #expect(removeAll?.title == "Remove all quick searches?")
        #expect(removeAll?.actions.map(\.title) == ["Remove All", "Cancel"])
        #expect(removeAll?.actions.map(\.role) == [.destructive, .cancel])
        removeAll?.actions[0].perform()
        #expect(removed == 1)
        if let removeAll { center.dismiss(removeAll.id) }
        #expect(center.current?.title == "Clear search history?")
        #expect(center.current?.actions.map(\.role) == [.destructive, .cancel])
    }
}
