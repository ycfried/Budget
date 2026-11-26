import SwiftUI
import OnBudgetKit

// MARK: - Add Money (top-up, admin only — spec §9.3)
//
// "Log cash for the fund."
// Manual top-ups simply add to the fund balance. Top-ups never touch
// weekly allowance / spending room / debt math. Admin-only;
// double-tap protection. Build 41 (owner, Nov 17, 2026): the
// "I have already put this money in checking" toggle no longer
// blocks saving — untoggled, the top-up saves as PENDING and counts
// for nothing until it is confirmed on its Activity-feed entry.
// Build 42 (owner, Nov 17, 2026): the old "owed back" split is
// gone — a top-up adds to the fund, full stop; money owed lives on
// the Debt card (Overspent (Past)), not here.

public struct AddMoneyForm: View {
    @ObservedObject public var viewModel: FundsViewModel
    /// Closes the form back to the Funds list (owned by FundsView).
    public var onClose: () -> Void = {}
    /// The fund's display name for the preview/confirm text (e.g.
    /// "Savings") — rename-aware when the caller passes it, as
    /// PayDebtForm does. Nil falls back to "the fund": the
    /// rename-aware name lives in `appState.fundNames`, which this
    /// form cannot reach (build 42, owner Nov 17, 2026).
    public var fundName: String?
    @State private var amountText = ""
    @State private var note = ""
    @State private var confirmed = false
    @State private var fieldError: String?
    @State private var showConfirm = false

    public init(viewModel: FundsViewModel, fundName: String? = nil, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.fundName = fundName
        self.onClose = onClose
    }

    private var amountCents: Int? { MoneyFormat.parseDollarsStrict(amountText) }

    private var fundNameText: String { fundName ?? "the fund" }

    private var previewText: String {
        guard let cents = amountCents, cents > 0 else { return "Enter an amount." }
        // Build 42 (owner, Nov 17, 2026): no "owed back" split — a
        // top-up simply adds to the fund. The old topupPreview call
        // is gone: it fed only the removed split text, and the
        // preview now needs nothing but the typed amount. The save
        // logic, RPCs and pending/confirmed behaviour are untouched.
        if confirmed {
            return "Add \(MoneyFormat.formatCents(cents)) to \(fundNameText)."
        }
        return "Add \(MoneyFormat.formatCents(cents)) to \(fundNameText). It will stay pending until you confirm the money is in checking."
    }

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("Add Money")
                // Build 41 (owner, Nov 17, 2026): a top-up may be
                // saved BEFORE the money is in checking — it saves
                // as PENDING until the toggle is confirmed on the
                // entry. The old "log cash already in checking"
                // wording no longer covers both cases.
                FundsMuted("Log cash for the fund.")
                // Build 42 (owner, Nov 17, 2026): full-width Amount,
                // like the Note field below — FundsMoneyField caps
                // at 220px (spec §1.2), which left this field ~1/3
                // wide. Same "$" prefix, same parsing/validation.
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Amount", required: true)
                    DollarTextField(text: $amountText, maxWidth: .infinity, minHeight: 48)
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Note")
                    FundsTextField("", text: $note)
                        .onChange(of: note) { _, newValue in
                            if newValue.count > 120 { note = String(newValue.prefix(120)) }
                        }
                }
                Toggle(isOn: $confirmed) {
                    Text("I have already put this money in checking")
                        .font(.system(size: 15))
                }
                Text(previewText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
                if let fieldError {
                    FundsErrorBox(fieldError)
                }
                // Build 70, item 5 (owner, Nov 24, 2026): the
                // Cancel button is gone — the back button above
                // the form closes it without saving, so Cancel
                // was a redundant way out.
                FundsPrimaryButton("Save Top-Up", isBusy: viewModel.busyAction == "topup") {
                    saveTapped()
                }
                FundsMuted("Log each deposit only once.")
            }
        }
        // Build 37 (owner, Nov 16, 2026): a CENTERED alert, not a
        // confirmationDialog — on iPad a confirmationDialog is a
        // popover anchored at the top of the screen (same fix as the
        // Clear Debt confirm). An .alert is centred on iPhone and
        // iPad alike.
        .alert(
            "Save Top-Up",
            isPresented: $showConfirm
        ) {
            Button(TitleCase.apply(to: "Save Top-Up")) {
                Task {
                    // On success the form clears AND closes back to
                    // the Funds list with the success toast (owner
                    // decision #9); on failure the typed input stays
                    // put beside the error. The in-flight double-tap
                    // guard lives in addTopup itself.
                    if await viewModel.addTopup(amountCents: amountCents ?? 0, note: note.trimmingCharacters(in: .whitespaces), confirmed: confirmed) {
                        amountText = ""
                        note = ""
                        confirmed = false
                        fieldError = nil
                        onClose()
                    }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            Text(previewText)
        }
    }

    private func saveTapped() {
        guard let cents = amountCents, cents > 0 else {
            fieldError = "Enter a valid amount."
            return
        }
        // Build 41 (owner, Nov 17, 2026): the toggle no longer
        // BLOCKS saving — without it the top-up saves as PENDING
        // and counts for nothing until it is confirmed on the
        // entry in the Activity feed. The old red "Confirm you
        // have already put this money in checking." error is gone.
        fieldError = nil
        showConfirm = true
    }
}

