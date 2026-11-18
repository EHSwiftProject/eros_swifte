import EHModels
import SwiftUI

/// The sheet that adds a search text to a group (Flutter `search_text_dialog.dart` with `ProfileEditController`),
/// titled `New Text`: the text field, and below it the tag suggestions for the word being typed (`TagSuggestionQuery`
/// over `TagSuggestionService`: the local tag table while tags are shown translated, else the site's `tagsuggest`).
/// Picking one puts its search term in place of that word (`TagSuggestionQuery.apply(_:to:)`). Add
/// (`topBarPinnedTrailing`) hands the trimmed text over and closes the sheet; it is disabled while the text is blank.
/// The sheet hosts its own alerts.
struct KeywordEntrySheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.browsingSite) private var site
    @Environment(\.dismiss) private var dismiss
    private let onAdd: (String) -> Void

    @State private var text = ""
    @State private var query: TagSuggestionQuery

    /// `suggestions`: the environment's `tagSuggestions`. `onAdd` gets the text (trimmed) once Add is tapped.
    init(suggestions: TagSuggestionService, onAdd: @escaping (String) -> Void) {
        self.onAdd = onAdd
        _query = State(initialValue: TagSuggestionQuery(service: suggestions))
    }

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsTranslation = environment.settings.settings.showsTagTranslations
        NavigationStack {
            Form {
                Section {
                    TextField("Search Text", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("keyword.text")
                }
                if !query.suggestions.isEmpty {
                    Section {
                        ForEach(query.suggestions, id: \.self) { suggestion in
                            Button {
                                text = query.apply(suggestion, to: text)
                            } label: {
                                TagSuggestionRow(suggestion: suggestion, showsTranslation: showsTranslation)
                                    .foregroundStyle(Color.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("keyword.close")
                }
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Button {
                        onAdd(trimmed)
                        dismiss()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(trimmed.isEmpty)
                    .accessibilityIdentifier("keyword.add")
                }
            }
            .onChange(of: text) { _, text in
                query.textDidChange(text, site: site)
            }
        }
        .alertHost()
    }
}
