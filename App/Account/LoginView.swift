import EHNetwork
import EHParsing
import SwiftUI

/// The three ways to log in, as the segments of the login screen.
nonisolated enum LoginMethodChoice: String, CaseIterable, Identifiable, Sendable {
    case password, cookie, web

    var id: Self { self }

    var title: String {
        switch self {
        case .password: "Password"
        case .cookie: "Cookie"
        case .web: "Web"
        }
    }
}

/// The message of the `Login Failed` alert for an error of a login.
nonisolated enum LoginFailureMessage {
    /// Shown above the web login's button when a password login was handed over to it.
    static let webLoginTakesOver = "The forum wants a check that only the web page can do. Log in on the page."

    /// The `Login Failed` alert for `error`, shown through the app's alerts (`AppEnvironment.alerts`, as every alert
    /// without a text field is): its message (`text(for:)`) and OK. nil when `text(for:)` is nil.
    @MainActor static func alert(for error: any Error) -> HostedAlert? {
        guard let message = text(for: error) else { return nil }
        return alert(message: message)
    }

    /// The `Login Failed` alert with `message`.
    @MainActor static func alert(message: String) -> HostedAlert {
        HostedAlert(title: "Login Failed", message: message, actions: [.init("OK", role: .cancel)])
    }

    /// nil for `CancellationError`: the login was refused because another one is in progress
    /// (`AppEnvironment.isLoggingIn`), or logging out replaced it (`AppEnvironment`, `AccountService`); it then just
    /// ends, with no alert.
    static func text(for error: any Error) -> String? {
        if error is CancellationError { return nil }
        if let web = error as? WebPasswordLoginError {
            switch web {
            case .needsWebLogin:
                return "The forum wants a check that only the web login can do, and the web login is unavailable "
                    + "right now."
            case .unreachable:
                return "Could not reach the server."
            }
        }
        if let login = error as? LoginError {
            switch login {
            case .rejected: return "Login failed. Check your username and password, or try the web login."
            case .invalidMemberID: return "ipb_member_id must be a number."
            case .invalidPassHash: return "ipb_pass_hash must be 32 hexadecimal characters."
            }
        }
        if case EHNetworkError.paused(let pause)? = error as? EHNetworkError {
            return pausedText(for: pause)
        }
        if case EHNetworkError.issue(.banned)? = error as? EHNetworkError {
            return "Your IP address is temporarily banned. Try again later."
        }
        // The forum answered 429; both sites pause for a minute (`SiteBreaker`).
        if case EHNetworkError.issue(.tooManyRequests)? = error as? EHNetworkError {
            return "Too many requests. Try again in a minute."
        }
        // The WebView store did not answer in time (`WebSessionBridge.storeTimeout`); the login has ended.
        if error is WebStoreTimeout {
            return "Could not prepare the login. Try again."
        }
        return "Could not reach the server."
    }

    /// Both sites are paused (`SiteBreaker`): why, and until when, as the lists say it
    /// (`ListFailure.expiryText(until:now:calendar:locale:)`): the time alone today, the date too on a later day (a
    /// ban may last days).
    private static func pausedText(for pause: SitePause) -> String {
        let until = ListFailure.expiryText(until: pause.until, now: .now, calendar: .current, locale: .current)
        return switch pause.reason {
        case .banned:
            "Your IP address is temporarily banned. Requests to E-Hentai and ExHentai are paused until \(until)."
        case .tooManyRequests:
            "Too many requests. Requests to E-Hentai and ExHentai are paused until \(until)."
        }
    }
}

