import EHModels
import EHNetwork
import SwiftUI

/// The Account section of the settings: Log In when signed out; the avatar, the name and Log Out when signed in.
///
/// The login sheet is presented by the form around it (`isShowingLogin`): a presentation attached to a `Section`
/// is applied to each of its rows, and then none is presented.
struct AccountSection: View {
    @Binding var isShowingLogin: Bool

    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingLogOut = false

    var body: some View {
        Section("Account") {
            if environment.isLoggedIn {
                let display = environment.session.account.map(AccountDisplay.resolve)
                HStack(spacing: 12) {
                    AvatarView(url: display?.avatarURL)
                    Text(display?.name ?? "Logged In")
                        .accessibilityIdentifier("account.name")
                }
                Button("Log Out", role: .destructive) { isConfirmingLogOut = true }
                    .accessibilityIdentifier("account.logout")
                    // On the button it comes from (QK64, user decision 2026-11-17: kept as the system shows it). On
                    // iOS 27.2 the dialog is a popover bubble beside the button at every width, iPhone, iPad and the
                    // closed Duo, without a Cancel button (tapping outside it cancels): the system's behavior.
                    .confirmationDialog("Log Out", isPresented: $isConfirmingLogOut, titleVisibility: .hidden) {
                        Button("Log Out", role: .destructive) {
                            // A vault that cannot be deleted leaves the session as it is, and the section shows it.
                            Task { try? await environment.logOut() }
                        }
                        .accessibilityIdentifier("account.logout.confirm")
                        // The system leaves it out of the popover (see above).
                        Button("Cancel", role: .cancel) {}
                    }
            } else {
                Button("Log In") { isShowingLogin = true }
                    .accessibilityIdentifier("account.login")
            }
            #if DEBUG
            NavigationLink("Session Diagnostics") {
                SessionDiagnosticsView()
            }
            .accessibilityIdentifier("account.diagnostics")
            #endif
        }
    }
}
