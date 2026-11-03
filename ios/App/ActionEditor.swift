import SwiftUI
import OnBudgetCore

enum EditorMode: Identifiable {
    case manual, request(String?), approve(String), allocate, temporary, allowance, savings, attest
    case transaction(String, TransactionChange), flag(String), held(String)
    var id: String { title }
    var title: String {
        switch self {
        case .manual: "Add purchase"
        case .request: "Request Extra Fund"
        case .approve: "Approve or split"
        case .allocate: "Allocate Extra Fund"
        case .temporary: "Temporary increase"
        case .allowance: "Change allowance"
        case .savings: "Record savings movement"
        case .attest: "Record savings balance"
        case .transaction(_, let change): change.rawValue
        case .flag: "Flag for review"
        case .held: "Release held refund"
        }
    }
    var requiresAmount: Bool {
        switch self {
        case .transaction, .flag, .held: false
        default: true
        }
    }
}
struct ActionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: EditorMode
    @State private var amount = ""
    @State private var merchant = ""
    @State private var date = PurchaseDate.today().rawValue
    @State private var card = ""
    @State private var note = ""
    @State private var overrideReason = ""
    @State private var classification = "charge"
    @State private var savingsKind: SavingsKind = .transferIn
    @State private var confirming = false
    @State private var prepared: HouseholdAction?
    var body: some View {
        NavigationStack {
            Form {
                Section { SampleNotice(); Text("This records a sample action only. Financial summaries remain fixed.").font(.caption) }
                Section(mode.title) {
                    if case .manual = mode {
                        TextField("Merchant", text: $merchant).textInputAutocapitalization(.words)
                        TextField("Purchase date (YYYY-MM-DD)", text: $date).keyboardType(.numbersAndPunctuation)
                        TextField("Last four card digits", text: $card).keyboardType(.numberPad)
                    }
                    if mode.requiresAmount {
                        TextField("Amount in dollars", text: $amount).keyboardType(.decimalPad)
                            .accessibilityIdentifier("actionAmount")
                    }
                    if case .savings = mode {
                        Picker("Movement", selection: $savingsKind) {
                            ForEach(SavingsKind.allCases, id: \.self) { Text($0.rawValue.replacingOccurrences(of: "_", with: " ")).tag($0) }
                        }
                    }
                    if case .transaction(_, .reclassify) = mode {
                        Picker("Classification", selection: $classification) {
                            Text("Charge").tag("charge"); Text("Refund").tag("refund"); Text("Fund charge").tag("fund_charge")
                        }
                    }
                    TextField("Note or reason (optional)", text: $note, axis: .vertical).lineLimit(2...4)
                    if case .approve = mode { overrideInput }
                    if case .allocate = mode { overrideInput }
                    if case .allowance = mode {
                        Text("Current sample allowance: \(model.snapshot?.dashboard.allowance.formatted ?? "Unavailable"). Effective-date behavior requires a backend decision before staging.").font(.caption)
                    }
                    if case .held = mode { Text("Owner decision: release to spendable surplus after shortfall offsets. Only the server may post this.").font(.caption) }
                }
                Section {
                    Button("Review sample action") {
                        do { prepared = try action(); confirming = true }
                        catch { model.notify(error.localizedDescription) }
                    }.disabled(!model.canWrite)
                }
            }
            .modifier(ToastOverlay())
            .navigationTitle(mode.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("\(mode.title)\(amount.isEmpty ? "" : ": $" + amount)? Sample only; no account will change.", isPresented: $confirming, titleVisibility: .visible) {
                Button("Record sample action") {
                    guard let prepared else { return }
                    Task { if await model.submit(prepared) { dismiss() } }
                }
                Button("Cancel", role: .cancel) { prepared = nil }
            }
        }
    }
    private var overrideInput: some View {
        TextField("Insufficient-fund override reason (if needed)", text: $overrideReason, axis: .vertical).lineLimit(2...3)
    }
    private func action() throws -> HouseholdAction {
        let money = mode.requiresAmount ? try Money(dollars: amount) : Money(cents: 0)
        switch mode {
        case .manual: return .manual(try ManualPurchase(merchant: merchant, amount: money, date: PurchaseDate(date), cardSuffix: card))
        case .request(let id): return .request(transactionID: id, amount: money, note: note)
        case .approve(let id): return .approve(requestID: id, amount: money, overrideReason: overrideReason)
        case .allocate: return .allocate(amount: money, note: note, overrideReason: overrideReason)
        case .temporary: return .temporaryIncrease(money, note: note)
        case .allowance: return .allowance(money)
        case .savings: return .savings(savingsKind, money, note: note)
        case .attest: return .attest(money, note: note)
        case .transaction(let id, let change): return .transaction(id: id, change: change, value: classification, reason: note)
        case .flag(let id): return .flag(id: id, note: note)
        case .held(let id): return .resolveHeld(id: id)
        }
    }
}
