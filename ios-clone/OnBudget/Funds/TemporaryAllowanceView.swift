import SwiftUI
import OnBudgetKit

// MARK: - Temporary Allowance (admin only — spec §10.4)
//
// The amount is a NEW TOTAL weekly allowance, REPEATING each week for
// the chosen 1–4 weeks — not a total split across weeks (owner, Nov 4).
// Each week gets its own override row via `set_weekly_allowance_override`
// — never `add_temp_increase`, which cannot represent a lower total
// and must not be used as a fallback.
//
// Lives in the Settings Budget card (spec §10.4); built here because
// the Funds workstream owns the allowance-override wiring. The
// Settings builder embeds this view with the shared FundsViewModel.

public struct TemporaryAllowanceView: View {
    @ObservedObject public var viewModel: FundsViewModel
    @State private var newTotalText = ""
    @State private var weeks = 1
    @State private var fieldError: String?
    @State private var showConfirm = false

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    private var newTotalCents: Int? { MoneyFormat.parseDollarsStrict(newTotalText) }

    /// Preview: "Base `$B` · New total `$N` · `W` week(s) · `Mon D, …`."
    /// Empty until values are entered. Dates render short ("Nov 15,
    /// Nov 22"), never raw ISO (F-P2-1).
    private var previewText: String {
        guard let base = viewModel.baseAllowanceCents,
              let total = newTotalCents, total >= 0 else { return "" }
        let dates = MoneyFormat.sundays(from: MoneyFormat.currentSundayNY(), count: weeks)
            .map { MoneyFormat.fmtShort($0) }
        return "Base \(MoneyFormat.formatCents(base)) · New total \(MoneyFormat.formatCents(total)) · \(weeks) week(s) · \(dates.joined(separator: ", "))."
    }

    /// Confirm-dialog text: the new total + weeks + dates, calling
    /// out $0 explicitly — $0 is allowed only when confirmed here
    /// (F-P2-3).
    private var confirmMessage: String {
        guard let total = newTotalCents else { return "" }
        let dates = MoneyFormat.sundays(from: MoneyFormat.currentSundayNY(), count: weeks)
            .map { MoneyFormat.fmtShort($0) }
        var message = "Set the weekly allowance to \(MoneyFormat.formatCents(total)) for \(weeks) week\(weeks == 1 ? "" : "s") (\(dates.joined(separator: ", ")))."
        if total == 0 {
            message += " That is $0.00 — no spending room for those weeks."
        }
        return message
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Temporary Allowance")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            // Two compact fields side by side, symmetrical: same label
            // style, control height 46px, border, radius, padding,
            // 4px gap under the label, aligned baselines (spec §10.4).
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Total")
                        .font(.system(size: 14, weight: .semibold))
                    TextField("$0.00", text: $newTotalText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200, height: 46)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weeks")
                        .font(.system(size: 14, weight: .semibold))
                    Picker("Weeks", selection: $weeks) {
                        ForEach(1...4, id: \.self) { week in
                            Text("\(week)").tag(week)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 64, height: 46)
                    .background(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            // F-P2-14: the preview is empty until the base loads, so
            // say so — with a retry when the load failed — instead of
            // a bare amount field with no preview.
            if viewModel.baseAllowanceCents == nil {
                if let allowanceError = viewModel.allowanceError {
                    FundsErrorBox(allowanceError)
                    FundsSmallTertiaryButton("Try Again") {
                        Task { await viewModel.reloadAllowance() }
                    }
                } else {
                    FundsMuted("Loading your current allowance…")
                }
            } else if !previewText.isEmpty {
                Text(previewText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
            if let fieldError {
                FundsErrorBox(fieldError)
            }
            FundsPrimaryButton("Set New Total", isBusy: viewModel.busyAction == "temp") {
                // Non-negative, matching the preview (the kit's
                // web-faithful parse accepts negatives; a new total
                // can never be one).
                guard let cents = newTotalCents, cents >= 0 else {
                    fieldError = "Enter a valid amount."
                    return
                }
                fieldError = nil
                // F-P2-3: confirm before setting — one tap used to
                // set a 1–4 week allowance with no dialog, and $0
                // was accepted silently.
                showConfirm = true
            }
            // F-P2-2: remove the override for the current week
            // onward, so the base allowance applies again. Until
            // supabase/remove-weekly-allowance-override.sql is
            // applied live this fails with a plain-language error.
            FundsQuietButton("Remove Override", isBusy: viewModel.busyAction == "remove-temp") {
                Task { await viewModel.removeTemporaryAllowance() }
            }
        }
        .confirmationDialog(
            "Set New Total",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button(TitleCase.apply(to: "Set New Total")) {
                Task {
                    guard let cents = newTotalCents else { return }
                    // Clear only on success — on failure the typed
                    // input stays beside the error (F-P1-4).
                    if await viewModel.setTemporaryAllowance(newTotalCents: cents, weeks: weeks) {
                        newTotalText = ""
                        weeks = 1
                    }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }
}
