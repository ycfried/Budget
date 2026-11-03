import SwiftUI
import OnBudgetCore

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section { SnapshotNotice() }
            if let error = model.readError {
                Section("Update unavailable") {
                    Label(error, systemImage: "wifi.exclamationmark")
                    Text("Any values below are the last-known fixed sample, not current balances.")
                    Button("Retry") { Task { await model.refresh() } }
                }
            }
            if let snapshot = model.snapshot {
                let dashboard = snapshot.dashboard
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Available this week").font(.headline)
                        Text(Money(cents: dashboard.week.availableCents).formatted)
                            .font(.system(.largeTitle, design: .rounded).bold()).monospacedDigit()
                            .accessibilityIdentifier("weeklyAvailable")
                        if dashboard.week.availableCents < 0 { Label("Over budget", systemImage: "exclamationmark.circle") }
                        Text("Fixed sample · \(dashboard.daysLeft) days left in fixture").font(.subheadline)
                        Text("Some recent purchases may not be included. Fixed sample summaries do not recalculate after actions.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("As of \(dashboard.computedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                        if model.isAdmin {
                            Button { Task { await model.submit(.bankSync) } } label: { Label("Preview bank sync", systemImage: "arrow.clockwise") }
                                .disabled(!model.canWrite)
                        }
                    }.padding(.vertical, 8)
                } header: { Text("Week of \(dashboard.week.weekStart) · Sun–Sat") }
                Section("This week") {
                    AmountRow(title: "Allowance", money: dashboard.allowance)
                    AmountRow(title: "Spent", money: Money(cents: dashboard.week.chargesCents))
                    AmountRow(title: "Temporary increase", money: Money(cents: dashboard.week.tempCents))
                    AmountRow(title: "Carried over (incoming debt)", money: Money(cents: dashboard.week.carriedDebtCents))
                    if let outgoing = dashboard.outgoingDebt { AmountRow(title: "Outgoing debt", money: outgoing) }
                    AmountRow(title: "Pending refunds excluded", money: Money(cents: dashboard.week.pendingRefundExcludedCents))
                }
                Section("Extra Fund") {
                    AmountRow(title: "Available", money: snapshot.fund.available)
                    AmountRow(title: "Pending release", money: snapshot.fund.pending)
                }
                Section("Source freshness") { ForEach(snapshot.sources) { FreshnessView(source: $0) } }
                Section("Recent purchases") {
                    ForEach(snapshot.purchases.prefix(4)) { row in NavigationLink { PurchaseDetailView(purchase: row) } label: { PurchaseRow(purchase: row) } }
                }
            } else if model.loading { ProgressView("Loading sample…") }
        }.navigationTitle("OnBudget")
            .refreshable { await model.refresh() }
            .toolbar { if model.loading { ProgressView() } }
    }
}
