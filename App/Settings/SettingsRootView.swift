import SwiftUI

/// A page of the Settings tab pushed by value, so it is in the router's path: the Tab Bar page must outlive the
/// `TabView` being made anew when the user changes the tabs on it (`RootTabView`).
nonisolated enum SettingsPage: Hashable, Sendable {
    case tabBar
}

/// The root page of the Settings tab. Its stack is the tab's `RoutedStack` (`TabRootView`), and `TabRootContent`
/// gives it the identifier `settings.root`.
struct SettingsRootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isShowingLogin = false

    var body: some View {
        @Bindable var settings = environment.settings
        Form {
            AccountSection(isShowingLogin: $isShowingLogin)
            Section {
                NavigationLink(value: SettingsPage.tabBar) {
                    Label("Tab Bar", systemImage: "dock.rectangle")
                }
                .accessibilityIdentifier("settings.tabBar")
                Picker("List Mode", selection: $settings.settings.listStyle) {
                    ForEach(ListStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .accessibilityIdentifier("settings.listMode")
                Toggle("Show Tag Translations", isOn: $settings.settings.showsTagTranslations)
                    .accessibilityIdentifier("settings.tagTranslations")
                // Entry E3: the clipboard monitor (`ClipboardLinkMonitor`) looks only while this is on.
                Toggle("Clipboard Detection", isOn: $settings.settings.detectsClipboardLinks)
                    .accessibilityIdentifier("settings.clipboardLinks")
            } header: {
                Text("General")
            } footer: {
                // One literal, so the text stays a localized string key (M8).
                Text("""
                    When Eros-SE returns to the foreground, it offers to open an E-Hentai or ExHentai link found in the \
                    clipboard.
                    """)
                .keepsClearOfFold(alignment: .leading)
            }
            TagDatabaseSettings()
        }
        .navigationTitle(AppTab.settings.title)
        // Inline, as every other tab's root page.
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: SettingsPage.self) { page in
            switch page {
            case .tabBar:
                TabSettingsView()
            }
        }
        .sheet(isPresented: $isShowingLogin) {
            LoginView()
        }
    }
}
