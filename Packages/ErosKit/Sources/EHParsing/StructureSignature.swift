import EHModels
import SwiftSoup

/// The kinds of page whose structure is compared.
public enum PageKind: String, Sendable, CaseIterable {
    case list, detail, image
}

/// Which structural markers a page has, for comparing the HTML the site sends under different user agents.
/// It holds selector names and numbers only, never page text.
public struct StructureSignature: Sendable, Equatable, CustomStringConvertible {
    public let kind: PageKind
    /// Names of the markers found; a marker's name is its selector.
    public let present: Set<String>
    /// List pages: the number of rows with `td.gl1c.glcat`.
    public let listRows: Int?
    /// List pages: the selected display mode (nil: no selector on the page).
    public let displayMode: ListDisplayMode?

    /// The markers of each page kind. Only their presence is compared, not how many there are: tag and comment
    /// counts differ between galleries anyway.
    public static let markers: [PageKind: [String]] = [
        .list: [
            "table.itg.gltc", "td.gl1c.glcat", "td.gl2c > div.glcut", "td.gl2c div.glthumb", "div[id^=posted_]",
            "td.gl3c.glname .glink", "td.gl4c.glhide", ".searchnav", "#unext", "#dms", "meta[name=viewport]",
        ],
        .detail: [
            "#gd1 > div", "#gn", "#gj", "#gdc", "#gdn", "#gdd tr", "#rating_label", "#favoritelink", "#taglist tr",
            "#gdt > a", "#gdt > div.gdtm", "#gdt > div.gdtl", ".gtb table.ptt", "#cdiv > div.c1", "#gd5",
            "meta[name=viewport]",
        ],
        .image: [
            "#i1", "#i2 .sn", "#i3 img#img", "#i4", "#i5 a", "#loadfail", "a[href*=\"/fullimg/\"]",
            "meta[name=viewport]",
        ],
    ]

    /// - Throws: whatever SwiftSoup throws while parsing or selecting, unchanged.
    public static func of(_ html: String, kind: PageKind) throws -> StructureSignature {
        let document = try SwiftSoup.parse(html)
        var present = Set<String>()
        for marker in markers[kind] ?? [] where try !document.select(marker).isEmpty() {
            present.insert(marker)
        }
        if kind == .list {
            return StructureSignature(
                kind: kind, present: present, listRows: try document.select("td.gl1c.glcat").size(),
                displayMode: try ListDisplayMode.detect(in: html)
            )
        }
        return StructureSignature(kind: kind, present: present, listRows: nil, displayMode: nil)
    }

    /// Marker names, "listRows" or "displayMode" that differ between the two signatures; sorted.
    public func differences(from other: StructureSignature) -> [String] {
        var result = Array(present.symmetricDifference(other.present))
        if listRows != other.listRows { result.append("listRows") }
        if displayMode != other.displayMode { result.append("displayMode") }
        return result.sorted()
    }

    public var description: String {
        let mode = displayMode.map(Self.modeName) ?? "nil"
        let rows = listRows.map(String.init) ?? "nil"
        return "StructureSignature(kind: \(kind.rawValue), present: \(present.sorted()), listRows: \(rows), "
            + "displayMode: \(mode))"
    }

    /// The mode's case name; an unrecognized mode's raw code comes from the page and is not repeated.
    private static func modeName(_ mode: ListDisplayMode) -> String {
        switch mode {
        case .minimal: "minimal"
        case .minimalPlus: "minimalPlus"
        case .compact: "compact"
        case .extended: "extended"
        case .thumbnail: "thumbnail"
        case .unrecognized: "unrecognized"
        }
    }
}
