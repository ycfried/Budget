// OnBudget — Settings: Budget card (live web v66, §10.4).
//
// Base weekly allowance only. Admin only.
//
// Wiring (exact API calls):
// - Current allowance: `PostgrestClient.householdAllowance(
//   householdId:)` — `base_allowance_cents` + `allowance_set_at`.
//   A null `allowance_set_at` means the $375 figure is the schema
//   default, not a choice — the field is still prefilled from the
//   stored base, exactly as the web prefills it.
// - Save: RPC `set_base_allowance(p_household_id, p_cents)` after a
//   confirm sheet ("Change Allowance": old -> new, applies from the
//   current week onward, does not rewrite closed weeks). Empty input
//   is NOT 0 ("Enter a valid allowance (empty is not 0).").
//
// Temporary Allowance is owned by the Funds agent — it is NOT
// duplicated here. This card only links to it (when the coordinator
// supplies `onOpenTemporaryAllowance`): a "Temporary Allowance"
// row with an "Open Temporary Allowance" button. Without the link
// the row says where it lives (Funds page).

import SwiftUI
import OnBudgetKit

@MainActor
final class BudgetSettingsViewModel: ObservableObject {
    @Published var allowanceText = ""
    @Published var currentAllowanceCents: Int?
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var isSaving = false
    @Published var confirmChange: AllowanceChange?

    struct AllowanceChange: Identifiable {
        let oldCents: Int?
        let newCents: Int
        let weekStart: String?
        var id: String { "change-\(newCents)" }
    }

    private let context: SettingsContext
    private let toast: ToastState

    init(context: SettingsContext, toast: ToastState) {
        self.context = context
        self.toast = toast
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (baseCents, _) = try await context.client.postgrest.householdAllowance(householdId: context.householdId)
            currentAllowanceCents = baseCents
            if let baseCents {
                allowanceText = String(format: "%.2f", Double(baseCents) / 100)
            }
            loadError = nil
        } catch {
            loadError = settingsErrorMessage(error)
        }
    }

    func saveTapped() {
        guard let cents = OnBudgetKit.MoneyFormat.parseDollarsStrict(allowanceText), cents >= 0 else {
            toast.showError("Enter a valid allowance (empty is not 0).")
            return
        }
        confirmChange = AllowanceChange(
            oldCents: currentAllowanceCents,
            newCents: cents,
            weekStart: nil
        )
    }

    /// The change arrives as a parameter, captured by the alert's
    /// button: `.alert(item:)` nils the `confirmChange` binding when
    /// the alert dismisses, which happens BEFORE an unstructured
    /// `Task` runs — so re-reading the binding here always found nil
    /// and the allowance change silently never happened (same pitfall
    /// as removeConfirmed, Nov 11, 2026).
    func confirmSave(_ change: AllowanceChange) async {
        confirmChange = nil
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await context.client.rpcs.setBaseAllowance(
                pHouseholdId: context.householdId,
                pCents: change.newCents
            )
            currentAllowanceCents = change.newCents
            toast.show("Allowance saved.")
        } catch {
            toast.showError("Could not save allowance. Try again.")
        }
    }
}

struct BudgetSettingsView: View {
    @StateObject private var viewModel: BudgetSettingsViewModel
    private let context: SettingsContext

    init(context: SettingsContext, toast: ToastState) {
        self.context = context
        _viewModel = StateObject(wrappedValue: BudgetSettingsViewModel(context: context, toast: toast))
    }

    var body: some View {
        SettingsCard(title: "Budget") {
            HStack(spacing: 8) {
                Text("Only the admin can change these.")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#6b7280"))
                Spacer()
                RolePill(role: .admin)
            }

            Text("Weekly Allowance")
                .font(.headline)
                .padding(.top, 4)
            if viewModel.isLoading {
                ProgressView()
            } else if let error = viewModel.loadError {
                ErrorBox(error)
            }
            HStack(spacing: 8) {
                Text("$")
                    .font(.headline)
                    .foregroundStyle(DesignTokens.ink)
                TextField("0.00", text: $viewModel.allowanceText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
            Button(viewModel.isSaving ? "Saving…" : "Save Allowance") {
                viewModel.saveTapped()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.isSaving)

            // Temporary Allowance is owned by the Funds agent —
            // Settings only links to it, never duplicates the box.
            VStack(alignment: .leading, spacing: 8) {
                Text("Temporary Allowance")
                    .font(.headline)
                    .padding(.top, 8)
                if let openTemporary = context.onOpenTemporaryAllowance {
                    Button("Open Temporary Allowance") {
                        openTemporary()
                    }
                    .buttonStyle(TertiaryButtonStyle())
                } else {
                    MutedLine(text: "Set a temporary weekly total on the Funds page.")
                }
            }
        }
        .task { await viewModel.load() }
        .alert(item: $viewModel.confirmChange) { change in
            let message: String
            if let old = change.oldCents {
                message = "Change the weekly allowance from \(OnBudgetKit.MoneyFormat.formatCents(old)) to \(OnBudgetKit.MoneyFormat.formatCents(change.newCents))?\nThis applies from the current week onward. It does not rewrite closed weeks."
            } else {
                message = "Set the weekly allowance to \(OnBudgetKit.MoneyFormat.formatCents(change.newCents))? (The current allowance could not be read, so no old value is shown.)\nThis applies from the current week onward. It does not rewrite closed weeks."
            }
            return Alert(
                title: Text("Change Allowance"),
                message: Text(message),
                primaryButton: .default(Text("Change Allowance")) {
                    Task { await viewModel.confirmSave(change) }
                },
                secondaryButton: .cancel(Text("Keep Current"))
            )
        }
    }
}
