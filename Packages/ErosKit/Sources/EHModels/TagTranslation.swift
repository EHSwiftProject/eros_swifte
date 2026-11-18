/// The translation of one tag, a row of EhTagTranslation's `db.raw.json`.
public struct TagTranslation: Sendable, Hashable, Codable {
    /// The full namespace name, such as "female".
    public var namespace: String
    /// The tag name as the site writes it.
    public var key: String
    /// The translated name, as `db.raw` has it; may hold Markdown.
    public var name: String
    public var intro: String
    public var links: String

    public init(namespace: String, key: String, name: String, intro: String, links: String) {
        self.namespace = namespace
        self.key = key
        self.name = name
        self.intro = intro
        self.links = links
    }

    /// `name` without Markdown images (Flutter's `nameNotMD`); show this one in the interface.
    public var plainName: String {
        name.replacing(/!\[(\S+)?\]\(.+?\)(\s+)?(\S+)/) { String($0.output.3) }
    }
}
