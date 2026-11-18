/// A set of excluded gallery categories, as the site's `f_cats` filter: a set bit hides that category.
///
/// The bit of a category is its ``GalleryCategory/filterBit``. Codes as a bare integer.
public struct CategoryMask: OptionSet, Sendable, Hashable, Codable {
    /// The `f_cats` value; kept as given, high bits included.
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The mask that excludes exactly `categories`.
    public init(excluding categories: some Sequence<GalleryCategory>) {
        self.rawValue = categories.reduce(0) { $0 | $1.filterBit }
    }

    /// Whether `category` is excluded.
    public func excludes(_ category: GalleryCategory) -> Bool {
        rawValue & category.filterBit != 0
    }

    /// The mask that shows only `category`.
    public static func only(_ category: GalleryCategory) -> CategoryMask {
        CategoryMask(rawValue: 1023 & ~category.filterBit)
    }

    /// The mask that excludes only `category`.
    public static func allBut(_ category: GalleryCategory) -> CategoryMask {
        CategoryMask(rawValue: category.filterBit)
    }
}
