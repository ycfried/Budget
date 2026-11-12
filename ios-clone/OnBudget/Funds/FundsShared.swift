import SwiftUI
import OnBudgetKit

/// Shared context for the Funds / Review / Trash screens: the live
/// Supabase client plus the household the signed-in user belongs to.
/// Screens never re-derive the household or the role; the coordinator
/// (Auth/Home workstream) supplies them from `loadMembership`.
public struct FundsContext {
    public let client: SupabaseClient
    public let householdId: UUID
    public let role: HouseholdRole
    /// The signed-in user's id — the `requested_by` of a fund request.
    public let userId: UUID

    public var isAdmin: Bool { role == .admin }

    public init(client: SupabaseClient, householdId: UUID, role: HouseholdRole, userId: UUID) {
        self.client = client
        self.householdId = householdId
        self.role = role
        self.userId = userId
    }
}

// MARK: - Buttons (spec §1.3, owner rules Nov 3–4)
//
// Two-button rows: primary blue FIRST + grey tertiary SECOND.
// Pale #bfdbfe is ONLY the middle tier of a three-button row.
// No two adjacent buttons may share the same colour/treatment.
// Every label is Title Cased (minor words lower unless first;
// exceptions "Sign In", "Mark as Charity" — see TitleCase.swift).

public struct FundsPrimaryButton: View {
    public let label: String
    public let isBusy: Bool
    public let action: () -> Void

