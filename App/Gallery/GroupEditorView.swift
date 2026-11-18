import EHModels
import EHNetwork
import EHStore
import Foundation
import SwiftUI

nonisolated extension GroupListType {
    /// The name the group editor and the management page show for this kind of list.
    var title: String {
        switch self {
        case .popular: "Popular"
        case .gallery: "Gallery"
        case .watched: "Watched"
        }
    }
}

/// One search text of a group being edited, with an id of its own: the same text may be there twice, and a list row
/// has to stay with its text when one before it goes.
nonisolated struct SearchTextEntry: Identifiable, Equatable {
    let id: UUID
    var text: String

    init(_ text: String) {
        id = UUID()
        self.text = text
    }
}

/// What the group editor edits (Flutter `custom_profile_setting_page.dart`): the fields it shows, over the group as it
/// was. `makeGroup()` writes back only the fields that changed, so a field left alone stays as stored (nil included)
/// and the fields the editor does not show (`hideTab`, `aggregateGroups`, `catsTypeValue`, …) are kept.
nonisolated struct GroupDraft: Equatable {
    var name: String
    /// nil follows the global setting.
    var style: ListStyle?
    var type: GroupListType
    /// The excluded categories; nil until edited when the group has none (it then sends no `f_cats`).
    var categories: CategoryMask?
    /// The search texts, in order; edited through `addSearchText(_:)` and `removeSearchTexts(atOffsets:)`.
    private(set) var searchTexts: [SearchTextEntry]
    var enablesAdvanced: Bool
    /// Kept when `enablesAdvanced` is turned off (Flutter keeps `advSearch`).
    var advanced: AdvancedSearch

    /// The group as it was; a new one is an unnamed gallery group with a uuid of its own.
    private let original: CustomGroup
    /// The draft is of a group not stored yet.
    private let isNew: Bool

    /// The fields of `group`; nil: a new gallery group.
    init(group: CustomGroup?) {
        let original = group ?? CustomGroup(uuid: UUID().uuidString.lowercased(), name: "")
        self.original = original
        isNew = group == nil
        name = original.name
        style = original.listStyle
        type = original.listType
        categories = original.categories
        searchTexts = (original.searchText ?? []).map(SearchTextEntry.init)
        enablesAdvanced = original.enableAdvance ?? false
        advanced = original.advancedSearch ?? AdvancedSearch()
    }

    /// Adds `text` as the last search text.
    mutating func addSearchText(_ text: String) {
        searchTexts.append(SearchTextEntry(text))
    }

    /// Removes the search texts at `offsets`; the others keep their ids.
    mutating func removeSearchTexts(atOffsets offsets: IndexSet) {
        searchTexts.removeSubranges(RangeSet(offsets, within: searchTexts))
    }

    /// Whether saving would write anything: always for a new group; for a stored one, whether `makeGroup()` differs
    /// from it (so an editor left as it was, or a name that only gained spaces around it, writes nothing and keeps the
    /// group's list as it is).
    var hasChanges: Bool {
        isNew || makeGroup() != original
    }

    /// Whether the categories, the search texts and the advanced options apply: a popular list has none of them.
    var showsSearchOptions: Bool {
        type != .popular
    }

    /// Whether the name is something besides whitespace.
    var canSave: Bool {
        !trimmedName.isEmpty
    }

    /// How many of the ten categories the draft hides (the Categories row's summary); 0 while unset.
    var hiddenCategoryCount: Int {
        categories?.hiddenCategoryCount ?? 0
    }

    /// The name of another group that saving would replace, for the name's footnote; nil when it would replace none.
    ///
    /// Only a new group can replace another: `UserDataStore.saveGroup(_:)` updates the group with the draft's uuid in
    /// place when there is one (so an existing group renamed to another group's name leaves that group alone, and the
    /// two share the name), and only for a uuid it does not hold replaces the group with the same trimmed name
    /// (Flutter `addProfile`, uuid first, then name).
    func replacedGroupName(in groups: [CustomGroup]) -> String? {
        let name = trimmedName
        guard !name.isEmpty, !groups.contains(where: { $0.uuid == original.uuid }) else { return nil }
        return groups.first { $0.name == name }?.name
    }

    /// The group as edited: the original with the trimmed name and every field that changed.
    func makeGroup() -> CustomGroup {
        var group = original
        group.name = trimmedName
        if style != original.listStyle { group.listStyle = style }
        if type != original.listType { group.listType = type }
        if categories != original.categories { group.categories = categories }
        let texts = searchTexts.map(\.text)
        if texts != (original.searchText ?? []) { group.searchText = texts }
        if enablesAdvanced != (original.enableAdvance ?? false) { group.enableAdvance = enablesAdvanced }
        if advanced != (original.advancedSearch ?? AdvancedSearch()) { group.advancedSearch = advanced }
        return group
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A request to open the group editor: for `group`, or for a new group when it is nil. Every request is its own sheet.
struct GroupEditorRequest: Identifiable {
    let id = UUID()
    let group: CustomGroup?
}

/// The group editor sheet (Flutter `custom_profile_setting_page.dart`), titled `New Group` or `Edit Group`: the name
/// (with a footnote when saving would replace another group), the list mode, the group type, and for all but popular
/// groups the categories (a row with how many are hidden, opening `CategoryFilterView` on a page of its own), the
/// search texts (each with its translation when tags are shown translated; swipe to delete; New Text opens
/// `KeywordEntrySheet`) and the advanced options (`AdvancedSearchForm`). A group that exists can be deleted, after a
/// confirmation; the sheet closes once the store took the delete. Save (`topBarPinnedTrailing`) saves the group,
/// which is then shown, and closes the sheet; it is disabled while the name is blank. The sheet hosts its own alerts.
struct GroupEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    private let groups: GalleryGroupsModel
    private let group: CustomGroup?

    @State private var draft: GroupDraft
    @State private var isAddingText = false
    @State private var isConfirmingDeletion = false
    @State private var isSaving = false

    init(groups: GalleryGroupsModel, group: CustomGroup?) {
        self.groups = groups
        self.group = group
        _draft = State(initialValue: GroupDraft(group: group))
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                Section {
                    Picker("List Mode", selection: $draft.style) {
                        Text("Global Setting").tag(ListStyle?.none)
                        ForEach(ListStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(Optional(style))
                        }
                    }
                    .accessibilityIdentifier("group.listMode")
                }
                Section("Group Type") {
                    Picker("Group Type", selection: $draft.type) {
                        ForEach([GroupListType.popular, .gallery, .watched], id: \.self) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("group.type")
                }
                if draft.showsSearchOptions {
                    searchOptions
                }
                if let group {
                    Section {
                        Button("Delete Group", role: .destructive) {
                            isConfirmingDeletion = true
                        }
                        .disabled(isSaving)
                        .accessibilityIdentifier("group.delete")
                        // Attached to the button: on iOS 27.2 it shows as a popover from the button without a Cancel
                        // (tapping outside cancels), on all three devices. That is the system's own way and is kept
                        // (M2 review U2, option C), as for Log Out.
                        .confirmationDialog(
                            "Delete \"\(group.name)\"?", isPresented: $isConfirmingDeletion, titleVisibility: .visible
                        ) {
                            Button("Delete Group", role: .destructive) {
                                // Save and Delete stay disabled while it goes: a save then would put the group back
                                // as a new one. Only a delete the store took closes the sheet; a refused one leaves
                                // it open with the alert on it (`alertHost()` below), the group still there.
                                isSaving = true
                                Task {
                                    if await groups.delete(group.uuid) {
                                        dismiss()
                                    } else {
                                        isSaving = false
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(group == nil ? Text("New Group") : Text("Edit Group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("group.close")
                }
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .disabled(!draft.canSave || isSaving)
                    .accessibilityIdentifier("group.save")
                }
            }
            .sheet(isPresented: $isAddingText) {
                KeywordEntrySheet(suggestions: environment.tagSuggestions) { text in
                    draft.addSearchText(text)
                }
            }
        }
        .alertHost()
    }

    private var nameSection: some View {
        Section {
            TextField("Group Name", text: $draft.name)
                .accessibilityIdentifier("group.name")
        } footer: {
            if let replaced = draft.replacedGroupName(in: groups.groups) {
                Text("A group named \"\(replaced)\" will be replaced.")
                    .accessibilityIdentifier("group.nameFootnote")
            }
        }
    }

    @ViewBuilder private var searchOptions: some View {
        Section {
            NavigationLink {
                CategoryFilterPage(mask: categories, identifier: "group.categoriesPage")
            } label: {
                LabeledContent("Categories") {
                    if draft.hiddenCategoryCount == 0 {
                        Text("All")
                    } else {
                        Text("\(draft.hiddenCategoryCount) Hidden")
                    }
                }
            }
            .accessibilityIdentifier("group.categories")
        }
        Section("Search Texts") {
            ForEach(draft.searchTexts) { entry in
                SearchTextRow(text: entry.text)
            }
            .onDelete { offsets in
                draft.removeSearchTexts(atOffsets: offsets)
            }
            Button {
                isAddingText = true
            } label: {
                Label("New Text", systemImage: "plus")
            }
            .accessibilityIdentifier("group.newText")
        }
        Section {
            Toggle("Advanced Options", isOn: $draft.enablesAdvanced)
                .accessibilityIdentifier("group.advanced")
        }
        if draft.enablesAdvanced {
            AdvancedSearchForm(search: $draft.advanced)
        }
    }

    /// The draft's categories as the filter edits them: none excluded while unset, which stays unset until a toggle
    /// or a long-press item of the Categories page changes it (opening the page changes nothing).
    private var categories: Binding<CategoryMask> {
        let draft = $draft
        return Binding {
            draft.wrappedValue.categories ?? []
        } set: { mask in
            draft.wrappedValue.categories = mask
        }
    }

    /// Saves the group and closes the sheet; a stored group left as it was (`GroupDraft.hasChanges`) only closes it,
    /// so its list is not loaded again. A name the store still finds blank is told in an alert (a store that cannot
    /// save, in another); the sheet then stays.
    private func save() async {
        guard draft.hasChanges else {
            dismiss()
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await groups.save(draft.makeGroup())
            dismiss()
        } catch UserDataError.emptyGroupName {
            environment.alerts.present(HostedAlert(title: "Group Name is empty.", actions: [.init("OK")]))
        } catch {
            environment.alerts.present(HostedAlert(title: "The group could not be saved.", actions: [.init("OK")]))
        }
    }
}

/// One search text of the group editor; below it, while tags are shown translated, the text translated term by term
/// (`SearchTermTranslator`, Flutter `custom_profile_setting_page.dart:508-523`) when any term has a translation.
private struct SearchTextRow: View {
    @Environment(AppEnvironment.self) private var environment
    let text: String

    @State private var translation: String?

    var body: some View {
        let showsTranslation = environment.settings.settings.showsTagTranslations
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
            if showsTranslation, let translation {
                Text(translation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("group.searchText")
        .accessibilityLabel(text)
        .accessibilityValue(showsTranslation ? translation ?? "" : "")
        .task(id: TranslationKey(text: text, isOn: showsTranslation)) {
            translation = showsTranslation ? await environment.searchTerms.translation(of: text) : nil
        }
    }

    /// What the translation depends on.
    private struct TranslationKey: Equatable {
        let text: String
        let isOn: Bool
    }
}
