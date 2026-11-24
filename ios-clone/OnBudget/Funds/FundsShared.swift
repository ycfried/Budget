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

// MARK: - Buttons (spec §1.3, owner rules Nov 3–4, B3 Nov 23)
//
// B3 (owner, Nov 23, 2026 — build 64): one solid-blue primary on
// top + two OUTLINE buttons below, in DIFFERENT colours — ink
// #0f172a on one side, darker grey #4b5563 on the other. The
// strengthened standing rule: never have 3 buttons with 2 sharing
// the same colour or looking very similar — all three must be
// clearly distinct. The pale middle tier is retired for
// three-button groups (it survives as a component for the few
// two-button spots that still use it). Two-button rows stay
// primary blue first + grey tertiary second.
// Every label is Title Cased (minor words lower unless first;
// exceptions "Sign In", "Mark as Charity" — see TitleCase.swift).
// Radii (build 64, P-3 — one radius system): full-width buttons
// 10pt, small buttons 8pt, cards 12pt.

public struct FundsPrimaryButton: View {
    public let label: String
    public let isBusy: Bool
    /// iPad (build 37, owner Nov 16, 2026 — Clear Debt screen):
    /// larger/taller on the tablet form factor. False everywhere
    /// else; existing call sites are unchanged.
    public let isLarge: Bool
    public let action: () -> Void

    public init(_ label: String, isBusy: Bool = false, isLarge: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isBusy = isBusy
        self.isLarge = isLarge
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: isLarge ? 17 : 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, isLarge ? 16 : 13)
                .padding(.horizontal, 18)
                // Build 63 (Lean): the one filled deep-blue
                // primary in an action group — the deeper blue
                // (#1d4ed8) among the soft secondaries. Build 64
                // (P-3): full-width buttons are 10pt radius.
                .background(DesignTokens.deep)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

public struct FundsTertiaryButton: View {
    public let label: String
    public let isBusy: Bool
    /// iPad (build 37, owner Nov 16, 2026 — Clear Debt screen):
    /// larger/taller on the tablet form factor. False everywhere
    /// else; existing call sites are unchanged.
    public let isLarge: Bool
    public let action: () -> Void

    public init(_ label: String, isBusy: Bool = false, isLarge: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isBusy = isBusy
        self.isLarge = isLarge
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: isLarge ? 17 : 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, isLarge ? 16 : 13)
                .padding(.horizontal, 18)
                .background(Color(hex: "#e5e7eb"))
                .foregroundStyle(DesignTokens.ink)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

/// Danger (build 47, owner Nov 19, 2026 — "Delete This Income"
/// is a proper RED button, not a quiet link): the app's existing
/// error colour — bg #fef2f2, text #dc2626 — the same soft-red
/// treatment as the Settings danger buttons (DangerButtonStyle)
/// and the error toasts/boxes. Never a solid red button.
public struct FundsDangerButton: View {
    public let label: String
    public let isBusy: Bool
    public let isLarge: Bool
    public let action: () -> Void

    public init(_ label: String, isBusy: Bool = false, isLarge: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isBusy = isBusy
        self.isLarge = isLarge
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: isLarge ? 17 : 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, isLarge ? 16 : 13)
                .padding(.horizontal, 18)
                .background(DesignTokens.errorBackground)
                .foregroundStyle(DesignTokens.errorText)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

/// Pale #bfdbfe — the middle tier of a three-button row, and,
/// since build 52 (owner, Nov 20, 2026), the full-width treatment
/// for exactly two buttons that sit below a solid blue one (Top Up
/// Budget under Calculate; Activity & Transactions under Add to
/// Tzedaka). Those two call sites are the only pale full-width
/// buttons; do not add more without the owner's say-so.
public struct FundsPaleButton: View {
    public let label: String
    public let isBusy: Bool
    public let isLarge: Bool
    public let action: () -> Void

