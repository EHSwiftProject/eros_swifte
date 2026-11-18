import EHNetwork
import Testing

struct RateLimitScheduleTests {
    /// Reserves each host in order at the same instant and returns the start offsets in milliseconds.
    private func starts(_ hosts: [String], at now: Duration = .zero) -> [Int] {
        var schedule = RateLimitSchedule(policy: .flutterParity)
        return hosts.map { milliseconds(schedule.reserve(host: $0, at: now)) }
    }

    private func milliseconds(_ d: Duration) -> Int {
        let parts = d.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    @Test func ehentaiBurstThenRefillPace() {
        #expect(starts(Array(repeating: "e-hentai.org", count: 8)) == [0, 200, 400, 600, 800, 1000, 1600, 2400])
    }

    @Test func subdomainsShareTheParentBucket() {
        let hosts = ["e-hentai.org", "forums.e-hentai.org", "e-hentai.org", "forums.e-hentai.org", "e-hentai.org", "forums.e-hentai.org"]
        #expect(starts(hosts) == [0, 0, 200, 200, 400, 800])
    }

    @Test func separateGroupsDoNotShareTokens() {
        let result = starts(Array(repeating: "e-hentai.org", count: 5) + ["exhentai.org"])
        #expect(result.last == 0)
    }

    @Test func unmatchedHostUsesDefaultRule() {
        #expect(starts(Array(repeating: "example.com", count: 12)) == Array(stride(from: 0, through: 2200, by: 200)))
    }

    @Test func idleBucketRefillsOnlyUpToCapacity() {
        var schedule = RateLimitSchedule(policy: .flutterParity)
        for _ in 0..<5 { _ = schedule.reserve(host: "e-hentai.org", at: .zero) }
        let later = (0..<7).map { _ in milliseconds(schedule.reserve(host: "e-hentai.org", at: .milliseconds(100_000))) }
        #expect(later == [100_000, 100_200, 100_400, 100_600, 100_800, 101_000, 101_600])
    }

    @Test func singleLabelHathHostsShareOneBucket() {
        let result = starts((0..<21).map { "h\($0).hath.network" })
        #expect(result == Array(repeating: 0, count: 20) + [400])
    }

    @Test func twoLabelHathHostsHaveTheirOwnBuckets() {
        let singleLabel = (0..<20).map { "h\($0).hath.network" }
        let twoLabel = (0..<11).map { "h\($0).x.hath.network" }
        let result = starts(singleLabel + twoLabel)
        #expect(Array(result.prefix(20)) == Array(repeating: 0, count: 20))
        #expect(Array(result.suffix(11)) == Array(repeating: 0, count: 11))
    }

    @Test func twoLabelHathHostUsesTheDefaultRule() {
        #expect(starts(Array(repeating: "a.b.hath.network", count: 12)) == Array(stride(from: 0, through: 2200, by: 200)))
    }

    @Test func portDoesNotSplitTheBucket() {
        let hosts = ["x.y.hath.network:8443", "x.y.hath.network", "x.y.hath.network:8443", "x.y.hath.network"]
        #expect(starts(hosts) == [0, 200, 400, 600])
    }

    @Test func cancellingTheLatestReservationRestoresTheSchedule() {
        var schedule = RateLimitSchedule(policy: .flutterParity)
        _ = schedule.reserveUndoable(host: "e-hentai.org", at: .zero)
        let second = schedule.reserveUndoable(host: "e-hentai.org", at: .zero)
        let cancelled = schedule.cancel(second)
        #expect(cancelled)
        #expect(schedule.reserve(host: "e-hentai.org", at: .zero) == second.start)

        // From here on the schedule matches one that booked the first reservation and the re-booked one.
        var reference = RateLimitSchedule(policy: .flutterParity)
        _ = reference.reserve(host: "e-hentai.org", at: .zero)
        _ = reference.reserve(host: "e-hentai.org", at: .zero)
        let next = (0..<6).map { _ in schedule.reserve(host: "forums.e-hentai.org", at: .zero) }
        let expected = (0..<6).map { _ in reference.reserve(host: "forums.e-hentai.org", at: .zero) }
        #expect(next == expected)
    }

    @Test func cancellingAnOlderReservationDoesNothing() {
        var schedule = RateLimitSchedule(policy: .flutterParity)
        let first = schedule.reserveUndoable(host: "e-hentai.org", at: .zero)
        _ = schedule.reserveUndoable(host: "e-hentai.org", at: .zero)
        let cancelled = schedule.cancel(first)
        #expect(!cancelled)

        var reference = RateLimitSchedule(policy: .flutterParity)
        _ = reference.reserve(host: "e-hentai.org", at: .zero)
        _ = reference.reserve(host: "e-hentai.org", at: .zero)
        let next = (0..<6).map { _ in schedule.reserve(host: "e-hentai.org", at: .zero) }
        let expected = (0..<6).map { _ in reference.reserve(host: "e-hentai.org", at: .zero) }
        #expect(next == expected)
    }

    /// Trailing dots name the same host: one bucket and one host interval, and `cancel` takes the host a reservation
    /// recorded as it is. Wrong outcomes: "e-hentai.org..." recorded as
    /// "e-hentai.org.", so the plain host started at once; a cancel normalized its host again and rolled back the
    /// reservation of another spelling.
    @Test func trailingDotsDoNotSplitTheHost() {
        var schedule = RateLimitSchedule(policy: .flutterParity)
        let dotted = schedule.reserveUndoable(host: "E-Hentai.org...", at: .zero)
        #expect(dotted.host == "e-hentai.org")
        let plain = schedule.reserveUndoable(host: "e-hentai.org", at: .zero)
        #expect(plain.start == .milliseconds(200))
        let cancelledOlder = schedule.cancel(dotted)
        #expect(!cancelledOlder)
        let cancelledOtherSpelling = schedule.cancel(RateLimitReservation(host: "e-hentai.org.", start: plain.start))
        #expect(!cancelledOtherSpelling)
        let cancelledPlain = schedule.cancel(plain)
        #expect(cancelledPlain)
        #expect(schedule.reserve(host: "e-hentai.org.", at: .zero) == plain.start)
    }

    @Test func idleEntriesArePruned() {
        var schedule = RateLimitSchedule(policy: .flutterParity)
        for n in 0..<300 { _ = schedule.reserve(host: "h\(n).example.com", at: .zero) }
        #expect(schedule.trackedEntryCount > 256)
        schedule.pruneIdle(at: .seconds(1000))
        #expect(schedule.trackedEntryCount == 0)
    }

    // Beyond the task brief: pruning keeps busy entries as they are and never lets a request start earlier.
    @Test func pruningNeverLoosensTheSchedule() {
        func drained() -> RateLimitSchedule {
            var schedule = RateLimitSchedule(policy: .flutterParity)
            for _ in 0..<5 { _ = schedule.reserve(host: "e-hentai.org", at: .zero) }
            return schedule
        }
        func next(_ schedule: inout RateLimitSchedule, at now: Duration) -> [Duration] {
            (0..<8).map { _ in schedule.reserve(host: "e-hentai.org", at: now) }
        }

        var busy = drained(), busyReference = drained()
        busy.pruneIdle(at: .milliseconds(900))
        #expect(busy.trackedEntryCount == busyReference.trackedEntryCount)
        let afterBusyPrune = next(&busy, at: .milliseconds(900))
        let withoutBusyPrune = next(&busyReference, at: .milliseconds(900))
        #expect(afterBusyPrune == withoutBusyPrune)

        var idle = drained(), idleReference = drained()
        idle.pruneIdle(at: .seconds(10))
        #expect(idle.trackedEntryCount == 0)
        let pruned = next(&idle, at: .seconds(10)), kept = next(&idleReference, at: .seconds(10))
        #expect(zip(pruned, kept).allSatisfy { $0 >= $1 })
    }
}
