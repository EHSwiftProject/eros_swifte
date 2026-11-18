import EHStore
import SwiftUI

/// The "Tag Translations" section of the settings root page: the downloaded version, a manual update and the two
/// switches. The footer holds only the result of the last update the user started. The mirror switch takes effect
/// with the next update (`AppEnvironment.updateTagDatabase(force:)` reads it then), Update Now during one in flight
/// included: it runs through the new route once that one has ended (M2 re-review F5 N-2).
struct TagDatabaseSettings: View {
    @Environment(AppEnvironment.self) private var environment
    /// The version in the store; nil before a download.
    @State private var version: String?
    @State private var isUpdating = false
    /// The footer text; nil until Update Now has been pressed.
    @State private var result: String?

    var body: some View {
        @Bindable var settings = environment.settings
        Section {
            LabeledContent("Version", value: version ?? "Not Downloaded")
                .accessibilityIdentifier("settings.tagDatabase.version")
            Button {
                Task { await update() }
            } label: {
                HStack {
                    Label("Update Now", systemImage: "arrow.down.circle")
                    if isUpdating {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isUpdating)
            .accessibilityIdentifier("settings.tagDatabase.update")
            Toggle("Update on Launch", isOn: $settings.settings.updatesTagDatabaseOnLaunch)
                .accessibilityIdentifier("settings.tagDatabase.onLaunch")
            Toggle("Use Download Mirror", isOn: $settings.settings.usesTagDatabaseMirror)
                .accessibilityIdentifier("settings.tagDatabase.mirror")
        } header: {
            Text("Tag Translations")
        } footer: {
            if let result {
                Text(result)
                    .accessibilityIdentifier("settings.tagDatabase.result")
                    .keepsClearOfFold(alignment: .leading)
            }
        }
        .task { await readVersion() }
    }

    private func readVersion() async {
        version = try? await environment.tagTranslations?.version()
    }

    /// Updates unless the store already has the latest release (the footer says which) and reads the version again.
    private func update() async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            switch try await environment.updateTagDatabase(force: false) {
            case .updated(let version, let count):
                result = "Updated to \(version), \(count) tags."
            case .upToDate:
                result = "Already up to date."
            }
        } catch {
            result = Self.failureText(for: error)
        }
        await readVersion()
    }

    /// The footer for a download larger than a tag database can be (the updater's and the store's `.tooLarge`).
    static let tooLargeText = "Update failed. The download is larger than a tag database can be."

    /// The footer for a database file found damaged (`TagDatabaseError.damaged`): the store rebuilds it at the next
    /// launch, and the app then downloads it again whatever "Update on Launch" says (U5, 2026-11-17; M2 re-review F5
    /// N-3). Its final words come with M8.
    static let damagedText = "The tag database is damaged. It will be downloaded again the next time Eros-SE starts."

    /// The footer for a failed update: a download that was too large and a damaged database say so; every other
    /// failure still reads as a connection problem until M8 words each (a database that cannot be opened among them).
    static func failureText(for error: any Error) -> String {
        switch error {
        case TagDatabaseUpdateError.tooLarge, TagDatabaseError.tooLarge: tooLargeText
        case TagDatabaseError.damaged: damagedText
        default: "Update failed. Check your connection."
        }
    }
}
