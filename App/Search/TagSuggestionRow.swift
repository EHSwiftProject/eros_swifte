import SwiftUI

/// One tag suggestion in a list: its `displayName`, and below it, when translations are shown and it has one, its
/// `translatedName` in a smaller, secondary font. One accessibility element, identifier `search.suggestion`, labelled
/// with the `displayName` (the translated name, when shown, is its value).
struct TagSuggestionRow: View {
    let suggestion: TagSuggestion
    let showsTranslation: Bool

    init(suggestion: TagSuggestion, showsTranslation: Bool) {
        self.suggestion = suggestion
        self.showsTranslation = showsTranslation
    }

    /// The translated name to show, if any.
    private var translatedName: String? {
        showsTranslation ? suggestion.translatedName : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(suggestion.displayName)
            if let translatedName {
                Text(translatedName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("search.suggestion")
        .accessibilityLabel(suggestion.displayName)
        .accessibilityValue(translatedName ?? "")
    }
}