/// The login sheet: password, cookie or the site's web login page.
struct LoginView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var method: LoginMethodChoice = .password
    @State private var username = ""
    @State private var password = ""
    @State private var memberID = ""
    @State private var passHash = ""
    @State private var isWorking = false
    @State private var isShowingWebLogin = false
    /// A password login met a check only the visible web page can do, and was handed over to the web login.
    @State private var isHandedOverToWeb = false
    /// A web login failure, shown once its sheet is gone.
    @State private var webLoginFailure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Method", selection: $method) {
                        ForEach(LoginMethodChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("login.method")
                }
                switch method {
                case .password: passwordSection
                case .cookie: cookieSection
                case .web: webSection
                }
            }
            .navigationTitle("Log In")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("login.close")
                }
            }
            .disabled(isWorking || environment.isLoggingIn)
            .sheet(isPresented: $isShowingWebLogin, onDismiss: showWebLoginFailure) {
                WebLoginSheet(onFinish: finishWebLogin)
            }
        }
        .alertHost()
        // A login in progress is not left behind a closed sheet: no swipe down.
        .interactiveDismissDisabled(isWorking || environment.isLoggingIn)
        // Signed in: the sheet goes at once, whichever login did it (the web login's end closes it once more, see
        // `finishWebLogin`); the forum profile page is read behind it, by the environment (the name and avatar follow).
        .onChange(of: environment.isLoggedIn) { _, isLoggedIn in
            if isLoggedIn { dismiss() }
        }
        .onChange(of: method) { _, method in
            if method != .web { isHandedOverToWeb = false }
        }
    }

    // MARK: - Sections

    private var passwordSection: some View {
        Section {
            TextField("Username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("login.username")
            SecureField("Password", text: $password)
                .textContentType(.password)
                .accessibilityIdentifier("login.password")
            submitButton(enabled: !username.isEmpty && !password.isEmpty) {
                try await environment.logIn(username: username, password: password)
            }
        }
    }

    private var cookieSection: some View {
        Section {
            TextField("ipb_member_id", text: $memberID)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("login.memberID")
            TextField("ipb_pass_hash", text: $passHash)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("login.passHash")
            // The system paste button reads the pasteboard without the paste permission prompt.
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first, let credentials = CookieClipboard.parse(text) else { return }
                memberID = credentials.memberID
                passHash = credentials.passHash
            }
            .accessibilityIdentifier("login.paste")
            submitButton(enabled: !memberID.isEmpty && !passHash.isEmpty) {
                try await environment.logIn(memberID: memberID, passHash: passHash)
            }
        }
    }

    private var webSection: some View {
        Section {
            if isHandedOverToWeb {
                Text(LoginFailureMessage.webLoginTakesOver)
                    .accessibilityIdentifier("login.web.handover")
            }
            Text("Log in on the E-Hentai forums page.")
            Button("Open Login Page") { openWebLogin() }
                .disabled(!environment.canUseWebLogin)
                .accessibilityIdentifier("login.web.open")
        } footer: {
            if !environment.canUseWebLogin {
                Text("Web login is temporarily unavailable.")
            }
        }
    }

    private func submitButton(enabled: Bool, login: @escaping @MainActor () async throws -> Void) -> some View {
        Button("Log In") {
            run(login)
        }
        .disabled(!enabled || isWorking)
        .accessibilityIdentifier("login.submit")
    }

    // MARK: - Actions

    /// Runs one login; shows the failure when it failed (signed in, the sheet closes by `isLoggedIn`). A password
    /// login that met a check only the visible page can do goes on in the web login (when it can be used): nothing of
    /// the username or password is carried into the page. A login refused because another one runs, or one logging out
    /// replaced, ends silently.
    private func run(_ login: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await login()
                isWorking = false
            } catch WebPasswordLoginError.needsWebLogin where environment.canUseWebLogin {
                isWorking = false
                method = .web
                isHandedOverToWeb = true
                openWebLogin()
            } catch {
                isWorking = false
                showFailure(error)
            }
        }
    }

    /// Prepares the login (the cookie store, a clean WebView store), then opens the page.
    private func openWebLogin() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await environment.prepareLogin()
                isShowingWebLogin = true
            } catch {
                showFailure(error)
            }
        }
    }

    /// Signed in, the web login's sheet goes, and the login sheet with it.
    private func finishWebLogin(_ result: Result<Void, any Error>) {
        switch result {
        case .success:
            isShowingWebLogin = false
            // `onChange(of: isLoggedIn)` already calls `dismiss()`, but while the web login's sheet is still shown
            // above this one; whether SwiftUI then closes both has not been tried on a device.
            // Once more here, with the web sheet going, so the login sheet cannot stay open on a signed-in app. A
            // second `dismiss()` of a sheet that is already going does nothing, and this one cannot come late and
            // close a sheet opened afterwards: `completeWebLogin` returns without waiting for the forum profile page.
            if environment.isLoggedIn { dismiss() }
        case .failure(let error):
            webLoginFailure = LoginFailureMessage.text(for: error)
            isShowingWebLogin = false
        }
    }

    private func showWebLoginFailure() {
        guard let webLoginFailure else { return }
        self.webLoginFailure = nil
        environment.alerts.present(LoginFailureMessage.alert(message: webLoginFailure))
    }

    /// The `Login Failed` alert for `error`, through the app's alerts: the host on this sheet shows it, in turn with
    /// any other alert (a link that cannot be opened, a site setting question), never over one. None for a login that
    /// was refused or replaced (`LoginFailureMessage.text(for:)` is nil).
    private func showFailure(_ error: any Error) {
        guard let alert = LoginFailureMessage.alert(for: error) else { return }
        environment.alerts.present(alert)
    }
}
