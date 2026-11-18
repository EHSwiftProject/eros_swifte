import EHNetwork
import Foundation
import Testing

/// Runs inside the Eros app on the simulator, so the suite's plist lives in the app's container (and goes with it).
/// One fixed suite, cleared before and after.
@Suite struct UserDefaultsLaunchMarkerTests {
    private static let suite = "proj.eros.swifte.tests.launch-marker"
    private static let key = "eros.hasLaunched"

    @Test func roundTrips() async throws {
        let defaults = try #require(UserDefaults(suiteName: Self.suite))
        defaults.removePersistentDomain(forName: Self.suite)
        defer { defaults.removePersistentDomain(forName: Self.suite) }

        let marker = UserDefaultsLaunchMarker(defaults: try #require(UserDefaults(suiteName: Self.suite)))
        #expect(await !marker.hasLaunched())
        await marker.markLaunched()
        #expect(await marker.hasLaunched())
        // Another marker on the same suite, made by name, sees it.
        #expect(await UserDefaultsLaunchMarker(suiteName: Self.suite).hasLaunched())
        #expect(defaults.bool(forKey: Self.key))
    }
}
