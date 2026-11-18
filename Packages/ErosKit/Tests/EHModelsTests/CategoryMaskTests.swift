import EHModels
import Foundation
import Testing

@Suite struct CategoryMaskTests {
    @Test func bitsFollowFilterBits() {
        #expect(CategoryMask(excluding: [GalleryCategory.doujinshi]).rawValue == 2)
        #expect(CategoryMask(excluding: GalleryCategory.allCases).rawValue == 1023)
        #expect(CategoryMask.only(.doujinshi).rawValue == 1021)  // the captured f_cats=1021 sample: only doujinshi
        #expect(CategoryMask.allBut(.manga).rawValue == 4)
        #expect(CategoryMask.only(.doujinshi).excludes(.manga) && !CategoryMask.only(.doujinshi).excludes(.doujinshi))
    }

    @Test func codesAsABareInteger() throws {
        let encoded = try JSONEncoder().encode(CategoryMask(rawValue: 1021))
        #expect(String(decoding: encoded, as: UTF8.self) == "1021")
        #expect(try JSONDecoder().decode(CategoryMask.self, from: Data("1021".utf8)) == .only(.doujinshi))
    }

    @Test func rawValueKeepsHighBits() {
        #expect(CategoryMask(rawValue: 4096).rawValue == 4096)
    }

    @Test func styleAndTypeNamesMatchFlutter() {
        #expect(ListStyle.allCases.map(\.rawValue) == ["list", "simpleList", "waterfall", "waterfallLarge", "grid"])
        #expect(GroupListType.allCases.map(\.rawValue) == ["gallery", "watched", "popular"])
    }
}
