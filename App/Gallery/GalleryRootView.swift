import EHModels
import EHNetwork
import SwiftUI

/// The gallery tab's root page (Flutter's custom group tabs, `custom_tabbar_controller.dart`): the list of the group
/// shown (`GalleryGroupsModel.selected`), titled with the group's name, in the group's list style, with the list's
/// jumps in the toolbar (`listJumpControls`, B5).
///
/// - The title menu (`toolbarTitleMenu`, M2 index §7) lists every group to pick from (`Group`), then Edit Group (the
///   group shown, in `GroupEditorView`) and Manage Groups (`GroupsManagementView`, pushed onto this stack).
/// - Without groups: titled `Gallery`, `No Groups` with Add Group, and the title menu has Manage Groups only. Without
///   a store: "Groups could not be loaded.", and no title menu (`GalleryGroupsModel.offersTitleMenu`).
/// - The status pages keep clear of the Duo's fold (`keepsClearOfFold(alignment:)`).
/// - A double reselect of the gallery tab scrolls the list shown to the top and refreshes it
///   (`refreshesOnDoubleReselect(_:model:)`); a single one is left to the system (`TabReselection`).
/// - A change of the session's identity reloads the list shown in `GalleryListView`; the lists kept for the other
///   groups are dropped (`GalleryGroupsModel.updateSession(_:)`).
/// - The toolbar's Search item (`gallery.search`, search Q2) opens the search page on the tab's site.
///
/// The page is one accessibility container, so the identifier `TabRootContent` gives it (`gallery.root`) stays on the
/// page while the list's own identifiers stay on its parts.
struct GalleryRootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.browsingSite) private var site

    var body: some View {
        GalleryGroupsPage(environment: environment, site: site)
            .id(site)
            .accessibilityElement(children: .contain)
            .searchEntry(identifier: "gallery.search") {
                SearchRequest(scope: .gallery, site: site)
            }
    }
}

/// The page over its groups. The model is made once, with the page (`State(initialValue:)` needs the store and the
/// service, which only the environment has, so this view takes them from its parent).
private struct GalleryGroupsPage: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var groups: GalleryGroupsModel
    @State private var editor: GroupEditorRequest?
    @State private var isManaging = false

    init(environment: AppEnvironment, site: EHSite) {
        _groups = State(initialValue: GalleryGroupsModel(
            store: environment.userData, settings: environment.settings, service: environment.service, site: site,
            languageCode: Locale.preferredLanguages.first ?? "en", alerts: environment.alerts
        ))
    }

    var body: some View {
        content
            .navigationTitle(groups.selected.map { Text($0.name) } ?? Text("Gallery"))
            .navigationBarTitleDisplayMode(.inline)
            .titleMenu(isShown: groups.offersTitleMenu) {
                titleMenu
            }
            .navigationDestination(isPresented: $isManaging) {
                GroupsManagementView(groups: groups)
            }
            .sheet(item: $editor) { request in
                GroupEditorView(groups: groups, group: request.group)
            }
            .task {
                await groups.load()
            }
            .onChange(of: environment.sessionIdentity, initial: true) { _, identity in
                groups.updateSession(identity)
            }
            .refreshesOnDoubleReselect(.gallery) {
                groups.selected.map { groups.model(for: $0) }
            }
    }

    @ViewBuilder private var content: some View {
        if groups.storeFailed {
            ContentUnavailableView(
                "Groups could not be loaded.", systemImage: "exclamationmark.triangle"
            )
            .accessibilityIdentifier("groups.failure")
            .keepsClearOfFold()
        } else if !groups.isLoaded {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .keepsClearOfFold()
        } else if let shown = groups.selected {
            let model = groups.model(for: shown)
            GalleryListView(model: model, style: groups.style(for: shown))
                .listJumpControls(model)
                .id(model.id)
        } else {
            ContentUnavailableView {
                Label("No Groups", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text("Add a group to browse galleries.")
            } actions: {
                Button("Add Group") {
                    editor = GroupEditorRequest(group: nil)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("groups.add")
            }
            .keepsClearOfFold()
        }
    }

    @ViewBuilder private var titleMenu: some View {
        if let shown = groups.selected {
            Picker("Group", selection: selection) {
                ForEach(groups.groups) { group in
                    Text(group.name)
                        .tag(group.uuid)
                        .accessibilityIdentifier("groups.menu.\(group.uuid)")
                }
            }
            Button {
                editor = GroupEditorRequest(group: shown)
            } label: {
                Label("Edit Group", systemImage: "pencil")
            }
            .accessibilityIdentifier("groups.edit")
        }
        if !groups.storeFailed {
            Button {
                isManaging = true
            } label: {
                Label("Manage Groups", systemImage: "list.bullet")
            }
            .accessibilityIdentifier("groups.manage")
        }
    }

    /// The group shown, by uuid, as the title menu's picker sets it.
    private var selection: Binding<String> {
        let groups = groups
        return Binding {
            groups.selected?.uuid ?? ""
        } set: { uuid in
            groups.select(uuid)
        }
    }
}
