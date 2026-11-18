import EHModels
import Foundation
import Testing

@Suite struct CoreModelTests {
    @Test func categoryLabelsRoundTrip() {
        for category in GalleryCategory.allCases {
            #expect(GalleryCategory(siteLabel: category.siteLabel) == category)
        }
        #expect(GalleryCategory(siteLabel: "non-h") == .nonH)
        #expect(GalleryCategory(siteLabel: " Artist CG ") == .artistCG)
        #expect(GalleryCategory(siteLabel: "ArtistCG") == nil)
        #expect(GalleryCategory(siteLabel: "") == nil)
    }

    @Test func filterBitsMatchFlutter() {
        let bits = GalleryCategory.allCases.map(\.filterBit)
        #expect(bits == [1, 2, 4, 8, 16, 32, 64, 128, 256, 512])
        #expect(bits.reduce(0, +) == 1023)
    }

    @Test func tagRefSplitsAtFirstColon() {
        let namespaced = TagRef(raw: "female:fake tag")
        #expect(namespaced.namespace == "female")
        #expect(namespaced.name == "fake tag")
        #expect(namespaced.raw == "female:fake tag")

        let twoColons = TagRef(raw: "parody:a:b")
        #expect(twoColons.namespace == "parody")
        #expect(twoColons.name == "a:b")
        #expect(twoColons.raw == "parody:a:b")

        let plain = TagRef(raw: "plain")
        #expect(plain.namespace == nil)
        #expect(plain.name == "plain")
        #expect(plain.raw == "plain")

        let spaced = TagRef(raw: " female : fake tag ")
        #expect(spaced == TagRef(namespace: "female", name: "fake tag"))
        #expect(TagRef(raw: spaced.raw) == spaced)
    }

    /// The enum moved from EHParsing keeps its cases and codes, and is now Codable.
    @Test func listDisplayModeRoundTripsThroughJSON() throws {
        let modes: [ListDisplayMode] = [.minimal, .minimalPlus, .compact, .extended, .thumbnail, .unrecognized("x")]
        #expect(["m", "p", "l", "e", "t", "x"].map(ListDisplayMode.init(code:)) == modes)
        #expect(modes.map(\.isCompact) == [false, false, true, false, false, false])
        let decoded = try JSONDecoder().decode([ListDisplayMode].self, from: JSONEncoder().encode(modes))
        #expect(decoded == modes)
    }

    @Test func valueTypesRoundTripThroughJSON() throws {
        let gallery = GalleryID(gid: 900001, token: "0f0f0f0f0f")
        #expect(try JSONDecoder().decode(GalleryID.self, from: JSONEncoder().encode(gallery)) == gallery)
        let size = ImageSize(width: 1280, height: 1810)
        #expect(try JSONDecoder().decode(ImageSize.self, from: JSONEncoder().encode(size)) == size)
        let tag = TagRef(namespace: nil, name: "plain")
        #expect(try JSONDecoder().decode(TagRef.self, from: JSONEncoder().encode(tag)) == tag)
        let categories = GalleryCategory.allCases
        #expect(try JSONDecoder().decode([GalleryCategory].self, from: JSONEncoder().encode(categories)) == categories)
    }
}
