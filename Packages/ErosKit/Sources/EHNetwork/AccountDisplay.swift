import EHModels
import Foundation

/// What the UI shows for the signed-in account: the forum nickname and avatar when they were read, the name typed at
/// login and the system default avatar otherwise.
public enum AccountDisplay {
    public struct Resolved: Sendable, Equatable {
        /// The nickname, else the login name; nil when the account has neither (cookie and web logins without a
        /// forum profile).
        public let name: String?
        /// The avatar as stored; nil means the system default avatar.
        public let avatarURL: URL?

        public init(name: String?, avatarURL: URL?) {
            self.name = name
            self.avatarURL = avatarURL
        }
    }

    /// `displayName ?? username` and the stored avatar URL.
    public static func resolve(_ account: AccountInfo) -> Resolved {
        Resolved(name: account.displayName ?? account.username, avatarURL: account.avatarURL)
    }
}
