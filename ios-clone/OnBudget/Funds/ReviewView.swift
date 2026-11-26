import SwiftUI
import OnBudgetKit

// MARK: - Review area (admin only — spec §9.4)
//
// Sub-sections in order:
// 1. Refund Restorations & Held Refunds
// 2. Possible Duplicates (first 20 + Show More, +20 per tap)
// 3. Resolved Duplicates (first 20 + Show More, +20 per tap)
// 4. Refund Links (first 20 + Show More, +20 per tap)
//
// Every link / merge / release is an admin tap; nothing here links
// anything by itself. Server refusals surface verbatim.
//
// Build 30: the confirms are NOT one set of confirmationDialogs
// on this root — on iPad those floated at the top of the page
// instead of next to the button tapped (owner report, Nov 15,
// 2026). Same Purchase / Separate are CENTERED alerts (the owner
// wants the Same Purchase explainer centred on the screen, Nov 15,
// 2026); Release / Reopen / Link / Dismiss are confirmationDialogs
// attached to their own buttons. Each card/row owns its confirm
// state, so no two dialogs ever share one view — the same stacked-
// `.alert` pitfall as the Settings screens (build 30, item A).

public struct ReviewView: View {
    @ObservedObject public var viewModel: FundsViewModel
    @State private var dedupeShownCount = 20
    @State private var resolvedShownCount = 20
    @State private var refundLinkShownCount = 20
    /// Resolved Duplicates starts COLLAPSED (build 52): the list
    /// dominated the page and every row repeated the same line.
    @State private var resolvedExpanded = false

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    /// Nothing to review at all — no restorations, no held refunds,
    /// no possible duplicates, no unlinked refunds — and no load
    /// error hiding one of them. (Resolved duplicates are already
    /// dealt with, so they don't count.)
    private var allClear: Bool {
        viewModel.restorations.isEmpty && viewModel.heldRefunds.isEmpty
            && viewModel.pendingDuplicates.isEmpty && !viewModel.hasUnlinkedRefunds
            && viewModel.restorationsError == nil && viewModel.heldError == nil
            && viewModel.duplicatesError == nil && viewModel.refundLinksError == nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Build 64 (F-39, owner Nov 23, 2026): when there is
            // nothing to review, this ONE card is the whole page —
            // the sections below stay hidden, so the page never
            // reads as a list of "No…" lines. When there IS
            // something to review, the sections show as before.
            if allClear {
                allClearCard
            } else {
                // Owner, Nov 25, 2026: Possible Duplicates first,
                // then Resolved, Refund Links, Restorations last.
                duplicatesSection
                resolvedSection
                refundLinksSection
                restorationsSection
            }
        }
    }

    /// One "All clear" card — the whole page when nothing needs
    /// review (build 52, owner Nov 20, 2026 — the page was "an
    /// ocean of text… especially when there's nothing to review";
    /// build 64, F-39: the empty sections are hidden entirely
    /// now, so this card stands alone): a green checkmark and one
    /// line, not three empty sections.
    private var allClearCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color(hex: "#16a34a"))
            VStack(alignment: .leading, spacing: 2) {
                Text("All clear — nothing to review")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                Text("You're all caught up.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
            Spacer()
        }
        .padding(14)
        .background(Color(hex: "#f0fdf4"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(hex: "#bbf7d0"), lineWidth: 1)
        )
    }

    // MARK: - Section card chrome (build 52)

    /// One Review section as a card (build 52, owner Nov 20, 2026
    /// — the page had "no visual language — no icons, cards,
    /// color"): white card, SF Symbol icon + Title Case title in
    /// the header, a plain count when the section has items
    /// waiting. An empty section is a single compact muted line
    /// inside the card, not a heading plus a sentence.
    private struct ReviewSectionCard<Content: View>: View {
        let icon: String
        let title: String
        let count: Int?
        let content: Content

        init(icon: String, title: String, count: Int? = nil, @ViewBuilder content: () -> Content) {
            self.icon = icon
            self.title = title
            self.count = count
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                    Text(TitleCase.apply(to: title))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(DesignTokens.ink)
                    Spacer()
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(DesignTokens.primary)
                    }
                }
                content
            }
            .padding(14)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
            )
        }
    }

    // MARK: 4 — Restorations & Held Refunds

    /// A written-off held refund is not "Resolved": it was closed
    /// with no money moved and no release (F-P2-7).
    private func heldStatusText(_ held: HeldRefund) -> String {
        switch held.status {
        case "held", "pending":
            return "Held for review"
        case "written_off":
            return "Written off\(held.resolutionNote.map { " — \($0)" } ?? "")"
        default:
            return "Resolved\(held.resolutionNote.map { " — \($0)" } ?? "")"
        }
    }

    private var restorationsSection: some View {
        // The two groups keep quiet muted labels (the Funds
        // pattern: a quiet muted inline label, never a bold
        // sub-header) and a load error in one group no longer hides
        // the other. Both empty is one compact line.
        ReviewSectionCard(
            icon: "arrow.uturn.backward",
            title: "Refund Restorations & Held Refunds",
            count: viewModel.restorations.count + viewModel.heldRefunds.count
        ) {
            if let error = viewModel.restorationsError {
                FundsErrorBox(error)
            } else if !viewModel.restorations.isEmpty {
                FundsMuted("Restorations")
                ForEach(Array(viewModel.restorations.enumerated()), id: \.offset) { _, entry in
                    Text("Week of \(MoneyFormat.fmtLong(entry.weekStart)) · Restored \(MoneyFormat.formatCents(entry.restoredSurplusCents)) · Debt cut \(MoneyFormat.formatCents(entry.debtReductionCents))\(entry.fundCreditCents != 0 ? " · Fund +\(MoneyFormat.formatCents(entry.fundCreditCents))" : "")")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
            }
            if let error = viewModel.heldError {
                FundsErrorBox(error)
            } else if !viewModel.heldRefunds.isEmpty {
                FundsMuted("Held for Review")
                ForEach(viewModel.heldRefunds) { held in
                    HeldRefundRow(
                        held: held,
                        statusText: heldStatusText(held),
                        isBusy: viewModel.busyAction == "release-\(held.id.uuidString)",
                        onRelease: { Task { await viewModel.releaseHeldRefund(held) } }
                    )
                    if held.id != viewModel.heldRefunds.last?.id {
                        Divider()
                    }
                }
            }
            if viewModel.restorationsError == nil && viewModel.heldError == nil
                && viewModel.restorations.isEmpty && viewModel.heldRefunds.isEmpty {
                FundsMuted("No restorations or held refunds.")
            }
        }
    }

    // MARK: 1 — Possible Duplicates

    private var duplicatesSection: some View {
        ReviewSectionCard(
            icon: "doc.on.doc",
            title: "Possible Duplicates",
            count: viewModel.pendingDuplicates.count
        ) {
            if let error = viewModel.duplicatesError {
                FundsErrorBox(error)
            } else if viewModel.pendingDuplicates.isEmpty {
                FundsMuted("No possible duplicates waiting.")
            } else {
                let shown = Array(viewModel.pendingDuplicates.prefix(dedupeShownCount))
                if viewModel.pendingDuplicates.count > shown.count {
                    FundsMuted("Showing the first \(shown.count) of \(viewModel.pendingDuplicates.count) possible duplicates.")
                }
                ForEach(shown) { candidate in
                    DuplicatePairCard(
                        candidate: candidate,
                        keep: viewModel.duplicateTransactions[candidate.canonicalTransactionId],
                        duplicate: viewModel.duplicateTransactions[candidate.duplicateTransactionId],
                        isBusy: viewModel.busyAction == "dedupe-\(candidate.id.uuidString)",
                        onSamePurchase: { rememberAlias in
                            Task { await viewModel.resolveDuplicate(candidate, action: .merge, rememberAlias: rememberAlias) }
                        },
                        onSeparate: {
                            Task { await viewModel.resolveDuplicate(candidate, action: .separate, rememberAlias: false) }
                        }
                    )
                }
                if viewModel.pendingDuplicates.count > shown.count {
                    FundsSmallTertiaryButton("Show More") {
                        dedupeShownCount += 20
                    }
                }
            }
        }
    }

    /// Resolved row, second line (build 30 redesign — shorter,
    /// clearer): merchant names Title Cased above, then one short
    /// line — status + date. Build 52 drops the "— Restore from
    /// Trash." tail: Restore is now a real button on the row, not
    /// a repeated label.
    private func resolvedStatusLine(for row: DuplicateCandidate) -> String {
        let when = row.resolvedAt.map { MoneyFormat.displayDay($0) } ?? ""
        let datePart = when.isEmpty ? "" : " · \(when)"
        if row.status == "merged" {
            return "Merged\(datePart)."
        }
        return "Kept separate\(datePart)."
    }

    // MARK: 2 — Resolved Duplicates

    private var resolvedSection: some View {
        // Collapsed behind its count by default (build 52): the
        // resolved list dominated the page. Tap the header to
        // expand — INSTANT, no animation (standing rule). The
        // count reads "N resolved" so the header says what is
        // behind it without opening it.
        VStack(alignment: .leading, spacing: 12) {
            Button {
                resolvedExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                    Text("Resolved Duplicates")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(DesignTokens.ink)
                    Spacer()
                    Text("\(viewModel.resolvedDuplicates.count) resolved")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: "#6b7280"))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                        .rotationEffect(.degrees(resolvedExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Owner, Nov 25, 2026: Resolved was the only Review
            // section without a subtitle — add one, visible while
            // collapsed (the default), in the same FundsMuted
            // style as the other sections' subtitles.
            if !resolvedExpanded {
                FundsMuted(viewModel.resolvedDuplicates.isEmpty
                    ? "No duplicates resolved yet."
                    : "Tap to see the ones you've already decided.")
            }
            if resolvedExpanded {
                if let error = viewModel.resolvedError {
                    FundsErrorBox(error)
                } else if viewModel.resolvedDuplicates.isEmpty {
                    FundsMuted("No resolved duplicates.")
                } else {
                    // Newest first (the fetch orders by resolved_at
                    // desc); first 20 + Show More, same pattern as
                    // Possible Duplicates (F-P2-6).
                    let shown = Array(viewModel.resolvedDuplicates.prefix(resolvedShownCount))
                    if viewModel.resolvedDuplicates.count > shown.count {
                        FundsMuted("Showing the first \(shown.count) of \(viewModel.resolvedDuplicates.count) resolved duplicates.")
                    }
                    ForEach(shown) { row in
                        ResolvedDuplicateRow(
                            row: row,
                            statusLine: resolvedStatusLine(for: row),
                            isBusy: viewModel.busyAction == "reopen-\(row.id.uuidString)",
                            isRestoreBusy: viewModel.busyAction == "restore-\(row.duplicateTransactionId.uuidString)",
                            onReopen: { Task { await viewModel.reopenDuplicate(row) } },
                            onRestore: { Task { await viewModel.restoreResolvedDuplicate(row) } }
                        )
                        if row.id != shown.last?.id {
                            Divider()
                        }
                    }
                    if viewModel.resolvedDuplicates.count > shown.count {
                        FundsSmallTertiaryButton("Show More") {
                            resolvedShownCount += 20
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
    }

    // MARK: 3 — Refund Links

    private var refundLinksSection: some View {
        ReviewSectionCard(
            icon: "link",
            title: "Refund Links",
            count: viewModel.refundSuggestions.count
        ) {
            if let error = viewModel.refundLinksError {
                FundsErrorBox(error)
            } else if !viewModel.hasUnlinkedRefunds {
                FundsMuted("No unlinked refunds.")
            } else if viewModel.refundSuggestions.isEmpty {
                FundsMuted("No refund links to suggest.")
            } else {
                let shown = Array(viewModel.refundSuggestions.prefix(refundLinkShownCount))
                if viewModel.refundSuggestions.count > shown.count {
                    FundsMuted("Showing the first \(shown.count) of \(viewModel.refundSuggestions.count) refund link suggestions.")
                }
                ForEach(shown) { suggestion in
                    RefundLinkCard(
                        suggestion: suggestion,
                        isLinkBusy: viewModel.busyAction == "link-\(suggestion.id)",
                        isDismissBusy: viewModel.busyAction == "dismiss-\(suggestion.id)",
                        onLink: { Task { await viewModel.linkRefund(suggestion) } },
                        onDismiss: { Task { await viewModel.dismissSuggestion(suggestion) } }
                    )
                }
                if viewModel.refundSuggestions.count > shown.count {
                    FundsSmallTertiaryButton("Show More") {
                        refundLinkShownCount += 20
                    }
                }
            }
        }
    }

}

/// One held-refund row. Its Release confirm hangs off the row's
/// own button (build 30 anchoring fix — see DuplicatePairCard).
private struct HeldRefundRow: View {
    let held: HeldRefund
    let statusText: String
    let isBusy: Bool
    let onRelease: () -> Void
    @State private var showReleaseConfirm = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(MoneyFormat.formatCents(held.heldCents))
                    .font(.system(size: 15, weight: .semibold))
                Text(statusText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
            Spacer()
            // PR #62 (live Nov 9, 2026): the server releases on
            // status='held'; the 'pending' arm is kept only so a
            // legacy row is not stranded.
            if held.status == "held" || held.status == "pending" {
                FundsSmallPrimaryButton("Release", isBusy: isBusy) {
                    showReleaseConfirm = true
                }
                .appConfirmDialog(
                    isPresented: $showReleaseConfirm,
                    title: "Release Held Refund",
                    message: "Release \(MoneyFormat.formatCents(held.heldCents)) to spendable surplus? Any amount owed back is covered first.",
                    primaryTitle: "Release",
                    onPrimary: { onRelease() }
                )
            }
        }
    }
}

/// One resolved-duplicate row (build 30 redesign: Title-Cased
/// names, one short status line). Build 52: a MERGED row now has
/// a real Restore button — one action per row — instead of the
/// repeated "Restore from Trash." label; restoring returns the
/// merged transaction to its stored prior state so it counts
/// again. A SEPARATE row keeps its Reopen button. Each confirm
/// hangs off its own button (build 30 anchoring fix).
private struct ResolvedDuplicateRow: View {
    let row: DuplicateCandidate
    let statusLine: String
    let isBusy: Bool
    let isRestoreBusy: Bool
    let onReopen: () -> Void
    let onRestore: () -> Void
    @State private var showReopenConfirm = false
    @State private var showRestoreConfirm = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(TransactionFormatting.displayMerchant(row.merchantA)) / \(TransactionFormatting.displayMerchant(row.merchantB))")
                    .font(.system(size: 15, weight: .semibold))
                Text(statusLine)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
            Spacer()
            if row.status == "separate" {
                FundsSmallTertiaryButton("Reopen", isBusy: isBusy) {
                    showReopenConfirm = true
                }
                .appConfirmDialog(
                    isPresented: $showReopenConfirm,
                    title: "Reopen Duplicate Review",
                    message: "Show this pair in Possible Duplicates again?",
                    primaryTitle: "Reopen",
                    onPrimary: { onReopen() }
                )
            } else if row.status == "merged" {
                FundsSmallTertiaryButton("Restore", isBusy: isRestoreBusy) {
                    showRestoreConfirm = true
                }
                .appConfirmDialog(
                    isPresented: $showRestoreConfirm,
                    title: "Restore This Transaction",
                    message: "Restore this transaction so it counts again? The pair stays resolved.",
                    primaryTitle: "Restore",
                    onPrimary: { onRestore() }
                )
            }
        }
    }
}

/// One refund-link suggestion card. Its Link / Dismiss confirms
/// hang off their own buttons (build 30 anchoring fix).
private struct RefundLinkCard: View {
    let suggestion: RefundSuggestion
    let isLinkBusy: Bool
    let isDismissBusy: Bool
    let onLink: () -> Void
    let onDismiss: () -> Void
    @State private var showLinkConfirm = false
    @State private var showDismissConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(suggestion.reason.text)
                .font(.system(size: 14, weight: .semibold))
            HStack(alignment: .top, spacing: 16) {
                refundLinkSide(label: "Refund", transaction: suggestion.refund)
                refundLinkSide(label: "Purchase", transaction: suggestion.purchase)
            }
            HStack(spacing: 12) {
                FundsSmallPrimaryButton("Link", isBusy: isLinkBusy) {
                    showLinkConfirm = true
                }
                .appConfirmDialog(
                    isPresented: $showLinkConfirm,
                    title: "Link Refund",
                    message: "Link this \(TransactionFormatting.amountDisplay(for: suggestion.refund).text) refund from \(TransactionFormatting.displayMerchant(suggestion.refund.merchant)) to \(TransactionFormatting.displayMerchant(suggestion.purchase.merchant)) \(MoneyFormat.formatCents(suggestion.purchase.amountCents))?",
                    primaryTitle: "Link Refund",
                    onPrimary: { onLink() }
                )
                FundsSmallTertiaryButton("Dismiss", isBusy: isDismissBusy) {
                    showDismissConfirm = true
                }
                .appConfirmDialog(
                    isPresented: $showDismissConfirm,
                    title: "Dismiss Suggestion",
                    message: "Hide this suggestion? It will not be shown again.",
                    primaryTitle: "Dismiss",
                    onPrimary: { onDismiss() }
                )
            }
        }
        .padding(12)
        .background(Color(hex: "#f9fafb"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func refundLinkSide(label: String, transaction: Transaction) -> some View {
        // The Amount row uses the one shared kind rule
        // (amountDisplay): money in green with "+", charity blue,
        // regular kinds ink — never red.
        let display = TransactionFormatting.amountDisplay(for: transaction)
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 14, weight: .bold))
            Text(TransactionFormatting.displayMerchant(transaction.merchant))
                .font(.system(size: 15, weight: .semibold))
            labeledRow("Amount", display.text, valueColor: display.color)
            labeledRow("Date", MoneyFormat.fmtLong(transaction.date))
            labeledRow("Card", transaction.cardSuffix.isEmpty ? "—" : "••\(transaction.cardSuffix)")
            labeledRow("Source", sourceLabel(transaction.source))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledRow(_ label: String, _ value: String, valueColor: Color? = nil) -> some View {
        HStack {
            Text(label).foregroundStyle(Color(hex: "#6b7280"))
            Spacer()
            Text(value).fontWeight(.medium).foregroundStyle(valueColor ?? DesignTokens.ink)
        }
        .font(.system(size: 14))
    }
}

// MARK: - One possible-duplicate comparison card (spec §9.4)
//
// Vertical comparison card: match line, flag-reason line, two sides
// (Keep / Possible duplicate) with labelled Amount / Date / Card /
// Source / Counts rows, buttons BELOW the comparison, and the
// remember-alias checkbox below the buttons. Each card owns its own
// checkbox state. Merge keeps the canonical row and excludes the
// duplicate — it NEVER deletes a row.

public struct DuplicatePairCard: View {
    public let candidate: DuplicateCandidate
    public let keep: Transaction?
    public let duplicate: Transaction?
    public let isBusy: Bool
    public let onSamePurchase: (Bool) -> Void
    public let onSeparate: () -> Void
    @State private var rememberAlias = false
    @State private var showSamePurchaseConfirm = false
    @State private var showSeparateConfirm = false

    public init(
        candidate: DuplicateCandidate,
        keep: Transaction?,
        duplicate: Transaction?,
        isBusy: Bool,
        onSamePurchase: @escaping (Bool) -> Void,
        onSeparate: @escaping () -> Void
    ) {
        self.candidate = candidate
        self.keep = keep
        self.duplicate = duplicate
        self.isBusy = isBusy
        self.onSamePurchase = onSamePurchase
        self.onSeparate = onSeparate
    }

    private var matchLine: String {
        guard let keep, let duplicate else { return "Compare the two records below." }
        var parts: [String] = []
        if keep.amountCents == duplicate.amountCents { parts.append("Same Amount") }
        if keep.date == duplicate.date { parts.append("Same Date") }
        if keep.cardSuffix == duplicate.cardSuffix { parts.append("Same Card") }
        if keep.source == duplicate.source { parts.append("Same Source") }
        return parts.isEmpty ? "Compare the two records below." : parts.joined(separator: ", ")
    }

    /// Build 68 (owner, Nov 23, 2026 — the Toiremorg $1 pair):
    /// both rows are charity gifts (kind = charity), not purchases.
    /// The owner confirmed the two $1.00 Toiremorg rows (Nov 4
    /// bank + Nov 5 email) are the SAME gift reported twice, and
    /// he will tap "Same Purchase" himself once build 68 lands —
    /// so "Same Purchase" stays ENABLED for charity pairs (it is
    /// never hidden or disabled here), with copy that says plainly
    /// what merging does. The server's repoint logic still expects
    /// the kept row to be a live purchase, so the merge itself
    /// needs the server follow-up flagged in the build 68 report;
    /// until then a failed tap surfaces a plain-language message
    /// (see ReviewPageView), not the cryptic server text.
    /// No data is changed here — nothing is resolved or excluded
    /// from this screen; the owner merges the pair himself.
    private var isCharityPair: Bool {
        guard let keep, let duplicate else { return false }
        return keep.kind == .charity && duplicate.kind == .charity
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(matchLine)
                .font(.system(size: 14, weight: .semibold))
            // Build 68: for a charity pair, one plain line says
            // what the pair is — two reports of one gift — so the
            // choice below reads in context.
            if isCharityPair {
                Text("Both rows are charity gifts — the same gift reported twice.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
            HStack(alignment: .top, spacing: 16) {
                DuplicateSide(label: "Keep", transaction: keep, fallback: "Keep: transaction not found")
                DuplicateSide(label: "Possible Duplicate", transaction: duplicate, fallback: "Possible duplicate: transaction not found")
            }
            HStack(spacing: 12) {
                // Build 30: the two confirms are CENTRED dialogs,
                // not popovers — the owner (Nov 15, 2026) wants the
                // Same Purchase explainer centred on the screen,
                // not anchored next to its button. (Build 74: all
                // Review confirms are the app-styled choice dialog
                // now — the system alert rendered both buttons
                // blue, and a confirmationDialog on iPad is a
                // popover, which is how the old root-anchored
                // dialogs ended up floating at the top of the page.)
                FundsSmallPrimaryButton("Same Purchase", isBusy: isBusy) {
                    showSamePurchaseConfirm = true
                }
                .appConfirmDialog(
                    isPresented: $showSamePurchaseConfirm,
                    title: "Same Purchase",
                    // Build 68: a charity pair merges two reports
                    // of ONE gift — the message uses the gift wording,
                    // not the generic purchase wording. Shortened
                    // Nov 25 (owner): two short sentences; the button
                    // and the side-by-side rows already say the rest.
                    message: isCharityPair
                        ? "One gift stays counted, the other is excluded. Nothing is deleted."
                        : "One stays counted, the other is excluded. Nothing is deleted.",
                    primaryTitle: "Same Purchase",
                    onPrimary: { onSamePurchase(rememberAlias) }
                )
                FundsSmallTertiaryButton("Separate", isBusy: isBusy) {
                    showSeparateConfirm = true
                }
                .appConfirmDialog(
                    isPresented: $showSeparateConfirm,
                    title: "Separate Purchases",
                    message: "Keep both transactions and never flag this pair again?",
                    primaryTitle: "Separate",
                    onPrimary: { onSeparate() }
                )
            }
            Toggle(isOn: $rememberAlias) {
                Text("Remember as same merchant")
                    .font(.system(size: 14))
            }
        }
        .padding(12)
        .background(Color(hex: "#f9fafb"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

public struct DuplicateSide: View {
    public let label: String
    public let transaction: Transaction?
    public let fallback: String

    public init(label: String, transaction: Transaction?, fallback: String) {
        self.label = label
        self.transaction = transaction
        self.fallback = fallback
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 14, weight: .bold))
            if let transaction {
                Text(TransactionFormatting.displayMerchant(transaction.merchant))
                    .font(.system(size: 15, weight: .semibold))
                // The Amount row uses the one shared kind rule
                // (amountDisplay): money in green with "+",
                // charity blue, regular kinds ink — never red.
                DuplicateDetailRow("Amount", TransactionFormatting.amountDisplay(for: transaction).text, valueColor: TransactionFormatting.amountDisplay(for: transaction).color)
                DuplicateDetailRow("Date", MoneyFormat.fmtLong(transaction.date))
                DuplicateDetailRow("Card", transaction.cardSuffix.isEmpty ? "—" : "••\(transaction.cardSuffix)")
                DuplicateDetailRow("Source", sourceLabel(transaction.source))
                DuplicateDetailRow("Counts", transaction.excluded ? "Excluded" : "Counted")
            } else {
                FundsMuted(fallback)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct DuplicateDetailRow: View {
    public let label: String
    public let value: String
    /// Amount colour under the shared kind rule, when this row is
    /// an amount; nil keeps the inherited ink.
    public let valueColor: Color?

    public init(_ label: String, _ value: String, valueColor: Color? = nil) {
        self.label = label
        self.value = value
        self.valueColor = valueColor
    }

    public var body: some View {
        HStack {
            Text(label).foregroundStyle(Color(hex: "#6b7280"))
            Spacer()
            Text(value).fontWeight(.medium).foregroundStyle(valueColor ?? DesignTokens.ink)
        }
        .font(.system(size: 14))
    }
}
