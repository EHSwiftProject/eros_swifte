import EHModels
import SwiftUI

/// The search filters (search Q3; Flutter `search_page.dart`'s filter sheet, `filter.dart`), the content of the search
/// page's Filter sheet: a form titled Search Filters (inline, identified `searchFilter.root`) with
///
/// - Categories (`searchFilter.categories`), reading All or "<n> Hidden", which pushes the ten categories of the
///   settings' category filter (`AppSettings.categoryFilter`) on a page of their own (`CategoryFilterPage`, identified
///   `searchFilter.categoriesPage`), with the footnote that they apply to searches only;
/// - Advanced Options (`searchFilter.advanced`), and while it is on, browse B6's `AdvancedSearchForm` over the
///   preferences' advanced search, with, while From is above To, a footnote under the page fields that the page
///   numbers will be swapped (`searchFilter.swapNote`);
/// - Done (`searchFilter.done`, `topBarPinnedTrailing`), which closes the sheet.
///
/// Every change is saved at once (the stores save on every change). The sheet's `onDismiss` (Done, or swiped down) puts
/// the page range right and runs the search again (`SearchModel.filtersDidClose()`); nothing is swapped while typing.
struct SearchFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var preferences: SearchPreferencesStore
    @Bindable private var settings: AppSettingsStore

    init(preferences: SearchPreferencesStore, settings: AppSettingsStore) {
        self.preferences = preferences
        self.settings = settings
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        CategoryFilterPage(
                            mask: $settings.settings.categoryFilter, identifier: "searchFilter.categoriesPage"
                        )
                    } label: {
                        LabeledContent("Categories") {
                            let hidden = settings.settings.categoryFilter.hiddenCategoryCount
                            if hidden == 0 {
                                Text("All")
                            } else {
                                Text("\(hidden) Hidden")
                            }
                        }
                    }
                    .accessibilityIdentifier("searchFilter.categories")
                } footer: {
                    Text("These categories apply to searches only.")
                }
                Section {
                    Toggle("Advanced Options", isOn: $preferences.preferences.usesAdvancedSearch)
                        .accessibilityIdentifier("searchFilter.advanced")
                }
                if preferences.preferences.usesAdvancedSearch {
                    AdvancedSearchForm(
                        search: $preferences.preferences.advancedSearch,
                        pagesNote: preferences.preferences.swapsPageBounds
                            ? AdvancedSearchForm.Note(
                                text: Text("The page numbers will be swapped."), identifier: "searchFilter.swapNote"
                            )
                            : nil
                    )
                }
            }
            .accessibilityIdentifier("searchFilter.root")
            .navigationTitle("Search Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Button(role: .confirm) {
                        dismiss()
                    }
                    .accessibilityIdentifier("searchFilter.done")
                }
            }
        }
        .alertHost()
    }
}
