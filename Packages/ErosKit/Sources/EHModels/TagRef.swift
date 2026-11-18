import Foundation

/// A tag, with its namespace when it has one ("ns:name").
public struct TagRef: Sendable, Hashable, Codable {
    /// The namespace, or nil for a tag without one.
    public let namespace: String?
    /// The tag name.
    public let name: String

    public init(namespace: String?, name: String) {
        self.namespace = namespace
        self.name = name
    }

    /// Splits `raw` at its first ":"; both sides are trimmed. Without a ":" the whole text, trimmed, is the name and
    /// the namespace is nil.
    public init(raw: String) {
        if let colon = raw.firstIndex(of: ":") {
            self.init(
                namespace: raw[..<colon].trimmingCharacters(in: .whitespacesAndNewlines),
                name: raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else {
            self.init(namespace: nil, name: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// "ns:name", or "name" without a namespace.
    public var raw: String {
        namespace.map { "\($0):\(name)" } ?? name
    }
}
