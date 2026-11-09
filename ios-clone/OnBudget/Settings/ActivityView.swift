// OnBudget — Activity (live web v66, §13).
//
// Who did what, and when — not the transaction list. Grouped by day
// (newest day first), each entry: small coloured dot per type, short
// bold title, one plain detail line, muted "Actor · Mon D, h:mm AM".
//
// Wiring (exact API calls):
// - `PostgrestClient.auditLogPage(householdId:limit:from:to:)` —
//   `audit_log`, newest first, page size 50 (`Load More Activity`
//   +50 per tap). A filtered view fetches up to 1000 newest rows so
//   the period is not silently cut off. The `to` bound is sent as
//   end-of-day UTC so the whole `to` day is included (the web
//   filters client-side on the UTC date part of `created_at`).
// - Display text is translated from stored rows
//   (`AuditFormatting.formatAuditDetail` / `formatAuditAction` /
//   `formatAuditActor`): UUIDs stripped, ISO dates -> long dates,
//   "N cents" -> $X, "N basis points" -> N%, "as provisional" ->
//   "as pending". Stored rows are never edited.
// - Repeated weekly-processing rows collapse into one line with a
//   count ("N weeks closed"); user actions never collapse.
// - Shares the History date filter with Past Weeks
//   (`HistoryFilterState`); applying the filter resets the page to 50.

import SwiftUI
import OnBudgetKit

/// One day's Activity entries, newest day first.
struct ActivityDayGroup: Identifiable {
    let day: String
    let entries: [AuditDisplayEntry]
    var id: String { day }
}

@MainActor
final class ActivityViewModel: ObservableObject {
    @Published var groups: [ActivityDayGroup] = []
    @Published var loadError: String?
    @Published var isLoading = false
    @Published var auditLimit = 50
    @Published var hasMore = false
    @Published var draftFrom = ""
    @Published var draftTo = ""

    private let context: SettingsContext
    let filter: HistoryFilterState

    init(context: SettingsContext, filter: HistoryFilterState) {
        self.context = context
        self.filter = filter
        self.draftFrom = filter.fromDate
        self.draftTo = filter.toDate
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let filtered = filter.isActive
        let fetchLimit = filtered ? 1000 : auditLimit
        do {
            let (rows, total) = try await context.client.postgrest.auditLogPage(
                householdId: context.householdId,
                limit: fetchLimit,
                from: filter.fromDate.isEmpty ? nil : filter.fromDate,
                to: filter.toDate.isEmpty ? nil : "\(filter.toDate)T23:59:59.999Z"
            )
            // Client-side date filter too (same UTC-date-part rule
            // as the web): rows without a parseable date are kept.
            let filteredRows = AuditFormatting.filterRowsByDate(
                rows,
                getDate: { $0.createdAt },
                from: filter.fromDate.isEmpty ? nil : filter.fromDate,
                to: filter.toDate.isEmpty ? nil : filter.toDate
            )
            filter.auditShown = filteredRows.count
            filter.auditTotal = total
            hasMore = !filtered && (total.map { filteredRows.count < $0 } ?? rows.count >= fetchLimit)
            var byDay: [String: [AuditDisplayEntry]] = [:]
            var dayOrder: [String] = []
            for row in filteredRows {
                let day = MoneyFormat.newYorkDayString(row.createdAt) ?? "Unknown date"
                let entry = AuditDisplayEntry(
                    action: AuditFormatting.formatAction(row.action),
                    detail: AuditFormatting.formatDetail(row.detail),
                    actor: AuditFormatting.formatActor(row.actorName),
                    time: MoneyFormat.fmtDateTime(row.createdAt)
                )
                if byDay[day] == nil { dayOrder.append(day) }
                byDay[day, default: []].append(entry)
            }
            groups = dayOrder.map { day in
                ActivityDayGroup(
                    day: day,
                    entries: AuditFormatting.groupDayActivity(byDay[day] ?? [])
                )
            }
            loadError = nil
        } catch {
            loadError = "Could not load history. Try again."
            hasMore = false
        }
    }

    func loadMore() async {
        auditLimit += 50
        await load()
    }

    func applyFilter() async {
        filter.fromDate = draftFrom
        filter.toDate = draftTo
        auditLimit = 50
        await load()
    }

    func clearFilter() async {
        draftFrom = ""
        draftTo = ""
        filter.clear()
        auditLimit = 50
        await load()
    }
}

struct ActivityView: View {
    @StateObject private var viewModel: ActivityViewModel
    let onBack: () -> Void

    init(context: SettingsContext, filter: HistoryFilterState, onBack: @escaping () -> Void = {}) {
        self.onBack = onBack
        _viewModel = StateObject(wrappedValue: ActivityViewModel(context: context, filter: filter))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    BackButton(action: onBack)
                    Spacer()
                }
                Text("Activity")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Who did what, and when — not the transaction list.")
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

                if viewModel.isLoading && viewModel.groups.isEmpty {
                    ProgressView()
                } else if let error = viewModel.loadError {
                    ErrorBox(message: error)
                } else if viewModel.groups.isEmpty {
                    MutedLine(text: viewModel.filter.isActive
                        ? "No entries in the selected period."
                        : "No audit entries yet.")
                } else {
                    ForEach(viewModel.groups) { group in
                        daySection(group)
                    }
                    if !viewModel.filter.isActive && viewModel.hasMore {
                        MutedLine(text: "More entries exist — tap Load more below.")
                    }
                    if viewModel.hasMore {
                        Button("Load More Activity") {
                            Task { await viewModel.loadMore() }
                        }
                        .buttonStyle(TertiaryButtonStyle())
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

    private func daySection(_ group: ActivityDayGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.day == "Unknown date" ? "Unknown date" : MoneyFormat.fmtLong(group.day))
                .font(.headline)
            ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                activityRow(entry)
            }
        }
    }

    private func activityRow(_ entry: AuditDisplayEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(dotColor(for: entry))
                .frame(width: 10, height: 10)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(AuditFormatting.activityTitle(action: entry.action, count: entry.count))
                    .font(.subheadline)
                    .fontWeight(.bold)
                Text(entry.detail)
                    .font(.subheadline)
                Text("\(entry.actor) · \(entry.time)")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
        }
    }

    private func dotColor(for entry: AuditDisplayEntry) -> Color {
        switch AuditFormatting.dotClass(action: entry.action, detail: entry.detail) {
        case "charity": return Color(hex: "#16a34a")
        case "system": return Color(hex: "#6b7280")
        default: return DesignTokens.primary
        }
    }
}
