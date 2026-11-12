// OnBudget — Activity (live web v66, §13).
//
// General Activity: who did what, and when — not the transaction
// list. Grouped by day (newest day first), each entry: small
// coloured dot per type, short bold title, one plain detail line
// (only when it adds something the title does not say), muted
// "Actor · Mon D, h:mm AM".
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
//   "as pending". Stored rows are never edited. Row wording is
//   shortened display-side only (owner, Nov 12 2026): the title
//   says the thing once, the detail adds only new information, a
//   no-op "changed from $X to $X" never renders as a change.
// - Repeated weekly-processing rows collapse into one line with a
//   count ("N weeks closed"); user actions never collapse.
// - The date filter is the shared one-button + one-calendar range
//   picker (`HistoryDateFilterCard`, same calendar as
//   Transactions); the type filter is a chip row of the types
//   actually present in the log (single-select, combines with the
//   date filter). Reset Filters clears both.

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
    /// Type filter: nil = All. Chips show only the types actually
    /// present in the (date-filtered) log, in canonical order.
    @Published var selectedType: AuditFormatting.ActivityType?
    @Published var availableTypes: [AuditFormatting.ActivityType] = []

    private let context: SettingsContext
    let filter: HistoryFilterState

    init(context: SettingsContext, filter: HistoryFilterState) {
        self.context = context
        self.filter = filter
        self.draftFrom = filter.fromDate
        self.draftTo = filter.toDate
    }

    /// Empty-state copy: the type filter names itself when it is
    /// what emptied the list; otherwise the existing lines stay
    /// (audit X-P2-2: "No activity yet.").
    var emptyText: String {
        if let type = selectedType {
            return "No \(type.label) entries in this view."
        }
        return filter.isActive ? "No entries in the selected period." : "No activity yet."
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
            // `??` binds TIGHTER than `>=` in Swift, so the RHS of
            // `??` needs explicit parens: without them this parsed
            // as `(total.map { ... } ?? rows.count) >= fetchLimit`
            // and the closure was expected to return Int
            // (compile-fixes, Nov 9, 2026).
            hasMore = !filtered && (total.map { filteredRows.count < $0 } ?? (rows.count >= fetchLimit))
            var byDay: [String: [AuditDisplayEntry]] = [:]
            var dayOrder: [String] = []
            for row in filteredRows {
                let day = OnBudgetKit.MoneyFormat.newYorkDayString(row.createdAt) ?? "Unknown date"
                let entry = AuditDisplayEntry(
                    action: AuditFormatting.formatAction(row.action),
                    detail: AuditFormatting.formatDetail(row.detail),
                    actor: AuditFormatting.formatActor(row.actorName),
                    time: OnBudgetKit.MoneyFormat.fmtDateTime(row.createdAt)
                )
                if byDay[day] == nil { dayOrder.append(day) }
                byDay[day, default: []].append(entry)
            }
            // Type chips: only the types actually present in the
            // date-filtered log, in canonical order. The chip list
            // is derived BEFORE the type filter applies, so picking
            // a chip never shrinks the chips themselves.
            let allEntries = byDay.values.flatMap { $0 }
            availableTypes = AuditFormatting.ActivityType.allCases.filter { type in
                allEntries.contains { $0.type == type }
            }
            // The type filter combines with the date filter (both
            // apply together); "All" (nil) shows everything.
            let shownByDay: [String: [AuditDisplayEntry]]
            if let type = selectedType {
                shownByDay = byDay.mapValues { $0.filter { $0.type == type } }
            } else {
                shownByDay = byDay
            }
            filter.auditShown = shownByDay.values.flatMap { $0 }.count
            filter.auditTotal = total
            groups = dayOrder.compactMap { day in
                let entries = AuditFormatting.groupDayActivity(shownByDay[day] ?? [])
                guard !entries.isEmpty else { return nil }
                return ActivityDayGroup(day: day, entries: entries)
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

    /// A type chip is single-select and applies on tap (no Apply
    /// step); it combines with the date filter, which stays as is.
    func selectType(_ type: AuditFormatting.ActivityType?) async {
        selectedType = type
        await load()
    }

    /// Reset Filters clears BOTH filters (owner, Nov 12 2026): the
    /// date range and the type chip.
    func resetAllFilters() async {
        draftFrom = ""
        draftTo = ""
        filter.clear()
        selectedType = nil
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
                Text("General Activity")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                // No subtitle (owner, Nov 12 2026): the title + the
                // list speak for themselves.

                typeFilterChips

                HistoryDateFilterCard(
                    draftFrom: $viewModel.draftFrom,
                    draftTo: $viewModel.draftTo,
                    filter: viewModel.filter,
                    onApply: { Task { await viewModel.applyFilter() } },
                    onClear: { Task { await viewModel.clearFilter() } },
                    onResetAll: { Task { await viewModel.resetAllFilters() } }
                )

                if viewModel.isLoading && viewModel.groups.isEmpty {
                    ProgressView()
                } else if let error = viewModel.loadError {
                    DismissableErrorBox(error) { viewModel.loadError = nil }
                } else if viewModel.groups.isEmpty {
                    MutedLine(text: viewModel.emptyText)
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

    /// Type filter (owner, Nov 12 2026): a horizontal chip row
    /// under the title — "All" first and selected by default, then
    /// one chip per type actually present in the log. Single-select
    /// only; combines with the date-range filter. Squarish chips,
    /// never round pills: selected is brand-blue fill with white
    /// text, unselected is a white chip with a light outline.
    private var typeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                typeChip(label: "All", selected: viewModel.selectedType == nil) {
                    Task { await viewModel.selectType(nil) }
                }
                ForEach(viewModel.availableTypes, id: \.self) { type in
                    typeChip(label: type.label, selected: viewModel.selectedType == type) {
                        Task { await viewModel.selectType(type) }
                    }
                }
            }
        }
    }

    private func typeChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? DesignTokens.primary : .white)
                .foregroundStyle(selected ? .white : DesignTokens.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? DesignTokens.primary : Color(hex: "#e5e7eb"), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) filter\(selected ? ", selected" : "")")
    }

    private func daySection(_ group: ActivityDayGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.day == "Unknown date" ? "Unknown date" : OnBudgetKit.MoneyFormat.fmtLong(group.day))
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
                    // Wrap, never truncate at the right edge: the
                    // row must read in full at narrow phone widths
                    // (owner, Nov 12 2026).
                    .fixedSize(horizontal: false, vertical: true)
                // The detail line renders only when it adds
                // something the title does not say — a detail that
                // restates the title is empty by now (see
                // AuditFormatting.simplifyDetail) and stays hidden.
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(entry.actor) · \(entry.time)")
                    .font(.subheadline)
                    .foregroundStyle(DesignTokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dotColor(for entry: AuditDisplayEntry) -> Color {
        switch AuditFormatting.dotClass(action: entry.action, detail: entry.detail) {
        case "charity": return Color(hex: "#16a34a")
        case "system": return DesignTokens.muted
        default: return DesignTokens.primary
        }
    }
}
