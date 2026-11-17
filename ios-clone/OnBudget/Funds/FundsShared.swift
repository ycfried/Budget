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
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Text(TitleCase.apply(to: label))
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(DesignTokens.primary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
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
                .clipShape(RoundedRectangle(cornerRadius: 12))
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
                .clipShape(RoundedRectangle(cornerRadius: 12))
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
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    summary
                    Spacer()
                    Text("⌄")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.muted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                detail
            }
        }
    }
}

/// One transaction inside "Activity & Transactions": minimal summary
/// (merchant + amount in its kind colour) with the detail on tap
/// (date, source, card, state). The amount uses the one shared kind
/// rule (`TransactionFormatting.amountDisplay`): charity blue,
/// money-in green with "+", everything else ink.
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

    public init(_ transaction: Transaction, merchantRules: [MerchantRule] = []) {
        self.transaction = transaction
        self.merchantRules = merchantRules
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
            VStack(alignment: .leading, spacing: 2) {
                Text(MoneyFormat.fmtLong(transaction.date))
                Text("\(sourceLabel(transaction.source))\(transaction.cardSuffix == "0000" ? "" : " · Card ••\(transaction.cardSuffix)")")
                if transaction.state == .provisional {
                    Text("Pending — not posted yet.")
                } else if transaction.state == .reversed {
                    Text("Reversed.")
                }
                if transaction.fundAllocationCents > 0 {
                    Text("\(MoneyFormat.formatCents(transaction.fundAllocationCents)) covered by the Extra Fund.")
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(Color(hex: "#6b7280"))
        }
    }
}

// MARK: - Cards, rows, error boxes

/// A white card, radius 20, hairline shadow (spec §1.2). `background`
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
/// (Available / Pending / Total — spec §6.2/§9.1). `isInflow`
/// marks a money-in row (e.g. savings "Transferred In"): green
/// with a "+" prefix under the shared kind rule — never red, and
/// never applied to a balance or a shortfall (those stay ink, or
/// red when negative via `isNegative`).
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
                .foregroundStyle(isNegative ? DesignTokens.errorText : (isInflow ? DesignTokens.success : DesignTokens.ink))
        }
        .font(.system(size: 15))
    }
}

