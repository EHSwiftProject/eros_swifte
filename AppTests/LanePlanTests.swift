import CoreGraphics
import EHModels
import Testing

@testable import Eros

/// `LanePlan` and `LaneAssignment`: how many lanes a width holds, where they are, and which lane each item goes to.
@MainActor @Suite struct LanePlanTests {
    private static func id(_ gid: Int) -> GalleryID {
        GalleryID(gid: gid, token: String(format: "%010x", gid))
    }

    @Test func laneCountFollowsWidth() {
        #expect(LanePlan.make(width: 382, style: .waterfall, regularWidth: false, division: nil).lanes.count == 3)
        let wide = LanePlan.make(width: 951, style: .waterfall, regularWidth: true, division: nil)
        #expect(wide.lanes.count == 5)
        // Five lanes no wider than 220 fill the width, 4 apart.
        #expect(wide.lanes.allSatisfy { $0.upperBound - $0.lowerBound <= 220 })
        #expect(abs((wide.lanes.last?.upperBound ?? 0) - 951) < 0.001)
        #expect(LanePlan.make(width: 382, style: .grid, regularWidth: false, division: nil).lanes.count == 3)
        #expect(LanePlan.make(width: 951, style: .list, regularWidth: true, division: nil).lanes.count == 1)
        #expect(LanePlan.make(width: 951, style: .simpleList, regularWidth: true, division: nil).lanes.count == 1)
        #expect(LanePlan.make(width: 382, style: .waterfallLarge, regularWidth: false, division: nil).lanes.count == 2)
    }

    @Test func divisionSplitsLanes() {
        let division: ClosedRange<CGFloat> = 466...485
        for style in ListStyle.allCases {
            let plan = LanePlan.make(width: 951, style: style, regularWidth: true, division: division)
            let left = plan.lanes.filter { $0.upperBound <= division.lowerBound }
            let right = plan.lanes.filter { $0.lowerBound >= division.upperBound }
            #expect(left.count + right.count == plan.lanes.count, "\(style): a lane crosses the division")
            #expect(left.count >= 1, "\(style): no lane left of the division")
            #expect(right.count >= 1, "\(style): no lane right of the division")
            if style == .list || style == .simpleList {
                #expect(left.count == 1 && right.count == 1, "\(style)")
            }
        }
    }

    // MARK: - The fold from the reserved regions

    /// The Duo half open, its inner screen held sideways (simulator, 2026-11-15): the fold stands at x 455.5–495.5 of
    /// the scroll view.
    @Test func uprightDivisionIsTheFold() {
        let fold = DivisionRegion(frame: CGRect(x: 455.5, y: -82, width: 40, height: 669), isActive: true)
        #expect(LanePlan.fold(in: [fold]) == 455.5...495.5)

        // The scroll view moved down (the pause banner): the region's y changes, the fold does not.
        let lower = DivisionRegion(frame: CGRect(x: 455.5, y: -120, width: 40, height: 669), isActive: true)
        #expect(LanePlan.fold(in: [lower]) == 455.5...495.5)
    }

    /// Half open, held upright: the fold lies across the screen (0, 373.5, 669, 40), across the lanes rather than
    /// between two; it splits none.
    @Test func lyingDivisionIsIgnored() {
        let fold = DivisionRegion(frame: CGRect(x: 0, y: 373.5, width: 669, height: 40), isActive: true)
        #expect(LanePlan.fold(in: [fold]) == nil)
    }

    @Test func inactiveDivisionIsIgnored() {
        let fold = DivisionRegion(frame: CGRect(x: 455.5, y: -82, width: 40, height: 669), isActive: false)
        #expect(LanePlan.fold(in: [fold]) == nil)
    }

    @Test func firstUprightActiveDivisionCounts() {
        let regions = [
            DivisionRegion(frame: CGRect(x: 0, y: 373.5, width: 669, height: 40), isActive: true),
            DivisionRegion(frame: CGRect(x: 100, y: 0, width: 20, height: 500), isActive: false),
            DivisionRegion(frame: CGRect(x: 455.5, y: -82, width: 40, height: 669), isActive: true),
            DivisionRegion(frame: CGRect(x: 600, y: 0, width: 30, height: 669), isActive: true),
        ]
        #expect(LanePlan.fold(in: regions) == 455.5...495.5)
    }

    @Test func noRegionsNoFold() {
        #expect(LanePlan.fold(in: []) == nil)
    }

    // MARK: - The fold in the content