// MARK: - Pay Carried Debt from Extra Fund (admin only, build 29)
//
// Mirrors the fund-spending form: amount + note + confirmation dialog, and the
// same "Fund Is Short" typed-reason override sheet when the Extra
// Fund does not cover the amount. The server refuses an amount over
// the remaining debt (never silently partial) and returns the debt
// left after the payment.

public struct PayDebtForm: View {
    @ObservedObject public var viewModel: FundsViewModel
    /// The funds' CURRENT display names (e.g. "Savings" /
    /// "Overspent (Past)" when renamed) — button labels and the
    /// heading read them, never hardcoded defaults (build 41).
    public let fundName: String
    public let debtName: String
    /// Closes the form back to the Funds list (owned by FundsView).
    public var onClose: () -> Void = {}
    @State private var amountText = ""
    @State private var note = ""
    @State private var fieldError: String?
    @State private var showConfirm = false
    @State private var showOverride = false
    @State private var overrideReason = ""
    @State private var pendingCents: Int?

    public init(viewModel: FundsViewModel, fundName: String, debtName: String, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.fundName = fundName
        self.debtName = debtName
        self.onClose = onClose
    }

    private var amountCents: Int? { MoneyFormat.parseDollarsStrict(amountText) }

    /// The preview line: what leaves the fund and what the
    /// debt becomes. Client-side only — the server's remaining debt
    /// (returned by the RPC) is authoritative.
    private var previewText: String? {
        guard let cents = amountCents, cents > 0,
              let debt = viewModel.debtBalanceCents else { return nil }
        return "\(MoneyFormat.formatCents(cents)) leaves the \(fundName), debt becomes \(MoneyFormat.formatCents(max(0, debt - cents)))."
    }

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("Pay \(debtName) from \(fundName)")
                FundsMuted("Lowers the \(debtName) and the \(fundName) balance.")
                FundsMoneyField("Amount", text: $amountText)
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Note")
                    FundsTextField("", text: $note)
                }
                if let previewText {
                    FundsMuted(previewText)
                }
                if let fieldError {
                    FundsErrorBox(fieldError)
                }
                // Build 70, item 5 (owner, Nov 24, 2026): the
                // Cancel button is gone — the back button above
                // the form closes it without saving, so Cancel
                // was a redundant way out.
                FundsPrimaryButton("Pay \(debtName)") {
                    guard let cents = amountCents, cents > 0 else {
                        fieldError = "Enter a valid amount."
                        return
                    }
                    if let debt = viewModel.debtBalanceCents, cents > debt {
                        fieldError = "That is more than the \(MoneyFormat.formatCents(debt)) debt left."
                        return
                    }
                    fieldError = nil
                    pendingCents = cents
                    showConfirm = true
                }
            }
        }
        // Build 37 (owner, Nov 16, 2026): a CENTERED alert, not a
        // confirmationDialog — on iPad a confirmationDialog is a
        // popover anchored at the top of the screen (same fix as the
        // Clear Debt confirm). An .alert is centred on iPhone and
        // iPad alike.
        .alert(
            "Pay \(debtName) from \(fundName)",
            isPresented: $showConfirm
        ) {
            Button(TitleCase.apply(to: "Pay \(debtName)")) {
                Task { await record(overrideReason: nil) }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            if let pendingCents {
                Text(previewText ?? "Pay \(MoneyFormat.formatCents(pendingCents)) toward the carried debt?")
            }
        }
        .alert("Fund Is Short", isPresented: $showOverride) {
            TextField("Reason for overriding", text: $overrideReason)
            Button(TitleCase.apply(to: "Pay Anyway")) {
                Task { await record(overrideReason: overrideReason.trimmingCharacters(in: .whitespaces)) }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            if let pendingCents {
                Text("The fund does not cover \(MoneyFormat.formatCents(pendingCents)). Pay it anyway with a typed reason — it will be logged.")
            }
        }
    }

    private func record(overrideReason: String?) async {
        guard let cents = pendingCents else { return }
        do {
            _ = try await viewModel.payDebtFromFund(amountCents: cents, note: note.trimmingCharacters(in: .whitespaces), overrideReason: overrideReason)
            amountText = ""
            note = ""
            pendingCents = nil
        } catch let error as OnBudgetError {
            if case .insufficientFund = error, overrideReason == nil {
                showOverride = true
            } else {
                viewModel.alertTitle = "Could Not Pay \(debtName)"
                viewModel.alertMessage = error.displayMessage
            }
        } catch {
            viewModel.alertTitle = "Could Not Pay \(debtName)"
            viewModel.alertMessage = OnBudgetError.displayMessage(for: error)
        }
    }
}

// MARK: - Debt management: Clear + Adjust in ONE sheet (build 70)
//
// Owner, Nov 24, 2026: the "Edit Overspent (Past)" screen was
// confusing — TWO redundant fields ("Amount to Add" and "New Total
// Overspent (Past)"), each with its own Note, on a separate screen
// from Clear Debt. This ONE sheet replaces BOTH the old Clear Debt
// form and the Edit Debt sheet: the debt is managed in one place,
// titled with the plain word "Debt" (the owner named the flow
// "Debt"; the "Edit Overspent (Past)" name is gone — the sheet's
// title and buttons read "Debt", not the fund's stored display
// name, by the owner's explicit rename). A mode slider (the
// unified slider) offers:
//   - Clear Debt: write off part or all of the debt — the slider,
//     % buttons and amount field from the old Clear form. No money
//     moves; the amount is recorded in the activity log.
//   - Adjust Debt: correct the total when the real debt differs
//     from the app's calculated weeks total (e.g. after a cash
//     payment). The server stores the delta (set_debt).
// ONE amount field (its meaning follows the mode) and ONE Note
// field, shared. The confirm is a centered .alert (the Clear Debt
// precedent, build 37). No Cancel button — the form is inline on
// the Funds page with a back button above it (build 70, item 5:
// the back button IS the cancel). Setting the debt to $0 is not
// offered in Adjust — that is Clear Debt.
// The debt math and the ledger are untouched (build 69, item 1);
// this is the management UI only.
public struct DebtManagementSheet: View {
    public enum Mode: Hashable {
        case clear
        case adjust
    }

