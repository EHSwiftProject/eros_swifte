import EHStore
import Foundation
import Synchronization

// Test support shared by the search suites (SearchTermTranslatorTests, TagSuggestionServiceTests,
// TagSuggestionQueryTests). Every tag here is made up.

/// In-memory tag tables with made-up rows, in the format of `db.raw.json`.
enum FakeTagTable {
    /// One row: namespace, key, name (the name may hold Markdown, as in the real database).
    typealias Row = (namespace: String, key: String, name: String)

    /// `female:fake tag` (its name holding a Markdown image), `female:fake second`, `other:fake other` and
    /// `artist:fakeartist`.
    static let rows: [Row] = [
        ("female", "fake tag", "![图](https://example.invalid/a.png) 示例标签"),
        ("female", "fake second", "示例二"),
        ("other", "fake other", "其他示例"),
        ("artist", "fakeartist", "示例作者"),
    ]

    /// A store in memory with `rows` imported.
    static func store(_ rows: [Row] = rows) async throws -> TagTranslationStore {
        let store = try TagTranslationStore(inMemory: true)
        _ = try await store.replaceAll(with: database(rows), version: "v0 test")
        return store
    }

    /// `db.raw.json` holding `rows`, one block per namespace in the order they first appear.
    static func database(_ rows: [Row]) throws -> Data {
        var namespaces: [String] = []
        var tags: [String: [String: Any]] = [:]
        for row in rows {
            if tags[row.namespace] == nil { namespaces.append(row.namespace) }
            tags[row.namespace, default: [:]][row.key] = ["name": row.name]
        }
        let blocks = namespaces.map { ["namespace": $0, "data": tags[$0] ?? [:]] as [String: Any] }
        return try JSONSerialization.data(withJSONObject: ["data": blocks])
    }
}

/// The `text` of every request a stub received, in order. A stub's responder runs on the session's loading thread,
/// where the body arrives as a stream, so it is read there.
final class SuggestRequestLog: Sendable {
    private let texts = Mutex<[String]>([])

    func record(_ request: URLRequest) {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
        }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let text = object?["text"] as? String ?? "<no text>"
        texts.withLock { $0.append(text) }
    }

    var all: [String] { texts.withLock { $0 } }
}
