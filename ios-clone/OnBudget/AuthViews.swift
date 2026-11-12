// OnBudget — AuthViews.swift
//
// Auth screens (CLONE_SPEC §4, live.html:45-74, live.js:2397-2620).
// Top bar: app logo + "OnBudget" brand block, no card heading, no
// subtitle. Footer under the card on both auth screens:
// "Your household budget, shared in one place." / "Bank and email
// are read-only — nothing is ever moved or changed." / "Privacy ·
// Terms" links.
//
// Sign-in: Email + Password (eye toggle inside the field), button
// row Sign In (primary) + Create Account (tertiary), Remember me
// checkbox, then a full-width quiet "Forgot Password?" link.
// Failures stay in the inline soft-red box under the buttons — never
// a toast — in plain language: wrong credentials read "Username or
// password is incorrect." (the server cannot say which field is
// wrong, by design) and no raw status code is ever shown.
// Biometric unlock (owner, Nov 11, 2026): for a returning user who
// opted in, the prompt fires automatically once when the screen
// appears, plus a small Face ID / Touch ID icon in the password row
// as the manual trigger; the old big grey button is gone. Sign-in
// stays email/password. Password AutoFill: the email field is the
// username field (.username) so iOS offers to save the login and to
// fill it in on return.
// Create-account: validates Email + Password ONLY, then moves to
// the separate "Choose Your Name" panel (values survive). Household
// name is REQUIRED at sign-up (owner, Nov 4): no default fallback,
// no "optional" copy. Back sits top-left on every screen, never
// next to the primary button.
// Forgot password: uses the filled Email, else a sheet with the
// 3-step message; the native app passes its own allow-listed deep
// link as redirectTo (AppDeepLinks.resetPassword). Generic wording
// either way — never reveals whether an account exists.
// The reset page itself is the web reset.html flow; the native app
// only handles the deep link + new-password save (ResetPasswordView).
//
// Clone basis: live web v66.

import SwiftUI
import OnBudgetKit

// MARK: - Shared auth chrome

