// OnBudget — Past Weeks (live web v66, §12).
//
// Closed weeks, read-only. Tap a week to see its summary and its
// transactions.
//
// Wiring (exact API calls):
// - `PostgrestClient.weekCloses(householdId:)` — `week_closes`
//   (`week_start, surplus_cents, outgoing_debt_cents`), newest
//   first, max 100 shown.
// - `PostgrestClient.surplusReleasesForHistory(householdId:)` —
//   `surplus_releases` (`week_start, surplus_cents, released_cents,
//   status`). The client NEVER recomputes a week.
// - Carry-in = the previous closed week's outgoing debt (the
//   debt-carry chain, computed over the FULL chain before filtering,
//   so it stays true); a first week has no carry-in on record.
//   Missing figures read "not recorded", never $0.
// - Release label/value: no release row -> "Release" / "not
//   recorded"; released -> "Released" / `released_cents ??
//   surplus_cents`; pending -> "Pending release" / `surplus_cents`;
//   held -> "Held" / `surplus_cents`.
// - Tap: `context.onShowWeekTransactions(weekStart)` (the
//   Transactions agent opens Transactions filtered to that Sun–Sat
//   week and refreshes) + toast "Showing transactions for the week
//   of `Mon D, YYYY`."
// - The History date filter is shared with Activity
//   (`HistoryFilterState`, also used by ActivityView).

import SwiftUI
import OnBudgetKit

/// The History date filter, shared by Past Weeks and Activity
/// (live.js `historyFilter`). From/To are `YYYY-MM-DD` strings;
/// blank means no limit on that side. The count line covers both
/// lists, so the shared state also carries each list's last shown
/// / total counts.
@MainActor
final class HistoryFilterState: ObservableObject {
    @Published var fromDate = ""
    @Published var toDate = ""
    @Published var weekShown = 0
    @Published var weekTotal: Int?
    @Published var auditShown = 0
    @Published var auditTotal: Int?

    var isActive: Bool { !fromDate.isEmpty || !toDate.isEmpty }

    var periodLine: String {
        AuditFormatting.historyPeriodLabel(
            from: fromDate.isEmpty ? nil : fromDate,
            to: toDate.isEmpty ? nil : toDate
        )
    }

    /// "Closed weeks: S shown of T total · Activity: S shown of T
    /// total" — shown only when a filter is active or a list is
    /// empty; otherwise blank (live.js:2255-2270).
    var countLine: String {
        let filterActive = isActive
        let listsEmpty = weekShown == 0 && auditShown == 0
        guard filterActive || listsEmpty else { return "" }
        let weekPart = "Closed weeks: \(weekShown) shown\(weekTotal.map { " of \($0) total" } ?? "")"
        let auditPart = "Activity: \(auditShown) shown\(auditTotal.map { " of \($0) total" } ?? "")"
        return "\(weekPart) · \(auditPart)"
    }

    func clear() {
        fromDate = ""
        toDate = ""
    }
}

/// One closed week, as rendered.
struct PastWeekRow: Identifiable {
    let weekStart: String
    let carryInCents: Int?
    let surplusCents: Int?
    let outgoingDebtCents: Int?
    let releaseLabel: String
    let releaseCents: Int?

    var id: String { weekStart }

    var heading: String { MoneyFormat.fmtLong(weekStart) }

    func moneyOrMissing(_ cents: Int?) -> String {
        cents.map { MoneyFormat.formatCents($0) } ?? "not recorded"
    }
}

@MainActor
final class PastWeeksViewModel: ObservableObject {
    @Published var weeks: [PastWeekRow] = []
    @Published var loadError: String?
    @Published var isLoading = false
    @Published var draftFrom = ""
    @Published var draftTo = ""

    private let context: SettingsContext
    private let toast: ToastState
    let filter: HistoryFilterState

