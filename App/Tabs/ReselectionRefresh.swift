import SwiftUI

extension View {
    /// A double reselect of `tab` (`TabReselection.scrollToTopAndRefresh`, posted by `RootTabView` to the environment's
    /// `TabReselectionCenter`) scrolls the list `model()` gives to the top and refreshes it
    /// (`GalleryListModel.scrollToTop(refreshing: true)`); nil (no list shown) does nothing. A single reselect is left
    /// to the system, and other tabs' reselects are theirs. The gallery, toplists and favorites roots use it.
    func refreshesOnDoubleReselect(_ tab: AppTab, model: @escaping () -> GalleryListModel?) -> some View {
        modifier(ReselectionRefresh(tab: tab, model: model))
    }
}

private struct ReselectionRefresh: ViewModifier {
    @Environment(TabReselectionCenter.self) private var reselection
    let tab: AppTab
    let model: () -> GalleryListModel?

    func body(content: Content) -> some View {
        content
            .onChange(of: reselection.latest) { _, event in
                guard let event, event.tab == tab, event.action == .scrollToTopAndRefresh, let list = model() else {
                    return
                }
                Task { await list.scrollToTop(refreshing: true) }
            }
    }
}