    public init(_ label: String, isBusy: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .padding(.horizontal, 18)
                .background(DesignTokens.primary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

public struct FundsTertiaryButton: View {
    public let label: String
    public let isBusy: Bool
    public let action: () -> Void

    public init(_ label: String, isBusy: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .padding(.horizontal, 18)
                .background(Color(hex: "#e5e7eb"))
                .foregroundStyle(DesignTokens.ink)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

/// Pale #bfdbfe — ONLY as the middle tier of a three-button row.
public struct FundsPaleButton: View {
    public let label: String
    public let isBusy: Bool
    public let action: () -> Void

    public init(_ label: String, isBusy: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .padding(.horizontal, 18)
                .background(DesignTokens.pale)
                .foregroundStyle(DesignTokens.ink)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

/// Small primary / tertiary buttons for list rows (Approve, Release,
/// Link, Same Purchase, Restore — spec §9.3/§9.4/§11).
public struct FundsSmallPrimaryButton: View {
    public let label: String
    public let isBusy: Bool
    public let action: () -> Void

    public init(_ label: String, isBusy: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: 14, weight: .semibold))
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(DesignTokens.primary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

public struct FundsSmallTertiaryButton: View {
    public let label: String
    public let isBusy: Bool
    public let action: () -> Void

    public init(_ label: String, isBusy: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: 14, weight: .semibold))
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color(hex: "#e5e7eb"))
                .foregroundStyle(DesignTokens.ink)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

/// Quiet text button (Decline on a fund request — spec §9.3 renders
/// Decline as a small quiet button next to primary Approve).
public struct FundsQuietButton: View {
    public let label: String
    public let isBusy: Bool
    public let action: () -> Void

    public init(_ label: String, isBusy: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: "#6b7280"))
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

// MARK: - Cards, rows, error boxes

/// A white card, radius 20, hairline shadow (spec §1.2). `background`
/// / `padding` are overridable for the outlined stat cards (owner,
/// Nov 12, 2026, corrected ~2:02 PM — Charity green / Extra Fund
/// brand-blue 2px outline, white inside, never a wash); `outline`
/// is nil for the plain white cards, which stay outline-free.
/// Everything else stays the default white / 16pt.
public struct FundsCard<Content: View>: View {
    public let content: Content
    public let background: Color
    public let padding: CGFloat
    public let outline: Color?
    public let outlineWidth: CGFloat

    public init(background: Color = .white, padding: CGFloat = 16, outline: Color? = nil, outlineWidth: CGFloat = 2, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.background = background
        self.padding = padding
        self.outline = outline
        self.outlineWidth = outlineWidth
    }

    public var body: some View {
        content
            .padding(padding)
            .background(background)
            .overlay {
                if let outline {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(outline, lineWidth: outlineWidth)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

/// Soft-red inline error box (bg #fef2f2, text #dc2626, border
/// #fecaca — spec §1.1/§2.3). Used for load failures and field errors.
public struct FundsErrorBox: View {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DesignTokens.errorText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(DesignTokens.errorBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(DesignTokens.errorBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// One labelled row inside an expanded balance card
/// (Available / Pending / Total — spec §6.2/§9.1).
public struct FundsBreakdownRow: View {
    public let label: String
    public let value: String
    public let isNegative: Bool

    public init(_ label: String, value: String, isNegative: Bool = false) {
        self.label = label
        self.value = value
        self.isNegative = isNegative
    }

    public var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(Color(hex: "#6b7280"))
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(isNegative ? DesignTokens.errorText : DesignTokens.ink)
        }
        .font(.system(size: 15))
    }
}

/// A Title + Amount face that expands in place (no sheet, no overlay —
/// spec §6.2/§9.1). Chevron `⌄` bottom-right, brand blue, flips to `⌃`.
/// Bigger and outlined when a `theme` is given (owner, Nov 12, 2026,
/// corrected ~2:02 PM — the same StatCardTheme as Home: Charity green
/// #16a34a outline, Extra Fund brand-blue #2f6bff outline, both 2px,
/// white inside, never a wash; 20pt padding, 18pt title, 28pt amount,
/// icon chip), so Home and Funds match. Loading shows the same bigger
/// shape with a muted grey outline and muted grey shimmer, with NO
/// colour and no "Loading…" text (`isLoading`); a failed face is a
/// STATIC grey block, never a bare "—" in amount type — the expanded
/// content carries the error box (F-P2-13 / owner loading language,
/// Nov 12, 2026).
public struct FundsExpandableCard<Expanded: View>: View {
    public let title: String
    public let amountText: String
    public let isExpanded: Bool
    public let isNegative: Bool
    /// When true the face text is a loading/error status, not an
    /// amount — render it as a skeleton/static block (matching the
    /// Home failure presentation), never in 28pt bold amount type
    /// (F-P2-13).
    public let amountIsStatus: Bool
    /// True only while loading (shimmer skeleton). False with
    /// `amountIsStatus` true means failed (static grey block).
    public let isLoading: Bool
    /// The card's outline identity; nil keeps the plain white card.
    public let theme: StatCardTheme?
    public let accessibilityLabel: String
    public let onToggle: () -> Void
    public let expanded: Expanded

    public init(
        title: String,
        amountText: String,
        isExpanded: Bool,
        isNegative: Bool = false,
        amountIsStatus: Bool = false,
        isLoading: Bool = false,
        theme: StatCardTheme? = nil,
        accessibilityLabel: String,
        onToggle: @escaping () -> Void,
        @ViewBuilder expanded: () -> Expanded
    ) {
        self.title = title
        self.amountText = amountText
        self.isExpanded = isExpanded
        self.isNegative = isNegative
        self.amountIsStatus = amountIsStatus
        self.isLoading = isLoading
        self.theme = theme
        self.accessibilityLabel = accessibilityLabel
        self.onToggle = onToggle
        self.expanded = expanded()
    }

    public var body: some View {
        FundsCard(
            background: .white,
            padding: theme == nil ? 16 : 20,
            outline: theme == nil ? nil : (isLoading ? StatCardTheme.loadingOutline : theme?.outline)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // Whole-area tap target (owner rule, Nov 11 2026):
                // the ENTIRE card face — title, amount AND the
                // chevron row — is the toggle. The chevron is only a
                // visual hint, never the only place that responds.
                // The expanded content keeps its own buttons (Add
                // Money / Spend / Request), so it is not part of the
                // toggle — tapping an action must not collapse the
                // card underneath it.
                Button(action: onToggle) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            if let theme {
                                if isLoading {
                                    SkeletonBlock(width: 36, height: 36, cornerRadius: 10)
                                } else {
                                    Image(systemName: theme.iconName)
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(theme.deep)
                                        .frame(width: 36, height: 36)
                                        .background(.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(theme.outline, lineWidth: 1)
                                        )
                                }
                            }
                            Text(TitleCase.apply(to: title))
                                .font(.system(size: theme == nil ? 17 : 18, weight: .bold))
                                .foregroundStyle(DesignTokens.ink)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if isLoading {
                            SkeletonBlock(width: 150, height: 34, cornerRadius: 8)
                        } else if amountIsStatus {
                            SkeletonBlock(width: 150, height: 34, cornerRadius: 8, animated: false)
                        } else {
                            Text(amountText)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(isNegative ? DesignTokens.errorText : (theme?.deep ?? DesignTokens.ink))
                        }
                        HStack {
                            Spacer()
                            Text("⌄")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(DesignTokens.primary)
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                if isExpanded {
                    Divider()
                        .transition(ExpandAnimation.transition)
                    expanded
                        .transition(ExpandAnimation.transition)
                }
            }
            .animation(ExpandAnimation.animation, value: isExpanded)
        }
    }
}

// MARK: - Toasts (spec §2.3)
//
// Bottom only, floating clear of the tab bar, auto-dismiss 4s, tap
// dismisses sooner, tab switch clears it. Info: brand blue
// #2f6bff, white text. Success: green #16a34a
// (`DesignTokens.success`), white text (owner rule, Nov 11, 2026 —
// native only; the web app stays blue for success). Error: soft
// red bg/text/border.
// NOTE (integration, Nov 9, 2026): the auto-dismiss sleeps on the
// one shared value `ToastStyle.autoDismissSeconds` (4.0, spec §2.3);
// the stale note claiming the kit value was 3.0s is removed —
// fixes-1 set it to 4.0 and this modifier no longer keeps its own 4s.

public struct FundsToastOverlay: ViewModifier {
    @Binding public var toast: Toast?
    @State private var dismissTask: Task<Void, Never>?

    public init(toast: Binding<Toast?>) {
        self._toast = toast
    }

    public func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    Button {
                        dismissTask?.cancel()
                        self.toast = nil
                    } label: {
                        Text(toast.message)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(hex: ToastStyle.textHex(for: toast.kind)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color(hex: ToastStyle.backgroundHex(for: toast.kind)))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(
                                        toast.kind == .error ? DesignTokens.errorBorder : .clear,
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 120)
                }
            }
            .onChange(of: toast) { _, newValue in
                dismissTask?.cancel()
                guard newValue != nil else { return }
                dismissTask = Task {
                    try? await Task.sleep(for: .seconds(ToastStyle.autoDismissSeconds))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { toast = nil }
                }
            }
    }
}

public extension View {
    func fundsToast(_ toast: Binding<Toast?>) -> some View {
        modifier(FundsToastOverlay(toast: toast))
    }
}

// MARK: - Small helpers

/// Title-Cased heading (h2, 22px, weight 700 — spec §1.2/§1.4).
public struct FundsHeading: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(TitleCase.apply(to: text))
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(DesignTokens.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Muted small text (secondary labels — spec §1.1).
public struct FundsMuted: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Color(hex: "#6b7280"))
    }
}

/// Compact money field, capped at 220px (spec §1.2 card-sizing rule).
public struct FundsMoneyField: View {
    public let label: String
    @Binding public var text: String

    public init(_ label: String, text: Binding<String>) {
        self.label = label
        self._text = text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            TextField("$0.00", text: $text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
    }
}

/// Source label, display only (live.js:347): plaid → Bank,
/// manual → By hand, csv → File, amex_alert → Email (renamed from
/// "Email alert", owner Nov 11, 2026).
public func sourceLabel(_ source: TransactionSource) -> String {
    switch source {
    case .plaid: return "Bank"
    case .manual: return "By hand"
    case .csv: return "File"
    case .amexAlert: return "Email"
    }
}
