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

public struct ReviewView: View {
    @ObservedObject public var viewModel: FundsViewModel
    @State private var dedupeShownCount = 20
    @State private var resolvedShownCount = 20
    @State private var refundLinkShownCount = 20

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            restorationsSection
            duplicatesSection
            resolvedSection
            refundLinksSection
        }
    }

    // MARK: 1 — Restorations & Held Refunds

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
        VStack(alignment: .leading, spacing: 8) {
            Text("Refund Restorations & Held Refunds")
                .font(.system(size: 17, weight: .bold))
            Text("Restorations")
                .font(.system(size: 15, weight: .semibold))
            if let error = viewModel.restorationsError {
                FundsErrorBox(error)
            } else if viewModel.restorations.isEmpty {
                FundsMuted("No restorations yet.")
            } else {
                ForEach(Array(viewModel.restorations.enumerated()), id: \.offset) { _, entry in
                    Text("Week of \(MoneyFormat.fmtLong(entry.weekStart)) · Restored \(MoneyFormat.formatCents(entry.restoredSurplusCents)) · Debt cut \(MoneyFormat.formatCents(entry.debtReductionCents))\(entry.fundCreditCents != 0 ? " · Fund +\(MoneyFormat.formatCents(entry.fundCreditCents))" : "")")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
            }
            Text("Held for Review")
                .font(.system(size: 15, weight: .semibold))
            if let error = viewModel.heldError {
                FundsErrorBox(error)
            } else if viewModel.heldRefunds.isEmpty {
                FundsMuted("Nothing held for review.")
            } else {
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
        }
    }

    // MARK: 2 — Possible Duplicates

    private var duplicatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Possible Duplicates")
                .font(.system(size: 17, weight: .bold))
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
    /// line — status + date + a brief restore note for merges.
    private func resolvedStatusLine(for row: DuplicateCandidate) -> String {
        let when = row.resolvedAt.map { MoneyFormat.displayDay($0) } ?? ""
        let datePart = when.isEmpty ? "" : " · \(when)"
        if row.status == "merged" {
            return "Merged\(datePart) — Restore from Trash."
        }
        return "Kept separate\(datePart)."
    }

    // MARK: 3 — Resolved Duplicates

    private var resolvedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resolved Duplicates")
                .font(.system(size: 17, weight: .bold))
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
                        onReopen: { Task { await viewModel.reopenDuplicate(row) } }
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

    // MARK: 4 — Refund Links

    private var refundLinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Refund Links")
                .font(.system(size: 17, weight: .bold))
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
                .confirmationDialog(
                    "Release Held Refund",
                    isPresented: $showReleaseConfirm,
                    titleVisibility: .visible
                ) {
                    Button(TitleCase.apply(to: "Release")) { onRelease() }
                    Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
                } message: {
                    Text("Release \(MoneyFormat.formatCents(held.heldCents)) to spendable surplus? Any amount owed back is covered first.")
                }
            }
        }
    }
}

/// One resolved-duplicate row (build 30 redesign: Title-Cased
/// names, one short status line). Its Reopen confirm hangs off
/// the row's own button.
private struct ResolvedDuplicateRow: View {
    let row: DuplicateCandidate
    let statusLine: String
    let isBusy: Bool
    let onReopen: () -> Void
    @State private var showReopenConfirm = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(TitleCase.apply(to: row.merchantA.lowercased())) / \(TitleCase.apply(to: row.merchantB.lowercased()))")
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
                .confirmationDialog(
                    "Reopen Duplicate Review",
                    isPresented: $showReopenConfirm,
                    titleVisibility: .visible
                ) {
                    Button(TitleCase.apply(to: "Reopen")) { onReopen() }
                    Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
                } message: {
                    Text("Show this pair in Possible Duplicates again?")
                }
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
                .confirmationDialog(
                    "Link Refund",
                    isPresented: $showLinkConfirm,
                    titleVisibility: .visible
                ) {
                    Button(TitleCase.apply(to: "Link Refund")) { onLink() }
                    Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
                } message: {
                    Text("Link this \(TransactionFormatting.amountDisplay(for: suggestion.refund).text) refund from \(TitleCase.apply(to: suggestion.refund.merchant.lowercased())) to \(TitleCase.apply(to: suggestion.purchase.merchant.lowercased())) \(MoneyFormat.formatCents(suggestion.purchase.amountCents))?")
                }
                FundsSmallTertiaryButton("Dismiss", isBusy: isDismissBusy) {
                    showDismissConfirm = true
                }
                .confirmationDialog(
                    "Dismiss Suggestion",
                    isPresented: $showDismissConfirm,
                    titleVisibility: .visible
                ) {
                    Button(TitleCase.apply(to: "Dismiss")) { onDismiss() }
                    Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
                } message: {
                    Text("Hide this suggestion? It will not be shown again.")
                }
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
            Text(TitleCase.apply(to: transaction.merchant.lowercased()))
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

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(matchLine)
                .font(.system(size: 14, weight: .semibold))
            HStack(alignment: .top, spacing: 16) {
                DuplicateSide(label: "Keep", transaction: keep, fallback: "Keep: transaction not found")
                DuplicateSide(label: "Possible Duplicate", transaction: duplicate, fallback: "Possible duplicate: transaction not found")
            }
            HStack(spacing: 12) {
                // Build 30: each confirm is a confirmationDialog on
                // ITS button, not on the Review root — on iPad the
                // root-anchored dialogs floated at the top of the
                // page instead of next to the button tapped.
                FundsSmallPrimaryButton("Same Purchase", isBusy: isBusy) {
                    showSamePurchaseConfirm = true
                }
                .confirmationDialog(
                    "Same Purchase",
                    isPresented: $showSamePurchaseConfirm,
                    titleVisibility: .visible
                ) {
                    Button(TitleCase.apply(to: "Same Purchase")) { onSamePurchase(rememberAlias) }
                    Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
                } message: {
                    Text("Keep one transaction and exclude the other from counts? Neither row is deleted.")
                }
                FundsSmallTertiaryButton("Separate", isBusy: isBusy) {
                    showSeparateConfirm = true
                }
                .confirmationDialog(
                    "Separate Purchases",
                    isPresented: $showSeparateConfirm,
                    titleVisibility: .visible
                ) {
                    Button(TitleCase.apply(to: "Separate")) { onSeparate() }
                    Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
                } message: {
                    Text("Keep both transactions and never flag this pair again?")
                }
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
                Text(TitleCase.apply(to: transaction.merchant.lowercased()))
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
