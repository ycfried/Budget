import SwiftUI
import OnBudgetCore

enum Brand {
    static let blue = Color(red: 47 / 255, green: 107 / 255, blue: 1)
}
struct AmountRow: View {
    let title: String
    let money: Money
    var body: some View {
        LabeledContent(title) { Text(money.formatted).monospacedDigit().foregroundStyle(.primary) }
            .accessibilityElement(children: .combine)
    }
}
struct SampleNotice: View {
    var body: some View {
        Label("SAMPLE DATA · No accounts connected", systemImage: "flask")
            .font(.caption).fontWeight(.semibold).foregroundStyle(Brand.blue)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("sampleNotice")
    }
}
struct SnapshotNotice: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SampleNotice()
            if model.readError != nil {
                Label("Last-known sample · updates unavailable · read-only", systemImage: "clock.badge.exclamationmark")
                    .font(.caption).accessibilityIdentifier("staleSnapshotNotice")
            }
        }
    }
}
struct FreshnessView: View {
    let source: SourceHealth
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(source.name, systemImage: source.stale ? "clock.badge.exclamationmark" : "checkmark.circle")
                .font(.subheadline.bold())
            Text(source.status).font(.caption)
            if let date = source.lastUpdated {
                Text(date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
            } else { Text("Not updated").font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
}
struct PurchaseRow: View {
    let purchase: Purchase
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: purchase.kind == .refund ? "arrow.uturn.backward.circle" : "bag")
                .foregroundStyle(Brand.blue).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(purchase.merchant).font(.headline)
                Text("\(purchase.date.rawValue) · ••\(purchase.cardSuffix)").font(.caption).foregroundStyle(.secondary)
                Text("\(purchase.stateLabel) · \(purchase.kind.wireValue)").font(.caption)
                if purchase.needsReview { Label("Needs review", systemImage: "flag").font(.caption) }
            }
            Spacer(minLength: 8)
            Text(purchase.amount.formatted).monospacedDigit()
        }.accessibilityElement(children: .combine)
            .accessibilityLabel("\(purchase.merchant), \(purchase.amount.formatted), \(purchase.stateLabel), \(purchase.date.rawValue)")
    }
}
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab = 0
    var body: some View {
        Group {
            if model.session == nil { AuthenticationView() }
            else {
                TabView(selection: $selectedTab) {
                    NavigationStack { DashboardView() }.tabItem { Label("Home", systemImage: "house") }.tag(0)
                    NavigationStack { TransactionsView() }.tabItem { Label("Purchases", systemImage: "list.bullet.rectangle") }.tag(1)
                    NavigationStack { FundView() }.tabItem { Label("Extra Fund", systemImage: "tray.full") }.tag(2)
                    NavigationStack {
                        List {
                            NavigationLink("Savings") { SavingsView() }
                            NavigationLink("Weekly history") { HistoryView() }
                            NavigationLink("Connections") { ConnectionsView() }
                            NavigationLink("Settings & audit") { SettingsView() }
                        }.navigationTitle("More")
                    }.tabItem { Label("More", systemImage: "ellipsis.circle") }.tag(3)
                }
            }
        }
        .onOpenURL { url in
            guard url.scheme == "onbudget-sample", url.host == "home", url.query == nil else { return }
            selectedTab = 0
        }
        .onChange(of: model.session == nil) { _, signedOut in if signedOut { selectedTab = 0 } }
        .modifier(ToastOverlay())
    }
}
struct ToastOverlay: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = model.toast {
                Button { model.toast = nil } label: {
                    Text(toast).font(.subheadline).foregroundStyle(.white).padding()
                        .background(Brand.blue, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal).padding(.bottom, 120)
                .accessibilityLabel("Notification: \(toast). Tap to dismiss.")
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
}
