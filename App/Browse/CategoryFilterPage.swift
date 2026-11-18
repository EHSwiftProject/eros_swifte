import EHModels
import SwiftUI

/// The categories on a page of their own, pushed onto a sheet's stack: the ten categories (`CategoryFilterView`) in a
/// scroll view, titled Categories (inline), identified `identifier`. Not a row of the sheet's form: a form row takes
/// the first of its views' context menus for all of them, so every category's long press would offer the first
/// category's items. The group editor (B6, `group.categoriesPage`) and the
/// search filters (search Q3, `searchFilter.categoriesPage`) push it from a Categories row
/// that reads `CategoryMask.hiddenCategoryCount`.
struct CategoryFilterPage: View {
    @Binding private var mask: CategoryMask
    private let identifier: String

    init(mask: Binding<CategoryMask>, identifier: String) {
        _mask = mask
        self.identifier = identifier
    }

    var body: some View {
        ScrollView {
            CategoryFilterView(mask: $mask)
        }
        .contentMargins(16, for: .scrollContent)
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(identifier)
    }
}

nonisolated extension CategoryMask {
    /// How many of the ten categories the mask hides (a Categories row reads All for none, else "<n> Hidden").
    var hiddenCategoryCount: Int {
        GalleryCategory.allCases.count { excludes($0) }
    }
}
