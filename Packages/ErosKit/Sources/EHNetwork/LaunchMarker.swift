import Foundation

/// Remembers that the app has started at least once on this install.
///
/// iOS keeps Keychain items when an app is deleted, but removes its UserDefaults. A missing marker therefore means
/// "first launch since install", and the old session in the Keychain belongs to a previous install.
public protocol LaunchMarker: Sendable {
    /// True once `markLaunched()` has run on this install.
    func hasLaunched() async -> Bool
    /// Records that the first-launch work is done.
    func markLaunched() async
}

/// Keeps the marker in UserDefaults under "eros.hasLaunched".
///
/// A development device that ran an earlier build without the marker counts as a first launch once, and its session
/// is cleared (such builds were never distributed).
public actor UserDefaultsLaunchMarker: LaunchMarker {
    private static let key = "eros.hasLaunched"
    private let defaults: UserDefaults

    /// nil, or a suite UserDefaults refuses (such as the app's own bundle identifier): the standard defaults.
    public init(suiteName: String? = nil) {
        self.init(defaults: suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard)
    }

    /// Keeps the marker in `defaults` (the app-hosted tests pass a suite inside the simulator app's container).
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func hasLaunched() -> Bool { defaults.bool(forKey: Self.key) }

    public func markLaunched() { defaults.set(true, forKey: Self.key) }
}

/// Keeps the marker in memory; for tests and UI tests.
public actor InMemoryLaunchMarker: LaunchMarker {
    private var launched: Bool

    public init(hasLaunched: Bool = false) {
        launched = hasLaunched
    }

    public func hasLaunched() -> Bool { launched }

    public func markLaunched() { launched = true }
}