    @ObservedObject public var viewModel: FundsViewModel
    public let initialMode: Mode
    /// Closes the form back to the Funds list (owned by FundsView).
    public var onClose: () -> Void = {}

    @State private var mode: Mode
    @State private var amountCents = 0
    @State private var amountText = "0"
    @State private var note = ""
    @State private var showConfirm = false
    @State private var pending: PendingChange?
    /// iPad (build 37, owner Nov 16, 2026): the % and action
    /// buttons are larger/taller on the tablet form factor.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isIPad: Bool { horizontalSizeClass == .regular }

    public init(viewModel: FundsViewModel, initialMode: Mode = .clear, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.initialMode = initialMode
        self._mode = State(initialValue: initialMode)
        self.onClose = onClose
    }

    private struct PendingChange {
        let mode: Mode
        let cents: Int
        let note: String
    }

    private var debtCents: Int? { viewModel.debtBalanceCents }
    private var debtDollars: Double { Double(debtCents ?? 0) / 100 }
    private var currentCents: Int { debtCents ?? 0 }

    /// The slider's value in dollars, two-way bound to
    /// `amountCents` (Clear mode only — the Adjust field writes
    /// `amountCents` directly). Same clamping as the old Clear
    /// form (build 37): after a full clear `refresh()` drops the
    /// debt to $0 while this form is still open, and an unclamped
    /// value outside a range that has collapsed to 0...0 is a
    /// degenerate Slider state — the getter CLAMPS to the current
    /// debt so the re-render in between never hands the Slider an
    /// out-of-range value.
    private var sliderDollars: Binding<Double> {
        Binding(
            get: { min(max(Double(amountCents) / 100, 0), debtDollars) },
            set: { newValue in
                amountCents = Int((newValue * 100).rounded())
                amountText = dollarsText(amountCents)
            }
        )
    }

    /// Plain dollars for the field (`parseDollarsStrict` takes no
    /// commas or $): whole dollars bare, cents with two decimals.
    private func dollarsText(_ cents: Int) -> String {
        if cents % 100 == 0 { return "\(cents / 100)" }
        return String(format: "%.2f", Double(cents) / 100)
    }

    private func setAmount(_ cents: Int) {
        let debt = debtCents ?? 0
        amountCents = min(max(cents, 0), debt)
        amountText = dollarsText(amountCents)
    }

    private var remainingCents: Int? {
        guard let debt = debtCents else { return nil }
        return max(0, debt - amountCents)
    }

    /// The confirm only renders for a valid amount (no greyed-out
    /// buttons, owner Nov 13): Clear needs an amount above $0;
    /// Adjust needs a total above $0 that differs from the
    /// current balance (the server refuses a zero delta, and $0
    /// is Clear Debt's job).
    private var isConfirmValid: Bool {
        switch mode {
        case .clear: return amountCents > 0
        case .adjust: return amountCents > 0 && amountCents != currentCents
        }
    }

    private var confirmLabel: String {
        switch mode {
        case .clear: return "Clear \(MoneyFormat.formatCents(amountCents))"
        case .adjust: return "Set Debt to \(MoneyFormat.formatCents(amountCents))"
        }
    }

