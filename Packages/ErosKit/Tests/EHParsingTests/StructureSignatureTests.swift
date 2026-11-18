import EHFixtures
import EHParsing
import Foundation
import SwiftSoup
import Testing

/// Structure signatures of the captured M0 samples and of altered copies.
@Suite struct StructureSignatureTests {
    /// The markers the M0 samples (eh and ex alike) do not have. Each is a sentinel: it is reported only if a page
    /// under another user agent gains it.
    static let absentFromM0Samples: [PageKind: Set<String>] = [
        .list: ["#dms", "meta[name=viewport]"],
        .detail: ["#gdt > div.gdtm", "#gdt > div.gdtl", "meta[name=viewport]"],
        .image: ["meta[name=viewport]"],
    ]

    @Test(arguments: ["eh", "ex"])
    func m0FrontPagesAreCompactListsOf25(site: String) throws {
        let signature = try StructureSignature.of(Fixtures.string("\(site)/list/front.html"), kind: .list)
        #expect(signature.listRows == 25)
        #expect(signature.displayMode == .compact)
    }

    @Test(arguments: [
        ("eh/list/front.html", PageKind.list), ("ex/list/front.html", .list),
        ("eh/gallery/detail.html", .detail), ("ex/gallery/detail.html", .detail),
        ("eh/image/page.html", .image), ("ex/image/page.html", .image),
    ])
    func signatureOfASampleEqualsItself(path: String, kind: PageKind) throws {
        let html = try Fixtures.string(path)
        let first = try StructureSignature.of(html, kind: kind)
        let second = try StructureSignature.of(html, kind: kind)
        #expect(first == second)
        #expect(first.differences(from: second).isEmpty)
        // A selector that silently stops matching would hide a change, so the markers the M0 samples lack are
        // pinned: the same on both sites.
        let missing = Set(StructureSignature.markers[kind] ?? []).subtracting(first.present)
        #expect(missing == Self.absentFromM0Samples[kind])
    }

    @Test func missingMarkerIsReportedByName() throws {
        let html = try Fixtures.string("eh/gallery/detail.html")
        let document = try SwiftSoup.parse(html)
        try document.select("#gdt > a").remove()
        let original = try StructureSignature.of(html, kind: .detail)
        let changed = try StructureSignature.of(document.outerHtml(), kind: .detail)
        #expect(changed.differences(from: original) == ["#gdt > a"])
        #expect(original.differences(from: changed) == ["#gdt > a"])
    }

    @Test func displayModeChangeIsReported() throws {
        let front = try StructureSignature.of(Fixtures.string("eh/list/front.html"), kind: .list)
        let other = try StructureSignature.of(Fixtures.string("constructed/eh/list-non-compact.html"), kind: .list)
        #expect(other.differences(from: front).contains("displayMode"))
    }

    @Test func signaturesHoldNoPageText() throws {
        var remainder = ""
        for path in ["eh/list/front.html", "ex/gallery/detail.html", "eh/image/page.html"] {
            let kind: PageKind = path.contains("list") ? .list : path.contains("gallery") ? .detail : .image
            remainder += String(describing: try StructureSignature.of(Fixtures.string(path), kind: kind)) + "\n"
        }
        // Everything that may appear: type and field names, enum names, selector names and numbers.
        let allowed = ["StructureSignature", "kind", "present", "listRows", "displayMode", "nil"]
            + PageKind.allCases.map(\.rawValue)
            + ["minimalPlus", "minimal", "compact", "extended", "thumbnail", "unrecognized"]
            // Arrays print their strings escaped, so a marker with quotes shows up with backslashes.
            + StructureSignature.markers.values.joined().flatMap { [$0, $0.replacingOccurrences(of: "\"", with: "\\\"")] }
        for word in allowed.sorted(by: { $0.count > $1.count }) {
            remainder = remainder.replacingOccurrences(of: word, with: " ")
        }
        let leftover = remainder.filter { !$0.isWhitespace && !$0.isNumber && !"()[],:\"\\".contains($0) }
        // Bound first: `leftover.isEmpty` itself would print the leftover text, page text if the check fails.
        let holdsNoPageText = leftover.isEmpty
        #expect(holdsNoPageText, "unexpected characters: \(Set(leftover).sorted())")
    }
}