    /// The fold at x 455.5–495.5 of the scroll view and the content beginning 10 in (simulator, 2026-11-15): the fold
    /// is at 445.5–485.5 of the content's 847.
    @Test func foldMovesToTheContent() {
        let division = LanePlan.division(from: 455.5...495.5, contentOrigin: 10)
        #expect(division == 445.5...485.5)
        #expect(LanePlan.division(from: 455.5...495.5, contentOrigin: 0) == 455.5...495.5)
        // Only moved, not cut: a fold reaching past the content's leading edge comes as it is (`make` cuts it).
        #expect(LanePlan.division(from: 0...30, contentOrigin: 10) == -10...20)

        // The list's one lane becomes one on each side, neither in the fold.
        let plan = LanePlan.make(width: 847, style: .list, regularWidth: true, division: division)
        #expect(plan.lanes == [0...445.5, 485.5...847])
    }

    /// A division the content's edges cut: wholly outside splits nothing; across an edge, only the other side has
    /// lanes; across the whole width, one lane rather than none.
    @Test func divisionAtTheContentsEdges() {
        func lanes(_ division: ClosedRange<CGFloat>) -> [ClosedRange<CGFloat>] {
            LanePlan.make(width: 847, style: .list, regularWidth: true, division: division).lanes
        }
        #expect(lanes(-10 ... -2) == [0...847])
        #expect(lanes(-5...30) == [30...847])
        #expect(lanes(830...870) == [0...830])
        #expect(lanes(-5...900) == [0...847])
    }

    // MARK: - Lane assignment

    @Test func appendingFillsTheShortestLane() {
        var assignment = LaneAssignment(laneCount: 2)
        assignment.append([(Self.id(1), 100), (Self.id(2), 50), (Self.id(3), 30), (Self.id(4), 10)])
        #expect(assignment.lanes == [[Self.id(1)], [Self.id(2), Self.id(3), Self.id(4)]])
        // 100 against 90: the second lane; then a tie goes to the first.
        assignment.append([(Self.id(5), 10)])
        assignment.append([(Self.id(6), 10)])
        #expect(assignment.lanes == [[Self.id(1), Self.id(6)], [Self.id(2), Self.id(3), Self.id(4), Self.id(5)]])

        // Syncing to a longer list with the same lane count places only the new items; the others stay.
        let items: [(id: GalleryID, height: CGFloat)] = [
            (Self.id(1), 100), (Self.id(2), 50), (Self.id(3), 30), (Self.id(4), 10), (Self.id(5), 10), (Self.id(6), 10),
            (Self.id(7), 5),
        ]
        assignment.sync(items, laneCount: 2)
        #expect(assignment.lanes == [[Self.id(1), Self.id(6)], [Self.id(2), Self.id(3), Self.id(4), Self.id(5), Self.id(7)]])
    }

    /// The lanes kept their number but not their width (L071b): the items placed are reckoned again at the new width
    /// before more are placed. The large waterfall's 96 below the cover does not grow with the width, so the tall
    /// cover's lane is the longer one at 100 wide (296 against 146 + 146) and the shorter one at 50 (196 against
    /// 121 + 121): the next item goes there.
    @Test func syncReckonsThePlacedItemsAtTheNewWidth() {
        let tall = ImageSize(width: 100, height: 200)
        let wide = ImageSize(width: 200, height: 100)
        func items(_ covers: [ImageSize], laneWidth: CGFloat) -> [(id: GalleryID, height: CGFloat)] {
            covers.enumerated().map { index, cover in
                (Self.id(900_001 + index), LaneAssignment.estimatedHeight(cover: cover, style: .waterfallLarge, laneWidth: laneWidth))
            }
        }
        var assignment = LaneAssignment(laneCount: 2)
        assignment.sync(items([tall, wide, wide], laneWidth: 100), laneCount: 2)
        #expect(assignment.lanes == [[Self.id(900_001)], [Self.id(900_002), Self.id(900_003)]])

        assignment.sync(items([tall, wide, wide, wide], laneWidth: 50), laneCount: 2)
        #expect(assignment.lanes == [[Self.id(900_001), Self.id(900_004)], [Self.id(900_002), Self.id(900_003)]])
    }

