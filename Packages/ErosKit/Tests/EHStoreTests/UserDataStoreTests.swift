import EHStore
import Foundation
import Testing

@Suite struct UserDataStoreTests {
    @Test func opensInMemory() throws {
        _ = try UserDataStore(inMemory: true)
    }

    @Test func createsTheStoreAndItsDirectories() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "nested/deeper/UserData.store")
            _ = try UserDataStore(storeURL: url)
            #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        }
    }

    /// Neither the file nor the directory above it is made.
    @Test func inMemoryWinsOverTheURL() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "nested/UserData.store")
            _ = try UserDataStore(inMemory: true, storeURL: url)
            #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "nested").path(percentEncoded: false)))
        }
    }
}
