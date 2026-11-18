import SwiftUI

extension View {
    /// `toolbarTitleMenu(content:)` when `isShown`; otherwise the title is plain, with no menu (rather than a menu with
    /// nothing in it). The favorites page shows one only when logged in, the gallery page only while it has groups to
    /// pick or can manage them (L080a).
    @ViewBuilder func titleMenu(isShown: Bool, @ViewBuilder content: () -> some View) -> some View {
        if isShown {
            toolbarTitleMenu(content: content)
        } else {
            self
        }
    }
}