    init(context: SettingsContext, toast: ToastState, filter: HistoryFilterState) {
        self.context = context
        self.toast = toast
        self.filter = filter
        self.draftFrom = filter.fromDate
        self.draftTo = filter.toDate
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let closes = try await context.client.postgrest.weekCloses(householdId: context.householdId)
            let releases = try await context.client.postgrest.surplusReleasesForHistory(householdId: context.householdId)
            let releaseByWeek: [String: SurplusRelease] = Dictionary(
                releases.map { ($0.weekStart, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // Carry-in over the FULL chain (ascending), before the
            // date filter narrows what is shown.
            let ascending = closes.sorted { $0.weekStart < $1.weekStart }
            var carryInByWeek: [String: Int?] = [:]
            for (index, close) in ascending.enumerated() {
                carryInByWeek[close.weekStart] = index == 0 ? nil : ascending[index - 1].outgoingDebtCents
            }
            let shown = AuditFormatting.filterRowsByDate(
                closes.sorted { $0.weekStart > $1.weekStart },
                getDate: { $0.weekStart },
                from: filter.fromDate.isEmpty ? nil : filter.fromDate,
                to: filter.toDate.isEmpty ? nil : filter.toDate
            ).prefix(100)
            filter.weekShown = shown.count
            filter.weekTotal = closes.count
            weeks = shown.map { close in
                let release = releaseByWeek[close.weekStart]
                let label: String
                let cents: Int?
                switch release?.status {
                case nil:
                    label = "Release"
                    cents = nil
                case "released":
                    label = "Released"
                    cents = release?.releasedCents ?? release?.surplusCents
                case "pending":
                    label = "Pending release"
                    cents = release?.surplusCents
                default:
                    label = "Held"
                    cents = release?.surplusCents
                }
                return PastWeekRow(
                    weekStart: close.weekStart,
                    carryInCents: carryInByWeek[close.weekStart] ?? nil,
                    surplusCents: close.surplusCents,
                    outgoingDebtCents: close.outgoingDebtCents,
                    releaseLabel: label,
                    releaseCents: cents
                )
            }
            loadError = nil
        } catch {
            loadError = "Could not load week history. Try again."
        }
    }

    func applyFilter() async {
        filter.fromDate = draftFrom
        filter.toDate = draftTo
        await load()
    }

    func clearFilter() async {
        draftFrom = ""
        draftTo = ""
        filter.clear()
        await load()
    }

    func weekTapped(_ week: PastWeekRow) {
        context.onShowWeekTransactions(week.weekStart)
        toast.show("Showing transactions for the week of \(week.heading).")
    }
}

struct PastWeeksView: View {
    @StateObject private var viewModel: PastWeeksViewModel
    let onBack: () -> Void

    init(context: SettingsContext, toast: ToastState, filter: HistoryFilterState, onBack: @escaping () -> Void = {}) {
        self.onBack = onBack
        _viewModel = StateObject(wrappedValue: PastWeeksViewModel(context: context, toast: toast, filter: filter))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    BackButton(action: onBack)
                    Spacer()
                }
                Text("Past Weeks")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Closed weeks, read-only. Tap a week to see its summary and its transactions.")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#6b7280"))

                SettingsCard(title: "Filter by Date") {
                    HStack(spacing: 12) {
                        dateField(label: "From", text: $viewModel.draftFrom)
                        dateField(label: "To", text: $viewModel.draftTo)
                    }
                    HStack(spacing: 12) {
                        Button("Apply Filter") {
                            Task { await viewModel.applyFilter() }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        Button("Clear Date Filter") {
                            Task { await viewModel.clearFilter() }
                        }
                        .buttonStyle(TertiaryButtonStyle())
                    }
                    if !viewModel.filter.periodLine.isEmpty {
                        MutedLine(text: viewModel.filter.periodLine)
                    }
                    if !viewModel.filter.countLine.isEmpty {
                        MutedLine(text: viewModel.filter.countLine)
                    }
                }

                SettingsCard(title: "Week History") {
                    if viewModel.isLoading && viewModel.weeks.isEmpty {
                        ProgressView()
                    } else if let error = viewModel.loadError {
                        ErrorBox(message: error)
                    } else if viewModel.weeks.isEmpty {
                        MutedLine(text: viewModel.filter.isActive
                            ? "No closed weeks in the selected period."
                            : "No closed weeks yet.")
                    } else {
                        ForEach(viewModel.weeks) { week in
                            weekBlock(week)
                        }
                    }
                }
            }
            .padding()
        }
        .task { await viewModel.load() }
    }

    private func dateField(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.semibold)
            DatePicker("", selection: Binding(
                get: { Self.date(from: text.wrappedValue) ?? Date() },
                set: { text.wrappedValue = Self.string(from: $0) }
            ), displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
            .frame(maxWidth: 160)
        }
    }

    private static func date(from string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)
    }

    private static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func weekBlock(_ week: PastWeekRow) -> some View {
        Button {
            viewModel.weekTapped(week)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(week.heading)
                    .font(.headline)
                    .foregroundStyle(DesignTokens.ink)
                metricRow(label: "Carry-in", value: week.moneyOrMissing(week.carryInCents))
                metricRow(label: "Surplus", value: week.moneyOrMissing(week.surplusCents))
                metricRow(label: "Debt carried out", value: week.moneyOrMissing(week.outgoingDebtCents))
                metricRow(label: week.releaseLabel, value: week.moneyOrMissing(week.releaseCents))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(hex: "#eef4ff"))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Week of \(week.heading) — show its transactions")
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#6b7280"))
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(DesignTokens.ink)
        }
    }
}
