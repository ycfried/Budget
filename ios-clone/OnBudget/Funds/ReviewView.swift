import SwiftUI
import OnBudgetKit

// MARK: - Review area (admin only — spec §9.4)
//
// Sub-sections in order:
// 1. Refund Restorations & Held Refunds
// 2. Possible Duplicates (first 20 + Show More, +20 per tap)
// 3. Resolved Duplicates (max 20, newest first)
// 4. Refund Links (first 20 + Show More, +20 per tap)
//
// Every link / merge / release is an admin tap; nothing here links
// anything by itself. Server refusals surface verbatim.

public struct ReviewView: View {
    @ObservedObject public var viewModel: FundsViewModel
    @State private var dedupeShownCount = 20
    @State private var refundLinkShownCount = 20
    @State private var confirmingRelease: HeldRefund?
    @State private var confirmingDedupe: (candidate: DuplicateCandidate, action: DuplicateResolutionAction, rememberAlias: Bool)?
    @State private var confirmingReopen: DuplicateCandidate?
    @State private var confirmingLink: RefundSuggestion?
    @State private var confirmingDismiss: RefundSuggestion?

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
        .confirmationDialog(
            "Release Held Refund",
            isPresented: Binding(
                get: { confirmingRelease != nil },
                set: { if !$0 { confirmingRelease = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(TitleCase.apply(to: "Release")) {
                if let held = confirmingRelease {
                    Task { await viewModel.releaseHeldRefund(held) }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            if let held = confirmingRelease {
                Text("Release \(MoneyFormat.formatCents(held.heldCents)) to spendable surplus? Any amount owed back is covered first.")
            }
        }
        .confirmationDialog(
            "Same Purchase",
            isPresented: Binding(
                get: { confirmingDedupe?.action == .merge },
                set: { if !$0 { confirmingDedupe = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(TitleCase.apply(to: "Same Purchase")) {
                if let pair = confirmingDedupe {
                    Task { await viewModel.resolveDuplicate(pair.candidate, action: .merge, rememberAlias: pair.rememberAlias) }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            Text("Keep one transaction and exclude the other from counts? Neither row is deleted.")
        }
        .confirmationDialog(
            "Separate Purchases",
            isPresented: Binding(
                get: { confirmingDedupe?.action == .separate },
                set: { if !$0 { confirmingDedupe = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(TitleCase.apply(to: "Separate")) {
                if let pair = confirmingDedupe {
                    Task { await viewModel.resolveDuplicate(pair.candidate, action: .separate, rememberAlias: false) }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            Text("Keep both transactions and never flag this pair again?")
        }
        .confirmationDialog(
            "Reopen Duplicate Review",
            isPresented: Binding(
                get: { confirmingReopen != nil },
                set: { if !$0 { confirmingReopen = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(TitleCase.apply(to: "Reopen")) {
                if let candidate = confirmingReopen {
                    Task { await viewModel.reopenDuplicate(candidate) }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            Text("Show this pair in Possible Duplicates again?")
        }
        .confirmationDialog(
            "Link Refund",
            isPresented: Binding(
                get: { confirmingLink != nil },
                set: { if !$0 { confirmingLink = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(TitleCase.apply(to: "Link Refund")) {
                if let suggestion = confirmingLink {
                    Task { await viewModel.linkRefund(suggestion) }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            if let suggestion = confirmingLink {
                Text("Link this \(MoneyFormat.formatCents(suggestion.refund.amountCents)) refund from \(TitleCase.apply(to: suggestion.refund.merchant.lowercased())) to \(TitleCase.apply(to: suggestion.purchase.merchant.lowercased())) \(MoneyFormat.formatCents(suggestion.purchase.amountCents))?")
            }
        }
        .confirmationDialog(
            "Dismiss Suggestion",
            isPresented: Binding(
                get: { confirmingDismiss != nil },
                set: { if !$0 { confirmingDismiss = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(TitleCase.apply(to: "Dismiss")) {
                if let suggestion = confirmingDismiss {
                    Task { await viewModel.dismissSuggestion(suggestion) }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            Text("Hide this suggestion? It will not be shown again.")
        }
    }

    // MARK: 1 — Restorations & Held Refunds

    private var restorationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Refund Restorations & Held Refunds")
                .font(.system(size: 17, weight: .bold))
            Text("Restorations")
                .font(.system(size: 15, weight: .semibold))
            if let error = viewModel.restorationsError {
                FundsErrorBox(error)
            } else if viewModel.restorations.isEmpty {
                FundsMuted(text: "No restorations yet.")
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
                FundsMuted(text: "Nothing held for review.")
            } else {
                ForEach(viewModel.heldRefunds) { held in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MoneyFormat.formatCents(held.heldCents))
                                .font(.system(size: 15, weight: .semibold))
                            Text(held.status == "held" || held.status == "pending"
                                 ? "Held for review"
                                 : "Resolved\(held.resolutionNote.map { " — \($0)" } ?? "")")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: "#6b7280"))
                        }
                        Spacer()
                        // LIVE DEFECT (Nov 9, 2026): the server refuses a
                        // release today (expects status='pending', CHECK
                        // allows only held/written_off/resolved). The
                        // button exists per the intended behaviour and
                        // the refusal surfaces verbatim; when the server
                        // fix lands, this works with no clone change.
                        if held.status == "held" || held.status == "pending" {
                            FundsSmallPrimaryButton("Release", isBusy: viewModel.busyAction == "release-\(held.id.uuidString)") {
                                confirmingRelease = held
                            }
                        }
                    }
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
                FundsMuted(text: "No possible duplicates waiting.")
            } else {
                let shown = Array(viewModel.pendingDuplicates.prefix(dedupeShownCount))
                if viewModel.pendingDuplicates.count > shown.count {
                    FundsMuted(text: "Showing the first \(shown.count) of \(viewModel.pendingDuplicates.count) possible duplicates.")
                }
                ForEach(shown) { candidate in
                    DuplicatePairCard(
                        candidate: candidate,
                        keep: viewModel.duplicateTransactions[candidate.canonicalTransactionId],
                        duplicate: viewModel.duplicateTransactions[candidate.duplicateTransactionId],
                        isBusy: viewModel.busyAction == "dedupe-\(candidate.id.uuidString)",
                        onSamePurchase: { rememberAlias in
                            confirmingDedupe = (candidate: candidate, action: .merge, rememberAlias: rememberAlias)
                        },
                        onSeparate: {
                            confirmingDedupe = (candidate: candidate, action: .separate, rememberAlias: false)
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

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color(hex: "#6b7280"))
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 14))
    }

    // MARK: 3 — Resolved Duplicates

    private var resolvedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resolved Duplicates")
                .font(.system(size: 17, weight: .bold))
            if let error = viewModel.resolvedError {
                FundsErrorBox(error)
            } else if viewModel.resolvedDuplicates.isEmpty {
                FundsMuted(text: "No resolved duplicates.")
            } else {
                ForEach(viewModel.resolvedDuplicates.prefix(20)) { row in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.merchantA) / \(row.merchantB)")
                                .font(.system(size: 15, weight: .semibold))
                            let when = row.resolvedAt.map { " · \(MoneyFormat.displayDay($0))" } ?? ""
                            Text(row.status == "merged"
                                 ? "Merged\(when) — the duplicate can be restored from Trash."
                                 : "Kept separate\(when).")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: "#6b7280"))
                        }
                        Spacer()
                        if row.status == "separate" {
                            FundsSmallTertiaryButton("Reopen", isBusy: viewModel.busyAction == "reopen-\(row.id.uuidString)") {
                                confirmingReopen = row
                            }
                        }
                    }
                    if row.id != viewModel.resolvedDuplicates.prefix(20).last?.id {
                        Divider()
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
                FundsMuted(text: "No unlinked refunds.")
            } else if viewModel.refundSuggestions.isEmpty {
                FundsMuted(text: "No refund links to suggest.")
            } else {
                let shown = Array(viewModel.refundSuggestions.prefix(refundLinkShownCount))
                if viewModel.refundSuggestions.count > shown.count {
                    FundsMuted(text: "Showing the first \(shown.count) of \(viewModel.refundSuggestions.count) refund link suggestions.")
                }
                ForEach(shown) { suggestion in
                    refundLinkCard(suggestion)
                }
                if viewModel.refundSuggestions.count > shown.count {
                    FundsSmallTertiaryButton("Show More") {
                        refundLinkShownCount += 20
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func refundLinkCard(_ suggestion: RefundSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(suggestion.reason.text)
                .font(.system(size: 14, weight: .semibold))
            HStack(alignment: .top, spacing: 16) {
                refundLinkSide(label: "Refund", transaction: suggestion.refund)
                refundLinkSide(label: "Purchase", transaction: suggestion.purchase)
            }
            HStack(spacing: 12) {
                FundsSmallPrimaryButton("Link", isBusy: viewModel.busyAction == "link-\(suggestion.id)") {
                    confirmingLink = suggestion
                }
                FundsSmallTertiaryButton("Dismiss", isBusy: viewModel.busyAction == "dismiss-\(suggestion.id)") {
                    confirmingDismiss = suggestion
                }
            }
        }
        .padding(12)
        .background(Color(hex: "#f9fafb"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func refundLinkSide(label: String, transaction: Transaction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 14, weight: .bold))
            Text(TitleCase.apply(to: transaction.merchant.lowercased()))
                .font(.system(size: 15, weight: .semibold))
            labeledRow("Amount", MoneyFormat.formatCents(transaction.amountCents))
            labeledRow("Date", MoneyFormat.fmtLong(transaction.date))
            labeledRow("Card", transaction.cardSuffix.isEmpty ? "—" : "••\(transaction.cardSuffix)")
            labeledRow("Source", sourceLabel(transaction.source))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        if keep.amountCents == duplicate.amountCents { parts.append("same amount") }
        if keep.date == duplicate.date { parts.append("same date") }
        if keep.cardSuffix == duplicate.cardSuffix { parts.append("same card") }
        if keep.source == duplicate.source { parts.append("same source") }
        return parts.isEmpty ? "Compare the two records below." : "Match: \(parts.joined(separator: ", "))."
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(matchLine)
                .font(.system(size: 14, weight: .semibold))
            if !candidate.merchantA.isEmpty, !candidate.merchantB.isEmpty {
                Text("Flagged as a lookalike — merchant names look related: \(candidate.merchantA) / \(candidate.merchantB).")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
            HStack(alignment: .top, spacing: 16) {
                DuplicateSide(label: "Keep", transaction: keep, fallback: "Keep: transaction not found")
                DuplicateSide(label: "Possible Duplicate", transaction: duplicate, fallback: "Possible duplicate: transaction not found")
            }
            HStack(spacing: 12) {
                FundsSmallPrimaryButton("Same Purchase", isBusy: isBusy) {
                    onSamePurchase(rememberAlias)
                }
                FundsSmallTertiaryButton("Separate", isBusy: isBusy) {
                    onSeparate()
                }
            }
            Toggle(isOn: $rememberAlias) {
                Text("Remember as same merchant — remembers these two merchant names as the same for future review, so similar pairs are treated as the same merchant next time.")
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
                DuplicateDetailRow("Amount", MoneyFormat.formatCents(transaction.amountCents))
                DuplicateDetailRow("Date", MoneyFormat.fmtLong(transaction.date))
                DuplicateDetailRow("Card", transaction.cardSuffix.isEmpty ? "—" : "••\(transaction.cardSuffix)")
                DuplicateDetailRow("Source", sourceLabel(transaction.source))
                DuplicateDetailRow("Counts", transaction.excluded ? "Excluded" : "Counted")
            } else {
                FundsMuted(text: fallback)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct DuplicateDetailRow: View {
    public let label: String
    public let value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack {
            Text(label).foregroundStyle(Color(hex: "#6b7280"))
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 14))
    }
}
