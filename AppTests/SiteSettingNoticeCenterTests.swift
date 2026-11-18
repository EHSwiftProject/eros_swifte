import EHModels
import EHNetwork
import Foundation
import Testing

@testable import Eros

/// The site setting questions, without a screen: `pending` is what the alert in `RootTabView` shows.
///
/// Each test has a minute (`.timeLimit`): some wait for a question's answer (`confirm`), and one whose answer never
/// comes must fail at the limit, not hang the run (the test process is then ended and started again for the tests
/// after it).
@MainActor @Suite(.timeLimit(.minutes(1))) struct SiteSettingNoticeCenterTests {
    /// Answers the question on screen, by its id, as its alert's buttons do.
    private static func answer(_ center: SiteSettingNoticeCenter, _ proceed: Bool) throws {
        center.resolve(id: try #require(center.pending).id, proceed: proceed)
    }

    @Test func noticeResolvesWithTheChosenButton() async throws {
        let center = SiteSettingNoticeCenter()
        let answer = Task { await center.confirm(.compactView(current: .thumbnail), site: .eh) }
        #expect(await eventually { center.waitingCount == 1 })
        let pending = try #require(center.pending)
        #expect(pending.site == .eh)
        #expect(pending.change == .compactView(current: .thumbnail))

        try Self.answer(center, true)
        #expect(await answer.value)
        #expect(center.pending == nil)
        #expect(center.waitingCount == 0)

        // The next question is a new alert, and Cancel answers false.
        let next = Task { await center.confirm(.compactView(current: .thumbnail), site: .ex) }
        #expect(await eventually { center.waitingCount == 1 })
        #expect(try #require(center.pending).id != pending.id)
        try Self.answer(center, false)
        #expect(await !next.value)
        #expect(center.pending == nil)
    }

    @Test func concurrentNoticesShowOneAlert() async throws {
        let center = SiteSettingNoticeCenter()
        var shown: [PendingNotice] = []
        let first = Task { await center.confirm(.compactView(current: .thumbnail), site: .eh) }
        #expect(await eventually { center.waitingCount == 1 })
        shown.append(try #require(center.pending))
        let second = Task { await center.confirm(.compactView(current: .thumbnail), site: .eh) }
        #expect(await eventually { center.waitingCount == 2 })
        // Still the first caller's alert: one alert for both.
        #expect(center.pending == shown[0])

        try Self.answer(center, false)
        #expect(await !first.value)
        #expect(await !second.value)
        #expect(center.pending == nil)
        #expect(center.waitingCount == 0)
    }

    /// `SiteSettingPresenter`: a cancelled caller gets false and the alert goes when no one waits for it.
    @Test func cancelledCallerTakesTheNoticeDown() async throws {
        let center = SiteSettingNoticeCenter()
        let only = Task { await center.confirm(.compactView(current: .thumbnail), site: .eh) }
        #expect(await eventually { center.waitingCount == 1 })
        #expect(center.pending != nil)
        only.cancel()
        #expect(await !only.value)
        #expect(await eventually { center.pending == nil })
        #expect(center.waitingCount == 0)

        // With two waiting, one leaving keeps the alert for the other, who still gets the answer.
        let leaving = Task { await center.confirm(.compactView(current: .thumbnail), site: .eh) }
        let staying = Task { await center.confirm(.compactView(current: .thumbnail), site: .eh) }
        #expect(await eventually { center.waitingCount == 2 })
        let shown = try #require(center.pending)
        leaving.cancel()
        #expect(await !leaving.value)
        #expect(await eventually { center.waitingCount == 1 })
        #expect(center.pending == shown)
        try Self.answer(center, true)
        #expect(await staying.value)
        #expect(center.pending == nil)

        // A task cancelled before it asks gets false without an alert.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await center.confirm(.compactView(current: .thumbnail), site: .eh)
        }
        #expect(await !early.value)
        #expect(center.pending == nil)
        #expect(center.waitingCount == 0)
    }

    @Test func questionsForTwoSitesAreAskedInTurn() async throws {
        let center = SiteSettingNoticeCenter()
        let eh = Task { await center.confirm(.compactView(current: .thumbnail), site: .eh) }
        #expect(await eventually { center.waitingCount == 1 })
        let ex = Task { await center.confirm(.compactView(current: .thumbnail), site: .ex) }
        #expect(await eventually { center.waitingCount == 2 })
        #expect(center.pending?.site == .eh)

        try Self.answer(center, true)
        #expect(await eh.value)
        #expect(center.pending?.site == .ex)
        try Self.answer(center, false)
        #expect(await !ex.value)
        #expect(center.pending == nil)
        #expect(center.waitingCount == 0)
    }

    /// A button of an alert that is no longer the question on screen (one left over in another window, or a question
    /// withdrawn meanwhile) answers nothing: the question asked now stays, with its callers waiting.
    @Test func anOldQuestionsAnswerChangesNothing() async throws {
        let center = SiteSettingNoticeCenter()
        let eh = Task { await center.confirm(.compactView(current: .thumbnail), site: .eh) }
        #expect(await eventually { center.waitingCount == 1 })
        let first = try #require(center.pending)
        let ex = Task { await center.confirm(.compactView(current: .thumbnail), site: .ex) }
        #expect(await eventually { center.waitingCount == 2 })
        center.resolve(id: first.id, proceed: false)
        #expect(await !eh.value)
        let second = try #require(center.pending)
        #expect(second.site == .ex)

        // The first question's alert again, and one of a question never asked.
        center.resolve(id: first.id, proceed: true)
        center.resolve(id: second.id + 1, proceed: true)
        #expect(center.pending == second)
        #expect(center.waitingCount == 1)
        center.resolve(id: second.id, proceed: true)
        #expect(await ex.value)
        #expect(center.pending == nil)
    }

    /// The alert of a question has an id of its own, the same for every window that puts it up.
    @Test func aQuestionsAlertIDFollowsTheQuestion() {
        let first = PendingNotice(id: 1, site: .eh, change: .compactView(current: .thumbnail))
        #expect(first.alertID == PendingNotice(id: 1, site: .ex, change: .favoritesOrder(.postedTime)).alertID)
        #expect(first.alertID != PendingNotice(id: 2, site: .eh, change: .compactView(current: .thumbnail)).alertID)
    }

    @Test func textsNameTheSiteAndTheChange() {
        let compact = SiteSettingChange.compactView(current: .thumbnail)
        #expect(SiteSettingNoticeText.title(for: compact) == "Switch to the Compact view?")
        #expect(
            SiteSettingNoticeText.message(for: compact, site: .ex)
                == "Eros-SE can only read the Compact list view. Continuing changes the list display setting of your ExHentai account to Compact."
        )
        #expect(SiteSettingNoticeText.title(for: .favoritesOrder(.postedTime)) == "Change the favorites order?")
        #expect(
            SiteSettingNoticeText.message(for: .favoritesOrder(.postedTime), site: .eh)
                == "Continuing changes the favorites sort order of your E-Hentai account to posted time."
        )
        #expect(
            SiteSettingNoticeText.message(for: .favoritesOrder(.favoritedTime), site: .ex)
                .hasSuffix("of your ExHentai account to favorited time.")
        )
    }
}
