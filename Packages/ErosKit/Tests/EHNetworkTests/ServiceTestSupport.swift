import EHModels
import EHNetwork
import Foundation

// The site setting prompt and notice ledger doubles the `EHService` suites share (EHServiceTests,
// SessionBoundaryTests, GalleryListResultTests; browse B8's favorites next), and the polling wait every suite of this
// target uses.

/// Polls `condition` every 10 ms until it holds; false once `limit` has passed (the test then fails instead of
/// hanging).
func waitUntil(within limit: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while true {
        if await condition() { return true }
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Agrees to every site setting change at once, without recording anything.
struct AlwaysAgree: SiteSettingPresenter {
    func confirm(_ change: SiteSettingChange, site: EHSite) async -> Bool { true }
}

/// Records every question and answers each with `answer`.
actor RecordingPresenter: SiteSettingPresenter {
    private let answer: Bool
    private(set) var calls: [(change: SiteSettingChange, site: EHSite)] = []

    init(answer: Bool) { self.answer = answer }

    func confirm(_ change: SiteSettingChange, site: EHSite) async -> Bool {
        calls.append((change, site))
        return answer
    }
}

/// Holds every question until the test answers it. On cancellation it answers false at once, or, with
/// `holdOnCancel`, only counts the cancellation and keeps the question open (a slow withdrawal). Two questions open at
/// the same time are a failure unless `allowsOverlap`.
actor GatedPresenter: SiteSettingPresenter {
    private let holdOnCancel: Bool
    private let allowsOverlap: Bool
    private(set) var calls = 0
    private(set) var cancellations = 0
    private var open: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var sites: [Int: EHSite] = [:]

    init(holdOnCancel: Bool = false, allowsOverlap: Bool = false) {
        self.holdOnCancel = holdOnCancel
        self.allowsOverlap = allowsOverlap
    }

    var isWaiting: Bool { !open.isEmpty }

    func confirm(_ change: SiteSettingChange, site: EHSite) async -> Bool {
        precondition(open.isEmpty || allowsOverlap, "a second question while one is open")
        calls += 1
        let number = calls
        sites[number] = site
        return await withTaskCancellationHandler {
            await withCheckedContinuation { open[number] = $0 }
        } onCancel: {
            Task { await self.cancelled(number) }
        }
    }

    private func cancelled(_ number: Int) {
        cancellations += 1
        if !holdOnCancel { answer(false, call: number) }
    }

    func answer(_ value: Bool, call number: Int) {
        open.removeValue(forKey: number)?.resume(returning: value)
    }

    /// Answers the open question of `site`, if there is one.
    func answer(_ value: Bool, site: EHSite) {
        for number in open.keys.sorted() where sites[number] == site { answer(value, call: number) }
    }

    func answerAll(_ value: Bool) {
        for number in open.keys.sorted() { answer(value, call: number) }
    }
}

/// A ledger that counts how often it is read.
actor CountingLedger: NoticeLedger {
    private(set) var reads = 0
    private var acknowledged: Set<NoticeScope> = []

    func isAcknowledged(_ scope: NoticeScope) -> Bool {
        reads += 1
        return acknowledged.contains(scope)
    }

    func acknowledge(_ scope: NoticeScope) { acknowledged.insert(scope) }
}
