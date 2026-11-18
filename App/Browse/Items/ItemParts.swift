import EHModels
import EHNetwork
import SwiftUI
import UIKit

// The parts the five list styles share (GalleryRows.swift, GalleryCells.swift): how a cover fits its box, the
// language code, stars, colors and posted time, and the views made of them. Tags are `ListTagView`s (B4a).

// MARK: - Rules

/// Whether a cover fills its box (and is cropped) or fits in it (Flutter `gallery_item.dart`, `gallery_item_grid.dart`).
nonisolated enum CoverFit {
    /// The list style's box: fit when the image is more than 0.28 wider or 0.2 narrower (w/h) than the box, else
    /// fill; fit when the size is unknown.
    static func list(image: ImageSize?, box: CGSize) -> ContentMode {
        guard let ratios = ratios(image: image, box: box) else { return .fit }
        let (contain, image) = ratios
        return image - contain > 0.28 || contain - image > 0.2 ? .fit : .fill
    }

    /// The grid's box: fill when the image is wider than the box but less than 2.2 times as wide as tall, else fit;
    /// fit when the size is unknown.
    static func grid(image: ImageSize?, box: CGSize) -> ContentMode {
        guard let ratios = ratios(image: image, box: box) else { return .fit }
        let (contain, image) = ratios
        return contain < image && image < 2.2 ? .fill : .fit
    }

    /// (box w/h, image w/h), or nil when either has no area.
    private static func ratios(image: ImageSize?, box: CGSize) -> (CGFloat, CGFloat)? {
        guard let image, image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return nil }
        return (box.width / box.height, CGFloat(image.width) / CGFloat(image.height))
    }
}

/// One of the five stars of a rating.
nonisolated enum StarFill: Equatable, Sendable {
    case full, half, empty
}

/// The texts and stars of a list item.
nonisolated enum ItemFormat {
    /// The language codes of the `language:` tags (Flutter `const.dart:456-472`).
    static let languageCodes: [String: String] = [
        "japanese": "JP", "english": "EN", "chinese": "ZH", "dutch": "NL", "french": "FR", "german": "DE",
        "hungarian": "HU", "italian": "IT", "korean": "KR", "polish": "PL", "portuguese": "PT", "russian": "RU",
        "spanish": "ES", "thai": "TH", "vietnamese": "VI",
    ]

    /// The code of the first `language:` tag that has one (language tags without a code are skipped); nil without
    /// one.
    static func languageCode(in tags: [ListTag]) -> String? {
        for item in tags where item.tag.namespace == "language" {
            if let code = languageCodes[item.tag.name.lowercased()] { return code }
        }
        return nil
    }

    /// Five stars for a rating of 0…5 in steps of 0.5 (rounded to one): full, then a half, then empty.
    static func stars(for rating: Double) -> [StarFill] {
        let halves = Int((min(max(rating, 0), 5) * 2).rounded())
        return (0..<5).map { star in
            let filled = halves - star * 2
            return filled >= 2 ? .full : filled == 1 ? .half : .empty
        }
    }

    /// The stars' color: the average's, or the account's own rating's (the site's blue; M1 does not tell its shades
    /// apart).
    static func starRGB(isRatedByUser: Bool) -> ListRGB {
        isRatedByUser ? ListRGB(red: 126, green: 120, blue: 255) : ListRGB(red: 255, green: 150, blue: 46)
    }

    /// "yyyy-MM-dd HH:mm" in `timeZone` (Flutter's list time).
    static func postedTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = Date.FormatStyle.Symbol.VerbatimHour.twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)
        let style = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: hour):\(minute: .twoDigits)",
            locale: Locale(identifier: "en_US_POSIX"), timeZone: timeZone, calendar: calendar
        )
        return date.formatted(style)
    }
}

// MARK: - Colors

