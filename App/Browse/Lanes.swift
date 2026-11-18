import CoreGraphics
import EHModels
import SwiftUI

/// How a list style lays its items out in lanes (Flutter `const.dart:287-301`, `pages/item/gallery_item*.dart`).
nonisolated struct LaneMetrics: Equatable, Sendable {
    /// The widest a lane may be; nil: one lane however wide (the list styles).
    let maxLaneWidth: CGFloat?
    /// Between two lanes.
    let laneSpacing: CGFloat
    /// Between two items of a lane.
    let itemSpacing: CGFloat
    /// Between the content's edges and the lanes (the scroll content's horizontal margins).
    let margin: CGFloat

    static func of(_ style: ListStyle, regularWidth: Bool) -> LaneMetrics {
        switch style {
        case .list: LaneMetrics(maxLaneWidth: nil, laneSpacing: 10, itemSpacing: 12, margin: 10)
        case .simpleList: LaneMetrics(maxLaneWidth: nil, laneSpacing: 12, itemSpacing: 0, margin: 12)
        case .waterfall:
            LaneMetrics(maxLaneWidth: regularWidth ? 220 : 150, laneSpacing: 4, itemSpacing: 4, margin: 4)
        case .waterfallLarge: LaneMetrics(maxLaneWidth: 220, laneSpacing: 8, itemSpacing: 12, margin: 8)
        case .grid: LaneMetrics(maxLaneWidth: 150, laneSpacing: 6, itemSpacing: 6, margin: 6)
        }
    }
}

/// Where the lanes of a list are, in the content's coordinate space (x from its leading edge).
///
/// A width holds max(1, ceil(width / (max lane width + spacing))) lanes of equal width (Flutter's
/// `SliverGridDelegateWithMaxCrossAxisExtent`); the list styles hold one. With an active division (the iPhone Duo's
/// fold, half open) each side counts for itself and no lane crosses it.
nonisolated struct LanePlan: Equatable, Sendable {
    /// x ranges in the content's coordinate space, leading to trailing.
    let lanes: [ClosedRange<CGFloat>]

    /// The width of a lane (all lanes of a side are as wide; the narrower side's when the division splits them
    /// unevenly); 0 without lanes.
    var laneWidth: CGFloat {
        lanes.map { $0.upperBound - $0.lowerBound }.min() ?? 0
    }

    static func make(width: CGFloat, style: ListStyle, regularWidth: Bool, division: ClosedRange<CGFloat>?) -> LanePlan {
        let metrics = LaneMetrics.of(style, regularWidth: regularWidth)
        let whole = 0...max(width, 0)
        guard let division, division.lowerBound < whole.upperBound, division.upperBound > whole.lowerBound else {
            return LanePlan(lanes: lanes(in: whole, metrics: metrics))
        }
        let leading = whole.lowerBound...max(whole.lowerBound, division.lowerBound)
        let trailing = min(whole.upperBound, division.upperBound)...whole.upperBound
        let lanes = lanes(in: leading, metrics: metrics) + lanes(in: trailing, metrics: metrics)
        // A division across the whole width leaves no side: one lane rather than none.
        return LanePlan(lanes: lanes.isEmpty ? [whole] : lanes)
    }

    /// The fold the lanes split at, in the coordinate space `regions` were read in: the x range of the first of them
    /// that is active and upright (taller than wide: a fold between halves side by side). nil without one: a lying
    /// division (the Duo half open and held upright, one half above the other) crosses every lane rather than falling
    /// between two, so it splits none. Only the x range: how high the region is or where it stands up or down does
    /// not matter to the lanes.
    static func fold(in regions: [DivisionRegion]) -> ClosedRange<CGFloat>? {
        guard let region = regions.first(where: { $0.isActive && $0.frame.height > $0.frame.width }) else {
            return nil
        }
        return region.frame.minX...region.frame.maxX
    }

    /// `fold` (from `fold(in:)`) in the content's coordinate space: less `contentOrigin`, the x of the content's
    /// leading edge in the space the fold was read in. Only moved, not cut to the content: a fold over a margin or
    /// across an edge is left to `make`.
    ///
    /// Both x are taken from the left edge (the regions are read with a fixed layout direction), which is the leading
    /// edge in left-to-right layouts only (right-to-left is not in M2).
    static func division(from fold: ClosedRange<CGFloat>, contentOrigin: CGFloat) -> ClosedRange<CGFloat> {
        (fold.lowerBound - contentOrigin)...(fold.upperBound - contentOrigin)
    }

    /// The lanes of one side; none when the side has no width.
    private static func lanes(in side: ClosedRange<CGFloat>, metrics: LaneMetrics) -> [ClosedRange<CGFloat>] {
        let available = side.upperBound - side.lowerBound
        guard available > 0 else { return [] }
        let count: Int
        if let maxWidth = metrics.maxLaneWidth {
            count = max(1, Int((available / (maxWidth + metrics.laneSpacing)).rounded(.up)))
        } else {
            count = 1
        }
        let spacing = count > 1 ? metrics.laneSpacing : 0
        let width = (available - spacing * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).map { index in
            let start = side.lowerBound + CGFloat(index) * (width + spacing)
            return start...min(start + width, side.upperBound)
        }
    }
}

