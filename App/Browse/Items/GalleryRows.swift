import EHModels
import SwiftUI

/// A gallery in the `list` style (Flutter `gallery_item.dart`): a card at least 204 tall, the cover on its leading
/// side (min(lane width / 3, 143) wide and as tall as the card, filled or fitted by `CoverFit.list` in that box),
/// then the title (5 − tag rows lines), the uploader, the tags, and at the bottom the rating row (stars, favorite
/// heart, language code, page count) and the category with the posted time.
struct GalleryListRow: View {
    static let minHeight: CGFloat = 204

    let summary: GallerySummary
    let laneWidth: CGFloat

    var body: some View {
        let coverWidth = min(laneWidth / 3, 143)
        // Flutter: the tags take max(1, round(count / 4)) rows, the title what is left of five.
        let tagRows = max(1, Int((Double(summary.tags.count) / 4).rounded()))
        PinnedColumn(minHeight: Self.minHeight - 16, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(max(5 - tagRows, 1))
                UploaderLine(summary: summary)
                if !summary.tags.isEmpty {
                    ItemTags(tags: summary.tags, maxRows: tagRows)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                ItemRatingRow(summary: summary)
                ItemCategoryRow(summary: summary)
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, coverWidth + 10)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            ItemCover(url: summary.coverURL, rule: .list, nominal: CGSize(width: coverWidth, height: Self.minHeight))
            .frame(width: coverWidth)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 12))
    }
}

/// A gallery in the `simpleList` style (Flutter `gallery_item_simple.dart`): a row at least 134 tall (144 with tags)
/// with a 90-wide cover, the title in two lines, the uploader, one row of tags, the rating row and the category with
/// the posted time; a separator below.
struct GallerySimpleRow: View {
    static let coverWidth: CGFloat = 90

    let summary: GallerySummary

    var body: some View {
        let minHeight: CGFloat = summary.tags.isEmpty ? 134 : 144
        PinnedColumn(minHeight: minHeight - 16, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                UploaderLine(summary: summary)
                if !summary.tags.isEmpty {
                    ItemTags(tags: summary.tags, maxRows: 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                ItemRatingRow(summary: summary)
                ItemCategoryRow(summary: summary)
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, Self.coverWidth + 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            ItemCover(
                url: summary.coverURL, rule: .list, nominal: CGSize(width: Self.coverWidth, height: minHeight - 16)
            )
            .frame(width: Self.coverWidth)
            .clipShape(.rect(cornerRadius: 6))
            .padding(.vertical, 8)
        }
        .overlay(alignment: .bottom) {
            // In a stack, so that it runs across the row (alone in an overlay it would stand upright).
            VStack(spacing: 0) {
                Divider()
            }
        }
    }
}

/// The rating row of the list styles, on one center line: stars, the favorite heart, then trailing the language code
/// and the page count.
struct ItemRatingRow: View {
    let summary: GallerySummary

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            RatingStars(rating: summary.rating, isRatedByUser: summary.isRatedByUser)
            if let slot = summary.favoriteSlot {
                FavoriteHeart(slot: slot, name: summary.favoriteName)
            }
            Spacer(minLength: 4)
            if let code = ItemFormat.languageCode(in: summary.tags) {
                Text(code)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let count = summary.pageCount {
                PageCount(count: count)
            }
        }
    }
}

/// The bottom row of the list styles, on one baseline: the category, then trailing the posted time.
struct ItemCategoryRow: View {
    let summary: GallerySummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let category = summary.category {
                CategoryCapsule(category: category)
            }
            Spacer(minLength: 4)
            PostedTime(date: summary.postedAt, isExpunged: summary.isExpunged)
        }
    }
}
