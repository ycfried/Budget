// STAGE — ConfirmationPopup.swift
//
// Confirmation popup (build 64, owner Nov 23, 2026 — C-5).
// Replaces the green/red toast BARS (ToastBanner in SharedViews)
// with a STAGE-styled confirmation popup: a white card with a
// soft shadow, never a full-width bar. Build 67 (owner, Nov 23,
// 2026 — the popup "look[s] cheap and small"): the card is
// BIGGER and more OFFICIAL/BRANDED — 520pt wide, a larger icon
// and message, and the S logo + T · A · G · E brand row at the
// top — so it reads as an official branded confirmation.
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

/// The confirmation popup card itself: a white card (soft-red
/// tint for errors) with a status icon, the message in ink (dark
/// red for errors), and an X to close early. Build 67 (owner,
/// Nov 23, 2026 — the popup "look[s] cheap and small"): BIGGER
/// and more OFFICIAL/BRANDED — a larger card (520pt wide, more
/// padding, stronger shadow), a larger status icon (40pt) and
/// message text (18pt), and a STAGE brand row at the top (the S
/// logo + T · A · G · E wordmark, the same lockup as the loading
/// page) so it reads as an official branded confirmation, not a
/// tiny plain toast. Success stays brand blue, never green.
/// Centred on the screen — never a full-width bar, never a top
/// banner (build 65). Build 68 (owner, Nov 23, 2026 — item 17):
/// BIGGER and MORE SQUARE-ISH — taller, closer to square
/// (560pt wide, more vertical padding, a larger status icon and
/// message), and the STAGE wordmark in the brand row is THINNER
/// and classier (light weight, not black — the build-67 black
/// wordmark read heavy).
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
    /// not green (build 64, C-5). Build 68: 52pt, so the icon
    /// carries the bigger, more square card.
    @ViewBuilder
    private var statusIcon: some View {
        switch toast.kind {
        case .success:
            ZStack {
                Circle()
                    .fill(DesignTokens.primary)
                    .frame(width: 52, height: 52)
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
        case .error:
            ZStack {
                Circle()
                    .fill(DesignTokens.errorBorder)
                    .frame(width: 52, height: 52)
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(DesignTokens.errorText)
            }
            .accessibilityHidden(true)
        case .info:
            ZStack {
                Circle()
                    .fill(DesignTokens.primary)
                    .frame(width: 52, height: 52)
                // Build 69 (owner, Nov 24, 2026): a drawn "i",
                // not the "info" SF Symbol — the symbol rendered
                // dark with a yellow "i" on device, so the mark
                // is a plain white "i" now: brand-blue circle,
                // white "i", no symbol-rendering ambiguity.
                Text("i")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Build 67 — the brand row: the S logo + the T · A · G · E
            // wordmark (the S IS the S of STAGE, so no second S —
            // same lockup as the loading page), with the X to close
            // at the right. This is what makes the card read as an
            // official STAGE confirmation. The row is identical on
            // all three kinds — the brand is the brand; the error
            // tint below still says failure. Build 68 (item 17):
            // the wordmark is THINNER and classier — light weight,
            // not black.
            HStack(spacing: 8) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                StageWordmarkText(font: .system(size: 16, weight: .light))
                Spacer()
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
            HStack(alignment: .center, spacing: 14) {
                Spacer()
                statusIcon
                Text(toast.message)
                    // Larger, centred (build 65, owner Nov 23, 2026):
                    // 20pt semibold, centred text (was 17pt, then
                    // 18pt in build 67) — a clean confirmation,
                    // not a crammed top banner.
                    // Message CONTENT is untouched here (the sync
                    // wording itself is shortened separately, in
                    // HomeView's sync handler) — this is rendering
                    // only. Build 69 (owner, Nov 24, 2026): NO
                    // line limit — the old `.lineLimit(3)` cut the
                    // message mid-word ("...older o..."). The
                    // message wraps fully now, however long it is.
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(messageColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 34)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(
                    toast.kind == .error ? DesignTokens.errorBorder : DesignTokens.tertiary,
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color.black.opacity(0.18), radius: 28, x: 0, y: 8)
        // Bigger card, never a full-width bar: at most 560pt
        // (build 68 — was 520pt), centred on the screen, with
        // room to breathe on each side. Taller and closer to
        // square than the build-67 card.
        .frame(maxWidth: 560)
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
