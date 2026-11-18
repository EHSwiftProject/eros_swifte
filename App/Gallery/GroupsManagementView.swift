import EHModels
import SwiftUI

/// The gallery groups' management page (Flutter `custom_profiles_page.dart`), titled `Groups`, pushed onto the gallery
/// tab's stack from the title menu: every group with its kind of list; tapping one opens the group editor. Swiping a
/// row deletes the group at once (Flutter asks nothing); in edit mode the rows are reordered with the system's reorder
/// control. The toolbar has Add Group (`topBarPinnedTrailing`) and the edit mode switch (Edit, then Done; low
/// visibility priority, so it gives way first when the bar is short).
struct GroupsManagementView: View {
    private let groups: GalleryGroupsModel

    @State private var editMode: EditMode = .inactive
    @State private var editor: GroupEditorRequest?

    init(groups: GalleryGroupsModel) {
        self.groups = groups
    }

    var body: some View {
        List {
            ForEach(groups.groups) { group in
                Button {
                    editor = GroupEditorRequest(group: group)
                } label: {
                    LabeledContent(group.name, value: group.listType.title)
                }
                .tint(.primary)
                .accessibilityIdentifier("groups.row")
                .accessibilityLabel(group.name)
                .accessibilityValue(group.listType.title)
            }
            .onDelete { offsets in
                let ids = offsets.map { groups.groups[$0].uuid }
                Task.immediate {
                    for id in ids { await groups.delete(id) }
                }
            }
            .onMove { offsets, destination in
                Task.immediate {
                    await groups.move(fromOffsets: offsets, toOffset: destination)
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Groups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                } label: {
                    if editMode.isEditing {
                        Label("Done", systemImage: "checkmark")
                    } else {
                        Label("Edit", systemImage: "pencil")
                    }
                }
                .accessibilityIdentifier("groups.management.edit")
            }
            // On the Duo's cover screen held sideways the rail has room for few items: Edit goes to the overflow menu
            // before Add Group does (U6), as Quick Search's Edit does.
            .visibilityPriority(.low)
            ToolbarItem(placement: .topBarPinnedTrailing) {
                Button {
                    editor = GroupEditorRequest(group: nil)
                } label: {
                    Label("Add Group", systemImage: "plus")
                }
                .accessibilityIdentifier("groups.management.add")
            }
        }
        .sheet(item: $editor) { request in
            GroupEditorView(groups: groups, group: request.group)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("groups.management")
    }
}
