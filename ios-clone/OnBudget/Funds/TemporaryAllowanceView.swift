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

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    private var newTotalCents: Int? { MoneyFormat.parseDollarsStrict(newTotalText) }

    /// Preview: "Base `$B` · New total `$N` · `W` week(s) · `YYYY-MM-DD, …`."
    /// Empty until values are entered.
    private var previewText: String {
        guard let base = viewModel.baseAllowanceCents,
              let total = newTotalCents, total >= 0 else { return "" }
        let dates = MoneyFormat.sundays(from: MoneyFormat.currentSundayNY(), count: weeks)
        return "Base \(MoneyFormat.formatCents(base)) · New total \(MoneyFormat.formatCents(total)) · \(weeks) week(s) · \(dates.joined(separator: ", "))."
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
            if !previewText.isEmpty {
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
                Task {
                    await viewModel.setTemporaryAllowance(newTotalCents: cents, weeks: weeks)
                    newTotalText = ""
                    weeks = 1
                }
            }
        }
    }
}
