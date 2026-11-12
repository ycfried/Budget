// OnBudget — Settings: Profile card (live web v66, §10.1).
//
// Display name + email; Save Name + Save Email BOTH primary blue;
// Change Password grey tertiary. Sign-out. Delete Account lives in
// the Account & Household card (MembersSettingsView) per the web,
// where it sits under the members list.
//
// Wiring (exact API calls):
// - Save Name: `SupabaseClient.updateDisplayName(_:)` — auth metadata
//   only (`full_name`), no SQL, no new column.
// - Save Email: `SupabaseClient.updateEmail(_:)` — the sign-in email
//   does NOT change until the new address is confirmed.
// - Change Password: `SupabaseClient.changePassword(_:)` (min 8 chars,
//   checked before the call).
// - Sign Out: `SupabaseClient.signOut()` then `context.onSignOut()`.
// - Delete Account: see MembersSettingsView (two-step confirm,
//   `EdgeFunctionsClient.deleteAccount()`, push-token unregister
//   best-effort, then sign-out + "Your account was deleted.").

import SwiftUI
import OnBudgetKit

@MainActor
final class ProfileSettingsViewModel: ObservableObject {
    @Published var name: String
    @Published var email: String
    /// The new address awaiting confirmation after a successful
    /// Save Email. The sign-in email does NOT change until the new
    /// address is confirmed, so the field keeps showing the pending
    /// address with a persistent "Confirmation pending" note under
    /// it — the user must never mistake it for the current one
    /// (audit S-P2-5). Clears on the next open (fresh view model).
    @Published var pendingEmailConfirmation: String?
    @Published var isSavingName = false
    @Published var isSavingEmail = false
    @Published var isSigningOut = false
    @Published var showChangePassword = false
    @Published var newPassword = ""
    @Published var showNewPassword = false
    @Published var passwordAlert: PasswordAlert?

    /// Persistent inline save error (audit CF-1, Nov 12 2026):
    /// a name/email save failure used to be toast-only, so the
    /// message vanished after 4s before the user could act on it.
    /// The toast still fires; this box ALSO stays on the Profile
    /// card until the next save attempt or a tap dismisses it.
    @Published var saveError: String?

    /// Face ID unlock (native v1, opt-in): shown only when the
    /// device can evaluate biometrics. Hidden entirely on devices
    /// without enrolled biometrics — including the simulator, so the
    /// UI tests' Sign Out button never moves.
    @Published var faceIDAvailable = false
    @Published var faceIDEnabled = false

    /// "Unlock with Face ID" / "Unlock with Touch ID", from the
    /// enrolled biometry kind.
    var faceIDLabel: String { "Unlock with \(faceIDBiometryName)" }
    /// "Face ID" / "Touch ID", for the explainer line.
    var faceIDBiometryName: String {
        biometricUnlock.biometryKind == .touchID ? "Touch ID" : "Face ID"
    }

    enum PasswordAlert: Identifiable {
        case tooShort
        case changed
        case failed

        var id: String {
            switch self {
            case .tooShort: return "tooShort"
            case .changed: return "changed"
            case .failed: return "failed"
            }
        }
    }

    private let context: SettingsContext
    private let toast: ToastState
    private let biometricUnlock: BiometricUnlock

    init(context: SettingsContext, toast: ToastState, biometricUnlock: BiometricUnlock = BiometricUnlock()) {
        self.context = context
        self.toast = toast
        self.biometricUnlock = biometricUnlock
        self.name = context.displayName ?? ""
        self.email = context.email ?? ""
        refreshFaceIDState()
    }

    // MARK: - Face ID unlock

    /// Re-read the toggle state from the Keychain (the source of
    /// truth) and whether biometrics can evaluate. Non-prompting.
    func refreshFaceIDState() {
        faceIDAvailable = biometricUnlock.canEvaluate
        faceIDEnabled = biometricUnlock.isEnabled
    }

