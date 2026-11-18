/// The display mode of a gallery list page, as selected in the site's settings.
public enum ListDisplayMode: Sendable, Hashable, Codable {
    case minimal, minimalPlus, compact, extended, thumbnail
    /// A mode code this app does not know; carries the raw `value`.
    case unrecognized(String)

    /// Maps the site's option value ("m", "p", "l", "e", "t") to a mode.
    public init(code: String) {
        switch code {
        case "m": self = .minimal
        case "p": self = .minimalPlus
        case "l": self = .compact
        case "e": self = .extended
        case "t": self = .thumbnail
        default: self = .unrecognized(code)
        }
    }

    /// True for the Compact mode, the one the app's list parser reads.
    public var isCompact: Bool { self == .compact }
}
