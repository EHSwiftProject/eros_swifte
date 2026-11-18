import SwiftUI

/// What a route shows until its page exists (`RouteDestinationView`): a system `ContentUnavailableView` with the
/// given title, symbol and description, also titling the page.
struct RoutePlaceholderView: View {
    let title: String
    let systemImage: String
    let description: String
    let identifier: String

    init(title: String, systemImage: String, description: String, identifier: String) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.identifier = identifier
    }

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
            .accessibilityIdentifier(identifier)
            .keepsClearOfFold()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
