// STAGE — Activity (live web v66, §13).
//
// General Activity: who did what, and when — not the transaction
// list. Grouped by day (newest day first), each entry: a small
// per-type icon on the left, coloured by meaning (red removals,
// green positive money movements, blue neutral changes, grey
// quiet housekeeping — palette only, colour in the icon only),
// a short bold title, and ONE short structured fact line (only
// when it adds something the title does not say) — the fact
// first, never a sentence, merchants in ALL CAPS as stored,
// facts joined with " · ", renames and money moves with " → ".
// Then the muted "Actor · Mon D, h:mm AM" — or just the time
// when the row has no real actor (system rows never name a fake
// person). The title says the thing once; the detail never
// restates it (owner, Nov 26, 2026: fact-first redesign; the
// Nov 14, 2026 sentence format and muted dot are gone).
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
//   Since Nov 26, 2026 the detail is a fact-first line
//   (`AuditFormatting.simplifyDetail`): the fact, not a sentence.
// - Type-chip taps are local-only and instant (owner, Nov 26,
//   2026): `selectType` re-derives the shown groups from the
//   rows already in memory — no server re-fetch, so the chips
//   no longer lag ~1s. The full server `load()` is still used
//   for initial load, date-filter changes, Reset Filters,
//   Load More, and refresh.
// - Repeated weekly-processing rows collapse into one line with a
//   count ("N weeks closed"); user actions never collapse.
// - The date filter is the shared one-button + one-calendar range
//   picker (`HistoryDateFilterCard`, same calendar as
//   Transactions) — live-apply on this page (owner, Nov 14, 2026):
//   no Apply/Cancel, the range applies when picked; the type
//   filter is a chip row of the types actually present in the log
//   (single-select, combines with the date filter). Reset Filters
//   clears both.

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

    /// The rows `load()` last fetched, kept so a type-chip tap can
    /// re-derive the shown list locally with no network (owner,
    /// Nov 26 2026: the chips lagged ~1s because `selectType`
    /// re-fetched the whole log on every tap). `load()` stores the
    /// rows here, then calls `applyTypeFilter()`; chip taps call
    /// only `applyTypeFilter()`.
    private var loadedByDay: [String: [AuditDisplayEntry]] = [:]
    private var loadedDayOrder: [String] = []

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
                    // `formatDetail` (via `simplifyDetail` in
                    // OnBudgetKit) already renders the fact-first
                    // line — e.g. surplus paid toward debt reads
                    // "$179.99 → Carried Debt · Week of Nov 8,
                    // 2026" (owner, Nov 26, 2026).
                    detail: AuditFormatting.formatDetail(row.detail),
                    actor: AuditFormatting.formatActor(row.actorName),
                    time: OnBudgetKit.MoneyFormat.fmtDateTime(row.createdAt)
                )
                // A no-op allowance row (e.g. $400 → $400, stored
                // Nov 11, 2026) changed nothing — it never renders
                // as a row at all (owner, Nov 14, 2026).
                if AuditFormatting.isNoOpAllowanceChange(action: entry.action, detail: entry.detail) {
                    continue
                }
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
            // Keep the fetched rows so a type-chip tap can re-derive
            // the shown list locally with no network (see
            // `applyTypeFilter`).
            loadedByDay = byDay
            loadedDayOrder = dayOrder
            filter.auditTotal = total
            applyTypeFilter()
            loadError = nil
        } catch {
            loadError = "Could not load history. Try again."
            hasMore = false
        }
    }

    /// Re-derive the shown groups from the rows `load()` already
    /// fetched, applying only the type filter — LOCAL-ONLY, no
    /// network. This is what a type-chip tap runs, so the chip
    /// highlight and the filtered list update in the same frame as
    /// the tap (owner, Nov 26 2026: the chips lagged ~1s because
    /// `selectType` re-fetched the whole log on every tap; the
    /// re-fetch bought nothing — the type filter was already
    /// client-side inside `load()`). The full server `load()` is
    /// still used for initial load, date-filter changes, Reset
    /// Filters, Load More, and refresh — each of those stores fresh
    /// rows first, then calls this. The chips themselves are
    /// derived from the date-filtered rows BEFORE the type filter
    /// applies, so picking a chip never shrinks the chips; "All"
    /// (nil) shows everything; Load More fetches more rows and
    /// re-applies the type filter locally; `hasMore` is set by
    /// `load()` and is unchanged by a type tap.
    func applyTypeFilter() {
        // The type filter combines with the date filter (both
        // apply together); "All" (nil) shows everything.
        let shownByDay: [String: [AuditDisplayEntry]]
        if let type = selectedType {
            shownByDay = loadedByDay.mapValues { $0.filter { $0.type == type } }
        } else {
            shownByDay = loadedByDay
        }
        filter.auditShown = shownByDay.values.flatMap { $0 }.count
        groups = loadedDayOrder.compactMap { day in
            // Build 68 (item 16): collapse repeated IDENTICAL
            // system entries inside one day — the week is
            // recomputed/closed repeatedly and each pass re-logs
            // the same event, so "Surplus Paid Toward Debt —
            // Surplus $179.99 for week Nov 8, 2026…" appeared
            // SEVEN times on Nov 23. Display each event once.
            // Only actor-less (system) rows collapse: two
            // identical user actions are two real actions and
            // must both stay.
            let entries = dedupeIdenticalSystemEntries(AuditFormatting.groupDayActivity(shownByDay[day] ?? []))
            guard !entries.isEmpty else { return nil }
            return ActivityDayGroup(day: day, entries: entries)
        }
    }

    /// Build 68 (item 16): display-side dedupe of identical
    /// SYSTEM entries inside one day (same action + detail, no
    /// actor). Week processing re-logs the same event on every
    /// recompute/close, so the same surplus-paid entry can appear
    /// many times in one day — the list shows the event once, at
    /// its newest time. User actions (which carry an actor) never
    /// collapse: two identical-looking user actions are two real
    /// actions. This is display-only — the stored audit rows are
    /// untouched. The logging itself happens server-side in week
    /// processing (outside this build's files): the server should
    /// log each week event once instead of once per recompute.
    /// Flagged as a server follow-up in the build 68 report.
    private func dedupeIdenticalSystemEntries(_ entries: [AuditDisplayEntry]) -> [AuditDisplayEntry] {
        var seen: Set<String> = []
        var output: [AuditDisplayEntry] = []
        for entry in entries {
            if entry.actor.isEmpty {
                let key = "\(entry.action)\n\(entry.detail)"
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            output.append(entry)
        }
        return output
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
    /// LOCAL-ONLY: re-derives the shown list from the rows already
    /// in memory — no server fetch, so the tap is instant (owner,
    /// Nov 26 2026: the chips lagged ~1s on the old re-fetch).
    func selectType(_ type: AuditFormatting.ActivityType?) {
        selectedType = type
        applyTypeFilter()
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
                    onResetAll: { Task { await viewModel.resetAllFilters() } },
                    // Live-apply (owner, Nov 14, 2026): no
                    // Apply/Cancel on this page — the range applies
                    // the moment both dates are picked, Reset
                    // Filters clears it. The Transactions Filters
                    // sheet keeps Apply/Cancel.
                    liveApply: true
                )

                if viewModel.isLoading && viewModel.groups.isEmpty {
                    // Build 99 (loading audit): skeletons shaped
                    // like the day groups below (heading + rows),
                    // not the centred logo loader — the list swaps
                    // in place under the filter card, so nothing
                    // moves when the entries land.
                    activityLoadingSkeleton
                } else if let error = viewModel.loadError {
                    DismissableErrorBox(error) { viewModel.loadError = nil }
                } else if viewModel.groups.isEmpty {
                    MutedLine(text: viewModel.emptyText)
                } else {
                    ForEach(viewModel.groups) { group in
                        daySection(group)
                    }
                    if viewModel.hasMore {
                        Button("Load More Activity") {
                            Task { await viewModel.loadMore() }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            .padding()
        }
        .task { await viewModel.load() }
        // Build 111 (owner, Nov 27, 2026): explicit
        // swipe-right-to-pop fallback — the system pop gesture
        // did nothing on the Settings stack despite
        // `.enableSwipeBack()` from the shell, so this page does
        // not rely on it alone either. Fires only when the system
        // gesture is disabled; never double-pops.
        .popSwipeBack()
    }

    /// Build 99 (loading audit): skeleton of the activity list
    /// while the first load runs — day groups, each a heading
    /// line plus three rows shaped like the loaded rows (muted
    /// dot + bold title + detail + time), so the entries swap in
    /// place under the filter card. Enough groups to fill the
    /// visible page (owner, Nov 26, 2026 — skeletons must fill
    /// the whole visible page, not a fixed two); a day group is
    /// ~218pt tall in a 16pt-spaced stack (234pt pitch) and the
    /// list starts ~270pt down the page (back row + title +
    /// chip row + date filter card).
    private var activityLoadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(0..<SkeletonFill.rows(rowHeight: 234, above: 270), id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: 140, height: 20)
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(alignment: .top, spacing: 10) {
                            SkeletonBlock(width: 10, height: 10, cornerRadius: 5)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                SkeletonBlock(width: 220, height: 18)
                                SkeletonBlock(width: 160, height: 18)
                                SkeletonBlock(width: 100, height: 18)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Loading activity")
    }

    /// Type filter (owner, Nov 12 2026): a horizontal chip row
    /// under the title — "All" first and selected by default, then
    /// one chip per type actually present in the log. Single-select
    /// only; combines with the date-range filter. Squarish chips,
    /// never round pills: selected is brand-blue fill with white
    /// text, unselected is a white chip with a light outline.
    @ViewBuilder
    private var typeFilterChips: some View {
        // Build 99 (loading audit): while the first load is still
        // running the chip row is skeleton chips in the same slot
        // — the real chips derive from the loaded log, so "All"
        // alone showed first and the type chips then popped in,
        // pushing the date filter card down.
        if viewModel.isLoading && viewModel.groups.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    SkeletonBlock(width: 48, height: 34, cornerRadius: 8)
                    SkeletonBlock(width: 76, height: 34, cornerRadius: 8)
                    SkeletonBlock(width: 64, height: 34, cornerRadius: 8)
                }
            }
            .accessibilityLabel("Loading activity filters")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    typeChip(label: "All", selected: viewModel.selectedType == nil) {
                        viewModel.selectType(nil)
                    }
                    ForEach(viewModel.availableTypes, id: \.self) { type in
                        typeChip(label: type.label, selected: viewModel.selectedType == type) {
                            viewModel.selectType(type)
                        }
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
        // Build 112 (owner, Nov 27, 2026): entries are cards now
        // (see activityRow), so the gap between them is 12pt —
        // comfortable, not cramped — instead of the old 8pt that
        // let the flat rows run together.
        VStack(alignment: .leading, spacing: 12) {
            Text(group.day == "Unknown date" ? "Unknown date" : OnBudgetKit.MoneyFormat.fmtLong(group.day))
                .font(.headline)
            ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                activityRow(entry)
            }
        }
    }

    /// Per-type icon + colour for the redesigned rows (owner, Nov 26,
    /// 2026: coloured icons, palette only, colour by meaning).
    /// Red (`errorText` #dc2626) = removals / destructive things.
    /// Green (`charity` #16a34a) = positive money movements
    /// (surplus, giving, saving). Blue (`primary` #2f6bff) =
    /// neutral changes. Grey (`muted` #6b7280) = quiet housekeeping.
    /// The colour lives in the icon only. Keyed on the translated
    /// action; an unknown action falls back to its type bucket,
    /// then to a grey info icon. The four transaction colours are
    /// untouched — these are the same palette, used by meaning.
    private func activityIcon(for entry: AuditDisplayEntry) -> (name: String, color: Color) {
        switch entry.action {
        case "Base allowance changed": return ("dollarsign.circle", DesignTokens.primary)
        case "Carried debt cleared": return ("checkmark.circle", DesignTokens.charity)
        case "Charity cash gift recorded": return ("heart.fill", DesignTokens.charity)
        case "Charity default rate changed": return ("percent", DesignTokens.primary)
        case "Charity gift recorded": return ("heart.fill", DesignTokens.charity)
        case "Charity income auto-accrued", "Charity income corrected", "Charity income recorded":
            return ("heart", DesignTokens.charity)
        case "Charity income reversed": return ("arrow.uturn.backward.circle", DesignTokens.errorText)
        case "Debt payment from Extra Fund": return ("arrow.down.circle", DesignTokens.charity)
        case "Debt repayment rule changed": return ("slider.horizontal.3", DesignTokens.primary)
        case "Duplicate merged": return ("doc.on.doc", DesignTokens.primary)
        case "Duplicate transaction excluded": return ("xmark.circle", DesignTokens.errorText)
        case "Expense removed": return ("minus.circle", DesignTokens.errorText)
        case "Extra Fund request approved": return ("checkmark.circle", DesignTokens.charity)
        case "Extra Fund request created": return ("doc.text", DesignTokens.primary)
        case "Extra Fund request declined": return ("xmark.circle", DesignTokens.errorText)
        case "Extra Fund spending recorded": return ("banknote", DesignTokens.primary)
        case "Extra Fund top-up recorded", "Extra Fund top-up recorded as pending":
            return ("plus.circle", DesignTokens.charity)
        case "Fund hidden from Home": return ("eye.slash", DesignTokens.muted)
        case "Fund renamed": return ("pencil", DesignTokens.primary)
        case "Fund shown on Home": return ("eye", DesignTokens.primary)
        case "gmail_disconnected": return ("envelope", DesignTokens.muted)
        case "Household created": return ("house", DesignTokens.primary)
        case "Household joined": return ("person.badge.plus", DesignTokens.primary)
        case "Member promoted": return ("person.badge.plus", DesignTokens.primary)
        case "Member removed": return ("person.badge.minus", DesignTokens.errorText)
        case "Merchant renamed": return ("pencil", DesignTokens.primary)
        case "Refund re-linked": return ("link", DesignTokens.primary)
        case "Surplus paid toward debt": return ("arrow.down.circle", DesignTokens.charity)
        case "Surplus released": return ("arrow.up.circle", DesignTokens.charity)
        case "Transaction added by hand": return ("plus.circle", DesignTokens.primary)
        case "Transaction deleted": return ("trash.fill", DesignTokens.errorText)
        case "Transaction excluded": return ("xmark.circle", DesignTokens.errorText)
        case "Transaction marked as charity gift": return ("heart.fill", DesignTokens.charity)
        case "Transaction moved to trash": return ("trash", DesignTokens.errorText)
        case "Transaction reclassified": return ("arrow.left.arrow.right", DesignTokens.primary)
        case "Transaction restored", "Transaction restored (one-off repair)":
            return ("arrow.uturn.backward.circle", DesignTokens.charity)
        case "Transaction tagged as expense": return ("tag", DesignTokens.primary)
        case "Temporary increase added": return ("arrow.up.circle", DesignTokens.primary)
        case "Weekly allowance set": return ("dollarsign.circle", DesignTokens.primary)
        case "Weeks processed": return ("calendar", DesignTokens.primary)
        case "CSV import": return ("square.and.arrow.down", DesignTokens.primary)
        default:
            switch entry.type {
            case .weekCloses: return ("calendar", DesignTokens.primary)
            case .members: return ("person", DesignTokens.primary)
            case .allowance: return ("dollarsign.circle", DesignTokens.primary)
            case .charity: return ("heart", DesignTokens.charity)
            case .duplicates: return ("doc.on.doc", DesignTokens.primary)
            case .trash: return ("trash", DesignTokens.errorText)
            case .other: return ("info.circle", DesignTokens.muted)
            }
        }
    }

    /// Each entry is its own card (owner, Nov 27, 2026): the flat
    /// rows with only 8pt between them ran together, so the row
    /// now sits in a `SettingsCard` — the same white card as the
    /// "Filter by Date" card above (radius 20, hairline border,
    /// light shadow, 16pt padding). Content is unchanged: icon,
    /// title, detail lines, timestamp.
    private func activityRow(_ entry: AuditDisplayEntry) -> some View {
        SettingsCard {
            activityRowContent(entry)
        }
    }

    private func activityRowContent(_ entry: AuditDisplayEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // One small per-type icon, coloured by meaning (owner,
            // Nov 26, 2026): red removals, green positive money
            // movements, blue neutral changes, grey quiet
            // housekeeping. The colour lives in the icon only —
            // titles and fact lines stay ink/muted. This replaces
            // the Nov 14, 2026 muted dot (one dot for every row —
            // the dots meant nothing without a legend); the icons
            // ARE the legend now, one per type.
            let icon = activityIcon(for: entry)
            Image(systemName: icon.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(icon.color)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(AuditFormatting.activityTitle(action: entry.action, count: entry.count))
                    .font(.subheadline)
                    .fontWeight(.bold)
                    // Wrap, never truncate at the right edge: the
                    // row must read in full at narrow phone widths
                    // (owner, Nov 12 2026). The frame pins the
                    // text column to the available width — without
                    // it a long detail could run past the edge
                    // (owner, Nov 14, 2026: Member Removed).
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
                // No actor, no "Admin ·" prefix: system rows show
                // the time only (owner, Nov 14, 2026 — "Admin" is
                // a role, not a person).
                Text(entry.actor.isEmpty ? entry.time : "\(entry.actor) · \(entry.time)")
                    .font(.subheadline)
                    .foregroundStyle(DesignTokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
