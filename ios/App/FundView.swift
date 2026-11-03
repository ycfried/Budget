import SwiftUI
import OnBudgetCore

struct FundView: View {
    @Environment(AppModel.self) private var model
    @State private var editor: EditorMode?
    @State private var decline: FundRequest?
    var body: some View {
        List {
            Section { SnapshotNotice() }
            if let snapshot = model.snapshot {
                Section("Extra Spending Fund") {
                    AmountRow(title: "Available", money: snapshot.fund.available)
                    AmountRow(title: "Pending release", money: snapshot.fund.pending)
                    AmountRow(title: "Released total", money: snapshot.fund.released)
                    AmountRow(title: "Spent", money: snapshot.fund.spent)
                    AmountRow(title: "Adjustments", money: snapshot.fund.adjustments)
                    AmountRow(title: "Owed back (shortfall)", money: snapshot.fund.shortfall)
                    Text("A ledger entitlement, not a bank balance. Overspending is never automatically taken from this fund.").font(.caption)
                    Button("Request fund use") { editor = .request(nil) }.disabled(!model.canWrite)
                    if model.isAdmin { Button("Allocate fund") { editor = .allocate }.disabled(!model.canWrite) }
                }
                Section("Requests") {
                    ForEach(snapshot.requests) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(request.merchant).font(.headline)
                            Text("\(request.requester) · \(request.amount.formatted) · \(request.status)")
                            if !request.note.isEmpty { Text(request.note).font(.caption) }
                            if request.status == "split" {
                                Text("Closed split · remainder \(request.remainder.formatted) is not re-approvable.").font(.caption)
                            }
                            if model.isAdmin && request.status == "pending" {
                                Button("Approve or adjust split") { editor = .approve(request.id) }
                                Button("Decline", role: .destructive) { decline = request }
                            }
                        }.disabled(!model.canWrite)
                    }
                }
                Section("Fund ledger") {
                    ForEach(snapshot.fundLedger) { entry in
                        VStack(alignment: .leading) { AmountRow(title: entry.title, money: entry.amount); Text(entry.detail).font(.caption) }
                    }
                }
                Section("Refund restorations") {
                    ForEach(snapshot.restorations) { entry in
                        VStack(alignment: .leading) { AmountRow(title: entry.title, money: entry.amount); Text(entry.detail).font(.caption) }
                    }
                }
                Section("Held for review") {
                    ForEach(snapshot.heldRefunds) { held in
                        VStack(alignment: .leading) {
                            AmountRow(title: held.merchant, money: held.amount)
                            Text(held.status).font(.caption)
                            if model.isAdmin && held.status == "pending" {
                                Button("Review release") { editor = .held(held.id) }.disabled(!model.canWrite)
                            }
                        }
                    }
                }
            }
        }.navigationTitle("Extra Fund")
            .sheet(item: $editor) { ActionEditor(mode: $0) }
            .confirmationDialog("Decline this sample request?", isPresented: Binding(get: { decline != nil }, set: { if !$0 { decline = nil } })) {
                Button("Record sample decline", role: .destructive) {
                    guard let request = decline else { return }
                    Task { await model.submit(.decline(requestID: request.id)); decline = nil }
                }
            }
            .refreshable { await model.refresh() }
    }
}