public struct AuthBrandHeader: View {
    public init() {}
    public var body: some View {
        HStack(spacing: 10) {
            // The real logo (Assets.xcassets/AppLogo — the same
            // circular picture the web app uses), not the "S"
            // placeholder ring the clone shipped with (owner, Nov 11,
            // 2026).
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            Text("OnBudget")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
        }
        // Centered as a unit (owner, Nov 11, 2026): the header was
        // left-aligned, which read as shifted-left on a wide screen.
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

public struct AuthFooter: View {
    public init() {}
    public var body: some View {
        VStack(spacing: 4) {
            Text("Your household budget, shared in one place.")
            Text("Bank and email are read-only — nothing is ever moved or changed.")
            HStack(spacing: 4) {
                Link("Privacy", destination: URL(string: "https://ycfried.github.io/Budget/privacy.html")!)
                Text("·")
                Link("Terms", destination: URL(string: "https://ycfried.github.io/Budget/terms.html")!)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color(hex: "#6b7280"))
        .multilineTextAlignment(.center)
        // Full width so the centered text actually centers on the
        // screen (owner, Nov 11, 2026): the footer was only as wide
        // as its longest line and sat left-aligned.
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sign-in / create-account

public struct AuthView: View {
    @ObservedObject var appState: AppViewModel

    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var busy: String? // label of the running action
    @State private var showNameStep = false
    @State private var showForgotSheet = false
    // Remember me (owner, Nov 11, 2026): ON by default — today's
    // behaviour (the session persists across launches). OFF signs in
    // into memory only, so closing the app signs the user out.
    @State private var rememberMe = true
    // Auto-prompt guard: the biometric prompt fires at most once per
    // appearance of this screen.
    @State private var didAutoPromptBiometrics = false

    public init(appState: AppViewModel) { self.appState = appState }

    public var body: some View {
        // Vertical balance (owner, Nov 11, 2026): the page was
        // bunched at the top with a big empty area below. The content
        // takes at least the full screen height and the spacers share
        // the leftover space, so a short screen centers the content;
        // a tall screen still scrolls normally.
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Spacer(minLength: 0)
                    AuthBrandHeader()
                    if showNameStep {
                        nameStep
                    } else {
                        signInPanel
                    }
                    AuthFooter()
                        .padding(.top, 8)
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(minHeight: geometry.size.height)
            }
            .background(DesignTokens.background)
        }
        .sheet(isPresented: $showForgotSheet) {
            ForgotPasswordSheet(email: email) { result in
                message = result
                messageIsError = false
            }
        }
        .onAppear {
            // Sign-out lands here fresh: fields cleared, sign-in
            // panel (never stranded on the name step).
            if appState.phase == .auth && !showNameStep {
                email = ""
                password = ""
                message = nil
            }
            // Offer Face ID unlock when a protected session exists
            // and biometrics can evaluate.
            appState.refreshBiometricUnlockAvailability()
            // Smarter unlock (owner, Nov 11, 2026): prompt
            // automatically for a returning user who opted in. Safe
            // after an explicit sign-out — sign-out deletes the
            // protected session, so there is nothing to prompt for.
            // Never fires in the UI tests (they never opt in).
            if appState.biometricUnlockAvailable && !didAutoPromptBiometrics {
                didAutoPromptBiometrics = true
                Task { await unlockWithBiometrics() }
            }
        }
    }

    /// "Unlock with Face ID" / "Unlock with Touch ID", from the
    /// enrolled biometry kind.
    private var biometricUnlockLabel: String {
        appState.biometricUnlock.label
    }

    private var signInPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Email")
                .font(.system(size: 14, weight: .bold))
            TextField("Email", text: $email)
                // Password AutoFill (owner, Nov 11, 2026): the email
                // field is the username field, so iOS offers to save
                // the login to the passwords app on sign-in and offers
                // to fill it in on return. The email keyboard stays.
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("auth.email")
                .padding(12)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text("Password")
                .font(.system(size: 14, weight: .bold))
            HStack {
                Group {
                    if showPassword {
                        TextField("Password", text: $password)
                            .accessibilityIdentifier("auth.password")
                    } else {
                        SecureField("Password", text: $password)
                            .accessibilityIdentifier("auth.password")
                    }
                }
                .textContentType(.password)
                Button(showPassword ? "Hide" : "Show") { showPassword.toggle() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
                    .accessibilityLabel(showPassword ? "Hide Password" : "Show Password")
                // Biometric unlock as a small icon in the password
                // row (owner, Nov 11, 2026) — the manual trigger,
                // next to the field it unlocks. Shown only when a
                // protected session exists; the icon follows the
                // hardware (Face ID / Touch ID).
                if appState.biometricUnlockAvailable {
                    Button {
                        Task { await unlockWithBiometrics() }
                    } label: {
                        Image(systemName: appState.biometricUnlock.biometryKind == .touchID ? "touchid" : "faceid")
                            .font(.system(size: 20))
                            .foregroundStyle(DesignTokens.primary)
                    }
                    .accessibilityLabel(biometricUnlockLabel)
                    .disabled(busy != nil)
                }
            }
            .padding(12)
            .background(.white)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let message {
                if messageIsError { ErrorBox(message) } else { InfoBox(message) }
            }

            // Two-button rule: primary first, grey tertiary second.
            HStack(spacing: 12) {
                Button(busy == "signIn" ? "Signing in…" : "Sign In") { Task { await signIn() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("auth.signIn")
                    .disabled(busy != nil)
                Button("Create Account") { createAccountTapped() }
                    .buttonStyle(TertiaryButtonStyle())
                    .accessibilityIdentifier("auth.createAccount")
                    .disabled(busy != nil)
            }

            // Remember me (owner, Nov 11, 2026): ticked (the
            // default) keeps the session across launches; unticked
            // signs in into memory only, so closing the app signs
            // the user out. When biometric unlock is on, the session
            // is already kept for that — the box is checked and
            // disabled rather than pretending to control it.
            Button {
                rememberMe.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: rememberMeEffective ? "checkmark.square.fill" : "square")
                        .font(.system(size: 18))
                        .foregroundStyle(rememberMeDisabled ? Color(hex: "#9ca3af") : DesignTokens.primary)
                    Text("Remember me")
                        .font(.system(size: 15))
                        .foregroundStyle(DesignTokens.ink)
                }
            }
            .disabled(rememberMeDisabled)
            .accessibilityIdentifier("auth.rememberMe")
            .padding(.top, 4)
            if rememberMeDisabled {
                Text("Biometric unlock is on — it keeps you signed in.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }

            Button("Forgot Password?") {
                if AuthValidation.isValidEmail(email) {
                    Task { await sendReset(email: email) }
                } else {
                    showForgotSheet = true
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DesignTokens.primary)
            .underline()
            .frame(maxWidth: .infinity)
            .padding(.top, 4)

            // The big "Unlock with Touch ID" button is gone (owner,
            // Nov 11, 2026): biometric unlock is now the auto-prompt
            // on open plus the icon in the password row above.
        }
    }

    /// The effective Remember-me state: biometric unlock implies a
    /// kept session, so the box reads checked while it is on.
    private var rememberMeEffective: Bool {
        rememberMe || appState.biometricUnlockAvailable
    }

    /// Biometric unlock already keeps the session — the box must not
    /// pretend to control that.
    private var rememberMeDisabled: Bool {
        appState.biometricUnlockAvailable
    }

    private var nameStep: some View {
        NameStepView(
            email: email,
            password: password,
            onBack: { showNameStep = false; message = nil },
            onCreated: { Task { await appState.boot() } }
        )
    }

    // MARK: Actions

    /// Face ID unlock: on success boot into the app; on cancel stay
    /// silent on the password screen; on failure show the message in
    /// the inline error box (the password screen is the fallback).
    private func unlockWithBiometrics() async {
        busy = "faceID"
        message = nil
        switch await appState.unlockWithBiometrics() {
        case .unlocked:
            busy = nil
            await appState.boot()
        case .cancelled:
            busy = nil
        case .failed(let text):
            message = text
            messageIsError = true
            busy = nil
        }
    }

    private func signIn() async {
        if let error = AuthValidation.signInError(email: email, password: password) {
            message = error
            messageIsError = true
            return
        }
        busy = "signIn"
        message = nil
        // Remember me: pick the session store BEFORE signing in, so
        // the session lands in the right place. Unticked signs in
        // into memory only (InMemorySessionStore) — closing the app
        // signs the user out. When biometric unlock is on, the
        // protected Keychain session already keeps the user signed
        // in — never swap that store away.
        if !appState.biometricUnlockAvailable {
            appState.client.replaceSessionStore(
                rememberMe ? UserDefaultsSessionStore() : InMemorySessionStore())
        }
        do {
            _ = try await appState.client.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password)
            message = "Signed in."
            messageIsError = false
            busy = nil
            await appState.boot()
        } catch let error as OnBudgetError {
            if case .invalidCredentials = error {
                // Per-field wording (owner, Nov 11, 2026): the check
                // says which field was wrong. If the check itself
                // fails, keep the generic message — never guess.
                let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
                let exists = try? await appState.client.functions.checkEmailExists(email: trimmed)
                message = SignInErrorMessage.invalidCredentials(emailExists: exists)
            } else {
                message = error.userMessage
            }
            messageIsError = true
            busy = nil
        } catch {
            // A non-OnBudgetError here cannot be a credential failure
            // (those arrive as OnBudgetError via fromAuthResponse) —
            // never blame the password for a transport surprise.
            message = "Could not sign in. Try again."
            messageIsError = true
            busy = nil
        }
    }

    private func createAccountTapped() {
        if let error = AuthValidation.createAccountError(email: email, password: password) {
            message = error
            messageIsError = true
            return
        }
        message = nil
        showNameStep = true
    }

    private func sendReset(email: String) async {
        do {
            try await appState.client.requestPasswordReset(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                redirectTo: AppDeepLinks.resetPassword)
            message = "If an account exists for that email, a password-reset link was sent to it."
            messageIsError = false
        } catch let error as OnBudgetError {
            message = error.userMessage
            messageIsError = true
        } catch {
            message = "Could not send the reset link. Try again."
            messageIsError = true
        }
    }
}

// MARK: - Create-account name step

/// "Choose Your Name" (live.js:2440-2530). The name is stored as
/// auth metadata `full_name` at sign-up time, never as a separate
/// call. Email confirmation is OFF in the live project, so sign-up
/// normally returns a session immediately; `.needsConfirmation`
/// covers the setting being turned back on.
public struct NameStepView: View {
    let email: String
    let password: String
    let onBack: () -> Void
    let onCreated: () -> Void

    @EnvironmentObject private var appState: AppViewModel
    @State private var name = ""
    @State private var message: String?
    @State private var busy = false

    public init(email: String, password: String, onBack: @escaping () -> Void, onCreated: @escaping () -> Void) {
        self.email = email
        self.password = password
        self.onBack = onBack
        self.onCreated = onCreated
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Back goes top-left, same place on every screen (owner,
            // Nov 11, 2026) — never squeezed next to the primary
            // button at the bottom.
            HStack {
                BackButton(action: onBack)
                Spacer()
            }
            Text("Choose Your Name")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            Text("Name")
                .font(.system(size: 14, weight: .bold))
            TextField("Name", text: $name)
                .textContentType(.name)
                .accessibilityIdentifier("auth.name")
                .padding(12)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if let message { ErrorBox(message) }
            Button(busy ? "Creating account…" : "Create Account") { Task { await createAccount() } }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("auth.createAccountConfirm")
                .disabled(busy)
        }
    }

    private func createAccount() async {
        if let error = AuthValidation.accountNameError(name) {
            message = error
            return
        }
        busy = true
        message = nil
        do {
            let outcome = try await appState.client.signUp(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                fullName: name.trimmingCharacters(in: .whitespacesAndNewlines))
            busy = false
            switch outcome {
            case .signedIn:
                onCreated()
            case .needsConfirmation:
                // The message is shown by the caller via toast; the
                // user then signs in after confirming email.
                appState.showToast(
                    "Account created. If email confirmation is on in Auth settings, confirm the email first, then sign in.",
                    kind: .info)
                appState.phase = .auth
            }
        } catch let error as OnBudgetError {
            // The server's already-registered error surfaces HERE, at
            // the name step — the earliest point it can be known (the
            // sign-in card's Create Account button makes no server
            // call, same as the web; there is no email-existence
            // check to call). Name the problem and point at sign-in
            // (owner, Nov 11, 2026); other failures stay generic.
            if error.userMessage.lowercased().contains("already registered") {
                message = "An account already exists for this email. Sign in instead."
            } else {
                message = "Could not create the account. Try again."
            }
            busy = false
        } catch {
            message = "Could not create the account. Try again."
            busy = false
        }
    }
}

// MARK: - Forgot password sheet

/// Sheet (live.js:2399-2410): 3-step message, Email input, Confirm
/// "Send Reset Link", Cancel as the top text link (never a button
/// in the row — §2.3). Generic wording either way.
public struct ForgotPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppViewModel
    @State private var email: String
    @State private var message: String?
    @State private var busy = false
    let onSent: (String) -> Void

    public init(email: String, onSent: @escaping (String) -> Void) {
        self._email = State(initialValue: email)
        self.onSent = onSent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
                Spacer()
                Text("Forgot Password?")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Color.clear.frame(width: 50)
            }
            Text("Step 1: enter the email for your account. Step 2: check your inbox for the reset link. Step 3: choose a new password on that page, then return here to sign in. If the link has expired, send a fresh one from here.")
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            Text("Email")
                .font(.system(size: 14, weight: .bold))
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if let message { ErrorBox(message) }
            HStack(spacing: 12) {
                Button(busy ? "Sending…" : "Send Reset Link") { Task { await send() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy)
            }
            Spacer()
        }
        .padding(20)
    }

    private func send() async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AuthValidation.isValidEmail(trimmed) else {
            message = "Enter a valid email address."
            return
        }
        busy = true
        do {
            try await appState.client.requestPasswordReset(
                email: trimmed, redirectTo: AppDeepLinks.resetPassword)
            busy = false
            let text = "If an account exists for that email, a password-reset link was sent to it."
            onSent(text)
            dismiss()
        } catch let error as OnBudgetError {
            message = error.userMessage
            busy = false
        } catch {
            message = "Could not send the reset link. Try again."
            busy = false
        }
    }
}

// MARK: - Reset-password completion (deep link)

/// Native completion of the reset flow (reset.html, verified
/// Nov 9, 2026): heading "Reset Your Password", "Password
/// requirements: at least 8 characters.", New Password + Confirm
/// New Password each with a Show/Hide toggle, "Save New Password"
/// (full-width primary), "Back to Sign In" link. Messages are the
/// reset page's exact texts.
public struct ResetPasswordView: View {
    @EnvironmentObject private var appState: AppViewModel
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var showNew = false
    @State private var showConfirm = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var busy = false
    @State private var exchanging = true

