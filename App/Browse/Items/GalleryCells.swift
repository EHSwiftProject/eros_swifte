import EHModels
import SwiftUI

/// A gallery in the `waterfall` style (Flutter `gallery_item_flow.dart`): only the cover, as wide as the lane in its
/// own ratio (never cropped), with rounded corners and the language code on the category's color at its top leading
/// corner. Its height is what `LaneAssignment.estimatedHeight` reckons with.
struct GalleryWaterfallCell: View {
    let summary: GallerySummary
    let laneWidth: CGFloat

    var body: some View {
        let height = laneWidth * LaneAssignment.heightRatio(summary.coverSize)
        ItemCover(url: summary.coverURL, rule: .whole, nominal: CGSize(width: laneWidth, height: height))
            .frame(width: laneWidth, height: height)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                CoverBadge(
                    text: ItemFormat.languageCode(in: summary.tags) ?? "",
                    color: summary.category?.listColor ?? Color(.systemGray)
                )
                .padding(4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(summary.title))
    }
}

/// A gallery in the `waterfallLarge` style (Flutter `gallery_item_flow_large.dart`): the cover as wide as the lane in
/// its own ratio, no taller than 1:2, with the category and language code at its top leading corner and the page
/// count at its bottom trailing one; below it the stars and favorite heart, the title in three lines and the tags.
struct GalleryWaterfallLargeCell: View {
    let summary: GallerySummary
    let laneWidth: CGFloat

    var body: some View {
        let coverHeight = laneWidth / max(1 / LaneAssignment.heightRatio(summary.coverSize), 0.5)
        VStack(alignment: .leading, spacing: 6) {
            ItemCover(url: summary.coverURL, rule: .fill, nominal: CGSize(width: laneWidth, height: coverHeight))
                .frame(width: laneWidth, height: coverHeight)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    CoverCategoryBadges(summary: summary).padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let count = summary.pageCount {
                        PageBadge(count: count).padding(6)
                    }
                }
            HStack(alignment: .center, spacing: 6) {
                RatingStars(rating: summary.rating, isRatedByUser: summary.isRatedByUser)
                if let slot = summary.favoriteSlot {
                    FavoriteHeart(slot: slot, name: summary.favoriteName)
                }
                Spacer(minLength: 0)
            }
            Text(summary.title)
                .font(.footnote.weight(.medium))
                .lineLimit(3)
            if !summary.tags.isEmpty {
                ItemTags(tags: summary.tags, maxRows: 2)
            }
        }
        .frame(width: laneWidth, alignment: .leading)
    }
}

/// A gallery in the `grid` style (Flutter `gallery_item_grid.dart`): a card at least 1.8 times as tall as the lane is
/// wide; the cover area is 4/3 of the width (`CoverFit.grid`), with the category and language code at its top leading
/// corner and the favorite heart and page count at its bottom trailing one; below it the title in three lines (the
/// space of three is always kept, so the cards of a row are equally tall) and the posted time.
struct GalleryGridCell: View {
    let summary: GallerySummary
    let laneWidth: CGFloat

    var body: some View {
        let coverHeight = laneWidth * 4 / 3
        VStack(alignment: .leading, spacing: 4) {
            ItemCover(url: summary.coverURL, rule: .grid, nominal: CGSize(width: laneWidth, height: coverHeight))
            .frame(width: laneWidth, height: coverHeight)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                CoverCategoryBadges(summary: summary).padding(4)
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 4) {
                    if let slot = summary.favoriteSlot {
                        FavoriteHeart(slot: slot, name: summary.favoriteName)
                            .padding(3)
                            .background(.regularMaterial, in: Circle())
                    }
                    if let count = summary.pageCount {
                        PageBadge(count: count)
                    }
                }
                .padding(4)
            }
            Text(summary.title)
                .font(.caption.weight(.medium))
                .lineLimit(3, reservesSpace: true)
            PostedTime(date: summary.postedAt, isExpunged: summary.isExpunged)
        }
        .frame(width: laneWidth, alignment: .topLeading)
        .frame(minHeight: laneWidth * 1.8, alignment: .top)
    }
}

/// The category and the language code on a cover's top leading corner (the large waterfall, the grid).
struct CoverCategoryBadges: View {
    let summary: GallerySummary

    var body: some View {
        HStack(spacing: 3) {
            if let category = summary.category {
                CategoryCapsule(category: category)
            }
            if let code = ItemFormat.languageCode(in: summary.tags) {
                CoverBadge(text: code, color: nil)
            }
        }
    }
}