    /// Toggle handler. Turning ON evaluates Face ID once, then
    /// moves the live session into the biometric Keychain store;
    /// turning OFF deletes the Keychain item and swaps the client
    /// back to the UserDefaults store (no prompt needed to turn it
    /// off). A failed or cancelled opt-in leaves the toggle off.
    func setFaceID(_ enabled: Bool) async {
        if enabled {
            do {
                try await biometricUnlock.enable(client: context.client)
                toast.show("\(faceIDBiometryName) unlock is on. You can unlock with \(faceIDBiometryName) instead of typing your password.", kind: .success)
            } catch let error as BiometricUnlockError {
                if error == .cancelled {
                    // Silent: the user backed out of the prompt.
                } else {
                    // Audit A-P2-2: the message names the device's
                    // actual biometry kind.
                    toast.showError(error.userMessage(for: biometricUnlock.biometryKind))
                }
            } catch {
                toast.showError("Could not turn on \(faceIDBiometryName) unlock. Try again.")
            }
        } else {
            // Silent when nothing was enabled: flipping the toggle
            // back off after a failed opt-in re-fires this handler,
            // and it must not overwrite the real error toast with an
            // "is off" message.
            guard biometricUnlock.isEnabled else {
                refreshFaceIDState()
                return
            }
            biometricUnlock.disable(client: context.client)
            toast.show("\(faceIDBiometryName) unlock is off. Your saved unlock was removed.", kind: .success)
        }
        refreshFaceIDState()
    }

    // MARK: - Save Name

    func saveName() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast.showError("Enter a name to save.")
            return
        }
        guard !isSavingName else { return }
        saveError = nil
        isSavingName = true
        defer { isSavingName = false }
        do {
            _ = try await context.client.updateDisplayName(trimmed)
            name = trimmed
            toast.show("Name saved — it now shows in your profile.", kind: .success)
        } catch {
            saveError = "Could not save your name. Try again."
            toast.showError("Could not save your name. Try again.")
        }
    }

    // MARK: - Save Email

    func saveEmail() async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OnBudgetKit.MoneyFormat.isValidEmail(trimmed) else {
            toast.showError("Enter a valid email address.")
            return
        }
        if let current = context.email, trimmed == current {
            toast.show("That is already your sign-in email.")
            return
        }
        guard !isSavingEmail else { return }
        saveError = nil
        isSavingEmail = true
        defer { isSavingEmail = false }
        do {
            _ = try await context.client.updateEmail(trimmed)
            pendingEmailConfirmation = trimmed
            toast.show("Confirmation sent to \(trimmed) — your sign-in email stays as it is until you confirm it.", kind: .success)
        } catch {
            saveError = "Could not change your email. Try again."
            toast.showError("Could not change your email. Try again.")
        }
    }

    // MARK: - Change Password

    func submitNewPassword() async {
        guard newPassword.count >= 8 else {
            passwordAlert = .tooShort
            return
        }
        do {
            try await context.client.changePassword(newPassword)
            newPassword = ""
            showChangePassword = false
            passwordAlert = .changed
        } catch {
            passwordAlert = .failed
        }
    }

    // MARK: - Sign Out

    func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        // Best-effort push-token unregister (APNS_DESIGN §3): a
        // failure here must never block signing out.
        if let unregister = context.unregisterPushToken {
            await unregister()
        }
        await context.client.signOut()
        isSigningOut = false
        context.onSignOut()
    }
}

struct ProfileSettingsView: View {
    @StateObject private var viewModel: ProfileSettingsViewModel

    init(context: SettingsContext, toast: ToastState) {
        _viewModel = StateObject(wrappedValue: ProfileSettingsViewModel(context: context, toast: toast))
    }