    private var confirmTitle: String {
        mode == .clear ? "Clear Debt" : "Adjust Debt"
    }

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("Debt")
                // Mode choice — the unified slider (one track,
                // sliding thumb), like the Tzedaka and Adjust
                // Budget sheets. Switching modes clears the
                // amount: its meaning follows the mode (an amount
                // to clear vs a new total), so a Clear amount must
                // never carry into Adjust.
                SquarishPicker(
                    [(Mode.clear, "Clear Debt"), (Mode.adjust, "Adjust Debt")],
                    selection: $mode
                )
                if let debt = debtCents {
                    if mode == .clear {
                        FundsMoneyField("Amount to Clear", text: $amountText)
                            .onChange(of: amountText) { _, newValue in
                                // Typing moves the slider. A value
                                // that does not parse yet (mid-type)
                                // leaves the slider where it was.
                                if let cents = MoneyFormat.parseDollarsStrict(newValue) {
                                    amountCents = min(max(cents, 0), debt)
                                }
                            }
                        // The range is never zero-width (build 37 —
                        // see sliderDollars): at $0 debt the range is
                        // 0...0.01, not 0...0.
                        Slider(value: sliderDollars, in: 0...max(debtDollars, 0.01), step: 0.01)
                            .tint(DesignTokens.primary)
                        HStack {
                            Text("$0")
                                .font(.system(size: 13))
                                .foregroundStyle(Color(hex: "#6b7280"))
                            Spacer()
                            Text(MoneyFormat.formatCents(debt))
                                .font(.system(size: 13))
                                .foregroundStyle(Color(hex: "#6b7280"))
                        }
                        HStack(spacing: 8) {
                            // Build 37 (owner, Nov 16, 2026): a 100%
                            // button joins 10 / 25 / 50 / 75% — one tap
                            // clears the full debt instead of sliding to
                            // the end.
                            ForEach([10, 25, 50, 75, 100], id: \.self) { pct in
                                FundsSmallTertiaryButton("\(pct)%", isLarge: isIPad) {
                                    setAmount((debt * pct) / 100)
                                }
                            }
                        }
                        if amountCents > 0, let remaining = remainingCents {
                            FundsBreakdownRow("Remaining Debt", value: MoneyFormat.formatCents(remaining))
                        } else {
                            FundsMuted("Drag the slider or type an amount.")
                        }
                    } else {
                        // Adjust — ONE amount field: the corrected
                        // TOTAL (not an amount to add). A correction
                        // can be larger than the current balance, so
                        // there is no upper clamp, only a floor at $0.
                        FundsMoneyField("New Total", text: $amountText)
                            .onChange(of: amountText) { _, newValue in
                                if let cents = MoneyFormat.parseDollarsStrict(newValue) {
                                    amountCents = max(cents, 0)
                                }
                            }
                    }
                    // ONE Note field, shared by both modes.
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel("Note")
                        FundsTextField("", text: $note)
                            .onChange(of: note) { _, newValue in
                                if newValue.count > 120 { note = String(newValue.prefix(120)) }
                            }
                    }
                    if isConfirmValid {
                        FundsPrimaryButton(confirmLabel, isLarge: isIPad) {
                            pending = PendingChange(mode: mode, cents: amountCents, note: note.trimmingCharacters(in: .whitespaces))
                            showConfirm = true
                        }
                    }
                } else if let error = viewModel.debtError {
                    FundsErrorBox(error)
                } else {
                    // Loading mandate (owner, Nov 26, 2026): the
                    // old single 200x16 block stood in for the
                    // whole form (mode picker + amount field +
                    // slider + note + confirm), so the form jumped
                    // from one thin line to full height when the
                    // debt loaded. Skeletons shaped like the form
                    // hold its space instead.
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBlock(height: 52)
                        SkeletonBlock(height: 52)
                        SkeletonBlock(height: 48)
                        SkeletonBlock(height: 56, cornerRadius: 10)
                    }
                }
            }
        }
        .onChange(of: mode) { _, _ in
            amountCents = 0
            amountText = "0"
        }
        // Build 37 (owner, Nov 16, 2026): a CENTERED alert, not a
        // confirmationDialog — on iPad a confirmationDialog is a
        // popover anchored at the top of the screen, and the owner
        // reported the Clear Debt confirm floating up there. An
        // .alert is centred on iPhone and iPad alike. The bottom
        // success toast is untouched.
        .alert(
            confirmTitle,
            isPresented: $showConfirm
        ) {
            Button(TitleCase.apply(to: confirmLabel)) {
                guard let pending else { return }
                self.pending = nil
                Task {
                    let ok: Bool
                    if pending.mode == .clear {
                        ok = await viewModel.clearDebt(amountCents: pending.cents, note: pending.note)
                    } else {
                        ok = await viewModel.setDebt(amountCents: pending.cents, note: pending.note)
                    }
                    if ok { onClose() }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) { pending = nil }
        } message: {
            if let pending {
                if pending.mode == .clear {
                    Text("Write off \(MoneyFormat.formatCents(pending.cents)) of the Debt? \(MoneyFormat.formatCents(max(0, currentCents - pending.cents))) will remain. No money moves.")
                } else {
                    Text("Set Debt to \(MoneyFormat.formatCents(pending.cents))? This replaces the current \(MoneyFormat.formatCents(currentCents)).")
                }
            }
        }
    }
}

// MARK: - Ask for Fund Money (all roles — spec §9.3)
//
// "The admin approves or declines each request." Below the form:
// the fund-request queue (max 50, newest first), each row expandable
// to detail; pending requests show admin-only Approve / Decline.

public struct AskFundForm: View {
    @ObservedObject public var viewModel: FundsViewModel
    /// Closes the form back to the Funds list (owned by FundsView).
    public var onClose: () -> Void = {}
    @State private var amountText = ""
    @State private var note = ""
    @State private var fieldError: String?

    public init(viewModel: FundsViewModel, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    private var amountCents: Int? { MoneyFormat.parseDollarsStrict(amountText) }

    public var body: some View {
        VStack(spacing: 16) {
            FundsCard {
                VStack(alignment: .leading, spacing: 12) {
                    FundsHeading("Ask for Fund Money")
                    FundsMuted("The admin approves or declines each request.")
                    FundsMoneyField("Amount", text: $amountText)
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel("Note")
                        FundsTextField("", text: $note)
                    }
                    if let fieldError {
                        FundsErrorBox(fieldError)
                    }
                    // Build 70, item 5 (owner, Nov 24, 2026):
                    // the Cancel button is gone — the back button
                    // above the form closes it without saving, so
                    // Cancel was a redundant way out.
                    FundsPrimaryButton("Send Request", isBusy: viewModel.busyAction == "request") {
                        guard let cents = amountCents, cents > 0 else {
                            fieldError = "Enter a valid amount."
                            return
                        }
                        fieldError = nil
                        Task {
                            // Clear only on success — on failure
                            // the typed input stays beside the
                            // error (F-P1-4).
                            if await viewModel.createFundRequest(
                                amountCents: cents,
                                note: note.trimmingCharacters(in: .whitespaces),
                                transactionId: nil
                            ) {
                                amountText = ""
                                note = ""
                            }
                        }
                    }
                }
            }
            FundRequestQueue(viewModel: viewModel)
        }
    }
}

