import SwiftUI

/// Temporary root page of the tabs that have none yet: downloads and history keep theirs until M5 and M3. (The
/// gallery's became its custom groups in browse B6, `GalleryRootView`, the toplists' became `ToplistsRootView` in
/// browse B7, and the favorites' became `FavoritesRootView` in browse B8.)
struct TabScaffold: View {
    private let tab: AppTab

    init(tab: AppTab) {
        self.tab = tab
    }

    var body: some View {
        ContentUnavailableView(tab.title, systemImage: tab.systemImage, description: Text("Not available yet."))
            .keepsClearOfFold()
            .navigationTitle(tab.title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
