import SwiftUI

extension EnvironmentValues {
    /// The x range of the active, upright division over the tab's page (the iPhone Duo's fold, half open and held
    /// sideways; `LanePlan.fold(in:)`) in the window's coordinate space; nil without one. `TabRootView` reads it on
    /// the whole page (`foldReader()`), since a view is told only of the divisions over it, and a short one (a
    /// footnote, a banner) might not be told of the fold at all; `keepsClearOfFold(alignment:)` reads it here. The
    /// window's space, so that it means the same on every page of the tab's stack.
    @Entry var windowFold: ClosedRange<CGFloat>? = nil
}

extension View {
    /// Reads the fold over this view (a tab's whole page) and hands it down as `windowFold`.
    func foldReader() -> some View {
        modifier(FoldReader())
    }

    /// Keeps the text and the controls of this block clear of the fold (`windowFold`, design §5.4: controls never sit
    /// in the fold): on the wider side of it, the leading one when both are as wide (`FoldSide`). The block takes the
    /// whole width it is offered (aligned by `alignment` in it, as before), and the side it gives up is measured on
    /// that width, so moving it never changes what is measured. Backgrounds put on outside this modifier still run
    /// across the fold. Without a fold (closed, fully open, held upright) nothing moves.
    func keepsClearOfFold(alignment: Alignment = .center) -> some View {
        modifier(FoldClearance(alignment: alignment))
    }
}

/// See `View.foldReader()`. Only the fold's x range is kept, as for the lanes (`GalleryListView`), moved into the
/// window's space by the page's own x there.
private struct FoldReader: ViewModifier {
    @State private var fold: ClosedRange<CGFloat>?

    func body(content: Content) -> some View {
        content
            .environment(\.windowFold, fold)
            .onGeometryChange(for: ClosedRange<CGFloat>?.self) { proxy in
                LanePlan.fold(in: DivisionRegion.all(of: proxy)).map { fold in
                    let origin = proxy.frame(in: .global).minX
                    return (fold.lowerBound + origin)...(fold.upperBound + origin)
                }
            } action: { fold in
                self.fold = fold
            }
    }
}

/// See `View.keepsClearOfFold(alignment:)`.
private struct FoldClearance: ViewModifier {
    let alignment: Alignment
    @Environment(\.windowFold) private var fold
    /// The block's x range in the window's space: only that, so scrolling up or down changes nothing.
    @State private var extent: ClosedRange<CGFloat> = 0...0

    func body(content: Content) -> some View {
        let insets = FoldSide.insets(
            division: fold.map { LanePlan.division(from: $0, contentOrigin: extent.lowerBound) },
            width: extent.upperBound - extent.lowerBound
        )
        content
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .frame(maxWidth: .infinity, alignment: alignment)
            .onGeometryChange(for: ClosedRange<CGFloat>.self) { proxy in
                let frame = proxy.frame(in: .global)
                return frame.minX...frame.maxX
            } action: { extent in
                self.extent = extent
            }
    }
}
