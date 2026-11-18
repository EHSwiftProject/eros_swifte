import SwiftUI

/// Settings → Tab Bar: which tabs the tab bar shows and in what order (`TabConfiguration`). The list is always in edit
/// mode, so every row has the system reorder handle; a switch that would hide the last tab or show more than
/// `TabConfiguration.maximumEnabled` is disabled, its row dimmed.
struct TabSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let store = environment.settings
        List {
            Section {
                ForEach(store.tabs.orderedTabs) { tab in
                    let isLocked = !store.tabs.canDisable(tab) || !store.tabs.canEnable(tab)
                    Toggle(isOn: isShown(tab, in: store)) {
                        // Dimmed by hand: in this always-editing list the system draws a disabled row's label and
                        // switch exactly like an enabled one (iOS 27.2, browse B2).
                        Label(tab.title, systemImage: tab.systemImage)
                            .opacity(isLocked ? 0.4 : 1)
                    }
                    .disabled(isLocked)
                    .accessibilityIdentifier("tabSettings.toggle.\(tab.rawValue)")
                }
                .onMove { source, destination in
                    store.tabs.move(fromOffsets: source, toOffset: destination)
                }
            } footer: {
                Text(
                    "Drag to reorder. Up to four tabs can be shown besides Settings, which always stays last: more would not fit the iPhone tab bar."
                )
                .keepsClearOfFold(alignment: .leading)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Tab Bar")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func isShown(_ tab: AppTab, in store: AppSettingsStore) -> Binding<Bool> {
        Binding(
            get: { store.tabs.isEnabled(tab) },
            set: { store.tabs.setEnabled($0, for: tab) }
        )
    }
}