    var body: some View {
        SettingsCard(title: "Profile") {
            // Persistent save failure (audit CF-1): unlike the
            // toast, this box stays until the next save attempt
            // or a tap dismisses it.
            if let saveError = viewModel.saveError {
                ErrorBox(saveError)
                    .onTapGesture { viewModel.saveError = nil }
            }
            LabeledField(label: "Name", text: $viewModel.name, placeholder: "Your name", autocapitalization: .words)
            Button(viewModel.isSavingName ? "Saving…" : "Save Name") {
                Task { await viewModel.saveName() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.isSavingName)

            LabeledField(label: "Email", text: $viewModel.email, placeholder: "you@example.com", keyboardType: .emailAddress, autocapitalization: .never)
            Button(viewModel.isSavingEmail ? "Saving…" : "Save Email") {
                Task { await viewModel.saveEmail() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.isSavingEmail)
            if let pending = viewModel.pendingEmailConfirmation {
                Text("Confirmation pending — check your inbox to confirm \(pending). Your sign-in email stays as it is until then.")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#6b7280"))
            }

            Text("Password")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(DesignTokens.ink)
                .padding(.top, 4)
            Button("Change Password") {
                viewModel.showChangePassword = true
            }
            .buttonStyle(TertiaryButtonStyle())

            // Face ID unlock (native v1, opt-in, default off): hidden
            // entirely when the device cannot evaluate biometrics
            // (no Face ID/Touch ID enrolled, including the simulator),
            // so the Sign Out button below never moves for the UI
            // tests. Toggling on evaluates Face ID once, then stores
            // the session behind biometrics; toggling off deletes it.
            if viewModel.faceIDAvailable {
                Toggle(viewModel.faceIDLabel, isOn: $viewModel.faceIDEnabled)
                    .accessibilityIdentifier("settings.faceIDToggle")
                    .onChange(of: viewModel.faceIDEnabled) { _, newValue in
                        Task { await viewModel.setFaceID(newValue) }
                    }
                Text("Unlock OnBudget with \(viewModel.faceIDBiometryName) instead of typing your password.")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#6b7280"))
            }

            Button(viewModel.isSigningOut ? "Signing Out…" : "Sign Out") {
                Task { await viewModel.signOut() }
            }
            // Distinct outline treatment — never the same grey
            // tertiary as Change Password above it when the Face ID
            // section is hidden (audit S-P2-6; owner button rule:
            // two adjacent buttons never share a colour/treatment).
            .buttonStyle(OutlineButtonStyle())
            .accessibilityIdentifier("settings.signOut")
            .disabled(viewModel.isSigningOut)
            .padding(.top, 4)
        }
        .sheet(isPresented: $viewModel.showChangePassword) {
            changePasswordSheet
        }
        .alert(item: $viewModel.passwordAlert) { alert in
            switch alert {
            case .tooShort:
                return Alert(
                    title: Text("Password too short"),
                    message: Text("Enter a password of at least 8 characters."),
                    dismissButton: .default(Text("Close"))
                )
            case .changed:
                return Alert(
                    title: Text("Password changed"),
                    message: Text("Your password is updated."),
                    dismissButton: .default(Text("Close"))
                )
            case .failed:
                return Alert(
                    title: Text("Could Not Change Password"),
                    message: Text("Could not change your password. Try again."),
                    dismissButton: .default(Text("Close"))
                )
            }
        }
    }

    private var changePasswordSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Enter a new password for this account. Password requirement: at least 8 characters.")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#6b7280"))
                HStack {
                    Group {
                        if viewModel.showNewPassword {
                            TextField("New password", text: $viewModel.newPassword)
                        } else {
                            SecureField("New password", text: $viewModel.newPassword)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button(viewModel.showNewPassword ? "Hide" : "Show") {
                        viewModel.showNewPassword.toggle()
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                HStack(spacing: 12) {
                    Button("Change Password") {
                        Task { await viewModel.submitNewPassword() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Cancel") {
                        viewModel.newPassword = ""
                        viewModel.showChangePassword = false
                    }
                    .buttonStyle(TertiaryButtonStyle())
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