/// A color by its 8-bit components (the values of Flutter's `const/theme_colors.dart`, kept comparable for tests).
nonisolated struct ListRGB: Equatable, Sendable {
    let red: Int
    let green: Int
    let blue: Int

    init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From 0xRRGGBB.
    init(_ hex: UInt32) {
        self.init(red: Int((hex >> 16) & 0xFF), green: Int((hex >> 8) & 0xFF), blue: Int(hex & 0xFF))
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    var color: Color { Color(uiColor: uiColor) }

    /// `light` in the light appearance, `dark` in the dark one.
    static func dynamic(light: ListRGB, dark: ListRGB) -> Color {
        let light = light.uiColor, dark = dark.uiColor
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension GalleryCategory {
    /// The category's color in the lists, light and dark (Flutter `const/theme_colors.dart:279-341`).
    nonisolated var listRGB: (light: ListRGB, dark: ListRGB) {
        switch self {
        case .doujinshi: (ListRGB(0xF44336), ListRGB(red: 145, green: 49, blue: 39))
        case .manga: (ListRGB(0xFF9800), ListRGB(red: 206, green: 113, blue: 56))
        case .artistCG: (ListRGB(0xFBC02D), ListRGB(red: 202, green: 145, blue: 58))
        case .gameCG: (ListRGB(0x4CAF50), ListRGB(red: 115, green: 145, blue: 112))
        case .western: (ListRGB(0x8BC34A), ListRGB(red: 169, green: 158, blue: 104))
        case .nonH: (ListRGB(0x2196F3), ListRGB(red: 112, green: 168, blue: 203))
        case .imageSet: (ListRGB(0x3F51B5), ListRGB(red: 59, green: 93, blue: 157))
        case .cosplay: (ListRGB(0x9C27B0), ListRGB(red: 98, green: 57, blue: 156))
        case .asianPorn: (ListRGB(0x9575CD), ListRGB(red: 150, green: 60, blue: 127))
        case .misc: (ListRGB(0xF06292), ListRGB(red: 188, green: 91, blue: 123))
        }
    }

    /// The category's color in the lists, following the appearance (browse B5 and B6 use it
    /// too).
    var listColor: Color {
        let rgb = listRGB
        return ListRGB.dynamic(light: rgb.light, dark: rgb.dark)
    }
}

/// The heart colors of the ten favorites folders (Flutter `ThemeColors.favColor`), and of all favorites and the local
/// ones (its `a` and `l`; the favorites tab's title menu, browse B8).
nonisolated enum FavoriteSlotColors {
    static let rgb: [ListRGB] = [
        0x5F5F5F, 0xDE1C31, 0xF97D1C, 0xF8B500, 0x2BAE85, 0x5BAE23, 0x22A2C3, 0x1661AB, 0x9F3EF9, 0xEC2D7A,
    ].map(ListRGB.init)
    /// All favorites (`a`).
    static let all = ListRGB(0xB5A4A4)
    /// The local favorites (`l`).
    static let local = ListRGB(red: 169, green: 158, blue: 104)

    /// The color of folder `slot` (0…9); the first one's for any other.
    static func color(for slot: Int) -> Color {
        rgb(for: slot).color
    }

    /// The components of `color(for:)`.
    static func rgb(for slot: Int) -> ListRGB {
        rgb.indices.contains(slot) ? rgb[slot] : rgb[0]
    }
}

// MARK: - Long-press menu

/// What the long-press menu of a list item does.
enum ItemMenuAction {
    /// Puts the gallery's address on `pasteboard`, as a URL and as text (`PasteboardWriter.writeURL(_:)`; the app's is
    /// `AppEnvironment.pasteboardWriter`, the general pasteboard).
    static func copyLink(_ id: GalleryID, site: EHSite, to pasteboard: any PasteboardWriter) {
        pasteboard.writeURL(EHEndpoints.gallery(id, site: site))
    }
}

/// The long-press menu of a list item (M2 index §6): Copy Link and Share. Copy Link writes the environment's clipboard
/// (`pasteboardWriter`), then tells the clipboard monitor (`ClipboardLinkMonitor.noteOwnWrite()`), so the app's own
/// link is not offered back when it returns.
struct ItemContextMenu: View {
    @Environment(AppEnvironment.self) private var environment
    let id: GalleryID
    let site: EHSite

    var body: some View {
        Button("Copy Link", systemImage: "link") {
            ItemMenuAction.copyLink(id, site: site, to: environment.pasteboardWriter)
            environment.clipboardLinks.noteOwnWrite()
        }
        ShareLink(item: EHEndpoints.gallery(id, site: site)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

// MARK: - Views

/// How a cover picks its content mode.
nonisolated enum CoverFitRule: Equatable, Sendable {
    /// `CoverFit.list` in the cover's box.
    case list
    /// `CoverFit.grid` in the cover's box.
    case grid
    /// The whole image, never cropped (the waterfall: the box has the image's ratio already).
    case whole
    /// Filling the box (the large waterfall, whose box is the image's ratio, no taller than 1:2).
    case fill

    /// The mode for `image` in `box`, the size the cover was laid out at (zero before it was: fit).
    func mode(for image: ImageSize?, in box: CGSize) -> ContentMode {
        switch self {
        case .list: CoverFit.list(image: image, box: box)
        case .grid: CoverFit.grid(image: image, box: box)
        case .whole: .fit
        case .fill: .fill
        }
    }
}

/// A list item's cover from the thumbnail pipeline (`RemoteImage`), filling or fitting the frame it is given by
/// `rule`; a placeholder until it loads or when it fails. The frame's size comes from the item, and the rule reads
/// it as laid out (a list row grows with the text size and the tag rows: L071c), not as the item's smallest size.
/// Until it has been measured, the rule reads `nominal`, the frame the item means to give it, so that an image the
/// memory cache shows at once is not fitted for a frame and then filled (M2 re-review F3 M-4).
struct ItemCover: View {
    let url: URL?
    let rule: CoverFitRule
    /// The frame the item gives the cover at its smallest (`box(measured:nominal:)`).
    let nominal: CGSize

    /// The size the cover was laid out at; zero until it was measured.
    @State private var box: CGSize = .zero

    /// The box the rule reads: the one measured, else (zero, before the first measure) `nominal`.
    static func box(measured: CGSize, nominal: CGSize) -> CGSize {
        measured.width > 0 && measured.height > 0 ? measured : nominal
    }

    var body: some View {
        RemoteImage(url: url) { phase in
            switch phase {
            case .success(let image, let size):
                image
                    .resizable()
                    .aspectRatio(
                        contentMode: rule.mode(
                            for: ImageSize(width: Int(size.width), height: Int(size.height)),
                            in: Self.box(measured: box, nominal: nominal)
                        )
                    )
            case .empty, .failure:
                ZStack {
                    Rectangle().fill(Color(.secondarySystemFill))
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            box = size
        }
        .background(Color(.secondarySystemFill))
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Five stars: full, half (`star.leadinghalf.filled`) and empty (secondary), in the average's color or the
/// account's rating's.
struct RatingStars: View {
    let rating: Double
    let isRatedByUser: Bool

    var body: some View {
        let color = ItemFormat.starRGB(isRatedByUser: isRatedByUser).color
        HStack(spacing: 1) {
            ForEach(Array(ItemFormat.stars(for: rating).enumerated()), id: \.offset) { _, fill in
                switch fill {
                case .full: Image(systemName: "star.fill").foregroundStyle(color)
                case .half: Image(systemName: "star.leadinghalf.filled").foregroundStyle(color)
                case .empty: Image(systemName: "star").foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating \(rating.formatted(.number.precision(.fractionLength(0...1))))")
    }
}

/// The category's name on its color.
struct CategoryCapsule: View {
    let category: GalleryCategory

    var body: some View {
        Text(category.siteLabel)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(category.listColor, in: Capsule())
    }
}

/// A small capsule on a cover: the language code on the category's color (the waterfall), or on a material.
struct CoverBadge: View {
    let text: String
    let color: Color?

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(color == nil ? Color.primary : Color.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 16)
            .background {
                if let color {
                    Capsule().fill(color)
                } else {
                    Capsule().fill(.regularMaterial)
                }
            }
    }
}

/// The heart of the favorites folder the gallery is in.
struct FavoriteHeart: View {
    let slot: Int
    let name: String?

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.caption2)
            .foregroundStyle(FavoriteSlotColors.color(for: slot))
            .accessibilityLabel(name ?? "Favorited")
    }
}

/// The page count with the `photo` symbol.
struct PageCount: View {
    let count: Int

    var body: some View {
        Label("\(count)", systemImage: "photo")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// The page count as a badge on a cover.
struct PageBadge: View {
    let count: Int

    var body: some View {
        Label("\(count)", systemImage: "photo")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
    }
}

/// When the gallery was posted ("yyyy-MM-dd HH:mm"), struck through when it is expunged.
struct PostedTime: View {
    let date: Date?
    let isExpunged: Bool

    var body: some View {
        if let date {
            Text(ItemFormat.postedTime(date))
                .font(.caption)
                .monospacedDigit()
                .strikethrough(isExpunged)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// The uploader, or the favorite note when the list has no uploaders ("Note: …"); faded as the page shows it.
struct UploaderLine: View {
    let summary: GallerySummary

    var body: some View {
        if let uploader = summary.uploader {
            Text(uploader)
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(summary.isUploaderDimmed ? 0.5 : 1)
                .lineLimit(1)
        } else if let note = summary.favoriteNote, !note.isEmpty {
            Text("Note: \(note)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// An item's tags (`ListTagView`), wrapped onto rows; rows past `maxRows` are left out.
struct ItemTags: View {
    let tags: [ListTag]
    let maxRows: Int?

    var body: some View {
        TagFlowLayout(spacing: 4, maxRows: maxRows) {
            ForEach(tags, id: \.self) { tag in
                ListTagView(tag: tag)
            }
        }
        .clipped()
    }
}

/// Lays its subviews out leading to trailing, wrapping onto new rows; only the first `maxRows` rows count toward its
/// size, and the subviews of later rows are placed below it (the caller clips them).
struct TagFlowLayout: Layout {
    var spacing: CGFloat
    var maxRows: Int?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let shown = rows.prefix(maxRows ?? rows.count)
        let height = shown.map(\.height).reduce(0, +) + spacing * CGFloat(max(shown.count - 1, 0))
        let width = proposal.width ?? shown.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (number, row) in rows.enumerated() {
            let hidden = maxRows.map { number >= $0 } ?? false
            var x = bounds.minX
            for item in row.items {
                let point = hidden ? CGPoint(x: bounds.minX, y: bounds.maxY + 1_000) : CGPoint(x: x, y: y)
                subviews[item.index].place(at: point, anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// A column at least `minHeight` tall: the first subview at its top, the second at its bottom (the rating and the
/// category of a list row stay at the bottom of a row whose title is short).
struct PinnedColumn: Layout {
    var minHeight: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        let content = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: width ?? sizes.map(\.width).max() ?? 0, height: max(minHeight, content))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let top = subviews.first else { return }
        let width = ProposedViewSize(width: bounds.width, height: nil)
        top.place(at: bounds.origin, anchor: .topLeading, proposal: width)
        if subviews.count > 1, let bottom = subviews.last {
            bottom.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading, proposal: width)
        }
    }
}
