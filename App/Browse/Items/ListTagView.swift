import EHModels
import SwiftUI

extension EnvironmentValues {
    /// Non-nil: list tags are buttons (identifier `list.tag`, accessibilityValue `tag.raw`) that perform this. The
    /// search screens set it; without it a tag is plain text.
    @Entry var listTagAction: ListTagAction? = nil
}

/// What tapping a list tag does, compared by its owner (the model it acts on): a page passes a new action on every
/// redraw, and a closure in the environment cannot be compared, so each would make every tag of the list draw again
/// (the `@Entry` warning, L071e). Two actions of one owner count as the same.
///
/// That holds as long as the closure reaches nothing but the owner it is handed (M2 re-review F3 M-6, F5 N-8): the
/// type cannot stop it from capturing other values, so keep to it. Then what it does depends on the owner alone, and
/// an action kept from an earlier redraw does what a new one would. Write what it needs into the owner, not into the
/// closure. The owner is held weakly: the action does not keep a page's model alive, and does nothing once it is gone.
nonisolated struct ListTagAction: Equatable, Sendable {
    let owner: ObjectIdentifier
    // @MainActor: a global-actor-isolated function type is implicitly Sendable (SE-0434).
    private let perform: @MainActor (TagRef) -> Void

    /// An action of `owner`: `perform` gets the owner (while it lives) and the tag tapped.
    @MainActor init<Owner: AnyObject>(_ owner: Owner, perform: @escaping @MainActor (Owner, TagRef) -> Void) {
        self.owner = ObjectIdentifier(owner)
        self.perform = { [weak owner] tag in
            if let owner { perform(owner, tag) }
        }
    }

    @MainActor func callAsFunction(_ tag: TagRef) {
        perform(tag)
    }

    static func == (lhs: ListTagAction, rhs: ListTagAction) -> Bool {
        lhs.owner == rhs.owner
    }
}

/// One tag of a list item. It reads `showsTagTranslations`, the tag names and `listTagAction` from the environment.
struct ListTagView: View {
    let tag: ListTag
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.listTagAction) private var action

    init(tag: ListTag) {
        self.tag = tag
    }

    /// The text shown for `tag`: its translated name when translations are shown and the name is known, else its
    /// own name.
    static func text(for tag: TagRef, showsTranslations: Bool, names: TagNameCache) -> String {
        if showsTranslations, let name = names.name(for: tag) {
            return name
        }
        return tag.name
    }

    var body: some View {
        let text = Self.text(
            for: tag.tag, showsTranslations: environment.settings.settings.showsTagTranslations,
            names: environment.tagNames
        )
        if let action {
            Button {
                action(tag.tag)
            } label: {
                chip(text)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("list.tag")
            .accessibilityValue(tag.tag.raw)
        } else {
            chip(text)
        }
    }

    /// The tag's text in the page's colors: its background and border when it gave them, else the secondary fill.
    private func chip(_ text: String) -> some View {
        let colors = tag.colors
        return Text(text)
            .font(.caption2)
            .lineLimit(1)
            .foregroundStyle(colors?.text.flatMap(Color.init(hex:)) ?? Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                colors?.background.flatMap(Color.init(hex:)) ?? Color(.secondarySystemFill),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay {
                if let border = colors?.border.flatMap(Color.init(hex:)) {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(border, lineWidth: 1)
                }
            }
    }
}

extension Color {
    /// A color from "#rrggbb" (what the list pages give tags); nil for anything else.
    fileprivate init?(hex: String) {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
