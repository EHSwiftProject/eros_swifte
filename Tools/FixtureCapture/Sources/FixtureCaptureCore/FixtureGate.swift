import EHFixtures
import Foundation

/// One text about to be written to a fixture root, with what the gate needs to judge it.
public struct GateText: Sendable, Equatable {
    /// Path relative to the fixture root, or "manifest.json" / "local/manifest.local.json".
    public let file: String
    public let text: String
    /// Only constructed fixtures may use `FixtureHygiene.constructedExemptions`.
    public let isConstructed: Bool

    public init(file: String, text: String, isConstructed: Bool = false) {
        self.file = file
        self.text = text
        self.isConstructed = isConstructed
    }
}

/// The single gate every fixture write passes: `FixtureWriter.write` and `resanitizeFixtures` both go through it.
public enum FixtureGate {
    /// Every check a fixture write must pass: structural rules (less the constructed exemptions, and on the private
    /// pages under `local/` less what they show by design, `FixtureHygiene.isAllowedInPrivatePage`), known secrets,
    /// and `HomePageCheck` on `*/account/home.html`. Violations carry file, rule and line only.
    public static func violations(in texts: [GateText], secrets: [KnownSecret]) -> [HygieneViolation] {
        let known = secrets.sorted { ($0.kind.rawValue, $0.value) < ($1.kind.rawValue, $1.value) }
        var violations: [HygieneViolation] = []
        for item in texts {
            let structural = FixtureHygiene.structuralViolations(in: item.text, file: item.file)
                .filter { !FixtureHygiene.isAllowedInPrivatePage($0) }
            violations += item.isConstructed ? structural.filter { !FixtureHygiene.isExempt($0) } : structural
            violations += FixtureHygiene.secretViolations(in: item.text, file: item.file, secrets: known)
            // A second, rule-independent look at home.php: any number left outside Image Limits is a violation.
            if HomePageCheck.applies(to: item.file) {
                violations += HomePageCheck.violations(in: item.text, file: item.file)
            }
        }
        return violations
    }

    /// Throws `FixtureWriterError.hygiene` when there is any violation; writes nothing itself.
    public static func check(_ texts: [GateText], secrets: [KnownSecret]) throws {
        let found = violations(in: texts, secrets: secrets)
        guard found.isEmpty else { throw FixtureWriterError.hygiene(found) }
    }
}
