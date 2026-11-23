// STAGE — ConfirmationPopup.swift
//
// Confirmation popup (build 64, owner Nov 23, 2026 — C-5).
// Replaces the green/red toast BARS (ToastBanner in SharedViews)
// with a small STAGE-styled confirmation popup: a compact white
// card with a soft shadow, never a full-width bar.
//
//   - Success: brand-blue checkmark in a blue circle + ink message
//     text (e.g. "Saved — Donation recorded · Tzedaka $533.08").
//     Success is BRAND BLUE, not green — this revises the earlier
//     "success GREEN" rule (owner, Nov 11, 2026).
//   - Failure: soft-red tint card + dark red text + red X
//     (e.g. "Couldn't save — try again").
//   - Info: brand-blue info mark + ink message text.
//
// Same behaviour as the toast spec it replaces (owner, Nov 20,
// 2026 — build 50): pops up CENTRED on the screen (build 65,
// owner Nov 23, 2026 — larger text, centred, so it reads as a
// clean confirmation, not a crammed top banner), auto-dismisses
// after 4s (ToastStyle.autoDismissSeconds), tap elsewhere or the
// X closes early, never blocks the user (not a modal).
//
// WHY A SEPARATE FILE: SharedViews.swift owns the old ToastBanner
// / ToastOverlayModifier (another stream owns that file). This file
// is the new rendering; the old bars are retired by the stream
// that owns SharedViews. The `AppState.showToast` API is unchanged
// — callers keep firing confirmations through it.
//
// RENDERING POINT (the missing-confirmation fix): the popup is
// attached at the APP-SHELL level in AppShellView — at the shell
// root, and again INSIDE the Settings fullScreenCover's content —
// so a confirmation fired from inside a cover is seen. A plain
// overlay on a presenting view renders UNDERNEATH a fullScreenCover
// it presents (the cover lives in its own view-controller
// hierarchy above it), which is why the Transactions toast overlay
// in TransactionsView's body never showed confirmations fired
// inside the Actions / Filters / Add / Trash / Export covers.
// Covers presented from TransactionsView still need this modifier
// attached inside THEIR content (TransactionsView stream's job);
// this file only provides the view + modifier.
//
// DOUBLE-RENDERING NOTE: ContentView.swift:37 still renders
// `$appState.toast` through SharedViews' `.toastOverlay`. While
// both attachments live, the popup shows twice during the .app
// phase (once from ContentView, once from the shell — same card,
// same position, so they overlap). The coordinator must retire
// one: the ContentView call is still needed for auth-phase toasts
// (e.g. "Email confirmed."), so the clean end state is the
// SharedViews stream making `.toastOverlay` render this popup
// card and the shell attachment below being removed — or the
// ContentView call being gated to non-.app phases. Do not delete
// either attachment unilaterally.

import SwiftUI
import OnBudgetKit

/// The confirmation popup card itself: a compact white card
/// (soft-red tint for errors) with a status icon, the message in
/// ink (dark red for errors), and an X to close early. Compact:
/// at most 420pt wide, centred on the screen — never a
/// full-width bar, never a top banner (build 65).
public struct ConfirmationPopupView: View {
    public let toast: Toast
    public let onDismiss: () -> Void

    public init(toast: Toast, onDismiss: @escaping () -> Void) {
        self.toast = toast
        self.onDismiss = onDismiss
    }

    /// Card background: white for success/info, soft-red tint
    /// (#fef2f2) for errors.
    private var cardBackground: Color {
        toast.kind == .error ? DesignTokens.errorBackground : .white
    }

    /// Message text: ink for success/info, dark red (#991b1b)
    /// for errors.
    private var messageColor: Color {
        toast.kind == .error ? DesignTokens.heroOverBudget : DesignTokens.ink
    }

    /// The leading status icon: a brand-blue checkmark in a blue
    /// circle for success, a brand-blue info mark for info, a red
    /// X in a soft-red disc for errors. Success is BRAND BLUE,
    /// not green (build 64, C-5).
    @ViewBuilder
    private var statusIcon: some View {
        switch toast.kind {
        case .success:
            ZStack {
                Circle()
                    .fill(DesignTokens.primary)
                    .frame(width: 28, height: 28)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
        case .error:
            ZStack {
                Circle()
                    .fill(DesignTokens.errorBorder)
                    .frame(width: 28, height: 28)
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DesignTokens.errorText)
            }
            .accessibilityHidden(true)
        case .info:
            ZStack {
                Circle()
                    .fill(DesignTokens.primary)
                    .frame(width: 28, height: 28)
                Image(systemName: "info")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
        }
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
            Text(toast.message)
                // Larger, centred (build 65, owner Nov 23, 2026):
                // 17pt semibold, centred text — a clean
                // confirmation, not a crammed top banner. Message
                // CONTENT is untouched here (the sync wording
                // itself is shortened separately, in HomeView's
                // sync handler) — this is rendering only.
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(messageColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DesignTokens.muted)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    toast.kind == .error ? DesignTokens.errorBorder : DesignTokens.tertiary,
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        // Compact card, never a full-width bar: at most 420pt,
        // centred on the screen, with room to breathe on each side.
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("confirmation-popup")
    }
}

/// Overlays the current confirmation popup CENTRED on the
/// screen (build 65, owner Nov 23, 2026 — it used to sit at the
/// top; a centred card with larger text reads as a clean
/// confirmation, not a crammed banner), with the 4-second
/// auto-dismiss (ToastStyle.autoDismissSeconds — the one shared
/// value, CLONE_SPEC §2.3). Same behaviour as the
/// ToastOverlayModifier it replaces: a tap anywhere else on the
/// page dismisses it — the clear background below catches the
/// tap, so the page under it never receives a stray tap while the
/// popup is up. The popup itself is a small card, never a modal —
/// it never blocks the page, it just sits on top of it for 4 seconds.
public struct ConfirmationPopupOverlayModifier: ViewModifier {
    @Binding public var toast: Toast?

    public init(toast: Binding<Toast?>) {
        self._toast = toast
    }

    public func body(content: Content) -> some View {
        content.overlay {
            if let toast {
                GeometryReader { _ in
                    ZStack(alignment: .center) {
                        // Tap anywhere else dismisses (owner,
                        // Nov 20, 2026). Clear, so the page shows
                        // through — but it still catches the tap.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { self.toast = nil }
                        ConfirmationPopupView(toast: toast) { self.toast = nil }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(ToastStyle.autoDismissSeconds))
                    if self.toast?.id == toast.id { self.toast = nil }
                }
            }
        }
    }
}

public extension View {
    /// Attach the confirmation popup overlay, bound to a `Toast?`.
    /// Attach at the app-shell level (AppShellView root, and inside
    /// any fullScreenCover content that must show confirmations)
    /// so the popup renders above covers. See the file header for
    /// why an overlay on a presenting view alone is not enough.
    func confirmationPopupOverlay(_ toast: Binding<Toast?>) -> some View {
        modifier(ConfirmationPopupOverlayModifier(toast: toast))
    }
}
