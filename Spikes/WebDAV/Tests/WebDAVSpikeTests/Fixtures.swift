import Foundation
import Testing
import WebDAVSpike

/// Loads the Dart-generated golden data (`Golden/`) and the hand-written or captured
/// PROPFIND responses (`MultiStatus/`) bundled with the test target.
enum Fixtures {
    static let golden: URL = Bundle.module.url(forResource: "Golden", withExtension: nil)!
    static let multiStatusDirectory: URL = Bundle.module.url(forResource: "MultiStatus", withExtension: nil)!
    static let sampleTree: URL = golden.appending(path: "sample-tree", directoryHint: .isDirectory)

    static let cipherVectors: CipherVectors = load("cipher-vectors.json")
    static let urlVectors: URLVectors = load("url-vectors.json")
    static let manifest: SampleManifest = load("sample-tree-manifest.json")

    static func multiStatus(_ name: String) throws -> Data {
        try Data(contentsOf: multiStatusDirectory.appending(path: name))
    }

    /// Bytes of a golden sample file, addressed by its remote path (`/fehviewer/...`).
    static func sampleTreeData(_ remotePath: String) throws -> Data {
        try Data(contentsOf: sampleTree.appending(path: String(remotePath.dropFirst())))
    }

    /// Remote paths of every file in the golden sample tree.
    static func sampleTreeRemotePaths() throws -> [String] {
        let root = sampleTree.standardizedFileURL.path(percentEncoded: false)
        guard let enumerator = FileManager.default.enumerator(
            at: sampleTree, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path(percentEncoded: false)
            paths.append("/" + full.dropFirst(root.count).drop(while: { $0 == "/" }))
        }
        return paths.sorted()
    }

    private static func load<T: Decodable>(_ name: String) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: golden.appending(path: name)))
        } catch {
            fatalError("cannot load golden \(name): \(error)")
        }
    }
}

struct CipherVectors: Decodable, Sendable {
    struct Vector: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let plaintext: String
        let utf8Length: Int
        let ciphertextBase64: String?
        let ciphertextLength: Int?
        let deterministic: Bool?
        let decryptsBack: Bool?
        let encryptError: String?
        let paddedBlockCiphertextBase64: String?
        let paddedBlockDecryptsTo: String?
        var testDescription: String { name }
    }

    struct DecryptCase: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let input: String
        let accepted: Bool
        let plaintext: String?
        let error: String?
        var testDescription: String { name }
    }

    let key: String
    let iv: String
    let algorithm: String
    let vectors: [Vector]
    let decryptCases: [DecryptCase]
}

struct URLVectors: Decodable, Sendable {
    struct Vector: Decodable, Sendable, CustomTestStringConvertible {
        let remotePath: String
        let url: String?
        let requestTarget: String?
        let fragmentDropped: Bool?
        let decodedPath: String?
        var testDescription: String { remotePath }
    }

    let baseURL: String
    let vectors: [Vector]
}

struct SampleManifest: Codable, Sendable {
    struct File: Codable, Sendable, CustomTestStringConvertible {
        let remotePath: String
        let kind: String
        var size: Int?
        var encrypted: Bool?
        var parsedName: JSONValue?
        var json: JSONValue?
        var lines: [String]?
        var testDescription: String { remotePath }
    }

    let files: [File]

    /// `parsedName` in the shape the Dart golden uses (inverse of ``expectedEntry(_:)``).
    static func parsedName(for entry: LegacyLayout.Entry) -> JSONValue {
        switch entry {
        case let .history(gid, time): .object(["g": .string(gid), "t": .int(Int64(time))])
        case let .historyDeletion(gid), let .readProgress(gid): .string(gid)
        case let .group(name, uuid, time):
            .object(["name": .string(name), "uuid": .string(uuid), "lastEditTime": .int(Int64(time))])
        case let .quickSearch(time): .int(Int64(time))
        }
    }

    /// The layout entry the Dart golden says the app parses out of `file`'s name.
    static func expectedEntry(_ file: File) -> LegacyLayout.Entry? {
        switch (file.kind, file.parsedName) {
        case let ("history", .object(fields)):
            guard case let .string(gid) = fields["g"], case let .int(time) = fields["t"] else { return nil }
            return .history(gid: gid, lastViewTime: Int(time))
        case let ("historyDeletion", .string(gid)):
            return .historyDeletion(gid: gid)
        case let ("readProgress", .string(gid)):
            return .readProgress(gid: gid)
        case let ("group", .object(fields)):
            guard case let .string(name) = fields["name"], case let .string(uuid) = fields["uuid"],
                  case let .int(time) = fields["lastEditTime"] else { return nil }
            return .group(name: name, uuid: uuid, lastEditTime: Int(time))
        case let ("quickSearch", .int(time)):
            return .quickSearch(time: Int(time))
        default:
            return nil
        }
    }
}
