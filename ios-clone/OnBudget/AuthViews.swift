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
            // Logo 72pt / wordmark 30pt (owner, Nov 12, 2026): the
            // sign-in header sat in a lot of empty space — the bump
            // fills it without crowding the fields. Same centered
            // layout and spacing as before.
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(Circle())
            Text("OnBudget")
                .font(.system(size: 30, weight: .bold))
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
            // Privacy / Terms look like links now (owner, Nov 12,
            // 2026): brand blue + underlined, like "Forgot
            // Password?" — the grey text did not read as tappable.
            HStack(spacing: 4) {
                Link("Privacy", destination: URL(string: "https://ycfried.github.io/Budget/privacy.html")!)
                    .foregroundStyle(DesignTokens.primary)
                    .underline()
                Text("·")
                Link("Terms", destination: URL(string: "https://ycfried.github.io/Budget/terms.html")!)
                    .foregroundStyle(DesignTokens.primary)
                    .underline()
            }
            .padding(.top, 8)
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

    public init(appState: AppViewModel) {
        self.appState = appState
        // Remember me (owner, Nov 12, 2026): the sign-in screen
        // opens with the saved email already filled in, so the
        // first frame never shows an empty Email field. Setting it
        // here (rather than in onAppear) also means no programmatic
        // change fires the email onChange that clears the message —
        // a boot-time offline notice set in onAppear survives.
        _email = State(initialValue: RememberedEmail().load() ?? "")
    }

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
            ForgotPasswordSheet(email: email)
                // iPad width (owner, Nov 12, 2026): same treatment
                // as the Weekly Budget sheet — a plain .sheet is a
                // narrow form sheet on iPad and the content floated
                // in dead space. .fitted hugs the content height.
                .presentationSizing(.fitted)
        }
        .onAppear {
            // Sign-out lands here fresh: password and message
            // cleared, sign-in panel (never stranded on the name
            // step). The email is NOT cleared here — it was already
            // pre-filled from Remember me in init (owner, Nov 12,
            // 2026), and setting it again in onAppear would fire
            // the email onChange and wipe the offline notice below.
            if appState.phase == .auth && !showNameStep {
                password = ""
                message = nil
            }
            // A boot-time offline notice (audit F-P1-2) shows once,
            // in the same box as any other sign-in message.
            if let notice = appState.authNotice {
                message = notice
                messageIsError = true
                appState.authNotice = nil
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
            HStack(spacing: 12) {
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
                // Eye icon, not "Show"/"Hide" text (owner, Nov 12,
                // 2026). The 12pt spacing keeps it clear of the
                // biometric icon next to it. 44pt hit area (audit
                // A-P2-8): the icon stays 18pt, the tappable frame
                // is 44pt.
                Button { showPassword.toggle() } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.system(size: 18))
                        .foregroundStyle(DesignTokens.primary)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
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
                    // 44pt hit area (audit A-P2-8): the icon stays
                    // 20pt, the tappable frame is 44pt.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel(biometricUnlockLabel)
                    .disabled(busy != nil)
                }
            }
            .padding(12)
            .background(.white)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let message {
                if messageIsError { DismissableErrorBox(message) { self.message = nil } } else { InfoBox(message) }
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

            // Remember me (owner, Nov 12, 2026): the row shows
            // ALWAYS — the Nov 12 hide-when-biometrics-on rule is
            // reversed. The owner was at the sign-in screen with
            // biometrics available and still faced an empty Email
            // field, so the hidden row did not help him. Ticked
            // (the default) keeps the session across launches AND
            // saves the email locally so the sign-in screen
            // pre-fills it; unticked signs in into memory only, so
            // closing the app signs the user out, and clears any
            // saved email immediately. The checkbox is ONE rounded
            // square (the app's squarish style), the whole row is
            // the tap target.
            Button {
                rememberMe.toggle()
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(rememberMe ? DesignTokens.primary : .white)
                            .frame(width: 22, height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        rememberMe ? DesignTokens.primary : Color(hex: "#9ca3af"),
                                        lineWidth: 1.5
                                    )
                            )
                        if rememberMe {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    Text("Remember me")
                        .font(.system(size: 15))
                        .foregroundStyle(DesignTokens.ink)
                }
            }
            .accessibilityIdentifier("auth.rememberMe")
            .padding(.top, 4)
            // Toggling writes the remembered email right away:
            // unticking clears it immediately (not just "stop
            // saving"), re-ticking saves whatever is typed so a
            // later sign-out still pre-fills. The sign-in itself
            // saves again on success (see signIn()).
            .onChange(of: rememberMe) { _, ticked in
                if ticked {
                    if !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        RememberedEmail().save(email)
                    }
                } else {
                    RememberedEmail().clear()
                }
            }

            // Forgot password (owner, Nov 12, 2026): always opens
            // the dedicated screen — it never sends the email
            // straight from here. The sheet has the email field and
            // the Reset Password button; the email goes out only
            // when the user presses it.
            Button("Forgot Password?") {
                showForgotSheet = true
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
        // A failed sign-in message leaves when the user starts
        // fixing the fields (owner rule, Nov 11 2026 — error
        // messages must not stay for good).
        .onChange(of: email) { message = nil }
        .onChange(of: password) { message = nil }
    }

    private var nameStep: some View {
        NameStepView(
            email: email,
            password: password,
            onBack: { showNameStep = false; message = nil },
            onCreated: {
                // Account created and signed in: remember the email
                // exactly as a password sign-in would (owner, Nov 12,
                // 2026) — the next sign-in screen pre-fills it.
                // (With email confirmation ON, this does not run at
                // creation; the email is saved at the sign-in after
                // confirming instead.)
                if rememberMe {
                    RememberedEmail().save(email)
                } else {
                    RememberedEmail().clear()
                }
                Task { await appState.boot() }
            }
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
            // Remember me (owner, Nov 12, 2026): a successful
            // sign-in remembers the email for the next sign-in
            // screen when ticked — even with biometrics on, where
            // the session store is left alone above. Unticked
            // clears any saved email (the toggle already cleared
            // it; this covers a sign-in that never toggled).
            if rememberMe {
                RememberedEmail().save(email)
            } else {
                RememberedEmail().clear()
            }
            // No "Signed in." message: boot() changes phase
            // immediately, so it was never rendered (audit F-P2-13).
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
                // Audit A-P2-7: show the sanitised displayMessage,
                // never raw transport text. Audit A-P2-9: an
                // unconfirmed email names the next step — GoTrue
                // answers "Email not confirmed" with no guidance.
                // There is no in-app resend (verified: no resend
                // path exists in the native code), so the step is
                // to check the inbox for the confirmation link.
                let text = error.displayMessage
                if text.lowercased().contains("not confirmed") {
                    message = "Email not confirmed. Check your inbox for the confirmation link, then sign in again."
                } else {
                    message = text
                }
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
}

// MARK: - Create-account name step

/// "Choose Your Name" (live.js:2440-2530). The name is stored as
/// auth metadata `full_name` at sign-up time, never as a separate
/// call. Email confirmation is ON in the live project (owner, Nov 12,
/// 2026), so sign-up returns `.needsConfirmation` and this step shows
/// the persistent "check your email" state instead of a toast.
public struct NameStepView: View {
    let email: String
    let password: String
    let onBack: () -> Void
    let onCreated: () -> Void

    @EnvironmentObject private var appState: AppViewModel
    @State private var name = ""
    @State private var message: String?
    @State private var busy = false
    /// Set when sign-up returns `.needsConfirmation` (owner, Nov 12,
    /// 2026: confirmations are ON). The step then shows the persistent
    /// "check your email" state instead of a toast that vanishes in
    /// 4s (audit F-P2-10) — the user must see it until they act.
    @State private var confirmationSent = false

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
            if confirmationSent {
                Text("Check Your Email")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                // Inline success is GREEN (owner decision, Nov 12,
                // 2026), like the success toasts — not the blue InfoBox.
                SuccessBox("Account created. Check your email to confirm it, then sign in.")
                Text("The confirmation link opens the OnBudget app. If it doesn't open, tap it on the iPhone or iPad where OnBudget is installed — the email is confirmed either way, then just sign in.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#6b7280"))
                Button("Back to Sign In") { onBack() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("auth.backToSignIn")
            } else {
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
                    .onChange(of: name) { message = nil }
                if let message { DismissableErrorBox(message) { self.message = nil } }
                Button(busy ? "Creating Account…" : "Create Account") { Task { await createAccount() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("auth.createAccountConfirm")
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
                fullName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                redirectTo: AppDeepLinks.emailConfirmed)
            busy = false
            switch outcome {
            case .signedIn:
                onCreated()
            case .needsConfirmation:
                // Persistent inline state (owner, Nov 12, 2026): the
                // user stays on this step until they act — no toast,
                // no jump back to sign-in. The confirmation link
                // opens the app via onbudget://email-confirmed.
                confirmationSent = true
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

/// Dedicated forgot-password screen (owner, Nov 12, 2026): Email
/// input + "Send Reset Link". The email goes out ONLY when the user
/// presses the button — tapping "Forgot Password?" on sign-in never
/// sends anything by itself. After sending, the sheet stays open on
/// a confirmation state ("Check Your Email") with Done + Send Again,
/// instead of dismissing into a toast (live.js:2399-2410: 3-step
/// message, generic wording either way).
public struct ForgotPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var email: String
    @State private var message: String?
    @State private var busy = false
    /// Set on a successful send: the sheet swaps the form for the
    /// confirmation state and stays open until the user taps Done.
    @State private var sent = false
    @State private var sentEmail = ""

    public init(email: String) {
        self._email = State(initialValue: email)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(sent ? "Done" : "Cancel") { dismiss() }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DesignTokens.mid)
                    .disabled(busy)
                Spacer()
                Text("Forgot Password?")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Color.clear.frame(width: 50)
            }
            if sent {
                Text("Check Your Email")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                InfoBox("If an account exists for \(sentEmail), a password-reset link was sent to it.")
                Text("Check your inbox (and spam folder) for the link. The link opens the OnBudget app, where you choose a new password. If the link has expired, send a fresh one from here.")
                    .font(.system(size: 15))
                    .foregroundStyle(DesignTokens.ink)
                // Audit A-P2-10: the error box sits above the
                // buttons, like everywhere else — not below them.
                if let message { DismissableErrorBox(message) { self.message = nil } }
                HStack(spacing: 12) {
                    Button("Done") { dismiss() }
                        .buttonStyle(PrimaryButtonStyle())
                    Button(busy ? "Sending…" : "Send Again") { Task { await send() } }
                        .buttonStyle(TertiaryButtonStyle())
                        .disabled(busy)
                }
            } else {
                // Steps as a proper list (owner, Nov 12, 2026):
                // the run-on "Step 1: ... Step 2: ... Step 3: ..."
                // paragraph was hard to scan. One step per line,
                // short; the expired-link note sits below, quiet.
                VStack(alignment: .leading, spacing: 8) {
                    forgotStep(number: 1, text: "Enter the email for your account.")
                    forgotStep(number: 2, text: "Check your inbox for the reset link.")
                    forgotStep(number: 3, text: "Choose a new password on that page, then return here to sign in.")
                }
                Text("If the link has expired, send a fresh one from here.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.muted)
                Text("Email")
                    .font(.system(size: 14, weight: .bold))
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("auth.forgotEmail")
                    .onChange(of: email) { message = nil }
                    .padding(12)
                    .background(.white)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if let message { DismissableErrorBox(message) { self.message = nil } }
                HStack(spacing: 12) {
                    Button(busy ? "Sending…" : "Send Reset Link") { Task { await send() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(busy)
                }
            }
        }
        .padding(20)
        // iPad width (owner, Nov 12, 2026): with
        // .presentationSizing(.fitted) at the presentation site,
        // the sheet sizes to this content — so a fixed 600pt width
        // here actually widens the sheet on iPad (regular size
        // class) instead of the system ~540pt form sheet. On iPhone
        // (compact) no width is fixed and the sheet stays
        // full-width. The trailing Spacer is gone: it stretched
        // the middle empty against the tall form sheet.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
    }

    /// One step row: bold "Step N:" + short text. Used by the
    /// steps list (owner, Nov 12, 2026).
    private func forgotStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Step \(number):")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
        }
    }

    private func send() async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AuthValidation.isValidEmail(trimmed) else {
            message = "Enter a valid email address."
            return
        }
        busy = true
        message = nil
        do {
            try await appState.client.requestPasswordReset(
                email: trimmed, redirectTo: AppDeepLinks.resetPassword)
            busy = false
            sent = true
            sentEmail = trimmed
        } catch let error as OnBudgetError {
            // Audit A-P2-7: the sanitised displayMessage, never raw
            // transport text.
            message = error.displayMessage
            busy = false
        } catch {
            message = "Could not send the reset link. Try again."
            busy = false
        }
    }
}

// MARK: - Reset-password completion (deep link)

/// Native completion of the reset flow (reset.html, verified
/// Nov 9, 2026): heading "Choose a New Password", the "Step 3 of
/// the reset…" intro, "Password requirements: at least 8 characters.
/// Both fields must match.", New Password + Confirm New Password
/// each with an eye-icon toggle (audit A-P2-4), "Save New Password" (full-width
/// primary), Back top-left. Messages are the reset page's exact texts.
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
                    HStack {
                        BackButton {
                            appState.pendingResetCode = nil
                            appState.resetLinkError = nil
                            // Audit A-P1-1: re-validate the stored
                            // session instead of forcing `.auth` — a
                            // signed-in user who opened a stale link
                            // goes back into the app; only a dead
                            // session lands on Auth. (The post-save
                            // path still returns to sign-in: the
                            // password just changed.)
                            Task { await appState.boot() }
                        }
                        .disabled(busy)
                        Spacer()
                    }
                    Text("Choose a New Password")
                        .font(.system(size: 22, weight: .bold))
                    Text("Step 3 of the reset: you asked for a link, checked your inbox, and opened it here. Now choose a new password, then return to sign-in with it. If this link has expired, go back to sign-in and use Forgot password? again for a fresh link.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "#6b7280"))
                    Text("Password requirements: at least 8 characters. Both fields must match.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "#6b7280"))
                    if exchanging {
                        // Labelled spinner (audit A-P2-6): the bare
                        // ProgressView said nothing about what was
                        // happening. Back stays the exit.
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Checking your link…")
                                .font(.system(size: 15))
                                .foregroundStyle(Color(hex: "#6b7280"))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        passwordField(label: "New Password", text: $newPassword, showing: $showNew)
                            .onChange(of: newPassword) { message = nil }
                        passwordField(label: "Confirm New Password", text: $confirmPassword, showing: $showConfirm)
                            .onChange(of: confirmPassword) { message = nil }
                        if let message {
                            // Inline success is GREEN (owner decision,
                            // Nov 12, 2026): "Password saved…" renders
                            // in a SuccessBox, not the blue InfoBox.
                            if messageIsError { DismissableErrorBox(message) { self.message = nil } } else { SuccessBox(message) }
                        }
                        Button(busy ? "Saving…" : "Save New Password") { Task { await save() } }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(busy)
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
                // Eye icon, not "Show"/"Hide" text (audit A-P2-4):
                // the reset fields match the sign-in field. 44pt hit
                // area (audit A-P2-8); the icon stays 18pt.
                Button { showing.wrappedValue.toggle() } label: {
                    Image(systemName: showing.wrappedValue ? "eye.slash" : "eye")
                        .font(.system(size: 18))
                        .foregroundStyle(DesignTokens.primary)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(showing.wrappedValue ? "Hide Password" : "Show Password")
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
            message = "Password saved. You can now sign in with it. Taking you back to sign in…"
            messageIsError = false
            appState.pendingResetCode = nil
            try? await Task.sleep(for: .seconds(2))
            appState.phase = .auth
            // Busy stays on until the phase change (audit F-P2-2):
            // clearing it before the sleep left Save tappable again
            // mid-save. The view unmounts on the phase change.
            busy = false
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
        // Vertical balance (audit A-P2-11): the old Spacer()s sat
        // inside a ScrollView with no height to share, so they
        // collapsed and the content top-packed. Same GeometryReader
        // + minHeight pattern as the sign-in screen: a short screen
        // centers the content, a tall one still scrolls (audit
        // F-P2-6), and large Dynamic Type is not clipped.
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    Spacer(minLength: 0)
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
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(minHeight: geometry.size.height)
            }
            .background(DesignTokens.background)
        }
    }
}
