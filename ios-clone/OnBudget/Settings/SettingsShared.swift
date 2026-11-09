// OnBudget — Settings shared UI (Settings workstream, live web v66).
//
// Shared context, toast, button styles, cards, and the bank-logo view
// used by every Settings / Past Weeks / Activity / CSV screen.
// Design rules (owner): palette #2f6bff/#1d4ed8/#3b82f6/#60a5fa/
// #bfdbfe/white/#0f172a; Title Case headings + button labels; two-
// button rows = primary blue first + grey tertiary second; pale
// #bfdbfe ONLY as the middle tier of a three-button row; no two
// adjacent buttons share a colour/treatment; errors soft red
// (bg #fef2f2, text #dc2626, border #fecaca); success/info toasts
// brand blue, bottom only, auto-dismiss 4s; cards/fields sized to
// what is necessary and comfortable; no explainer sentence where a
// title already says it.

import SwiftUI
import UIKit
import OnBudgetKit

// MARK: - Context

/// Everything a Settings-family screen needs, handed in by the app
/// coordinator (Auth/Home own the session + household loading).
/// Views never fetch the session themselves and never touch the real
/// household unless the coordinator passes it in.
struct SettingsContext {
    let client: SupabaseClient
    let householdId: UUID
    let isAdmin: Bool
    let currentUserId: UUID?
    let displayName: String?
    let email: String?
    let householdName: String?

    /// Called after a successful sign-out (Profile menu / Settings).
    var onSignOut: () -> Void
    /// Called after a successful account deletion, with the message
    /// the auth screen should show ("Your account was deleted.").
    var onAccountDeleted: (String) -> Void
    /// Called when a Past Week is tapped: the Transactions agent
    /// opens Transactions filtered to that Sun–Sat week.
    var onShowWeekTransactions: (String) -> Void
    /// Called from Budget when the owner taps Temporary Allowance.
    /// The Temporary Allowance box itself is owned by the Funds
    /// agent — Settings only links to it. Nil hides the link.
    var onOpenTemporaryAllowance: (() -> Void)?
    /// Best-effort push-token unregister (APNS_DESIGN §3: fire-and-
    /// forget on sign-out / account deletion). Nil = no token store
    /// wired yet; deletion still proceeds.
    var unregisterPushToken: (() async -> Void)?

    init(
        client: SupabaseClient,
        householdId: UUID,
        isAdmin: Bool,
        currentUserId: UUID? = nil,
        displayName: String? = nil,
        email: String? = nil,
        householdName: String? = nil,
        onSignOut: @escaping () -> Void = {},
        onAccountDeleted: @escaping (String) -> Void = { _ in },
        onShowWeekTransactions: @escaping (String) -> Void = { _ in },
        onOpenTemporaryAllowance: (() -> Void)? = nil,
        unregisterPushToken: (() async -> Void)? = nil
    ) {
        self.client = client
        self.householdId = householdId
        self.isAdmin = isAdmin
        self.currentUserId = currentUserId
        self.displayName = displayName
        self.email = email
        self.householdName = householdName
        self.onSignOut = onSignOut
        self.onAccountDeleted = onAccountDeleted
        self.onShowWeekTransactions = onShowWeekTransactions
        self.onOpenTemporaryAllowance = onOpenTemporaryAllowance
        self.unregisterPushToken = unregisterPushToken
    }
}

// MARK: - Errors

/// The exact text a screen should show for a backend failure: the
/// server's own text, unchanged, for `OnBudgetError`.
func settingsErrorMessage(_ error: Error) -> String {
    if let budgetError = error as? OnBudgetError { return budgetError.userMessage }
    return error.localizedDescription
}

// MARK: - Toast

/// Bottom-only toast state. Success/info render brand blue, errors
/// soft red. Auto-dismisses after 4s (spec §2.3); tap dismisses
/// sooner. One toast at a time — a new toast replaces the old one.
@MainActor
final class ToastState: ObservableObject {
    @Published var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, kind: ToastStyle.Kind = .info) {
        dismissTask?.cancel()
        current = Toast(message: message, kind: kind)
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            current = nil
        }
    }

    func showError(_ message: String) { show(message, kind: .error) }
    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

struct ToastBanner: View {
    let toast: Toast