public struct FundRequestQueue: View {
    @ObservedObject public var viewModel: FundsViewModel
    @State private var expandedId: UUID?
    @State private var approving: FundRequest?
    @State private var approveAmountText = ""
    @State private var approveError: String?
    @State private var showOverride = false
    @State private var overrideReason = ""
    @State private var declining: FundRequest?

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    /// Skeleton request rows that fill the visible page (owner,
    /// Nov 26, 2026 — skeletons must fill the whole visible page,
    /// not a fixed three). A request row is 29pt tall and the
    /// list starts ~450pt down the sheet (the Ask form above it).
    private var fundRequestsSkeletonRowCount: Int {
        SkeletonFill.rows(rowHeight: 29, above: 450)
    }

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("Fund Requests")
                if let error = viewModel.fundRequestsError {
                    FundsErrorBox(error)
                } else if !viewModel.fundRequestsReady {
                    // Loading mandate (owner, Nov 26, 2026): the
                    // requests are a supporting load, not in the
                    // page gate — the Ask form can open before
                    // they land, and the old body flashed "No fund
                    // requests yet." and then grew rows. Skeleton
                    // rows shaped like request rows hold the space.
                    // Enough rows to fill the visible page (owner,
                    // Nov 26, 2026 — skeletons must fill the whole
                    // visible page, not a fixed three); a request
                    // row is 29pt tall and the list starts ~450pt
                    // down the sheet (the Ask form above it).
                    ForEach(0..<fundRequestsSkeletonRowCount, id: \.self) { index in
                        HStack {
                            SkeletonBlock(width: 200, height: 16)
                            Spacer()
                            SkeletonBlock(width: 24, height: 16)
                        }
                        .padding(.vertical, 6)
                        if index < fundRequestsSkeletonRowCount - 1 {
                            Divider()
                        }
                    }
                } else if viewModel.fundRequests.isEmpty {
                    FundsMuted("No fund requests yet.")
                } else {
                    ForEach(viewModel.fundRequests) { request in
                        fundRequestRow(request)
                        if request.id != viewModel.fundRequests.last?.id {
                            Divider()
                        }
                    }
                    // The fetch caps at 50 (PostgrestClient); say so
                    // when the cap binds (F-P2-8).
                    if viewModel.fundRequests.count >= 50 {
                        FundsMuted("Showing the latest 50 fund requests.")
                    }
                }
            }
        }
        // Build 43 (owner, Nov 17, 2026 — item 17): full-screen
        // cover, not a detent sheet — popups are always full size.
        .fullScreenCover(item: $approving) { request in
            ApproveRequestSheet(
                request: request,
                amountText: $approveAmountText,
                error: approveError,
                onApprove: { Task { await approveTapped(overrideReason: nil) } },
                onCancel: { approving = nil; approveError = nil }
            )
                // iPad width (owner, Nov 12, 2026): same treatment
                // as the Weekly Budget sheet — 600pt width in the
                // regular size class, in a full-screen cover.
        }
        .appConfirmDialog(
            isPresented: $showOverride,
            title: "Fund Is Short",
            message: MoneyFormat.parseDollarsStrict(approveAmountText).map { "The fund does not cover \(MoneyFormat.formatCents($0)). You can still approve with a typed reason — it will be logged." } ?? "",
            primaryTitle: "Approve Anyway",
            extra: AnyView(
                TextField("Reason for overriding", text: $overrideReason)
                    .padding(.horizontal, 14)
                    .frame(height: 48, alignment: .leading)
                    .background(.white)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            ),
            onPrimary: {
                Task { await approveTapped(overrideReason: overrideReason.trimmingCharacters(in: .whitespaces)) }
            }
        )
        // Build 37 (owner, Nov 16, 2026): a CENTRED dialog, not a
        // confirmationDialog — on iPad a confirmationDialog is a
        // popover anchored at the top of the screen (same fix as the
        // Clear Debt confirm). Build 74: the app-styled choice
        // dialog (AppConfirmDialog) — the system alert rendered
        // both buttons blue.
        .appConfirmDialog(
            isPresented: Binding(
                get: { declining != nil },
                set: { if !$0 { declining = nil } }
            ),
            title: "Decline Request",
            message: "Decline this fund request?",
            primaryTitle: "Decline",
            onPrimary: {
                if let declining {
                    Task { await viewModel.declineRequest(declining) }
                }
            }
        )
    }

    private func statusLabel(_ request: FundRequest) -> String {
        if request.status == "split" {
            return "Split — \(MoneyFormat.formatCents(request.remainderCents)) remaining"
        }
        // Title Case, never ALL-CAPS (F-P2-5).
        switch request.status {
        case "pending": return "Pending"
        case "approved": return "Approved"
        case "declined": return "Declined"
        default: return request.status.capitalized
        }
    }

    private func statusSentence(_ request: FundRequest) -> String {
        switch request.status {
        case "pending":
            return "Waiting on the admin decision. You can track it here — its status changes when the admin approves or declines it."
        case "approved":
            return "Approved — the fund balance above already reflects it."
        case "split":
            return "Split approval — see the approved and remaining amounts above."
        default:
            return "Declined by the admin."
        }
    }

    @ViewBuilder
    private func fundRequestRow(_ request: FundRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expandedId = expandedId == request.id ? nil : request.id
            } label: {
                HStack {
                    Text("\(MoneyFormat.formatCents(request.amountCents)) · \(statusLabel(request)) · \(request.note)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    // Build 74 (B11): SF Symbol chevron, not the
                    // "⌃"/"⌄" text glyphs.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                        .rotationEffect(.degrees(expandedId == request.id ? 180 : 0))
                }
                // Whole-row tap target (owner, Nov 15, 2026 app-wide
                // pass): the empty space between the text and the
                // chevron responds too, not just the glyphs.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expandedId == request.id {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Requested: \(MoneyFormat.formatCents(request.amountCents)) · Status: \(statusLabel(request))")
                    // Build 74 (B19): never a "…" while loading —
                    // the line hides until the summary loads.
                    if let summary = viewModel.fundSummary {
                        Text("Fund available now: \(MoneyFormat.formatCents(summary.availableCents))")
                    }
                    if let approved = request.approvedCents {
                        if request.status == "split" {
                            Text("Approved: \(MoneyFormat.formatCents(approved)) of \(MoneyFormat.formatCents(request.amountCents)) requested — \(MoneyFormat.formatCents(request.remainderCents)) is still unapproved and needs a new request.")
                        } else {
                            Text("Approved: \(MoneyFormat.formatCents(approved)) (in full).")
                        }
                    }
                    Text("Note: \(request.note.isEmpty ? "—" : request.note)")
                    Text("Requested: \(MoneyFormat.fmtDateTime(request.createdAt))")
                    Text(statusSentence(request))
                }
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#6b7280"))
                if viewModel.context.isAdmin && request.status == "pending" {
                    HStack(spacing: 12) {
                        FundsSmallPrimaryButton("Approve", isBusy: viewModel.busyAction != nil) {
                            approveAmountText = String(format: "%.2f", Double(request.amountCents) / 100.0)
                            approveError = nil
                            approving = request
                        }
                        FundsQuietButton("Decline", isBusy: viewModel.busyAction != nil) {
                            declining = request
                        }
                    }
                }
            }
            if let approveError, approving?.id == request.id {
                FundsErrorBox(approveError)
            }
        }
    }

    private func approveTapped(overrideReason: String?) async {
        guard let request = approving else { return }
        guard let cents = MoneyFormat.parseDollarsStrict(approveAmountText), cents > 0 else {
            approveError = "Invalid amount — enter a positive amount."
            return
        }
        guard cents <= request.amountCents else {
            approveError = "Too much — you cannot approve more than the requested \(MoneyFormat.formatCents(request.amountCents))."
            return
        }
        do {
            try await viewModel.approveRequest(request, amountCents: cents, overrideReason: overrideReason)
            approving = nil
            approveAmountText = ""
        } catch let error as OnBudgetError {
            if case .insufficientFund = error, overrideReason == nil {
                showOverride = true
            } else {
                approveError = error.displayMessage
            }
        } catch {
            approveError = OnBudgetError.displayMessage(for: error)
        }
    }
}

