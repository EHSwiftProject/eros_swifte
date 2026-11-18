import Foundation
import Security
import Synchronization

/// One opaque blob of credentials (the session snapshot as JSON), read and written whole.
public protocol CredentialVault: Sendable {
    /// The stored bytes; nil when nothing is stored.
    func read() throws -> Data?
    /// Replaces the stored bytes.
    func write(_ data: Data) throws
    /// Removes the stored bytes; succeeds when nothing is stored.
    func delete() throws
}

/// A Keychain call that failed with something other than "item not found".
public struct KeychainError: Error, Equatable, Sendable {
    /// The `OSStatus` the Security framework returned (e.g. -34018, errSecMissingEntitlement).
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}

/// A generic-password Keychain item in the app's default access group.
///
/// Readable after the first unlock, never leaves the device: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
/// no `kSecAttrAccessGroup`, not synchronizable (no iCloud Keychain).
public struct KeychainVault: CredentialVault {
    public let service: String
    public let account: String

    public init(service: String = "proj.eros.swifte.session", account: String = "session") {
        self.service = service
        self.account = account
    }

    public func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError(status: errSecInternalError) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func write(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let added = SecItemAdd(baseQuery.merging(attributes) { $1 } as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        default:
            throw KeychainError(status: updated)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Identifies the item; also the base of every query.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// A vault that keeps its bytes in memory; for tests and UI tests.
public final class InMemoryVault: CredentialVault {
    private let storage: Mutex<Data?>

    public init(data: Data? = nil) {
        storage = Mutex(data)
    }

    public func read() throws -> Data? {
        storage.withLock { $0 }
    }

    public func write(_ data: Data) throws {
        storage.withLock { $0 = data }
    }

    public func delete() throws {
        storage.withLock { $0 = nil }
    }
}