    public init() {}

    public var body: some View {
        // Same vertical balance as the sign-in screen (owner, Nov 11,
        // 2026): centered when the content fits, scrolling when tall.
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Spacer(minLength: 0)
                    AuthBrandHeader()
                    Text("Reset Your Password")
                        .font(.system(size: 22, weight: .bold))
                    Text("Password requirements: at least 8 characters.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "#6b7280"))
                    if exchanging {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        passwordField(label: "New Password", text: $newPassword, showing: $showNew)
                        passwordField(label: "Confirm New Password", text: $confirmPassword, showing: $showConfirm)
                        if let message {
                            if messageIsError { ErrorBox(message) } else { InfoBox(message) }
                        }
                        Button(busy ? "Saving…" : "Save New Password") { Task { await save() } }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(busy)
                        Button("Back to Sign In") {
                            appState.pendingResetCode = nil
                            appState.resetLinkError = nil
                            appState.phase = .auth
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                    AuthFooter()
                        .padding(.top, 8)
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(minHeight: geometry.size.height)
            }
            .background(DesignTokens.background)
        }
        .task {
            // Exchange the code (or adopt the fragment session);
            // a bad code shows the reset page's exact message.
            if let error = appState.resetLinkError {
                message = error
                messageIsError = true
                exchanging = false
                return
            }
            let ok = await appState.exchangeResetCode()
            if !ok {
                message = appState.resetLinkError
                    ?? "This reset link could not be used. Request a new one from the sign-in screen."
                messageIsError = true
            }
            exchanging = false
        }
    }

    private func passwordField(label: String, text: Binding<String>, showing: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 14, weight: .bold))
            HStack {
                Group {
                    if showing.wrappedValue {
                        TextField(label, text: text)
                    } else {
                        SecureField(label, text: text)
                    }
                }
                .textContentType(.newPassword)
                Button(showing.wrappedValue ? "Hide" : "Show") { showing.wrappedValue.toggle() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
            }
            .padding(12)
            .background(.white)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func save() async {
        if let error = AuthValidation.newPasswordError(password: newPassword, confirm: confirmPassword) {
            message = error
            messageIsError = true
            return
        }
        busy = true
        do {
            try await appState.client.changePassword(newPassword)
            busy = false
            message = "Password saved. You can now sign in with it. Taking you back to sign in…"
            messageIsError = false
            appState.pendingResetCode = nil
            try? await Task.sleep(for: .seconds(2))
            appState.phase = .auth
        } catch {
            message = "Could not save the new password. The link may have expired — request a new one from the sign-in screen."
            messageIsError = true
            busy = false
        }
    }
}

// MARK: - Session expired

/// "Your sign-in expired" + Sign In Again (live.js tx-list auth
/// failure; OnBudgetError.sessionExpired).
public struct SessionExpiredView: View {
    @ObservedObject var appState: AppViewModel
    public init(appState: AppViewModel) { self.appState = appState }
    public var body: some View {
        VStack(spacing: 16) {
            AuthBrandHeader()
            Spacer()
            Text("Your Sign-In Expired")
                .font(.system(size: 22, weight: .bold))
            Text("Sign in again to see your household.")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "#6b7280"))
            Button("Sign In Again") { appState.signInAgain() }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 320)
            Spacer()
            AuthFooter()
        }
        .padding(20)
        .background(DesignTokens.background)
    }
}
