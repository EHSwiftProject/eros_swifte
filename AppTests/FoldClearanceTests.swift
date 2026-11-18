import EHStore
import SwiftUI
import Testing
import UIKit

@testable import Eros

/// `keepsClearOfFold(alignment:)` on the pages the D2 list missed (M2 re-review F3 M-5): the Quick Search page's two
/// status pages and the image search page's footnote, in a window as wide as the Duo's inner screen held sideways
/// (881). Without a fold they stand where they did before the modifier (centered in the content region; the footnote
/// from its leading edge, across the middle); with the measured fold (455.5–495.5 from the content region's leading
/// edge, given as the tab's `windowFold`) they move to its wider, leading side.
///
/// Positions are taken against the window's content region (`HostedViews.contentRegion(of:)`), measured on the
/// showing without a fold, not against the window: on the Duo's outer screen the window has a rail on one side
/// (M2 review F6). The fold is put from the region's leading edge, so the leading side stays the wider one (455.5
/// against at most 385.5) whichever side the rail is on.
///
/// Each test has a minute (`.timeLimit`): the views lay out on real windows, and one that never shows its text must
/// fail at the limit, not hang the run.
@MainActor @Suite(.timeLimit(.minutes(1))) struct FoldClearanceTests {
    private static let size = CGSize(width: 881, height: 700)
    /// The measured fold, from the leading edge of the content region.
    private static let fold: ClosedRange<CGFloat> = 455.5...495.5

    @Test(arguments: [true, false])
    func quickSearchStatusPagesKeepClearOfTheFold(available: Bool) async throws {
        let environment = AppEnvironment(uiTesting: true)
        let title = available ? "No Quick Searches" : "Quick Searches Unavailable"
        func page() throws -> some View {
            let model = QuickSearchListModel(
                userData: available ? try UserDataStore(inMemory: true) : nil, terms: environment.searchTerms,
                settings: environment.settings
            )
            return NavigationStack {
                QuickSearchListView(model: model) { _ in }
            }
        }

        let plain = try HostedViews.show(page(), environment: environment, size: Self.size)
        defer { HostedViews.hide(plain) }
        #expect(await eventually { Self.frame(labelled: title, in: plain) != nil }, "\(title)")
        let region = HostedViews.contentRegion(of: plain)
        try #require(region.width > 0)
        let middle = try #require(Self.frame(labelled: title, in: plain)).midX
        #expect(abs(middle - region.midX) < 2, "\(title) stands at \(middle) without a fold, in \(region)")
        HostedViews.hide(plain)

        // Left of the fold, in the middle of the content region's part on that side.
        let fold = Self.windowFold(in: region)
        let folded = try HostedViews.show(
            page().environment(\.windowFold, fold), environment: environment, size: Self.size
        )
        defer { HostedViews.hide(folded) }
        #expect(await eventually {
            guard let frame = Self.frame(labelled: title, in: folded) else { return false }
            return frame.maxX <= fold.lowerBound && abs(frame.midX - (region.minX + fold.lowerBound) / 2) < 2
        }, "\(title) at \(String(describing: Self.frame(labelled: title, in: folded))), the fold at \(fold)")
    }

    @Test func theConvertedNoteKeepsClearOfTheFold() async throws {
        let environment = AppEnvironment(uiTesting: true)
        let note = "Converted to JPEG for upload, so only similar images can match, not this exact file."
        let plain = try HostedViews.show(ImageSearchConvertedNote(), environment: environment, size: Self.size)
        defer { HostedViews.hide(plain) }
        #expect(await eventually { Self.frame(labelled: note, in: plain) != nil })
        let region = HostedViews.contentRegion(of: plain)
        try #require(region.width > 0)
        let fold = Self.windowFold(in: region)
        let frame = try #require(Self.frame(labelled: note, in: plain))
        #expect(frame.minX < region.minX + 20, "The note starts at \(frame.minX) without a fold, in \(region)")
        #expect(frame.maxX > fold.upperBound, "The note ends at \(frame.maxX) without a fold, in \(region)")

        let folded = try HostedViews.show(
            ImageSearchConvertedNote().environment(\.windowFold, fold), environment: environment, size: Self.size
        )
        defer { HostedViews.hide(folded) }
        #expect(await eventually {
            guard let frame = Self.frame(labelled: note, in: folded) else { return false }
            return frame.minX < region.minX + 20 && frame.maxX <= fold.lowerBound
        }, "The note at \(String(describing: Self.frame(labelled: note, in: folded))), the fold at \(fold)")
    }

    /// The measured fold put in the window's coordinates (`windowFold`'s) from the leading edge of `region`.
    private static func windowFold(in region: CGRect) -> ClosedRange<CGFloat> {
        (region.minX + fold.lowerBound)...(region.minX + fold.upperBound)
    }

    /// The frame, in the window's coordinates (`HostedViews.frame(of:in:)`; an accessibility frame is in the
    /// screen's), of the accessibility element labelled `label` on the window of `controller`.
    private static func frame(labelled label: String, in controller: UIViewController) -> CGRect? {
        guard let window = controller.view.window,
              let element = HostedViews.elements(in: controller.view).first(where: { $0.accessibilityLabel == label })
        else { return nil }
        return HostedViews.frame(of: element, in: window)
    }
}
