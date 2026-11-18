import EHModels
import SwiftUI
import Testing

@testable import Eros

/// The category filter's toggles and long-press items: what each does to the mask (a set bit hides a category).
@MainActor @Suite struct CategoryFilterTests {
    @MainActor final class MaskBox {
        var mask: CategoryMask = []
    }

    @Test func turningACategoryOffExcludesIt() {
        let box = MaskBox()
        let mask = Binding(get: { box.mask }, set: { box.mask = $0 })
        let manga = CategoryFilterView.isShown(.manga, in: mask)
        #expect(manga.wrappedValue)
        manga.wrappedValue = false
        #expect(box.mask.rawValue == 4)
        #expect(!manga.wrappedValue)
        // On again: shown; the other bits stay, high ones too.
        box.mask = CategoryMask(rawValue: 4 | 2 | 4096)
        manga.wrappedValue = true
        #expect(box.mask.rawValue == 2 | 4096)
    }

    @Test func showOnlyAndHideOnly() {
        let items = CategoryFilterView.menuItems(for: .manga)
        #expect(items.map(\.title) == ["Show Only Manga", "Hide Only Manga"])
        #expect(items.map(\.mask.rawValue) == [1019, 4])
    }
}
