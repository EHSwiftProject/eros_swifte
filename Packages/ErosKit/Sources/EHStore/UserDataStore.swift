import Foundation
import SwiftData

/// The user's own data, kept with SwiftData on this device only (no iCloud, design §6.3).
///
/// The SwiftData models stay inside the actor: callers pass and receive EHModels values. By default the store is the
/// file Application Support/UserData.store.
public actor UserDataStore {
    /// The one context of the store. Autosave is off: every change goes through `write(_:)`, which saves it.
    let modelContext: ModelContext

    /// Opens the store, creating it (and the directories above it) when missing.
    ///
    /// - Parameters:
    ///   - inMemory: Keeps the store in memory, apart from every other store; `storeURL` is then ignored.
    ///   - storeURL: The store file; nil means Application Support/UserData.store.
    /// - Throws: When a directory cannot be created or the store cannot be opened.
    public init(inMemory: Bool = false, storeURL: URL? = nil) throws {
        let schema = Self.schema
        let configuration: ModelConfiguration
        if inMemory {
            // A unique name per instance, so that two in-memory stores never share their data.
            configuration = ModelConfiguration(
                UUID().uuidString, schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
            )
        } else {
            let url = storeURL ?? Self.defaultStoreURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        }
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelContext = context
    }

    /// Application Support/UserData.store.
    static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "UserData.store")
    }

    /// Applies `change` to the context and saves it; when either throws, rolls the context back and rethrows.
    func write<T>(_ change: (ModelContext) throws -> T) throws -> T {
        do {
            let result = try change(modelContext)
            try modelContext.save()
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
