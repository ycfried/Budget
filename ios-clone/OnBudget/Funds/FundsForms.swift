import SwiftUI
import OnBudgetKit

// MARK: - Add Money (top-up, admin only — spec §9.3)
//
// "Log cash for the fund — owed back is covered first."
// Manual top-ups cover the fund shortfall FIRST; the remainder
// increases spendable Available. The save preview MUST show the split
// before saving; fund history shows the split. Top-ups never touch
// weekly allowance / spending room / debt math. Admin-only;
// double-tap protection. Build 41 (owner, Nov 17, 2026): the
// "I have already put this money in checking" toggle no longer
// blocks saving — untoggled, the top-up saves as PENDING and counts
// for nothing until it is confirmed on its Activity-feed entry.

public struct AddMoneyForm: View {
    @ObservedObject public var viewModel: FundsViewModel
    /// Closes the form back to the Funds list (owned by FundsView).
    public var onClose: () -> Void = {}
    @State private var amountText = ""
    @State private var note = ""
    @State private var confirmed = false
    @State private var fieldError: String?
    @State private var showConfirm = false

    public init(viewModel: FundsViewModel, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    private var amountCents: Int? { MoneyFormat.parseDollarsStrict(amountText) }

    private var previewText: String {
        guard let cents = amountCents, cents > 0 else { return "Enter an amount to see the split." }
        guard let split = viewModel.topupPreview(amountCents: cents) else {
            return "Fund balance has not loaded yet — the server still covers anything owed back first when you save."
        }
        // A pending save's split is a projection: the real split
        // runs at confirm time, against the then-current shortfall
        // (build 41 — pending top-ups, owner Nov 17, 2026).
        if confirmed {
            return "Split: \(MoneyFormat.formatCents(split.added)) added to fund · \(MoneyFormat.formatCents(split.covered)) covers owed back · Owed back after \(MoneyFormat.formatCents(split.after))."
        }
        return "Pending split when confirmed: \(MoneyFormat.formatCents(split.added)) added to fund · \(MoneyFormat.formatCents(split.covered)) covers owed back · Owed back after \(MoneyFormat.formatCents(split.after)). It will not count until you confirm it."
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
                FundsMuted("Log cash for the fund — owed back is covered first once it is confirmed.")
                FundsMoneyField("Amount", text: $amountText)
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Note")
                    TextField("", text: $note)
                        .textFieldStyle(.roundedBorder)
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
                HStack(spacing: 12) {
                    FundsPrimaryButton("Save Top-Up", isBusy: viewModel.busyAction == "topup") {
                        saveTapped()
                    }
                    FundsTertiaryButton("Cancel") {
                        amountText = ""
                        note = ""
                        confirmed = false
                        fieldError = nil
                        viewModel.toast = nil
                        onClose()
                    }
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

// MARK: - Use Fund Money (admin only — spec §9.3)
//
// "Lowers the fund balance only." On "insufficient fund" the server
// error offers a typed-reason override retry ("Fund Is Short" sheet).

public struct UseFundForm: View {
    @ObservedObject public var viewModel: FundsViewModel
    /// Closes the form back to the Funds list (owned by FundsView).
    public var onClose: () -> Void = {}
    @State private var amountText = ""
    @State private var note = ""
    @State private var fieldError: String?
    @State private var showConfirm = false
    @State private var showOverride = false
    @State private var overrideReason = ""
    @State private var pendingCents: Int?

    public init(viewModel: FundsViewModel, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    private var amountCents: Int? { MoneyFormat.parseDollarsStrict(amountText) }

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("Use Fund Money")
                FundsMuted("Lowers the fund balance only.")
                FundsMoneyField("Amount", text: $amountText)
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Note")
                    TextField("", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
                if let fieldError {
                    FundsErrorBox(fieldError)
                }
                HStack(spacing: 12) {
                    FundsPrimaryButton("Record It") {
                        guard let cents = amountCents, cents > 0 else {
                            fieldError = "Enter a valid amount."
                            return
                        }
                        fieldError = nil
                        pendingCents = cents
                        showConfirm = true
                    }
                    FundsTertiaryButton("Cancel") {
                        amountText = ""
                        note = ""
                        fieldError = nil
                        onClose()
                    }
                }
            }
        }
        // Build 37 (owner, Nov 16, 2026): a CENTERED alert, not a
        // confirmationDialog — on iPad a confirmationDialog is a
        // popover anchored at the top of the screen (same fix as the
        // Clear Debt confirm). An .alert is centred on iPhone and
        // iPad alike.
        .alert(
            "Record Fund Spending",
            isPresented: $showConfirm
        ) {
            Button(TitleCase.apply(to: "Record It")) {
                Task { await record(overrideReason: nil) }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            if let pendingCents {
                Text("Record \(MoneyFormat.formatCents(pendingCents)) of fund spending?")
            }
        }
        .alert("Fund Is Short", isPresented: $showOverride) {
            TextField("Reason for overriding", text: $overrideReason)
            Button(TitleCase.apply(to: "Record Anyway")) {
                Task { await record(overrideReason: overrideReason.trimmingCharacters(in: .whitespaces)) }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            if let pendingCents {
                Text("The fund does not cover \(MoneyFormat.formatCents(pendingCents)). Record it anyway with a typed reason — it will be logged.")
            }
        }
    }

    private func record(overrideReason: String?) async {
        guard let cents = pendingCents else { return }
        do {
            try await viewModel.allocateFund(amountCents: cents, note: note.trimmingCharacters(in: .whitespaces), overrideReason: overrideReason)
            amountText = ""
            note = ""
            pendingCents = nil
        } catch let error as OnBudgetError {
            if case .insufficientFund = error, overrideReason == nil {
                showOverride = true
            } else {
                viewModel.alertTitle = "Could Not Record"
                viewModel.alertMessage = error.displayMessage
            }
        } catch {
            viewModel.alertTitle = "Could Not Record"
            viewModel.alertMessage = OnBudgetError.displayMessage(for: error)
        }
    }
}

// MARK: - Pay Carried Debt from Extra Fund (admin only, build 29)
//
// Mirrors UseFundForm: amount + note + confirmation dialog, and the
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

    /// The preview line: what leaves the Extra Fund and what the
    /// debt becomes. Client-side only — the server's remaining debt
    /// (returned by the RPC) is authoritative.
    private var previewText: String? {
        guard let cents = amountCents, cents > 0,
              let debt = viewModel.debtBalanceCents else { return nil }
        return "\(MoneyFormat.formatCents(cents)) leaves the Extra Fund, debt becomes \(MoneyFormat.formatCents(max(0, debt - cents)))."
    }

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("Pay \(debtName) from \(fundName)")
                FundsMuted("Lowers the carried debt and the Extra Fund balance.")
                FundsMoneyField("Amount", text: $amountText)
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Note")
                    TextField("", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
                if let previewText {
                    FundsMuted(previewText)
                }
                if let fieldError {
                    FundsErrorBox(fieldError)
                }
                HStack(spacing: 12) {
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
                    FundsTertiaryButton("Cancel") {
                        amountText = ""
                        note = ""
                        fieldError = nil
                        onClose()
                    }
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
                viewModel.alertTitle = "Could Not Pay Debt"
                viewModel.alertMessage = error.displayMessage
            }
        } catch {
            viewModel.alertTitle = "Could Not Pay Debt"
            viewModel.alertMessage = OnBudgetError.displayMessage(for: error)
        }
    }
}

// MARK: - Clear Carried Debt, in part or in full (build 30)
//
// The owner asked for a slider, not a choice of amount / % / all:
// one slider from $0 to the full debt, an editable number above it
// (two-way bound — typing moves the slider, dragging updates the
// number), and 10 / 25 / 50 / 75 % quick buttons below it. The
// slider at max IS "all". A preview shows the remaining debt, then
// a confirm writes the amount off — audited like the full clear,
// NOT a payment from the Extra Fund ("Pay from Extra Fund" covers
// paying). The % buttons floor to the cent, the same as the
// server's percentage clear.

public struct ClearDebtForm: View {
    @ObservedObject public var viewModel: FundsViewModel
    /// Closes the form back to the Funds list (owned by FundsView).
    public var onClose: () -> Void = {}
    @State private var amountCents = 0
    @State private var amountText = "0"
    @State private var showConfirm = false
    @State private var pendingCents: Int?
    /// iPad (build 37, owner Nov 16, 2026): the % and action
    /// buttons are larger/taller on the tablet form factor.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isIPad: Bool { horizontalSizeClass == .regular }

    public init(viewModel: FundsViewModel, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    private var debtCents: Int? { viewModel.debtBalanceCents }
    private var debtDollars: Double { Double(debtCents ?? 0) / 100 }

    /// The slider's value in dollars, two-way bound to
    /// `amountCents`: dragging writes the field text, and the
    /// field / % buttons write the slider (through `setAmount`).
    /// Step is one cent, so a % button's floored amount sits
    /// exactly where the slider says it does. The getter CLAMPS
    /// to the current debt (build 37, owner Nov 16, 2026 — the
    /// iPad crash around the Clear Debt flow): after a full clear
    /// `refresh()` drops the debt to $0 while this form is still
    /// open, and an unclamped value ($2,988.24) outside a range
    /// that has collapsed to 0...0 is a degenerate Slider state —
    /// the one concrete hazard found in the post-clear path. The
    /// form closes right after, but the re-render in between must
    /// never hand the Slider an out-of-range value.
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

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("Clear Debt")
                FundsMuted("Write off part of the carried debt — or all of it. No money moves; the amount is recorded in the activity log.")
                if let debt = debtCents {
                    FundsMoneyField("Amount to Clear", text: $amountText)
                        .onChange(of: amountText) { _, newValue in
                            // Typing moves the slider. A value that
                            // does not parse yet (mid-type) leaves
                            // the slider where it was.
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
                        // the end. The "Slide to the end" hint is
                        // gone: the 100% button says it.
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
                    HStack(spacing: 12) {
                        // No greyed-out buttons (owner, Nov 13): the
                        // confirm only appears once there is an
                        // amount to clear.
                        if amountCents > 0 {
                            FundsPrimaryButton("Clear \(MoneyFormat.formatCents(amountCents))", isLarge: isIPad) {
                                pendingCents = amountCents
                                showConfirm = true
                            }
                        }
                        FundsTertiaryButton("Cancel", isLarge: isIPad) { onClose() }
                    }
                } else if let error = viewModel.debtError {
                    FundsErrorBox(error)
                } else {
                    SkeletonBlock(width: 200, height: 16)
                }
            }
        }
        // Build 37 (owner, Nov 16, 2026): a CENTERED alert, not a
        // confirmationDialog — on iPad a confirmationDialog is a
        // popover anchored at the top of the screen, and the owner
        // reported the Clear Debt confirm floating up there. An
        // .alert is centred on iPhone and iPad alike (same
        // precedent as the ReviewView Same Purchase / Separate
        // confirms). The bottom success toast is untouched.
        .alert(
            "Clear Debt",
            isPresented: $showConfirm
        ) {
            Button(TitleCase.apply(to: "Clear Debt"), role: .destructive) {
                if let pendingCents {
                    Task {
                        if await viewModel.clearDebt(amountCents: pendingCents, note: "") {
                            onClose()
                        }
                    }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            if let pendingCents, let remaining = remainingCents {
                Text("Write off \(MoneyFormat.formatCents(pendingCents)) of the carried debt? \(MoneyFormat.formatCents(remaining)) will remain. No money moves.")
            }
        }
    }
}

// MARK: - Edit Carried Debt: Add or Set (admin only, build 41)
//
// Owner, Nov 17, 2026: the debt fund only let you pay it down, set
// a repayment rule, and clear it — there was no way to manually
// increase it or correct it. This sheet holds BOTH manual changes
// behind the single pale "Edit Debt" button on the Overspent (Past)
// card (one entry point, not a fourth button on the card):
//   - Add Debt: increases the carried debt by the entered amount.
//   - Set Debt: replaces the carried debt with the entered total
//     (a correction; the server stores the delta).
// Both are admin-only, audited (add_debt / set_debt), and the new
// balance shows in the debt fund's Activity feed. Setting the debt
// to $0 is not offered here — that is the Clear Debt button.
// The buttons only render for a valid amount (no greyed-out
// buttons, owner Nov 13), and each change is confirmed with a
// centered .alert first (the Clear Debt precedent, build 37).
// Server: add-set-debt.sql (OWED — not applied live yet) plus the
// compute-week / week-close TS companions; until those land, the
// RPC returns the new balance but Home/Funds/the widget still show
// the old one.
struct EditDebtSheet: View {
    @ObservedObject var viewModel: FundsViewModel
    let currentCents: Int
    let debtName: String
    let onClose: () -> Void

    @State private var addText = ""
    @State private var addNote = ""
    @State private var setText = ""
    @State private var setNote = ""
    @State private var pending: PendingDebtChange?
    @State private var showConfirm = false

    private struct PendingDebtChange {
        enum Kind { case add, set }
        let kind: Kind
        let cents: Int
        let note: String
    }

    private var addCents: Int { MoneyFormat.parseDollarsStrict(addText) ?? 0 }
    private var setCents: Int { MoneyFormat.parseDollarsStrict(setText) ?? 0 }

    var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("Edit \(debtName)")
                FundsMuted("Current Debt \(MoneyFormat.formatCents(currentCents))")
                // Add Debt — primary blue (the first action, and
                // the one that grows the balance).
                VStack(alignment: .leading, spacing: 12) {
                    FundsMoneyField("Amount to Add", text: $addText)
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel("Note")
                        TextField("", text: $addNote)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: addNote) { _, newValue in
                                if newValue.count > 120 { addNote = String(newValue.prefix(120)) }
                            }
                    }
                    if addCents > 0 {
                        FundsPrimaryButton("Add Debt", isBusy: viewModel.busyAction == "debt-add") {
                            pending = PendingDebtChange(kind: .add, cents: addCents, note: addNote)
                            showConfirm = true
                        }
                    }
                }
                // Set Debt — pale middle tier (the correction, a
                // different treatment from Add, per the standing
                // button rule). Only offered for a total that
                // differs from the current balance — setting it to
                // the same amount is a no-op the server refuses.
                VStack(alignment: .leading, spacing: 12) {
                    FundsMoneyField("New Total Debt", text: $setText)
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel("Note")
                        TextField("", text: $setNote)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: setNote) { _, newValue in
                                if newValue.count > 120 { setNote = String(newValue.prefix(120)) }
                            }
                    }
                    if setCents > 0 && setCents != currentCents {
                        FundsPaleButton("Set Debt", isBusy: viewModel.busyAction == "debt-set") {
                            pending = PendingDebtChange(kind: .set, cents: setCents, note: setNote)
                            showConfirm = true
                        }
                    }
                }
                FundsTertiaryButton("Cancel") { onClose() }
            }
        }
        // Build 37 (owner, Nov 16, 2026): a CENTERED alert, not a
        // confirmationDialog — the Clear Debt precedent.
        .alert(
            pending?.kind == .set ? "Set Debt" : "Add Debt",
            isPresented: $showConfirm
        ) {
            Button(TitleCase.apply(to: pending?.kind == .set ? "Set Debt" : "Add Debt")) {
                guard let pending else { return }
                self.pending = nil
                Task {
                    let ok: Bool
                    if pending.kind == .add {
                        ok = await viewModel.addDebt(amountCents: pending.cents, note: pending.note)
                    } else {
                        ok = await viewModel.setDebt(amountCents: pending.cents, note: pending.note)
                    }
                    if ok { onClose() }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) { pending = nil }
        } message: {
            if let pending {
                if pending.kind == .add {
                    Text("Add \(MoneyFormat.formatCents(pending.cents)) to the carried debt? The new total will be \(MoneyFormat.formatCents(currentCents + pending.cents)).")
                } else {
                    Text("Set the carried debt to \(MoneyFormat.formatCents(pending.cents))? This replaces the current \(MoneyFormat.formatCents(currentCents)).")
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
                        TextField("", text: $note)
                            .textFieldStyle(.roundedBorder)
                    }
                    if let fieldError {
                        FundsErrorBox(fieldError)
                    }
                    HStack(spacing: 12) {
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
                        FundsTertiaryButton("Cancel") {
                            amountText = ""
                            note = ""
                            fieldError = nil
                            onClose()
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

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("Fund Requests")
                if let error = viewModel.fundRequestsError {
                    FundsErrorBox(error)
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
        .sheet(item: $approving) { request in
            ApproveRequestSheet(
                request: request,
                amountText: $approveAmountText,
                error: approveError,
                onApprove: { Task { await approveTapped(overrideReason: nil) } },
                onCancel: { approving = nil; approveError = nil }
            )
                // iPad width (owner, Nov 12, 2026): same treatment
                // as the Weekly Budget sheet — fitted height + 600pt
                // width in the regular size class.
                .presentationSizing(.fitted)
                .presentationBackground(.white)
        }
        .alert("Fund Is Short", isPresented: $showOverride) {
            TextField("Reason for overriding", text: $overrideReason)
            Button(TitleCase.apply(to: "Approve Anyway")) {
                Task { await approveTapped(overrideReason: overrideReason.trimmingCharacters(in: .whitespaces)) }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            if let cents = MoneyFormat.parseDollarsStrict(approveAmountText) {
                Text("The fund does not cover \(MoneyFormat.formatCents(cents)). You can still approve with a typed reason — it will be logged.")
            }
        }
        // Build 37 (owner, Nov 16, 2026): a CENTERED alert, not a
        // confirmationDialog — on iPad a confirmationDialog is a
        // popover anchored at the top of the screen (same fix as the
        // Clear Debt confirm). An .alert is centred on iPhone and
        // iPad alike.
        .alert(
            "Decline Request",
            isPresented: Binding(
                get: { declining != nil },
                set: { if !$0 { declining = nil } }
            )
        ) {
            Button(TitleCase.apply(to: "Decline"), role: .destructive) {
                if let declining {
                    Task { await viewModel.declineRequest(declining) }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            Text("Decline this fund request?")
        }
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
                    Text(expandedId == request.id ? "⌃" : "⌄")
                        .foregroundStyle(DesignTokens.primary)
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
                    Text("Fund available now: \(viewModel.fundSummary.map { MoneyFormat.formatCents($0.availableCents) } ?? "…")")
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
        // fitted-sizing rule as the Actions sheet): a NavigationStack
        // reports an unbounded ideal height, so the fitted sheet
        // rendered tall and mostly empty. Plain VStack + SheetHeader
        // lets fitted measure the real content.
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: TitleCase.apply(to: "Approve from the Fund"), onClose: onCancel)
            FundsMuted("Approve how much of this \(MoneyFormat.formatCents(request.amountCents)) request? Enter less for a split approval.")
            FundsMoneyField("Amount", text: $amountText)
            if let error {
                FundsErrorBox(error)
            }
            HStack(spacing: 12) {
                FundsPrimaryButton("Approve", action: onApprove)
                FundsTertiaryButton("Cancel", action: onCancel)
            }
        }
        .padding()
        // iPad width (owner, Nov 12, 2026): 600pt in the regular
        // size class, full-width on iPhone — same treatment as the
        // Weekly Budget sheet. The trailing Spacer is gone: it
        // stretched the middle empty against the tall form sheet.
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
    @ObservedObject public var viewModel: FundsViewModel
    /// Called with the household's updated fund_names map on a
    /// successful save, so the caller refreshes the shared source.
    public var onSaved: ([String: String]) -> Void
    /// Called with the household's updated fund_icons map on a
    /// successful icon save, so the caller refreshes the shared
    /// source.
    public var onIconsSaved: ([String: String]) -> Void
    public var onClose: () -> Void
    @State private var nameText: String
    /// The picked icon ("" = the default icon for this fund).
    @State private var selectedIcon: String
    @State private var fieldError: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        section: FundSectionID,
        currentName: String,
        currentIcon: String = "",
        viewModel: FundsViewModel,
        onSaved: @escaping ([String: String]) -> Void,
        onIconsSaved: @escaping ([String: String]) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        self.section = section
        self.currentName = currentName
        self.currentIcon = currentIcon
        self.viewModel = viewModel
        self.onSaved = onSaved
        self.onIconsSaved = onIconsSaved
        self.onClose = onClose
        self._nameText = State(initialValue: currentName)
        self._selectedIcon = State(initialValue: currentIcon)
    }

    /// The icon the grid highlights: the pick, or the fund's
    /// default when nothing custom is picked.
    private var effectiveIcon: String {
        selectedIcon.isEmpty ? section.theme.iconName : selectedIcon
    }

    public var body: some View {
        // No NavigationStack root (owner, Nov 14, 2026 — same
        // fitted-sizing rule as the Actions sheet): a NavigationStack
        // reports an unbounded ideal height, so the fitted sheet
        // rendered tall and mostly empty. Plain VStack + SheetHeader
        // lets fitted measure the real content.
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: TitleCase.apply(to: "Edit \(section.displayName)"), onClose: onClose)
            TextField("Fund name", text: $nameText)
                .font(.system(size: 17))
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 48)
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
                            .clipShape(RoundedRectangle(cornerRadius: 12))
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
            if let fieldError {
                FundsErrorBox(fieldError)
            }
            HStack(spacing: 12) {
                FundsPrimaryButton("Save", isBusy: viewModel.busyAction == "fund-rename" || viewModel.busyAction == "fund-icon") {
                    saveTapped()
                }
                FundsTertiaryButton("Cancel") { onClose() }
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
        guard nameChanged || iconChanged else {
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
            if ok { onClose() }
            // On failure the view model raises its alert (FundsView
            // presents it) and this sheet stays open with the typed
            // name and picked icon intact.
        }
    }
}

// MARK: - Record Cash Spent (cash taken out of Savings, admin only)
//
// Build 40 (owner, Nov 16, 2026): "Same goes for extra fund/savings.."
// — the Savings fund gets the same "record on the fund, not a
// transaction" function as the charity cash gift. The owner took cash
// out of Savings and wants to take it off the Available balance —
// WITHOUT creating a transaction row (cash is not traceable as a
// bank/email transaction and would confuse the transaction history).
// It IS recorded in the Savings fund's Activity & Transactions feed
// (a fund_ledger 'allocation' entry, which the feed now shows).
// The button opens a POPUP (sheet, like the charity popups: iPad
// 600pt, 17pt) with an amount field + a note +
// Record/Cancel. Validation lives INSIDE the popup: the amount must
// be above $0.00 and must not exceed the Available balance (no
// override — allocate_fund refuses when the amount exceeds Available,
// so a withdrawal can never take Savings below $0) — the error shows
// in the popup in plain language and the popup does not close on a
// bad amount. On success the popup closes, the field clears, and
// the balance updates everywhere. Reuses `allocate_fund` (no new
// server surface): a negative 'allocation' entry in fund_ledger.
// The button and the popup title use the fund's CURRENT name (e.g.
// "Record Cash Spent from Savings").

public struct RecordCashSpentSection: View {
    @ObservedObject public var viewModel: FundsViewModel
    /// The fund's CURRENT display name (e.g. "Savings" when renamed).
    public let fundName: String
    @State private var showPopup = false

    public init(viewModel: FundsViewModel, fundName: String) {
        self.viewModel = viewModel
        self.fundName = fundName
    }

    public var body: some View {
        // The fund card stacks THREE full-width buttons (Add Money /
        // Spend from Fund / Record Cash Spent — the "Request Money"
        // button is gone, owner Nov 16, 2026, build 41). The
        // standing no-adjacent-same-color rule puts this one PRIMARY
        // BLUE: blue, pale, blue — no two adjacent share a color
        // (the two blues are separated by the pale middle).
        // Full width, same size as the others.
        FundsPrimaryButton("Record Cash Spent") {
            showPopup = true
        }
        .accessibilityIdentifier("funds.recordCashSpent")
        .sheet(isPresented: $showPopup) {
            RecordCashSpentSheet(
                viewModel: viewModel,
                fundName: fundName,
                onClose: { showPopup = false }
            )
            .presentationSizing(.fitted)
        }
    }
}

/// The Record Cash Spent popup (owner, Nov 16, 2026 — build 40): an
/// amount field + a note + Record/Cancel, in the rename
/// sheet's style (iPad 600pt centred, 17pt). Validation lives here:
/// the amount must be above $0.00 and must not exceed the Available
/// balance — empty / zero / negative / over-Available shows a
/// plain-language error INSIDE the popup and the popup stays open
/// (the field keeps the typed input). On success the popup closes,
/// the field clears, and the balance updates everywhere.
public struct RecordCashSpentSheet: View {
    @ObservedObject public var viewModel: FundsViewModel
    public let fundName: String
    public var onClose: () -> Void
    @State private var amountText = ""
    @State private var noteText = ""
    @State private var spentError: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(viewModel: FundsViewModel, fundName: String, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.fundName = fundName
        self.onClose = onClose
    }

    /// The Available Savings balance, for the over-Available check
    /// (client-side; allocate_fund re-checks server-side and refuses
    /// too, with no override on this path).
    private var availableCents: Int? { viewModel.fundSummary?.availableCents }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: TitleCase.apply(to: "Record Cash Spent from \(fundName)"), onClose: onClose)
            if let availableCents {
                FundsMuted("Available: \(MoneyFormat.formatCents(availableCents)). The amount comes off Available. No transaction row is created.")
            }
            DollarTextField(text: $amountText, maxWidth: .infinity, minHeight: 48)
            TextField("Note", text: $noteText)
                .font(.system(size: 17))
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 48)
                .autocorrectionDisabled()
            if let spentError {
                FundsErrorBox(spentError)
            }
            HStack(spacing: 12) {
                FundsPrimaryButton("Record", isBusy: viewModel.busyAction == "record-cash-spent") {
                    record()
                }
                FundsTertiaryButton("Cancel") { onClose() }
            }
        }
        .padding()
        // iPad width (owner, Nov 12, 2026): 600pt in the regular
        // size class, full-width on iPhone — same treatment as the
        // rename sheet.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
    }

    private func record() {
        guard let cents = MoneyFormat.parseDollarsStrict(amountText), cents > 0 else {
            spentError = "Enter an amount above $0.00."
            return
        }
        if let availableCents, cents > availableCents {
            spentError = "That is more than the \(MoneyFormat.formatCents(availableCents)) available in \(fundName)."
            return
        }
        spentError = nil
        Task {
            // Clear only on success — on failure the typed input
            // stays beside the error (F-P1-4).
            if await viewModel.recordCashSpent(amountCents: cents, note: noteText) {
                amountText = ""
                noteText = ""
                onClose()
            }
        }
    }
}
