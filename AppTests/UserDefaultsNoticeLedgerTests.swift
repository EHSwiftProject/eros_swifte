import EHModels
import EHNetwork
import Foundation
import Testing

@testable import Eros

/// The ledger in a fixed UserDefaults suite, wiped before and after.
@Suite(.serialized) struct UserDefaultsNoticeLedgerTests {
    private static let suite = "proj.eros.swifte.tests.notice-ledger"

    private static func makeDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func keepsEachScopeApart() async throws {
        let defaults = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: Self.suite) }
        let ledger = UserDefaultsNoticeLedger(suiteName: Self.suite)
        let first = NoticeScope(kind: .compactView, site: .eh, memberID: 1234567)
        let anonymous = NoticeScope(kind: .favoritesOrder, site: .ex, memberID: nil)
        let others = [
            NoticeScope(kind: .favoritesOrder, site: .eh, memberID: 1234567),
            NoticeScope(kind: .compactView, site: .ex, memberID: 1234567),
            NoticeScope(kind: .compactView, site: .eh, memberID: 7654321),
            NoticeScope(kind: .compactView, site: .eh, memberID: nil),
            anonymous,
        ]
        await ledger.acknowledge(first)
        #expect(await ledger.isAcknowledged(first))
        for scope in others { #expect(await !ledger.isAcknowledged(scope)) }
        #expect(defaults.bool(forKey: "eros.siteSettingNotice.compactView.eh.1234567"))

        await ledger.acknowledge(anonymous)
        #expect(await ledger.isAcknowledged(anonymous))
        #expect(defaults.bool(forKey: "eros.siteSettingNotice.favoritesOrder.ex.anonymous"))
    }

    @Test func theOldGlobalKeyIsIgnored() async throws {
        let defaults = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: Self.suite) }
        defaults.set(true, forKey: "eros.compactNoticeAcknowledged")
        let ledger = UserDefaultsNoticeLedger(suiteName: Self.suite)
        for site in EHSite.allCases {
            for member in [1234567, nil] {
                #expect(await !ledger.isAcknowledged(NoticeScope(kind: .compactView, site: site, memberID: member)))
            }
        }
        // Left as it was: not migrated, not removed.
        #expect(defaults.bool(forKey: "eros.compactNoticeAcknowledged"))
    }
}
