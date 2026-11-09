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
// row Sign In (primary) + Create Account (tertiary), then a
// full-width quiet "Forgot Password?" link. Failures stay in the
// inline soft-red box under the buttons — never a toast.
// Create-account: validates Email + Password ONLY, then moves to
// the separate "Choose Your Name" panel (values survive). Household
// name is REQUIRED at sign-up (owner, Nov 4): no default fallback,
// no "optional" copy.
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
            ZStack {
                Circle()
                    .stroke(DesignTokens.primary, lineWidth: 2)
                    .frame(width: 40, height: 40)
                Text("S")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(DesignTokens.primary)
            }
            Text("OnBudget")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    public init(appState: AppViewModel) { self.appState = appState }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AuthBrandHeader()
                if showNameStep {
                    nameStep
                } else {
                    signInPanel
                }
                AuthFooter()
                    .padding(.top, 8)
            }
            .padding(20)
        }
        .background(DesignTokens.background)
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
        }
    }

    private var signInPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Text("Password")
                .font(.system(size: 14, weight: .bold))
            HStack {
                Group {
                    if showPassword {
                        TextField("Password", text: $password)
                    } else {
                        SecureField("Password", text: $password)
                    }
                }
                .textContentType(.password)
                Button(showPassword ? "Hide" : "Show") { showPassword.toggle() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
                    .accessibilityLabel(showPassword ? "Hide Password" : "Show Password")
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
                    .disabled(busy != nil)
                Button("Create Account") { createAccountTapped() }
                    .buttonStyle(TertiaryButtonStyle())
                    .disabled(busy != nil)
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
        }
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

    private func signIn() async {
        if let error = AuthValidation.signInError(email: email, password: password) {
            message = error
            messageIsError = true
            return
        }
        busy = "signIn"
        message = nil
        do {
            _ = try await appState.client.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password)
            message = "Signed in."
            messageIsError = false
            busy = nil
            await appState.boot()
        } catch let error as OnBudgetError {
            // Deliberately generic: never says which field was wrong.
            message = error.userMessage
            messageIsError = true
            busy = nil
        } catch {
            message = "Incorrect email or password"
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
            Text("Choose Your Name")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            Text("Name")
                .font(.system(size: 14, weight: .bold))
            TextField("Name", text: $name)
                .textContentType(.name)
                .padding(12)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if let message { ErrorBox(message) }
            HStack(spacing: 12) {
                BackButton(action: onBack)
                Button(busy ? "Creating account…" : "Create Account") { Task { await createAccount() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy)
            }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
            }
            .padding(20)
        }
        .background(DesignTokens.background)
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