// MARK: - Approve sheet (spec §9.3)
//
// "Approve from the Fund": "Approve how much of this $X request?
// Enter less for a split approval." Amount prefilled with the full
// amount. ≤0 or non-numeric → "Invalid amount"; > requested → "Too much".

public struct ApproveRequestSheet: View {
    public let request: FundRequest
    @Binding public var amountText: String
    public let error: String?
    public let onApprove: () -> Void
    public let onCancel: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        request: FundRequest,
        amountText: Binding<String>,
        error: String?,
        onApprove: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self._amountText = amountText
        self.error = error
        self.onApprove = onApprove
        self.onCancel = onCancel
    }

    public var body: some View {
        // No NavigationStack root (owner, Nov 14, 2026 — same
        // sheet-sizing rule as the Actions sheet): a NavigationStack
        // reports an unbounded ideal height, so the fitted sheet
        // rendered tall and mostly empty. Plain VStack + SheetHeader
        // keeps the content at the top of the full-screen popup.
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: TitleCase.apply(to: "Approve from the Fund"), onClose: onCancel)
            FundsMuted("Approve how much of this \(MoneyFormat.formatCents(request.amountCents)) request? Enter less for a split approval.")
            FundsMoneyField("Amount", text: $amountText)
            if let error {
                FundsErrorBox(error)
            }
            // Build 70, item 5 (owner, Nov 24, 2026): the Cancel
            // button is gone — the SheetHeader X + swipe-right
            // dismiss without approving, so Cancel was a third
            // redundant way out.
            FundsPrimaryButton("Approve", action: onApprove)
            // Build 43 (owner, Nov 17, 2026 — item 18): the
            // trailing Spacer top-anchors the content in the
            // full-screen cover — without it the short form
            // centres itself vertically in the full screen.
            Spacer()
        }
        .padding()
        // iPad width (owner, Nov 12, 2026): 600pt in the regular
        // size class, full-width on iPhone — same treatment as the
        // Weekly Budget sheet.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
    }
}