    @Test func reflowKeepsEveryItemOnce() {
        let covers = (0..<50).map { index in
            (id: Self.id(900_000 + index), cover: ImageSize(width: 100, height: 100 + (index % 7) * 20))
        }
        let narrow = LanePlan.make(width: 382, style: .waterfall, regularWidth: false, division: nil)
        var assignment = LaneAssignment(laneCount: narrow.lanes.count)
        assignment.sync(
            covers.map { ($0.id, LaneAssignment.estimatedHeight(cover: $0.cover, style: .waterfall, laneWidth: narrow.laneWidth)) },
            laneCount: narrow.lanes.count
        )
        #expect(assignment.lanes.count == 3)

        let wide = LanePlan.make(width: 951, style: .waterfall, regularWidth: true, division: nil)
        assignment.sync(
            covers.map { ($0.id, LaneAssignment.estimatedHeight(cover: $0.cover, style: .waterfall, laneWidth: wide.laneWidth)) },
            laneCount: wide.lanes.count
        )
        #expect(assignment.lanes.count == 5)
        let placed = assignment.lanes.flatMap { $0 }
        #expect(placed.count == 50)
        #expect(Set(placed) == Set(covers.map(\.id)))
        #expect(assignment.lanes.allSatisfy { !$0.isEmpty })
    }

    @Test func heightsFollowTheStyle() {
        let cover = ImageSize(width: 200, height: 300)
        #expect(LaneAssignment.estimatedHeight(cover: cover, style: .waterfall, laneWidth: 100) == 150)
        #expect(LaneAssignment.estimatedHeight(cover: nil, style: .waterfall, laneWidth: 100) == 140)
        // The large waterfall: the cover, then 96 for what is below it; taller than 1:2 counts as 1:2.
        #expect(LaneAssignment.estimatedHeight(cover: ImageSize(width: 200, height: 100), style: .waterfallLarge, laneWidth: 100) == 146)
        #expect(LaneAssignment.estimatedHeight(cover: ImageSize(width: 100, height: 400), style: .waterfallLarge, laneWidth: 100) == 296)
        // Grid and list items are all the same height: they go to the lanes in turn.
        #expect(LaneAssignment.estimatedHeight(cover: cover, style: .grid, laneWidth: 100)
            == LaneAssignment.estimatedHeight(cover: nil, style: .grid, laneWidth: 100))
    }
}

/// `FoldSide`: which side of the fold one block of content goes to (D2), as insets from its edges.
@MainActor @Suite struct FoldSideTests {
    /// No fold, or one wholly outside the block: nothing moves.
    @Test func noFoldMovesNothing() {
        #expect(FoldSide.insets(division: nil, width: 881) == .zero)
        #expect(FoldSide.insets(division: -60 ... -20, width: 881) == .zero)
        #expect(FoldSide.insets(division: 900...940, width: 881) == .zero)
        // Touching an edge from outside is still outside.
        #expect(FoldSide.insets(division: 881...921, width: 881) == .zero)
        #expect(FoldSide.insets(division: 455.5...495.5, width: 0) == .zero)
    }

    /// Half open and held sideways, the rail on the right (simulator, 2026-11-15): the page is 881 wide and the fold
    /// stands at 455.5–495.5. The left side (455.5) is wider than the right (385.5): the block keeps to the left, as
    /// the system's sheet does.
    @Test func measuredPostureKeepsToTheLeft() {
        let insets = FoldSide.insets(division: 455.5...495.5, width: 881)
        #expect(insets == FoldInsets(leading: 0, trailing: 425.5))
        // A block that starts 16 in (a footnote's margin) sees the fold 16 nearer.
        let division = LanePlan.division(from: 455.5...495.5, contentOrigin: 16)
        #expect(FoldSide.insets(division: division, width: 849) == FoldInsets(leading: 0, trailing: 409.5))
    }

    /// The rail on the left (not measured): the right side is the wider one, so the block keeps to the right.
    @Test func widerTrailingSideTakesTheBlock() {
        #expect(FoldSide.insets(division: 395.5...435.5, width: 881) == FoldInsets(leading: 435.5, trailing: 0))
    }

    /// Both sides as wide: the leading one.
    @Test func equalSidesTakeTheLeadingOne() {
        #expect(FoldSide.insets(division: 45...55, width: 100) == FoldInsets(leading: 0, trailing: 55))
    }

    /// A fold across one of the block's edges leaves the other side, never more than the block; one across the whole
    /// block leaves no side, and nothing moves.
    @Test func foldAcrossAnEdgeStaysInside() {
        #expect(FoldSide.insets(division: -5...30, width: 847) == FoldInsets(leading: 30, trailing: 0))
        #expect(FoldSide.insets(division: 830...870, width: 847) == FoldInsets(leading: 0, trailing: 17))
        #expect(FoldSide.insets(division: -5...900, width: 847) == .zero)
        for division in [-5...30, 830...870, 455.5...495.5, 0...40] as [ClosedRange<CGFloat>] {
            let insets = FoldSide.insets(division: division, width: 847)
            #expect(insets.leading >= 0 && insets.trailing >= 0, "\(division)")
            #expect(insets.leading + insets.trailing <= 847, "\(division)")
        }
    }
}
