import EHModels
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Eros

/// What the list items show: cover fit, language code, colors, stars and the posted time (Flutter's rules).
@MainActor @Suite struct ItemFormattingTests {
    @Test func coverFitFollowsFlutter() {
        // List: a 1:1 box; an image ratio 0.3 off either way is fit, 0.1 off is filled.
        let square = CGSize(width: 100, height: 100)
        #expect(CoverFit.list(image: ImageSize(width: 130, height: 100), box: square) == .fit)
        #expect(CoverFit.list(image: ImageSize(width: 110, height: 100), box: square) == .fill)
        #expect(CoverFit.list(image: ImageSize(width: 70, height: 100), box: square) == .fit)
        #expect(CoverFit.list(image: ImageSize(width: 90, height: 100), box: square) == .fill)
        // Grid: a 3:4 box (0.75); wider than the box but below 2.2 is filled, else fit.
        let portrait = CGSize(width: 75, height: 100)
        #expect(CoverFit.grid(image: ImageSize(width: 150, height: 100), box: portrait) == .fill)
        #expect(CoverFit.grid(image: ImageSize(width: 250, height: 100), box: portrait) == .fit)
        #expect(CoverFit.grid(image: ImageSize(width: 50, height: 100), box: portrait) == .fit)
        // An unknown size is fit.
        #expect(CoverFit.list(image: nil, box: square) == .fit)
        #expect(CoverFit.grid(image: nil, box: portrait) == .fit)
    }

    /// A cover decides by the box it was laid out in (L071c): a list row grown by a large text size (204 → 300 tall)
    /// fits a cover it filled at the smallest height, rather than cropping about a third of it.
    @Test func coversFitTheBoxTheyWereGiven() {
        let cover = ImageSize(width: 100, height: 130)
        #expect(CoverFitRule.list.mode(for: cover, in: CGSize(width: 143, height: 204)) == .fill)
        #expect(CoverFitRule.list.mode(for: cover, in: CGSize(width: 143, height: 300)) == .fit)
        #expect(CoverFitRule.grid.mode(for: ImageSize(width: 150, height: 100), in: CGSize(width: 75, height: 100)) == .fill)
        // Not laid out yet: no box, fit.
        #expect(CoverFitRule.list.mode(for: cover, in: .zero) == .fit)
        // So a cover reads the frame its item gives it until it is measured (M2 re-review F3 M-4): an image the memory
        // cache shows at once is filled from the first frame, as it is once measured, not fitted first.
        let nominal = CGSize(width: 143, height: 204)
        #expect(ItemCover.box(measured: .zero, nominal: nominal) == nominal)
        #expect(ItemCover.box(measured: CGSize(width: 143, height: 0), nominal: nominal) == nominal)
        let grown = CGSize(width: 143, height: 300)
        #expect(ItemCover.box(measured: grown, nominal: nominal) == grown)
        #expect(CoverFitRule.list.mode(for: cover, in: ItemCover.box(measured: .zero, nominal: nominal)) == .fill)
        // The two that do not look at the box.
        #expect(CoverFitRule.whole.mode(for: cover, in: CGSize(width: 143, height: 300)) == .fit)
        #expect(CoverFitRule.fill.mode(for: cover, in: .zero) == .fill)
    }

    @Test func languageCodeComesFromLanguageTags() {
        func tags(_ raws: String...) -> [ListTag] {
            raws.map { ListTag(tag: TagRef(raw: $0), colors: nil) }
        }
        #expect(ItemFormat.languageCode(in: tags("language:fake language", "language:chinese")) == "ZH")
        #expect(ItemFormat.languageCode(in: tags("female:fake tag", "language:chinese")) == "ZH")
        #expect(ItemFormat.languageCode(in: tags("language:fake language")) == nil)
        #expect(ItemFormat.languageCode(in: tags("female:fake tag")) == nil)
        #expect(ItemFormat.languageCode(in: []) == nil)
    }

    @Test func colorsFollowFlutter() {
        let light: [GalleryCategory: UInt32] = [
            .doujinshi: 0xF44336, .manga: 0xFF9800, .artistCG: 0xFBC02D, .gameCG: 0x4CAF50, .western: 0x8BC34A,
            .nonH: 0x2196F3, .imageSet: 0x3F51B5, .cosplay: 0x9C27B0, .asianPorn: 0x9575CD, .misc: 0xF06292,
        ]
        for category in GalleryCategory.allCases {
            #expect(category.listRGB.light == ListRGB(light[category] ?? 0), "\(category)")
        }
        #expect(GalleryCategory.doujinshi.listRGB.dark == ListRGB(red: 145, green: 49, blue: 39))
        #expect(GalleryCategory.misc.listRGB.dark == ListRGB(red: 188, green: 91, blue: 123))
        #expect(FavoriteSlotColors.rgb == [
            0x5F5F5F, 0xDE1C31, 0xF97D1C, 0xF8B500, 0x2BAE85, 0x5BAE23, 0x22A2C3, 0x1661AB, 0x9F3EF9, 0xEC2D7A,
        ].map(ListRGB.init))
        #expect(ItemFormat.starRGB(isRatedByUser: false) == ListRGB(red: 255, green: 150, blue: 46))
        #expect(ItemFormat.starRGB(isRatedByUser: true) == ListRGB(red: 126, green: 120, blue: 255))

        // `listColor` follows the appearance: the light value in light mode, the dark one in dark mode.
        let color = UIColor(GalleryCategory.doujinshi.listColor)
        #expect(Self.rgb(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))) == ListRGB(0xF44336))
        #expect(Self.rgb(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
            == ListRGB(red: 145, green: 49, blue: 39))
    }

    @Test func ratingBecomesHalfStars() {
        #expect(ItemFormat.stars(for: 3.5) == [.full, .full, .full, .half, .empty])
        #expect(ItemFormat.stars(for: 0) == [.empty, .empty, .empty, .empty, .empty])
        #expect(ItemFormat.stars(for: 5) == [.full, .full, .full, .full, .full])
        #expect(ItemFormat.stars(for: 4.5) == [.full, .full, .full, .full, .half])
    }

    @Test func postedTimeUsesTheFlutterFormat() throws {
        // 2024-01-02 03:04 UTC.
        let posted = Date(timeIntervalSince1970: 1_704_164_640)
        #expect(ItemFormat.postedTime(posted, timeZone: try #require(TimeZone(identifier: "UTC"))) == "2024-01-02 03:04")
        #expect(
            ItemFormat.postedTime(posted, timeZone: try #require(TimeZone(identifier: "Asia/Tokyo"))) == "2024-01-02 12:04"
        )
    }

    private static func rgb(_ color: UIColor) -> ListRGB {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return ListRGB(red: Int((red * 255).rounded()), green: Int((green * 255).rounded()), blue: Int((blue * 255).rounded()))
    }
}