/// A division over a view (SwiftUI's `ReservedRegion` of kind `.division`, iOS 27.1: the iPhone Duo's fold) as the
/// lanes take it. A type of its own: SwiftUI's has no public initializer, so what is made of it could not be tested.
nonisolated struct DivisionRegion: Equatable, Sendable {
    /// In the coordinate space of the view the region was read from. It takes in the margins the system keeps around
    /// the fold for interactive content (`ReservedRegion.margins`), so the lanes, and the items tapped in them, keep
    /// clear of those as well as of the fold itself.
    let frame: CGRect
    /// Whether it divides the screen now (the Duo half open).
    let isActive: Bool

    /// The divisions over the view of `proxy`, in its coordinate space (only the active ones: the query's default);
    /// none before iOS 27.1. Their x is taken from the left edge whatever the layout direction (`.fixed`; the default
    /// mirrors it right to left).
    static func all(of proxy: GeometryProxy) -> [DivisionRegion] {
        guard #available(iOS 27.1, *) else { return [] }
        return proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed)
            .map { DivisionRegion(frame: $0.frame, isActive: $0.isActive) }
    }
}

/// The space a block of content (a status page, a footnote, a row of controls) gives up on each side to keep clear of
/// the fold.
nonisolated struct FoldInsets: Equatable, Sendable {
    static let zero = FoldInsets(leading: 0, trailing: 0)

    let leading: CGFloat
    let trailing: CGFloat
}

/// Which side of the fold one block of content goes to (design §5.4: controls never sit in the fold; the system keeps
/// its own containers clear of it, a view of the app has to keep clear itself). The block goes to the wider side, the
/// leading one when both are as wide: half open and held sideways with the rail on the right (simulator, 2026-11-15)
/// that is the left side, where the system puts a sheet too (docs/spikes/duo-rail.md), so the eye does not cross the
/// fold between a sheet and a status page. Only the text and the controls move; backgrounds still run across.
nonisolated enum FoldSide {
    /// The insets that keep a block `width` wide (x from its leading edge) on the wider side of `division` (in the
    /// block's coordinates, as `LanePlan.division(from:contentOrigin:)` gives it): all of the narrower side and the
    /// division itself. Zero without a division, for one wholly outside the block, and for one across all of it
    /// (there is no side to go to).
    static func insets(division: ClosedRange<CGFloat>?, width: CGFloat) -> FoldInsets {
        guard let division, width > 0, division.lowerBound < width, division.upperBound > 0 else { return .zero }
        let leadingSide = min(max(0, division.lowerBound), width)
        let trailingSide = min(max(0, width - division.upperBound), width)
        guard max(leadingSide, trailingSide) > 0 else { return .zero }
        return leadingSide >= trailingSide
            ? FoldInsets(leading: 0, trailing: width - leadingSide)
            : FoldInsets(leading: width - trailingSide, trailing: 0)
    }
}

/// Which lane each item of a list is in: every item goes to the lane that is shortest so far (by the estimated
/// heights), the first of equals. Items of equal height (the grid, the list styles) go to the lanes in turn, so the
/// rows line up.
nonisolated struct LaneAssignment: Equatable, Sendable {
    private(set) var lanes: [[GalleryID]]
    /// The estimated height of each lane so far.
    private var heights: [CGFloat]
    /// Every item placed, in the order it came.
    private var placed: [GalleryID] = []

    init(laneCount: Int) {
        let count = max(laneCount, 1)
        lanes = Array(repeating: [], count: count)
        heights = Array(repeating: 0, count: count)
    }

    /// Places `items` after those placed, each in the shortest lane by accumulated height.
    mutating func append(_ items: [(id: GalleryID, height: CGFloat)]) {
        for item in items {
            var shortest = 0
            for lane in heights.indices where heights[lane] < heights[shortest] {
                shortest = lane
            }
            lanes[shortest].append(item.id)
            heights[shortest] += item.height
            placed.append(item.id)
        }
    }

    /// Brings the assignment to `items` in `laneCount` lanes: when the lane count is the same and the items placed
    /// begin `items`, only the rest are placed (the others stay where they are), each lane's height first reckoned
    /// again from the heights `items` gives now (the lanes may have changed width, and a height reckoned at the old
    /// width would not compare with one at the new); otherwise everything is placed again from the start (the lane
    /// count changed, or the list was replaced or something came in front).
    mutating func sync(_ items: [(id: GalleryID, height: CGFloat)], laneCount: Int) {
        let count = max(laneCount, 1)
        let extends = items.count >= placed.count && zip(placed, items).allSatisfy { $0 == $1.id }
        if count == lanes.count, extends {
            guard items.count > placed.count else { return }
            let height = Dictionary(items.map { ($0.id, $0.height) }, uniquingKeysWith: { first, _ in first })
            heights = lanes.map { lane in lane.reduce(0) { $0 + (height[$1] ?? 0) } }
            append(Array(items[placed.count...]))
            return
        }
        self = LaneAssignment(laneCount: count)
        append(items)
    }

    /// The height an item is reckoned at in a lane `laneWidth` wide: the waterfall's cover (lane width × h/w, 1.4 for
    /// an unknown size); the large waterfall's cover (no taller than 1:2) and 96 for what is below it; 1 for the grid
    /// and the list styles, whose items are all equally tall.
    static func estimatedHeight(cover: ImageSize?, style: ListStyle, laneWidth: CGFloat) -> CGFloat {
        switch style {
        case .waterfall:
            return laneWidth * heightRatio(cover)
        case .waterfallLarge:
            return laneWidth / max(1 / heightRatio(cover), 0.5) + 96
        case .grid, .list, .simpleList:
            return 1
        }
    }

    /// h / w of `cover`; 1.4 when unknown or empty.
    static func heightRatio(_ cover: ImageSize?) -> CGFloat {
        guard let cover, cover.width > 0, cover.height > 0 else { return 1.4 }
        return CGFloat(cover.height) / CGFloat(cover.width)
    }
}