    var body: some View {
        Text(toast.message)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(
                toast.kind == .error ? DesignTokens.errorText : .white
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                toast.kind == .error ? DesignTokens.errorBackground : DesignTokens.primary
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        toast.kind == .error ? DesignTokens.errorBorder : Color.clear,
                        lineWidth: 1
                    )
            )
            .cornerRadius(12)
            .padding(.horizontal, 16)
            .padding(.bottom, 120)
    }
}

extension View {
    /// Bottom toast overlay, floating clear of the tab bar.
    func toastOverlay(_ toastState: ToastState) -> some View {
        ZStack(alignment: .bottom) {
            self
            if let toast = toastState.current {
                ToastBanner(toast: toast)
                    .onTapGesture { toastState.dismiss() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastState.current?.id)
    }
}

// MARK: - Buttons

/// Primary: #2f6bff fill, white text.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(DesignTokens.primary)
            .cornerRadius(14)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

/// Grey tertiary: #e5e7eb fill, ink text. Second button in a
/// two-button row.
struct TertiaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(DesignTokens.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(Color(hex: "#e5e7eb"))
            .cornerRadius(14)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

/// Pale: #bfdbfe fill, ink text. ONLY the middle tier of a
/// three-button row — never beside another pale button.
struct PaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(DesignTokens.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(DesignTokens.pale)
            .cornerRadius(14)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

/// Danger: soft-red treatment — bg #fef2f2, text #dc2626.
/// Never a solid red button.
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(DesignTokens.errorText)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(DesignTokens.errorBackground)
            .cornerRadius(14)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

/// Small danger button (member Remove, per-account Disconnect).
struct SmallDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(DesignTokens.errorText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DesignTokens.errorBackground)
            .cornerRadius(10)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

/// Quiet small button (nickname edit). No background, muted text.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(Color(hex: "#6b7280"))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

/// Back link: light blue #3b82f6, bold, no background, no border.
/// Text is always "← Back".
struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("← Back")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(DesignTokens.mid)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cards, fields, messages

/// White card, radius 20, light shadow (styles.css:388).
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TitleCase.apply(to: title))
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(DesignTokens.ink)
            content
        }
        .padding(16)
        .background(.white)
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

/// Soft-red inline error box (bg #fef2f2, text #dc2626,
/// border #fecaca).
struct ErrorBox: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(DesignTokens.errorText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(DesignTokens.errorBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DesignTokens.errorBorder, lineWidth: 1)
            )
            .cornerRadius(12)
    }
}

/// Muted small line (secondary labels, #6b7280).
struct MutedLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color(hex: "#6b7280"))
    }
}

/// A labelled field, sized to what it can hold — money inputs are
/// capped, not full-width (owner card-sizing rule).
struct LabeledField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var maxWidth: CGFloat? = nil
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TitleCase.apply(to: label))
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(DesignTokens.ink)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboardType)
                        .textInputAutocapitalization(autocapitalization)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: maxWidth)
        }
    }
}

/// Role pill: "Admin" / "Member".
struct RolePill: View {
    let role: HouseholdRole

    var body: some View {
        Text(role == .admin ? "Admin" : "Member")
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(hex: "#eef4ff"))
            .foregroundStyle(DesignTokens.ink)
            .cornerRadius(999)
    }
}

// MARK: - Bank logo

/// Bank favicon (Google favicon service, sz=128) with a
/// brand-coloured monogram fallback. Never Clearbit (dead Nov 4,
/// 2026). Unmapped banks fall back to a slate monogram tile.
struct BankLogoView: View {
    let institutionName: String?
    var size: CGFloat = 40

    @State private var imageFailed = false

    var body: some View {
        Group {
            if let url = BankBranding.faviconURL(for: institutionName), !imageFailed {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: size, height: size)
                            .cornerRadius(8)
                    default:
                        monogram
                            .onAppear {
                                if case .failure = phase { imageFailed = true }
                            }
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
    }

    private var monogram: some View {
        Text(BankBranding.initial(for: institutionName))
            .font(.headline)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: BankBranding.brandHex(for: institutionName)))
            .cornerRadius(8)
    }
}

// MARK: - Share sheet

/// Native iOS share sheet (UIActivityViewController).
struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