/// A fund section: ONE UNIFIED CARD that expands in place (no
/// sheet, no overlay — spec §6.2/§9.1). Owner, Nov 16, 2026
/// (build 40): a SHORT colored header strip on top (an icon in a
/// white circle + the fund name + the amount in ONE row, all white
/// on the fund's theme colour — Debt black #0f172a, Spending dark
/// blue #1d4ed8, Extra Fund muted grey #6b7280, Charity mid blue
/// #3b82f6) and a WHITE body below (the MAJORITY of the card)
/// holding the detail rows, editors and actions when expanded.
/// The color is a header accent, not half the card — "the majority
/// should be white, not half half." The detail below the header is
/// part of the SAME card (one container, one boundary) — it was a
/// separate block floating on white with a gap in build 39. The
/// green/amber/red outlines are gone. Chevron `⌄` at the header's
/// right end, white, flips to `⌃` when expanded (instant, build 34).
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
    /// only (icon + name + amount), no white body, no detail, no
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
    public let expanded: Expanded

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
            if isExpanded, !isReorderMode {
                // White body (majority): the detail rows, editors
                // and actions. Directly below the header, no gap —
                // part of the same card, not a separate block. The
                // expanded content keeps its own buttons (Add Money
                // / Spend / Request), so it is not part of the
                // toggle — tapping an action must not collapse the
                // section underneath it. Build 42 (owner, Nov 17,
                // 2026 — "the white body should be double the
                // header"): same 1/3 header, 2/3 white body rule
                // as Home, so the expanded body padding steps up
                // to 28pt top and bottom.
                expanded
                    .padding(.horizontal, pad)
                    .padding(.top, 28)
                    .padding(.bottom, 28)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Build 41 (owner, Nov 16, 2026): a small shadow below
        // the card — the shared fundCardShadow, so the Funds cards
        // lift exactly like the Home cards.
        .fundCardShadow()
    }

    /// The header strip (owner, Nov 16, 2026 — build 40): ONE ROW
    /// — icon in a white circle + title + (admin-only) pencil +
    /// amount + chevron, on the theme colour. The text colour is
    /// the theme's onBanner colour — white on the dark Spending /
    /// Debt banners, ink on the light Charity pale / Extra Fund
    /// tertiary banners (build 41, 3-button scheme). The icon sits
    /// on a WHITE circle in the theme's glyph colour (the
    /// reference's "$ in a white circle"). Loading / failed
    /// show the same strip shape in WHITE / muted grey with grey
    /// skeleton faces — no colour until the numbers arrive, and
    /// never a bare "—" in amount type. (Owner, Nov 16, 2026 —
    /// build 38, "a bit too heavy": the amount is a touch smaller
    /// and the strip a touch shorter than build 37. Build 41,
    /// owner Nov 16, 2026 — "much bigger": the amount is 28pt,
    /// the title 20pt, the icon disc 36pt, 14pt vertical
    /// padding.)
    private func headerStrip(pad: CGFloat) -> some View {
        // Header colour: WHITE while LOADING (owner, Nov 16, 2026
        // — build 40: the pale #dbeafe tint was horrendous, the
        // original white background with grey skeleton shapes was
        // nicest), muted grey #e5e7eb when FAILED (a failed load
        // stays distinct from loading), the theme colour when
        // loaded.
        let bannerColor: Color = {
            if isLoading { return DesignTokens.loadingBanner }
            if amountIsStatus { return Color(hex: "#e5e7eb") }
            return theme?.banner ?? .white
        }()
        // Title colour on the header: the theme's onBanner colour,
        // ink on the plain unthemed face or on a grey failed header
        // (the title always shows, even on failure). While LOADING
        // the title is a skeleton block, not real ink text — real
        // text on the placeholder read as a finished card.
        let titleColor: Color = {
            if theme == nil || amountIsStatus { return DesignTokens.ink }
            return theme?.onBanner ?? .white
        }()
        // Chevron colour: the theme's onBanner colour on a loaded
        // theme banner, muted grey everywhere else.
        let chevronColor: Color = {
            if theme != nil && !isLoading && !amountIsStatus { return theme?.onBanner ?? .white }
            return DesignTokens.muted
        }()
        // Pencil colour: the theme's onBanner colour on a loaded
        // theme banner (it sits on the colored header, next to the
        // title — white on dark banners, ink on the light Charity
        // pale / Extra Fund tertiary banners since build 41),
        // muted grey on the loading/failed header.
        let pencilColor: Color = {
            if theme != nil && !isLoading && !amountIsStatus { return theme?.onBanner ?? .white }
            return DesignTokens.muted
        }()
        return HStack(spacing: 10) {
            if let theme {
                if isLoading || amountIsStatus {
                    SkeletonBlock(width: 36, height: 36, cornerRadius: 18, animated: isLoading)
                } else {
                    // Icon in a white circle (owner, Nov 16, 2026 —
                    // build 40 reference): the theme's glyph colour
                    // on a white disc (build 41 — the banner colour
                    // itself is unreadable on white for the light
                    // banners).
                    Image(systemName: iconName ?? theme.iconName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.glyph)
                        .frame(width: 36, height: 36)
                        .background(.white)
                        .clipShape(Circle())
                }
            }
            if isLoading {
                // Skeleton title while loading (owner, Nov 16,
                // 2026 — build 38): real dark-ink text on the
                // placeholder read as a finished card. The failed
                // state keeps the real title in ink.
                SkeletonBlock(width: 140, height: 22, cornerRadius: 6, animated: true)
            } else {
                Text(TitleCase.apply(to: title))
                    .font(.system(size: theme == nil ? 17 : 20, weight: .bold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
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
                        .foregroundStyle(pencilColor)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename \(TitleCase.apply(to: title))")
            }
            Spacer()
            if isLoading || amountIsStatus {
                // Sized to the loaded 28pt amount (owner, Nov 14,
                // 2026: the 150-wide block was too small and the
                // card looked empty while loading). Static (not
                // shimmering) when failed — a failed load is not a
                // loading state.
                SkeletonBlock(width: 150, height: 34, cornerRadius: 8, animated: isLoading)
            } else {
                Text(amountText)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(theme == nil ? DesignTokens.ink : (theme?.onBanner ?? .white))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            // Chevron (build 41): hidden in reorder mode — the bar
            // does not expand while reordering, so there is nothing
            // to hint at.
            if !isReorderMode {
                Text("⌄")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(chevronColor)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .padding(.horizontal, pad)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bannerColor)
    }
}

// MARK: - Toasts (spec §2.3)
//
// Bottom only, floating clear of the tab bar, auto-dismiss 4s, tap
// dismisses sooner, tab switch clears it. Info: brand blue
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(toast: Binding<Toast?>) {
        self._toast = toast
    }

    public func body(content: Content) -> some View {
        content
            // Centered mid-screen popup (owner, Nov 16, 2026 —
            // build 38): the bottom banner kept missing the bottom.
            .overlay(alignment: .center) {
                if let toast {
                    Button {
                        dismissTask?.cancel()
                        self.toast = nil
                    } label: {
                        Text(toast.message)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(hex: ToastStyle.textHex(for: toast.kind)))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .padding(.horizontal, 20)
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
                    .frame(maxWidth: horizontalSizeClass == .regular ? 900 : .infinity)
                    .padding(.horizontal, 16)
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
/// "Email alert", owner Nov 11, 2026).
public func sourceLabel(_ source: TransactionSource) -> String {
    switch source {
    case .plaid: return "Bank"
    case .manual: return "By hand"
    case .csv: return "File"
    case .amexAlert: return "Email"
    }
}