// MARK: - Rename Fund (admin only, build 37)
//
// Rename a fund (owner, Nov 16, 2026): renaming was a confirmed rule
// (Nov 15) but never built — the owner asked how to rename the
// funds. The editor is a sheet with one field, pre-filled with the
// current name, + Save / Cancel at the build-36 editor sizing
// (17pt, proper height). The name is stored exactly as typed (no
// Title Case forcing) via the `set_fund_name` RPC
// (supabase/fund-names.sql), per household, so it persists and syncs
// — the caller updates the shared `appState.fundNames`, the ONE
// source every view reads from, so the new name updates everywhere
// (Funds, Home, Transactions filters, buttons, widget). An empty
// name resets that fund to its default. Admin-only: the Rename
// button that opens this sheet is hidden for non-admins.
//
// Build 41 (owner, Nov 16, 2026 — customizable fund icons): the
// same sheet also picks the fund's ICON. An Icon section shows the
// picker grid (FundIconOptions.all); the pick saves with the name
// via the `set_fund_icon` RPC (supabase/fund-icons.sql) and the
// caller updates the shared `appState.fundIcons`, so the new icon
// updates everywhere the fund's header shows (Funds, Home). An
// empty pick resets that fund to its default icon.

/// The icon picker options live in the kit (FundIconOptions) so
/// the test suite can pin them; the sheet below renders the grid.

