import SwiftUI

extension View {
    /// The Search item of a list tab's root page (search Q2): a `NavigationLink` to `request()` in the primary action
    /// placement, `Search` with a magnifying glass (the Duo rail shows the symbol), identified `identifier`.
    ///
    /// Only the link: `RoutedStack` shows every `SearchRequest` with `SearchView`, once for the stack, so a root page
    /// pushed onto another tab's stack (a hidden tab) adds no second destination.
    func searchEntry(identifier: String, _ request: @escaping () -> SearchRequest) -> some View {
        toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: request()) {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier(identifier)
            }
        }
    }
}
