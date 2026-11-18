import EHModels
import SwiftUI

/// The ten categories as toggle buttons in their list colors (Flutter pages/filter/filter.dart:109-228): on = shown
/// (the category's bit is clear in `mask`). A long press offers `Show Only <category>` (`CategoryMask.only`) and
/// `Hide Only <category>` (`CategoryMask.allBut`); Flutter offered one of them by the current state, both are listed
/// here. Each toggle is identified `category.<GalleryCategory rawValue>`. Used by the custom groups (B6) and search (Q3).
struct CategoryFilterView: View {
    @Binding private var mask: CategoryMask

    init(mask: Binding<CategoryMask>) {
        _mask = mask
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 4)], spacing: 4) {
            ForEach(GalleryCategory.allCases, id: \.self) { category in
                Toggle(isOn: Self.isShown(category, in: $mask)) {
                    Text(category.siteLabel)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .toggleStyle(.button)
                .tint(category.listColor)
                .contextMenu {
                    ForEach(Self.menuItems(for: category), id: \.title) { item in
                        Button(item.title) { mask = item.mask }
                    }
                }
                .accessibilityIdentifier("category.\(category.rawValue)")
            }
        }
    }

    /// The toggle of `category`: on while `mask` shows it; turning it off sets its bit, on clears it, and the other
    /// bits (high ones too) stay.
    static func isShown(_ category: GalleryCategory, in mask: Binding<CategoryMask>) -> Binding<Bool> {
        Binding {
            !mask.wrappedValue.excludes(category)
        } set: { isShown in
            if isShown {
                mask.wrappedValue.remove(CategoryMask(rawValue: category.filterBit))
            } else {
                mask.wrappedValue.insert(CategoryMask(rawValue: category.filterBit))
            }
        }
    }

    /// The long-press items of `category`, in order: Show Only, then Hide Only.
    static func menuItems(for category: GalleryCategory) -> [CategoryMenuItem] {
        [
            CategoryMenuItem(title: "Show Only \(category.siteLabel)", mask: .only(category)),
            CategoryMenuItem(title: "Hide Only \(category.siteLabel)", mask: .allBut(category)),
        ]
    }
}

/// A long-press item of the category filter: its title and the mask it sets.
nonisolated struct CategoryMenuItem: Equatable {
    let title: String
    let mask: CategoryMask
}
