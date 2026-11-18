import EHNetwork
import Foundation
import Testing

/// Runs inside the Eros app on the simulator: the Keychain needs a signed host (simulator builds are ad-hoc
/// signed, see CODE_SIGN_IDENTITY in project.yml); an unsigned package test bundle gets errSecMissingEntitlement (-34018).
@Suite struct KeychainVaultTests {
    /// A service of its own per test, so runs never see each other's items.
    private static func uniqueVault() -> KeychainVault {
        KeychainVault(service: "proj.eros.swifte.tests.\(UUID().uuidString)", account: "session")
    }

    @Test func roundTripsAndDeletes() throws {
        let vault = Self.uniqueVault()
        defer { try? vault.delete() }
        let first = Data(#"{"cookies":{"eh":{"ipb_member_id":"1234567"}}}"#.utf8)
        try vault.write(first)
        #expect(try vault.read() == first)
        let second = Data(#"{"cookies":{}}"#.utf8)
        try vault.write(second)
        #expect(try vault.read() == second)
        try vault.delete()
        #expect(try vault.read() == nil)
        try vault.delete()
    }

    @Test func missingItemReadsNil() throws {
        let vault = Self.uniqueVault()
        #expect(try vault.read() == nil)
    }
}