    public init(_ label: String, isBusy: Bool = false, isLarge: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isBusy = isBusy
        self.isLarge = isLarge
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: isLarge ? 17 : 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, isLarge ? 16 : 13)
                .padding(.horizontal, 18)
                // Build 63 (Lean, Between-style): a pale
                // soft-blue fill (#e9effe) with a hairline
                // border (#bfdbfe), ink text — a real button,
                // not a bare outline and not a solid blue block.
                .background(DesignTokens.softFill)
                .foregroundStyle(DesignTokens.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(DesignTokens.softBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

/// Small primary / tertiary buttons for list rows (Approve, Release,
/// Link, Same Purchase, Restore — spec §9.3/§9.4/§11).
public struct FundsSmallPrimaryButton: View {
    public let label: String
    public let systemImage: String?
    public let isBusy: Bool
    public let action: () -> Void

    public init(_ label: String, systemImage: String? = nil, isBusy: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            if let systemImage {
                Label(TitleCase.apply(to: label), systemImage: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(DesignTokens.primary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text(TitleCase.apply(to: label))
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(DesignTokens.primary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

public struct FundsSmallTertiaryButton: View {
    public let label: String
    public let isBusy: Bool
    /// iPad (build 37, owner Nov 16, 2026 — Clear Debt screen):
    /// larger/taller on the tablet form factor. False everywhere
    /// else; existing call sites are unchanged.
    public let isLarge: Bool
    public let action: () -> Void

    public init(_ label: String, isBusy: Bool = false, isLarge: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isBusy = isBusy
        self.isLarge = isLarge
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: isLarge ? 17 : 14, weight: .semibold))
                .padding(.vertical, isLarge ? 12 : 8)
                .padding(.horizontal, isLarge ? 16 : 12)
                .background(Color(hex: "#e5e7eb"))
                .foregroundStyle(DesignTokens.ink)
                .clipShape(RoundedRectangle(cornerRadius: 8))
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

/// The B3 darker-grey outline (#4b5563) lives here, not in the
/// kit: DesignTokens.swift is the shared kit file and #4b5563 is
/// not in it — this extension is the one place the B3 grey is
/// defined, so the two outline buttons below and their call sites
/// never hard-code the hex.
public extension DesignTokens {
    static var outlineSlate: Color { Color(hex: "#4b5563") }
}

/// B3 outline buttons (owner, Nov 23, 2026 — build 64): the two
/// secondary buttons under a solid-blue primary, in DIFFERENT
/// colours — ink #0f172a on one side, darker grey #4b5563 on the
/// other — white background, 1.5pt outline, same sizing as the
/// full-width primary/tertiary. The two must never sit side by
/// side in the same colour: ink pairs with slate, never ink with
/// ink or slate with slate.
public struct FundsInkOutlineButton: View {
    public let label: String
    public let isBusy: Bool
    public let isLarge: Bool
    public let action: () -> Void

    public init(_ label: String, isBusy: Bool = false, isLarge: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isBusy = isBusy
        self.isLarge = isLarge
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: isLarge ? 17 : 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, isLarge ? 16 : 13)
                .padding(.horizontal, 18)
                .background(.white)
                .foregroundStyle(DesignTokens.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(DesignTokens.ink, lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

public struct FundsSlateOutlineButton: View {
    public let label: String
    public let isBusy: Bool
    public let isLarge: Bool
    public let action: () -> Void

    public init(_ label: String, isBusy: Bool = false, isLarge: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isBusy = isBusy
        self.isLarge = isLarge
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(TitleCase.apply(to: label))
                .font(.system(size: isLarge ? 17 : 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, isLarge ? 16 : 13)
                .padding(.horizontal, 18)
                .background(.white)
                .foregroundStyle(DesignTokens.outlineSlate)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(DesignTokens.outlineSlate, lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

/// Squarish option control (build 64, C-6 — replaces every
/// `.pickerStyle(.segmented)` in the Funds screens). Build 69
/// (owner, Nov 24, 2026 — "This was supposed to become a
/// slider?"): the build-64 version was an HStack with 8pt gaps —
/// three SEPARATE boxes, each with its own border — so it read as
/// three buttons, not one slider. This is now ONE unified slider:
/// a single track (one white container, one hairline border) with
/// the segments sharing it edge to edge, and the selected segment
/// a pale-blue thumb that SLIDES between stops via
/// matchedGeometryEffect (the page select's pattern, build 66 —
/// 0.25s easeInOut, the owner-requested slide exception to the
/// instant-change rule). No pill/capsule track, no system
/// segmented control anywhere in these screens. One cell per
/// option; the caller passes (value, label) pairs so enums
/// without a display string still read plainly.
public struct SquarishPicker<Option: Hashable>: View {
    public let options: [(Option, String)]
    @Binding public var selection: Option
    /// Minimum cell height (e.g. 52pt beside the debt-rule Apply
    /// button); nil sizes the cells to their content.
    public let minHeight: CGFloat?
    /// The namespace for the sliding thumb — the pale-blue
    /// selected segment glides between stops via
    /// matchedGeometryEffect (see the background below).
    @Namespace private var thumbNamespace

    public init(_ options: [(Option, String)], selection: Binding<Option>, minHeight: CGFloat? = nil) {
        self.options = options
        self._selection = selection
        self.minHeight = minHeight
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { option, label in
                let isSelected = selection == option
                Button { selection = option } label: {
                    Text(label)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? DesignTokens.ink : DesignTokens.segmentInactive)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 8)
                        .frame(minHeight: minHeight)
                        .background(
                            Group {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(DesignTokens.softFill)
                                        .matchedGeometryEffect(id: "squarishPickerThumb", in: thumbNamespace)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label + (isSelected ? ", selected" : ""))
            }
        }
        .padding(4)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: selection)
    }
}

// MARK: - Fund editor controls (build 36)
//
// The controls inside an expanded fund's editor — the Charity rate
// row, the Debt Repayment Rule picker, the Weekly Allowance field —
// were the small list-row sizes (14pt text, 8pt padding) and looked
// small and cheap next to the 28pt card faces (owner, Nov 16, 2026).
// The editor controls are sized up to proper controls: 17pt text,
// 13pt vertical padding, 48pt+ fields. These are SEPARATE from the
// FundsSmall* buttons on purpose: the small sizes stay for list-row
// actions (Approve, Release, Correct, Same Purchase) — only the
// fund editors use the bigger treatment. Values never change here:
// only sizes.

/// Editor primary (Save in the rate / rule / allowance editors):
/// the FundsPrimaryButton's text and padding, without its
/// full-width frame — it sits inline in an editor row.
public struct FundsEditorPrimaryButton: View {
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
                .font(.system(size: 17, weight: .semibold))
                .padding(.vertical, 13)
                .padding(.horizontal, 18)
                .background(DesignTokens.primary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

/// Editor tertiary (Set / Change Temporary Allowance): the small
/// tertiary's grey fill, at editor size.
public struct FundsEditorTertiaryButton: View {
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
                .font(.system(size: 16, weight: .semibold))
                // Build 37 (owner, Nov 16, 2026): full-width, like
                // the other fund buttons — the Temporary Allowance
                // button read as a small pill on the left with a
                // large empty space on the right.
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color(hex: "#e5e7eb"))
                .foregroundStyle(DesignTokens.ink)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

/// Editor quiet (Reset in the rate / rule / allowance editors,
/// Remove Override in Temporary Allowance): the quiet text button
/// at editor size.
public struct FundsEditorQuietButton: View {
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(hex: "#6b7280"))
                .padding(.vertical, 13)
                .padding(.horizontal, 14)
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

// MARK: - Build 68 shared pieces
//
// CalculatorGlyph (item 11), FundsTextField (items 7/13),
// FundsDetailSkeleton (item 23) and the red remove/delete
// buttons (item 8) live here so every Funds screen shares them.

/// A calculator glyph that always renders (build 68, item 11):
/// the "calculator" SF Symbol draws NOTHING on device (verified
/// build 66) and "±" (plus.forwardslash.minus) reads as maths
/// keys, not a calculator. This glyph is drawn from shapes — an
/// outlined body, a display bar, a 3×3 keypad — so it can never
/// fail to resolve. `color` is white on a blue button by default;
/// pass brand blue (#2f6bff) on a white row.
public struct CalculatorGlyph: View {
    public let size: CGFloat
    public let color: Color

    public init(size: CGFloat = 20, color: Color = .white) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        VStack(spacing: size * 0.12) {
            RoundedRectangle(cornerRadius: size * 0.06)
                .frame(width: size * 0.62, height: size * 0.14)
            VStack(spacing: size * 0.12) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: size * 0.12) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle()
                                .frame(width: size * 0.09, height: size * 0.09)
                        }
                    }
                }
            }
        }
        .foregroundStyle(color)
        .frame(width: size * 0.8, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.18)
                .stroke(color, lineWidth: max(1.5, size * 0.07))
        )
    }
}

/// The standard plain text field (build 68, items 7/13): the
/// shared comfortable size — 17pt text, 14pt horizontal / 12pt
/// vertical padding, 12pt radius, white with a #e5e7eb hairline,
/// minimum 48pt tall — matching DollarTextField's treatment, so
/// every field in a form reads as one family. Plain
/// `.textFieldStyle(.roundedBorder)` fields varied in height and
/// radius; use this instead. Extra modifiers (keyboard type,
/// autocorrection, onChange caps) apply at the call site.
public struct FundsTextField: View {
    public let placeholder: String
    @Binding public var text: String
    public let axis: Axis

    public init(_ placeholder: String, text: Binding<String>, axis: Axis = .horizontal) {
        self.placeholder = placeholder
        self._text = text
        self.axis = axis
    }

    public var body: some View {
        TextField(placeholder, text: $text, axis: axis)
            .font(.system(size: 17))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// The Funds page loading skeleton (build 68, item 23): bigger,
/// shaped like the loaded card detail — three 20pt rows plus a
/// full-width 52pt button block — so the card holds its loaded
/// size while loading instead of three thin 16pt lines.
public struct FundsDetailSkeleton: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(width: 220, height: 20)
            SkeletonBlock(width: 190, height: 20)
            SkeletonBlock(width: 210, height: 20)
            SkeletonBlock(width: nil, height: 52, cornerRadius: 10)
        }
    }
}

/// Small red button for list-row remove/delete actions (build
/// 68, item 8): the app's error red #dc2626 on #fef2f2 — the
/// same soft-red treatment as FundsDangerButton, at the small
/// list-row size. Delete actions are never grey tertiary.
public struct FundsSmallDangerButton: View {
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
                .background(DesignTokens.errorBackground)
                .foregroundStyle(DesignTokens.errorText)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

/// Editor-size red text button (build 68, item 8): "Remove
/// Override" and friends — a remove action at editor size, in
/// the exact remove red #dc2626, never grey quiet text and never
/// the system destructive role (whose red differs).
public struct FundsEditorDangerButton: View {
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(hex: "#dc2626"))
                .padding(.vertical, 13)
                .padding(.horizontal, 14)
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
    }
}

// MARK: - Activity rows (build 36)
//
// Minimal overview rows for "Activity & Transactions" (owner, Nov 16,
// 2026): the overview shows only the essential — what it is + the
// amount — and tapping the row expands the full detail inline (date,
// rate, commits, approval, split, note). The full sentence per row
// ("Mobile Check Deposit · +$7,000.00 on Nov 2, 2026 at 10% → commits
// $700.00 · Owner approved Nov 5") is gone from the overview; it
// lives in the expanded detail. Actions (e.g. Correct on a charity
// income row) live in the expanded detail too — never nested inside
// the toggle button, so the row tap and the action tap stay separate
// buttons.

/// One minimal activity row: a tappable summary line with a chevron,
/// expanding in place (instant, no animation — the build-34 rule) to
/// the full detail. The chevron is the same "⌄" the fund section
/// rows use.
public struct FundsActivityRow<Summary: View, Detail: View>: View {
    public let summary: Summary
    public let detail: Detail
    @State private var isExpanded = false

    public init(@ViewBuilder summary: () -> Summary, @ViewBuilder detail: () -> Detail) {
        self.summary = summary()
        self.detail = detail()
    }

    public var body: some View {
        // Build 68 (item 25b): the chevron is brand blue (an
        // action hint, not muted text) and the expanded detail
        // sits in a soft #f8fafc box, so it reads as a designed
        // panel instead of bare plain text under the row.
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    summary
                    Spacer()
                    Text("⌄")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                detail
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "#f8fafc"))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

/// One transaction inside "Activity & Transactions": minimal summary
/// (merchant + amount in its kind colour) with the detail on tap
/// (date, source, card, state). The amount uses the one shared kind
/// rule (`TransactionFormatting.amountDisplay`): charity blue,
/// money-in deep blue with "+", everything else ink.
/// One transaction row in a fund's Activity & Transactions feed
/// (Funds, Charity, Debt). The merchant resolves through the
/// household's rename rules (build 41 — owner, Nov 16, 2026: the
/// feeds showed RAW names like "TOIREMORG" while the Transactions
/// list shows the renamed display name) and Title-Cases through the
/// same displayMerchant the Transactions list uses; a row with no
/// matching rule shows its raw name, Title-Cased, as before.
public struct FundTransactionRow: View {
    public let transaction: Transaction
    /// Merchant rename rules (FundsViewModel.merchantRules).
    /// Empty by default — then the row shows the raw name,
    /// Title-Cased, exactly as before this change.
    public let merchantRules: [MerchantRule]
    /// The Extra Fund's CURRENT display name (build 43, owner Nov
    /// 17, 2026 — item 16): the "covered by …" line reads it, so a
    /// renamed fund never shows the stale default. Nil falls back
    /// to the generic "the fund".
    public let fundName: String?
    /// Build 46 (owner, Nov 18, 2026 — "you can't delete it once
    /// it was added"): the Funds feeds showed transaction rows with
    /// NO Actions button, so Delete was only reachable from the
    /// Transactions list. When `onDelete` is set (admin only) the
    /// expanded detail offers Delete here too — same rules as the
    /// list: hand-written rows delete permanently, bank/email/file
    /// rows move to Trash with a reason. Nil (the default) keeps
    /// the row delete-free.
    public let isAdmin: Bool
    public let isDeleting: Bool
    public let onDelete: ((Transaction, String) async -> Void)?

    /// Inline delete confirm (build 46): the detail holds its own
    /// two-step confirm, so no sheet is needed from a feed row.
    @State private var confirmingDelete = false
    @State private var deleteReason = ""
    @State private var deleteReasonError: String?

    public init(_ transaction: Transaction, merchantRules: [MerchantRule] = [], fundName: String? = nil, isAdmin: Bool = false, isDeleting: Bool = false, onDelete: ((Transaction, String) async -> Void)? = nil) {
        self.transaction = transaction
        self.merchantRules = merchantRules
        self.fundName = fundName
        self.isAdmin = isAdmin
        self.isDeleting = isDeleting
        self.onDelete = onDelete
    }

    public var body: some View {
        let display = TransactionFormatting.amountDisplay(for: transaction)
        FundsActivityRow {
            HStack(spacing: 4) {
                Text(TransactionFormatting.displayMerchant(
                    MerchantDisplayName.displayName(for: transaction.merchant, rules: merchantRules)
                ))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(Color(hex: "#6b7280"))
                Text(display.text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(display.color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MoneyFormat.fmtLong(transaction.date))
                    Text("\(sourceLabel(transaction.source))\(transaction.cardSuffix == "0000" ? "" : " · Card ••\(transaction.cardSuffix)")")
                    if transaction.state == .provisional {
                        Text("Pending — not posted yet.")
                    } else if transaction.state == .reversed {
                        Text("Reversed.")
                    }
                    if transaction.fundAllocationCents > 0 {
                        Text("\(MoneyFormat.formatCents(transaction.fundAllocationCents)) covered by \(fundName ?? "the fund").")
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#6b7280"))
                // Build 46 (owner, Nov 18, 2026): Delete from the
                // feed itself — admin only, two-step, with a reason
                // for bank-synced rows (the Trash flow requires one),
                // exactly like the Transactions list's Actions sheet.
                if isAdmin, let onDelete {
                    if confirmingDelete {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(transaction.source == .manual
                                 ? "This removes the hand-entered transaction and cannot be undone."
                                 : "This moves it to the Trash. The admin can bring it back from the Trash. Give a reason to continue.")
                                .font(.system(size: 14))
                                .foregroundStyle(DesignTokens.ink)
                            if transaction.source != .manual {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Reason (Required)")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(DesignTokens.ink)
                                    FundsTextField("Reason", text: $deleteReason, axis: .vertical)
                                }
                                if let deleteReasonError {
                                    FundsErrorBox(deleteReasonError)
                                }
                            }
                            HStack(spacing: 12) {
                                FundsDangerButton(
                                    transaction.source == .manual ? "Delete" : "Move to Trash",
                                    isBusy: isDeleting
                                ) {
                                    Task {
                                        if transaction.source != .manual {
                                            let reason = deleteReason.trimmingCharacters(in: .whitespaces)
                                            guard !reason.isEmpty else {
                                                deleteReasonError = "Reason required"
                                                return
                                            }
                                            deleteReasonError = nil
                                            await onDelete(transaction, reason)
                                        } else {
                                            await onDelete(transaction, "")
                                        }
                                        confirmingDelete = false
                                        deleteReason = ""
                                    }
                                }
                                .accessibilityIdentifier("funds.confirmDeleteTransaction")
                                FundsTertiaryButton("Keep It") {
                                    confirmingDelete = false
                                    deleteReason = ""
                                    deleteReasonError = nil
                                }
                            }
                        }
                    } else {
                        FundsSmallDangerButton("Delete") {
                            deleteReason = ""
                            deleteReasonError = nil
                            confirmingDelete = true
                        }
                        .accessibilityIdentifier("funds.deleteTransaction")
                    }
                }
            }
        }
    }
}

// MARK: - Cards, rows, error boxes

/// A white card, radius 12, hairline shadow (spec §1.2; build 64,
/// P-3 — one radius system: cards 12pt everywhere). `background`
/// / `padding` are overridable; `outline` is nil for the plain white
/// cards, which stay outline-free. The fund sections no longer use
/// this card's outline (owner, Nov 16, 2026 — Mockup C banners);
/// the forms and sheets below still use the plain white card.
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
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(outline, lineWidth: outlineWidth)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
/// (Available / Pending / Total — spec §6.2/§9.1). `isInflow`
/// marks a money-in row (e.g. savings "Transferred In"): deep
/// blue with a "+" prefix under the shared kind rule (build 64,
/// F-20 — the old success green is retired; colour means kind,
/// never direction). A negative balance reads in the error red
/// via `isNegative` — a negative balance is one of the three
/// places red is allowed, never a row amount.
public struct FundsBreakdownRow: View {
    public let label: String
    public let value: String
    public let isNegative: Bool
    public let isInflow: Bool

    public init(_ label: String, value: String, isNegative: Bool = false, isInflow: Bool = false) {
        self.label = label
        self.value = value
        self.isNegative = isNegative
        self.isInflow = isInflow
    }

    public var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(Color(hex: "#6b7280"))
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(isNegative ? DesignTokens.errorText : (isInflow ? DesignTokens.deep : DesignTokens.ink))
        }
        .font(.system(size: 15))
    }
}

/// A fund section: ONE UNIFIED CARD that expands in place (no
/// sheet, no overlay — spec §6.2/§9.1). Build 64 (C-2 B2): the
/// header is plain WHITE — the fund NAME in its own colour
/// (Spending deep blue, Tzedaka primary blue, Savings muted grey,
/// Overspent ink) with a small glyph beside it, no solid banner
/// and no thin rule — and a WHITE body below holding the amount
/// in the same colour, then the detail rows, editors and actions
/// when expanded. The detail below the header is part of the SAME
/// card (one container, one boundary). The green/amber/red
/// outlines are gone. Chevron `⌄` at the header's right end,
/// muted grey, flips to `⌃` when expanded (instant, build 34).
/// A small pencil icon sits next to the fund name (admin-only) —
/// it opens the rename sheet (owner, Nov 16, 2026 — build 40: the
/// full-width "Rename" button is gone; rename is a pencil by the
/// name). Loading shows the same card shape in WHITE with grey
/// shimmer, with NO colour and no "Loading…" text (`isLoading`);
/// a failed face is a STATIC grey block, never a bare "—" in amount
/// type — the expanded content carries the error box (F-P2-13 /
/// owner loading language, Nov 12, 2026).
public struct FundsExpandableCard<Expanded: View>: View {
    public let title: String
    public let amountText: String
    public let isExpanded: Bool
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
    /// The header icon to show (build 41 — customizable fund
    /// icons): the fund's resolved icon. Nil keeps the theme's
    /// default icon.
    public let iconName: String?
    /// Reorder mode (build 41 — owner, Nov 16, 2026): when true
    /// the card collapses to JUST the color bar — the header strip
    /// only (icon + name; the amount lives in the body since
    /// build 50 and is hidden here), no white body, no detail, no
    /// progress bar, no buttons, no expanded content — so the
    /// cards are compact and easy to move. The chevron and pencil
    /// hide too (the card does not expand or rename while
    /// reordering); the arrows above the card still move it.
    /// False everywhere else; exiting reorder mode returns the
    /// card to its full size (the expanded state is untouched, so
    /// an expanded card re-opens as it was).
    public let isReorderMode: Bool
    public let accessibilityLabel: String
    public let onToggle: () -> Void
    /// Admin-only rename affordance: when non-nil and `isAdmin` is
    /// true, a small pencil sits next to the fund name in the
    /// header; tapping it opens the rename sheet (owner, Nov 16,
    /// 2026 — build 40). Nil hides the pencil entirely.
    public let isAdmin: Bool
    public let onRename: (() -> Void)?
    /// The one-line fund description (build 42 — owner, Nov 17,
    /// 2026): shown by tapping the ⓘ in the header. Nil hides
    /// the icon entirely.
    public let fundDescription: String?
    /// Show on Home control (build 68, item 26): only funds that
    /// can be hidden from Home (Savings, Overspent (Past)) pass
    /// this; the control lives INSIDE the card, in the expanded
    /// detail, instead of the old floating row below the card.
    public let showHomeVisibility: Bool
    public let isHiddenFromHome: Bool
    public let onSetHiddenFromHome: ((Bool) -> Void)?
    public let expanded: Expanded
    @State private var showingDescription = false

    public init(
        title: String,
        amountText: String,
        isExpanded: Bool,
        amountIsStatus: Bool = false,
        isLoading: Bool = false,
        theme: StatCardTheme? = nil,
        iconName: String? = nil,
        isReorderMode: Bool = false,
        accessibilityLabel: String,
        onToggle: @escaping () -> Void,
        isAdmin: Bool = false,
        onRename: (() -> Void)? = nil,
        fundDescription: String? = nil,
        showHomeVisibility: Bool = false,
        isHiddenFromHome: Bool = false,
        onSetHiddenFromHome: ((Bool) -> Void)? = nil,
        @ViewBuilder expanded: () -> Expanded
    ) {
        self.title = title
        self.amountText = amountText
        self.isExpanded = isExpanded
        self.amountIsStatus = amountIsStatus
        self.isLoading = isLoading
        self.theme = theme
        self.iconName = iconName
        self.isReorderMode = isReorderMode
        self.accessibilityLabel = accessibilityLabel
        self.onToggle = onToggle
        self.isAdmin = isAdmin
        self.onRename = onRename
        self.fundDescription = fundDescription
        self.showHomeVisibility = showHomeVisibility
        self.isHiddenFromHome = isHiddenFromHome
        self.onSetHiddenFromHome = onSetHiddenFromHome
        self.expanded = expanded()
    }

    public var body: some View {
        // One unified card (owner, Nov 16, 2026 — build 40): the
        // outer container is the single boundary — white background
        // + one rounded-rect clip. The header strip carries the
        // fund color; the white body sits directly below it, no
        // gap, no separate outline.
        // Build 41 (owner, Nov 16, 2026 — "much bigger and look
        // like cards.. a small shadow below each card"): the card
        // is bigger (24pt side padding, taller header, 28pt
        // amount) and carries the shared fundCardShadow, so the
        // Funds cards lift exactly like the Home cards.
        let pad: CGFloat = theme == nil ? 20 : 24
        return VStack(alignment: .leading, spacing: 0) {
            // Whole-area tap target (owner rule, Nov 11 2026,
            // and the Nov 15, 2026 app-wide pass): the ENTIRE
            // header strip — icon, title, amount AND the chevron —
            // is the toggle. The chevron is only a visual hint,
            // never the only place that responds. The header is a
            // tap gesture, NOT a Button: the pencil is a real Button
            // inside it, and a Button nested inside a Button never
            // fires (audit H-P1-3). A child Button wins over an
            // ancestor tap gesture, so the pencil opens the rename
            // sheet while the rest of the header still toggles.
            // `.contentShape(Rectangle())` makes the empty space
            // between the glyphs respond too — without it only the
            // glyphs hit and the header feels chevron-only.
            headerStrip(pad: pad)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Reorder mode: the bar does not expand — the
                    // arrows above the card move it. Everywhere
                    // else the whole header toggles the card.
                    if !isReorderMode { onToggle() }
                }
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAddTraits(.isButton)
            // Amount body (build 50, owner Nov 20, 2026): NAME in
            // the header, AMOUNT in the box/card. The amount used
            // to sit in the header beside the name, so the two
            // fought for width — different text sizes per card
            // (the amount's minimumScaleFactor shrank long amounts)
            // and some words were cut off. The amount now lives
            // here, always visible (collapsed or expanded), one
            // uniform 28pt bold in the theme's number colour, on
            // the full card width — nothing cut off, every card
            // the same size. Hidden in reorder mode (the bar is
            // just for dragging then).
            if !isReorderMode {
                amountBody(pad: pad)
            }
            if isExpanded, !isReorderMode {
                // White body (majority): the detail rows, editors
                // and actions. Directly below the amount, no gap —
                // part of the same card, not a separate block. The
                // expanded content keeps its own buttons (Add Money
                // / Spend / Request), so it is not part of the
                // toggle — tapping an action must not collapse the
                // section underneath it. Build 42 (owner, Nov 17,
                // 2026 — "the white body should be double the
                // header"): same 1/3 header, 2/3 white body rule
                // as Home. The top padding is 8pt now (build 50):
                // the amount body above already separates the
                // detail from the header, so the old 28pt top
                // padding would leave a dead gap.
                VStack(alignment: .leading, spacing: 0) {
                    expanded
                    // Build 68 (item 26): Show on Home lives
                    // INSIDE the card, at the foot of the expanded
                    // detail — a blue eye icon, the label, and a
                    // brand-blue toggle — never a floating row
                    // between cards.
                    if showHomeVisibility, let onSetHiddenFromHome {
                        Divider()
                            .padding(.top, 20)
                        HStack(spacing: 10) {
                            Image(systemName: isHiddenFromHome ? "eye.slash" : "eye")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(DesignTokens.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show on Home")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(DesignTokens.ink)
                                if isHiddenFromHome {
                                    Text("Hidden from Home — it won't appear on Home.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color(hex: "#6b7280"))
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { !isHiddenFromHome },
                                set: { show in onSetHiddenFromHome(!show) }
                            ))
                            .labelsHidden()
                            .tint(DesignTokens.primary)
                            .accessibilityLabel("Show on Home")
                        }
                        .padding(.top, 16)
                    }
                }
                .padding(.horizontal, pad)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Build 41 (owner, Nov 16, 2026): a small shadow below
        // the card — the shared fundCardShadow, so the Funds cards
        // lift exactly like the Home cards.
        .fundCardShadow()
        // Build 42 (owner, Nov 17, 2026 — fund descriptions
        // behind an info icon): tapping the ⓘ shows the fund's
        // one-line description as an alert, titled with the fund
        // name. The alert lives here (not per call site) so all
        // four cards get it from the one `fundDescription`
        // parameter.
        .alert(TitleCase.apply(to: title), isPresented: $showingDescription) {
            Button("OK") {}
        } message: {
            if let fundDescription {
                Text(fundDescription)
            }
        }
    }

    /// The header strip (build 64, C-2 B2 — "Coloured name, no
    /// line"): NO solid banner and NO thin rule any more. The
    /// header is plain white; the fund NAME is written in its own
    /// colour — Spending deep blue #1d4ed8, Tzedaka primary blue
    /// #2f6bff, Savings muted grey #6b7280, Overspent ink — and
    /// the amount in the body below takes the same colour
    /// (`theme.number`). The icon is a small 20pt glyph in the
    /// same colour, directly on white (build 64, P-6 — the white
    /// circle disc is gone). The name is 17pt semibold (build 64,
    /// C-1). The title always shows, even on failure — the failed
    /// signal is the static grey block in the amount body plus the
    /// error box in the expanded detail, never a grey header.
    /// Loading shows skeleton icon + title, never real text on a
    /// placeholder.
    private func headerStrip(pad: CGFloat) -> some View {
        // Title colour: the fund's own colour (theme.number) —
        // the B2 rule. Ink only when the card has no theme.
        let titleColor: Color = theme?.number ?? DesignTokens.ink
        // Chevron / pencil / info colours: muted grey on the
        // white header — they are hints, not the name.
        let hintColor: Color = DesignTokens.muted
        return HStack(spacing: 10) {
            if let theme {
                if isLoading {
                    SkeletonBlock(width: 22, height: 22, cornerRadius: 6, animated: true)
                } else {
                    // Small glyph directly on white (build 64,
                    // P-6): no white circle disc. The glyph takes
                    // the name's colour, so icon + name read as
                    // one fund identity.
                    Image(systemName: iconName ?? theme.iconName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(theme.number)
                        .frame(width: 24, height: 24)
                }
            }
            if isLoading {
                // Skeleton title while loading (owner, Nov 16,
                // 2026 — build 38): real dark-ink text on the
                // placeholder read as a finished card. The failed
                // state keeps the real title in its colour.
                SkeletonBlock(width: 140, height: 22, cornerRadius: 6, animated: true)
            } else {
                Text(TitleCase.apply(to: title))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(2)
            }
            // Pencil (admin-only): a small edit glyph right by the
            // fund name, in the header's text color — NOT a button
            // (owner, Nov 16, 2026 — build 40: "This shouldn't be
            // a button.. it should be like an edit sign or pencil
            // symbol by the name"). Tapping it opens the same
            // rename sheet the old full-width Rename button opened.
            // A child Button wins over the header's tap gesture, so
            // the pencil renames while the rest of the header still
            // toggles. Hidden in reorder mode (build 41): the bar
            // does not rename while reordering.
            if isAdmin, let onRename, !isLoading, !isReorderMode {
                Button(action: onRename) {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(hintColor)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename \(TitleCase.apply(to: title))")
            }
            Spacer()
            // Info icon (build 42 — owner, Nov 17, 2026: fund
            // descriptions live behind an info icon, not as a
            // text line in the expanded card; build 68, item 28:
            // info icons are brand blue #2f6bff everywhere).
            // Sits on the right side of the header, between the
            // amount and the chevron. A child Button
            // wins over the header's tap gesture (like the pencil),
            // so tapping it shows the description instead of
            // toggling the card. Hidden in reorder mode and while
            // loading; hidden entirely when the card has no
            // description.
            if let fundDescription, !isLoading, !isReorderMode {
                Button(action: { showingDescription = true }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About \(TitleCase.apply(to: title))")
            }
            // Chevron (build 41): hidden in reorder mode — the bar
            // does not expand while reordering, so there is nothing
            // to hint at.
            if !isReorderMode {
                Text("⌄")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(hintColor)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .padding(.horizontal, pad)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The amount body (build 50, owner Nov 20, 2026): the fund's
    /// amount on the white card body, always visible (collapsed or
    /// expanded) — NAME in the header, AMOUNT in the body. Build 64
    /// (C-1): one uniform size on every card, in the theme's
    /// number colour — Spending deep #1d4ed8, Tzedaka primary
    /// #2f6bff, Savings muted grey #6b7280, Overspent ink (the B2
    /// rule: the amount is the same colour as the name) — on the
    /// full card width with NO minimumScaleFactor, so a long amount
    /// never shrinks to a different size per card and never
    /// truncates on an iPhone. Build 68 (item 24): 32pt, with
    /// tighter top/bottom padding, so the cards feel substantial
    /// instead of a small number in empty white space. Loading
    /// shows the same skeleton block (sized to the 32pt amount);
    /// a failed load shows it static, never a bare "—".
    private func amountBody(pad: CGFloat) -> some View {
        Group {
            if isLoading || amountIsStatus {
                SkeletonBlock(width: 180, height: 40, cornerRadius: 8, animated: isLoading)
            } else {
                Text(amountText)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(theme?.number ?? DesignTokens.ink)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, pad)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }
}

// MARK: - Toasts (spec §2.3)
//
// Top popup (owner, Nov 20, 2026 — build 50), auto-dismiss 4s,
// tap anywhere else or the top-corner X dismisses sooner, tab
// switch clears it. Info: brand blue
// #2f6bff, white text. Success: the Posted badge treatment — light
// green bg #dcfce7, dark green text #166534 (owner, Nov 15, 2026;
// the solid #22c55e bar was the wrong green). Error: soft
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
            // Top popup toast (owner, Nov 20, 2026 — build 50):
            // the centered popup was "horrendous". The shared
            // ToastBanner is the ONE banner — a tap anywhere else
            // dismisses it, via the clear background below.
            .overlay {
                if let toast {
                    GeometryReader { proxy in
                        ZStack(alignment: .top) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    dismissTask?.cancel()
                                    self.toast = nil
                                }
                            ToastBanner(toast: toast) {
                                dismissTask?.cancel()
                                self.toast = nil
                            }
                            .padding(.top, proxy.safeAreaInsets.top + 8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
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

/// A form-field label (build 41 — owner, Nov 16, 2026: no "($)"
/// in a label when the field already shows the $ prefix, and no
/// "(optional)" anywhere). The label renders exactly as passed —
/// callers pass Title Case — with a small RED asterisk when the
/// field is required. Optional fields show no marker: the ABSENCE
/// of the star is the indicator. The star is the error red
/// (#dc2626); the label stays ink, 14pt.
public struct FieldLabel: View {
    public let text: String
    public let required: Bool
    public let weight: Font.Weight

    public init(_ text: String, required: Bool = false, weight: Font.Weight = .semibold) {
        self.text = text
        self.required = required
        self.weight = weight
    }

    public var body: some View {
        HStack(spacing: 2) {
            Text(text)
            if required {
                Text("*")
                    .foregroundStyle(Color(hex: "#dc2626"))
            }
        }
        .font(.system(size: 14, weight: weight))
        .foregroundStyle(DesignTokens.ink)
    }
}

/// Compact money field, capped at 220px (spec §1.2 card-sizing rule).
/// The "$" is a fixed prefix inside the field (owner, Nov 15, 2026)
/// — display only, never part of the typed text, so parsing is
/// unchanged. Shared `DollarTextField`, same as every $ entry field
/// cross-app. Build 41 (owner, Nov 16, 2026): the label never
/// carries "($)" — the field already shows the $ — and the label
/// carries the red required star (every amount field using this
/// component is required: the submit rejects an empty amount).
public struct FundsMoneyField: View {
    public let label: String
    public let required: Bool
    @Binding public var text: String

    public init(_ label: String, required: Bool = true, text: Binding<String>) {
        self.label = label
        self.required = required
        self._text = text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label, required: required)
            DollarTextField(text: $text)
        }
    }
}

/// Source label, display only (live.js:347): plaid → Bank,
/// manual → By hand, csv → File, amex_alert → Email (renamed from
/// "Email alert", owner Nov 11, 2026). restored → Restored
/// (build 44, change 2): a bank-dropped row restored from Trash.
public func sourceLabel(_ source: TransactionSource) -> String {
    switch source {
    case .plaid: return "Bank"
    case .manual: return "By hand"
    case .csv: return "File"
    case .amexAlert: return "Email"
    case .restored: return "Restored"
    }
}
