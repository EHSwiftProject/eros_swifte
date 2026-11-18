import EHModels
import EHNetwork
import Foundation
import Observation

/// The site setting question the app is waiting for the user to answer.
nonisolated struct PendingNotice: Identifiable, Equatable, Sendable {
    /// Stays the same for every caller that shares the alert.
    let id: Int
    let site: EHSite
    let change: SiteSettingChange

    /// The id of the hosted alert that asks this question (`siteSettingNoticeAlert()`): made from `id` alone, so
    /// every window's root puts up the same alert, which the alert center shows once.
    var alertID: UUID {
        let number = withUnsafeBytes(of: UInt64(truncatingIfNeeded: id).bigEndian, Array.init)
        // "SITENOTE", then the question's number.
        return UUID(uuid: (
            0x53, 0x49, 0x54, 0x45, 0x4E, 0x4F, 0x54, 0x45,
            number[0], number[1], number[2], number[3], number[4], number[5], number[6], number[7]
        ))
    }
}

/// The words of the site setting questions (`String(localized:)`; M8 translates them).
nonisolated enum SiteSettingNoticeText {
    static func title(for change: SiteSettingChange) -> String {
        switch change {
        case .compactView: String(localized: "Switch to the Compact view?")
        case .favoritesOrder: String(localized: "Change the favorites order?")
        }
    }

    static func message(for change: SiteSettingChange, site: EHSite) -> String {
        let name = siteName(site)
        switch change {
        case .compactView:
            return String(localized: """
                Eros-SE can only read the Compact list view. Continuing changes the list display setting of your \
                \(name) account to Compact.
                """)
        case .favoritesOrder(let order):
            let order = switch order {
            case .favoritedTime: String(localized: "favorited time")
            case .postedTime: String(localized: "posted time")
            }
            return String(localized: "Continuing changes the favorites sort order of your \(name) account to \(order).")
        }
    }

    private static func siteName(_ site: EHSite) -> String {
        switch site {
        case .eh: "E-Hentai"
        case .ex: "ExHentai"
        }
    }
}

/// Asks the user, with one system alert in `RootTabView`, before the app changes a setting of their account on a site
/// (`EHService`: the list display mode now, the favorites order later; user decision 2026-11-05: two buttons,
/// Continue and Cancel).
///
/// The questions are asked in turn, one alert at a time: `pending` is the oldest. Callers of the same site and change
/// share one question and get the same answer. A caller whose task is cancelled gets false at once (as
/// `SiteSettingPresenter` asks); when it was the last one waiting for its question, the question is taken down.
@MainActor @Observable final class SiteSettingNoticeCenter: SiteSettingPresenter {
    /// The question on screen (the oldest one); nil when none. Drives the alert in `RootTabView`.
    private(set) var pending: PendingNotice?

    @ObservationIgnored private var questions: [PendingNotice] = []
    @ObservationIgnored
    private var waiters: [Int: (question: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
    @ObservationIgnored private var lastID = 0

    /// How many callers wait for an answer, over all questions (for tests).
    var waitingCount: Int { waiters.count }

    /// Answers question `id` for every caller waiting for it and puts up the next one, when it is the question on
    /// screen (`pending`); nothing otherwise: an alert left over from a question that has gone (withdrawn, answered in
    /// another window) must not answer the one asked now.
    func resolve(id: Int, proceed: Bool) {
        guard let head = questions.first, head.id == id else { return }
        questions.removeFirst()
        let answered = waiters.filter { $0.value.question == head.id }
        for caller in answered.keys { waiters[caller] = nil }
        pending = questions.first
        for entry in answered.values {
            entry.continuation.resume(returning: proceed)
        }
    }

    nonisolated func confirm(_ change: SiteSettingChange, site: EHSite) async -> Bool {
        await ask(change, site: site)
    }

    /// Joins the question of the same site and change, or queues a new one; false at once for a task that is already
    /// cancelled.
    private func ask(_ change: SiteSettingChange, site: EHSite) async -> Bool {
        lastID += 1
        let caller = lastID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Runs on the main actor before the task suspends: a cancellation that came first is seen here, one
                // that comes later reaches `withdraw` after this has stored the continuation.
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                let question: Int
                if let shared = questions.first(where: { $0.site == site && $0.change == change }) {
                    question = shared.id
                } else {
                    question = caller
                    questions.append(PendingNotice(id: caller, site: site, change: change))
                    pending = questions.first
                }
                waiters[caller] = (question, continuation)
            }
        } onCancel: {
            Task { @MainActor in self.withdraw(caller) }
        }
    }

    /// A cancelled caller gets false; a question goes when no one waits for it any more.
    private func withdraw(_ caller: Int) {
        guard let entry = waiters.removeValue(forKey: caller) else { return }
        entry.continuation.resume(returning: false)
        if !waiters.values.contains(where: { $0.question == entry.question }) {
            questions.removeAll { $0.id == entry.question }
            pending = questions.first
        }
    }
}
