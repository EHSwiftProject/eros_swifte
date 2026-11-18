import EHModels
import EHNetwork
import Testing

@Suite struct SiteSettingNoticeTests {
    @Test func inMemoryLedgerKeepsEachScope() async {
        let first = NoticeScope(kind: .compactView, site: .eh, memberID: 1234567)
        let others = [
            NoticeScope(kind: .favoritesOrder, site: .eh, memberID: 1234567),
            NoticeScope(kind: .compactView, site: .ex, memberID: 1234567),
            NoticeScope(kind: .compactView, site: .eh, memberID: 7654321),
            NoticeScope(kind: .compactView, site: .eh, memberID: nil),
        ]
        let ledger = InMemoryNoticeLedger()
        #expect(await !ledger.isAcknowledged(first))
        await ledger.acknowledge(first)
        #expect(await ledger.isAcknowledged(first))
        for scope in others { #expect(await !ledger.isAcknowledged(scope)) }

        // The set given at the start counts as it is.
        let seeded = InMemoryNoticeLedger(acknowledged: [others[0], others[3]])
        #expect(await seeded.isAcknowledged(others[0]))
        #expect(await seeded.isAcknowledged(others[3]))
        #expect(await !seeded.isAcknowledged(first))
        #expect(await !seeded.isAcknowledged(others[1]))
    }
}