public struct RenameFundSheet: View {
    public let section: FundSectionID
    /// The name to show, pre-filled (the current display name —
    /// custom when set, else the default).
    public let currentName: String
    /// The stored custom icon ("" when none — the default icon
    /// shows). Pre-fills the picker selection.
    public let currentIcon: String
    /// The fund's current Home prominence (build 46 — the simpler
    /// Home, owner Nov 18, 2026). Pre-fills the picker selection.
    public let currentProminence: FundProminence
    /// Whether the fund is hidden from Home (build 47 — owner Nov
    /// 19, 2026). Only Savings and Overspent (Past) can be hidden;
    /// Spending and Tzedaka are built in and always false here.
    /// Pre-fills the Show on Home toggle.
    public let currentHidden: Bool
    @ObservedObject public var viewModel: FundsViewModel
    /// Called with the household's updated fund_names map on a
    /// successful save, so the caller refreshes the shared source.
    public var onSaved: ([String: String]) -> Void
    /// Called with the household's updated fund_icons map on a
    /// successful icon save, so the caller refreshes the shared
    /// source.
    public var onIconsSaved: ([String: String]) -> Void
    /// Called with the household's updated fund_prominence map on
    /// a successful prominence save, so the caller refreshes the
    /// shared source (build 46).
    public var onProminenceSaved: ([String: String]) -> Void
    /// Called with the household's updated fund_hidden map on a
    /// successful hide/show save, so the caller refreshes the
    /// shared source (build 47).
    public var onHiddenSaved: ([String: Bool]) -> Void
    public var onClose: () -> Void
    @State private var nameText: String
    /// The picked icon ("" = the default icon for this fund).
    @State private var selectedIcon: String
    /// The picked Home prominence (build 46).
    @State private var selectedProminence: FundProminence
    /// Show this fund on Home (build 47 — only Savings and
    /// Overspent (Past) get the toggle; Spending and Tzedaka are
    /// built in and this stays on).
    @State private var showOnHome: Bool
    @State private var fieldError: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        section: FundSectionID,
        currentName: String,
        currentIcon: String = "",
        currentProminence: FundProminence,
        currentHidden: Bool = false,
        viewModel: FundsViewModel,
        onSaved: @escaping ([String: String]) -> Void,
        onIconsSaved: @escaping ([String: String]) -> Void = { _ in },
        onProminenceSaved: @escaping ([String: String]) -> Void = { _ in },
        onHiddenSaved: @escaping ([String: Bool]) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        self.section = section
        self.currentName = currentName
        self.currentIcon = currentIcon
        self.currentProminence = currentProminence
        self.currentHidden = currentHidden
        self.viewModel = viewModel
        self.onSaved = onSaved
        self.onIconsSaved = onIconsSaved
        self.onProminenceSaved = onProminenceSaved
        self.onHiddenSaved = onHiddenSaved
        self.onClose = onClose
        self._nameText = State(initialValue: currentName)
        self._selectedIcon = State(initialValue: currentIcon)
        self._selectedProminence = State(initialValue: currentProminence)
        self._showOnHome = State(initialValue: !currentHidden)
    }

    /// The icon the grid highlights: the pick, or the fund's
    /// default when nothing custom is picked.
    private var effectiveIcon: String {
        selectedIcon.isEmpty ? section.theme.iconName : selectedIcon
    }

    public var body: some View {
        // No NavigationStack root (owner, Nov 14, 2026 — same
        // sheet-sizing rule as the Actions sheet): a NavigationStack
        // reports an unbounded ideal height, so the fitted sheet
        // rendered tall and mostly empty. Plain VStack + SheetHeader
        // keeps the content at the top of the full-screen popup.
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: TitleCase.apply(to: "Edit \(section.displayName)"), onClose: onClose)
            // Build 74 (owner, Nov 24, 2026 — popup sizing):
            // the tallest form in the app (the icon grid alone
            // is several rows) with no ScrollView — on a short
            // iPhone the Save button fell below the fold with no
            // way to reach it. The fields now scroll under a
            // pinned header.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FundsTextField("Fund name", text: $nameText)
                        .autocorrectionDisabled()
                    FundsMuted("Leave blank to use the default name (\(section.displayName)).")
                    // Icon picker (build 41 — customizable fund icons,
                    // owner Nov 16, 2026): the pencil opens this one sheet
                    // for name AND icon. A grid of picker symbols; the
                    // picked one saves with the name. Tapping a symbol
                    // only selects it — nothing saves until Save.
                    Text("Icon")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(FundIconOptions.all, id: \.self) { symbol in
                            Button { selectedIcon = symbol } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(symbol == effectiveIcon ? DesignTokens.primary : DesignTokens.ink)
                                    .frame(width: 52, height: 52)
                                    .background(symbol == effectiveIcon ? DesignTokens.pale : Color(hex: "#f3f4f6"))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol == effectiveIcon ? "\(symbol), selected" : symbol)
                        }
                    }
                    // Reset shows only when a custom icon is picked — an
                    // action the user cannot perform must not appear (owner
                    // rule, Nov 13, 2026): with the default showing there
                    // is nothing to reset.
                    if !selectedIcon.isEmpty {
                        Button("Reset to Default Icon") { selectedIcon = "" }
                            .buttonStyle(.plain)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.primary)
                    }
                    // Show on Home (build 47 — owner, Nov 19, 2026:
                    // "The only ones that stay and are built in are
                    // spending & Charity"). Only Savings and Overspent
                    // (Past) can be taken off Home and put back; Spending
                    // and Tzedaka always stay, so they get no toggle.
                    // Hiding never touches the prominence below — showing
                    // the fund again puts it back where it was.
                    if section.canHideFromHome {
                        Toggle("Show on Home", isOn: $showOnHome)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                            .accessibilityIdentifier("funds.showOnHomeToggle")
                    }
                    // Home prominence (build 46 — the simpler Home, owner
                    // Nov 18, 2026): the owner sets how THIS card shows on
                    // Home — the star hero, a full card, or a quiet row.
                    // The same edit sheet already holds the name and the
                    // icon, so the prominence lives here too, not on a
                    // separate screen. The pick saves with the name and
                    // icon below. Build 47: the picker is "Size on Home"
                    // now — "Show on Home" is the toggle above — and it
                    // only shows while the fund shows on Home (no point
                    // picking a size for a hidden fund).
                    if showOnHome {
                        Text("Size on Home")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        // Build 64 (C-6): the segmented picker is gone —
                        // a squarish control (8pt radius, ink text,
                        // pale-blue selected cell), no pill track.
                        SquarishPicker(
                            [(FundProminence.hero, "Hero"), (FundProminence.card, "Card"), (FundProminence.quiet, "Quiet Row")],
                            selection: $selectedProminence
                        )
                        .accessibilityIdentifier("funds.prominencePicker")
                    }
                    if let fieldError {
                        FundsErrorBox(fieldError)
                    }
                    // Build 70, item 5 (owner, Nov 24, 2026): the Cancel
                    // button is gone — the SheetHeader X + swipe-right
                    // dismiss without saving, so Cancel was a third
                    // redundant way out.
                    FundsPrimaryButton("Save", isBusy: viewModel.busyAction == "fund-rename" || viewModel.busyAction == "fund-icon" || viewModel.busyAction == "fund-prominence" || viewModel.busyAction == "fund-hidden") {
                        saveTapped()
                    }
                    // No trailing Spacer (build 74): inside a
                    // ScrollView the content top-anchors on its own.
                }
            }
        }
        .padding()
        // iPad width (owner, Nov 12, 2026): 600pt in the regular
        // size class, full-width on iPhone — same treatment as the
        // Weekly Budget sheet.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
    }

    private func saveTapped() {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 40 else {
            fieldError = "Keep the name to 40 characters or fewer."
            return
        }
        let nameChanged = trimmed != currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let iconChanged = selectedIcon != currentIcon
        let prominenceChanged = selectedProminence != currentProminence
        // Build 47: hiding is a change too — the toggle flips
        // `hidden`; a built-in fund never changes here (no toggle,
        // showOnHome stays on).
        let newHidden = section.canHideFromHome ? !showOnHome : false
        let hiddenChanged = newHidden != currentHidden
        guard nameChanged || iconChanged || prominenceChanged || hiddenChanged else {
            fieldError = "Nothing to change."
            return
        }
        fieldError = nil
        Task {
            // Each save is idempotent, so a retry after a partial
            // success only re-saves what still differs.
            var ok = true
            if nameChanged {
                if let names = await viewModel.renameFund(section: section, name: nameText) {
                    onSaved(names)
                } else {
                    ok = false
                }
            }
            if ok, iconChanged {
                if let icons = await viewModel.setFundIcon(section: section, icon: selectedIcon) {
                    onIconsSaved(icons)
                } else {
                    ok = false
                }
            }
            if ok, prominenceChanged {
                if let map = await viewModel.setFundProminence(section: section, prominence: selectedProminence) {
                    onProminenceSaved(map)
                } else {
                    ok = false
                }
            }
            if ok, hiddenChanged {
                if let map = await viewModel.setFundHidden(section: section, hidden: newHidden) {
                    onHiddenSaved(map)
                } else {
                    ok = false
                }
            }
            if ok { onClose() }
            // On failure the view model raises its alert (FundsView
            // presents it) and this sheet stays open with the typed
            // name and picked icon intact.
        }
    }
}


