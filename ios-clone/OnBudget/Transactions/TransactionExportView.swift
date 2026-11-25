import SwiftUI
import PDFKit
import OnBudgetKit

/// Transaction export (build 45, Nov 18, 2026): a full-screen popup
/// on the Transactions page. ONE filter set + format (PDF / CSV) →
/// Generate. A PDF opens an in-app preview first (build 59,
/// Nov 22, 2026 — the finished statement, rendered by PDFKit from
/// the very file that gets shared, so preview and file can never
/// differ); Share inside the preview opens the iOS share sheet, so
/// the user can save, AirDrop, email, or print it. A CSV has no
/// preview and goes straight to the share sheet. Nothing is
/// auto-emailed or auto-saved anywhere — the sheet is the choice.
/// Read-only: it never changes transactions.
///
/// Build 68 (item 21, Nov 23, 2026 — the "What to Export:
/// Filtered / All" switch is gone): the "Filter By" controls ARE
/// the export's filters — kind, date range, amount, and account,
/// picked right here before exporting, pre-filled with the
/// Transactions page's current filters on open (so if the page is
/// showing Spending, Nov 22–28, the export starts there). The
/// picks edit a draft of the shared `TransactionFilters` (one
/// filter system — the same `apply(to:)` the list uses, never a
/// second one); the count and the summary update live as the user
/// picks, and Generate commits the draft to the list's filter, so
/// the list and the export agree after every export (build 64,
/// F-7: a commit toasts "List now shows…"). "Clear Filters"
/// resets every Filter By control to "All" (all kinds, all dates,
/// all cards, no min/max) so a fresh filter can be built. Cancel
/// discards the draft and leaves the list untouched — the same
/// snapshot/draft/apply/cancel pattern as the list's Filters sheet.
///
/// The full history is fetched once, in the background, when the
/// popup opens — the list page only ever holds the rows loaded so
/// far (25 at a time), so exporting the loaded page alone would
/// silently miss the rows the user never tapped Load More for.
/// The draft filter applies to the fetched rows on every change;
/// no refetch is ever needed.
///
/// Design rules: Title Case headings and labels; two-button row
/// primary blue first + grey tertiary second; no greyed-out
/// buttons — Generate stays tappable and duplicate taps are
/// ignored (the `isSaving` guard pattern), except a min-above-max
/// amount range, which disables Generate the same way the list's
/// Filters sheet disables Apply (the error box above already says
/// why); loading is shimmer skeletons, no spinner, no "Loading..."
/// text; errors are the soft-red box with dark red text.
public struct TransactionExportView: View {
    @Bindable var viewModel: TransactionsViewModel
    /// The app state (build 64, F-7/F-34): confirmations from this
    /// popup go through `AppViewModel.showToast` (app-shell level),
    /// because the popup is a full-screen cover over
    /// TransactionsView — a toast fired from the view model would
    /// render underneath the cover, where nobody can see it.
    let appState: AppViewModel
    /// The household name the shell already loaded
    /// (`appState.householdName`); nil falls back to a fetch.
    let householdName: String?
    let onDismiss: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Build 68 (item 21): the "What to Export: Filtered / All"
    // switch is GONE — the "Filter By" controls below ARE the
    // export's filters, pre-filled from the Transactions page's
    // current filters on open (the draft starts as
    // `viewModel.filters`). "Clear Filters" resets them all to
    // "All", so a fresh filter can be built from scratch.
    @State private var format: TransactionExportFormat = .pdf
    /// Draft of the shared filter (build 61 — export filter
    /// picker): starts from the list's active filter, so an
    /// export of the list's filtered view needs no re-picking.
    /// The pickers edit this draft live; Generate commits it to
    /// `viewModel.filters`, Cancel discards it.
    @State private var draftFilters: TransactionFilters
    /// Amount text (the draft's bounds live as text until parsed
    /// — same as the list's Filters sheet: blank / unparseable =
    /// no limit; min > max is a validation state, not an empty
    /// result).
    @State private var minText: String
    @State private var maxText: String
    /// Which amount field holds the keyboard — the decimal pad
    /// has no return key, so the keyboard toolbar's Done button
    /// is the only way out (owner, Nov 13, 2026).
    @FocusState private var focusedField: AmountField?

    private enum AmountField: Hashable { case min, max }

    /// The whole household history, fetched once on open (nil
    /// until it arrives). Scope switching re-slices this, never
    /// refetches.
    @State private var allRows: [Transaction]? = nil
    @State private var fetchError: String? = nil
    @State private var isGenerating: Bool = false
    @State private var shareURL: URL? = nil
    /// The PDF to preview (build 59, Nov 22, 2026): the user
    /// sees the finished statement in-app and confirms before
    /// sharing — the preview IS the file, rendered by PDFKit,
    /// so it can never differ from what gets shared. CSV has no
    /// preview (a plain-text file) and goes straight to share.
    @State private var previewURL: URL? = nil
    @State private var resolvedHouseholdName: String? = nil
    /// Build 68 (item 14): the format explainer behind the ⓘ.
    @State private var showingFormatInfo = false

    public init(viewModel: TransactionsViewModel, appState: AppViewModel, householdName: String?, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.appState = appState
        self.householdName = householdName
        self.onDismiss = onDismiss
        _draftFilters = State(initialValue: viewModel.filters)
        _minText = State(initialValue: viewModel.filters.minCents.map { String(format: "%.2f", Double($0) / 100.0) } ?? "")
        _maxText = State(initialValue: viewModel.filters.maxCents.map { String(format: "%.2f", Double($0) / 100.0) } ?? "")
    }

    /// The kinds the picker offers (build 61): the eight concrete
    /// kinds, in the order the owner listed them — "All kinds" is
    /// the nil option, not a case. `.other` rows match only under
    /// "All kinds".
    private static let filterKinds: [TransactionKind] = [
        .charge, .income, .charity, .refund, .transfer, .payment, .cashback, .fundCharge,
    ]

    /// Card suffixes in the fetched full history (the account
    /// picker) — from the whole history, not the list's loaded
    /// page, so an account with only older rows still appears.
    private var cardsInHistory: [String] {
        guard let allRows else { return [] }
        return TransactionFilters.cards(in: allRows)
    }

    /// The kind picker's selection: picking a concrete kind runs
    /// `setKind`, which clears a kind-ish status so kind + status
    /// cannot AND to an empty set (see TransactionFilters.setKind).
    private var kindBinding: Binding<TransactionKind?> {
        Binding(get: { draftFilters.kind }, set: { draftFilters.setKind($0) })
    }

    /// The When picker's selection: the single "When" choice, read
    /// from and written to the draft's date fields.
    private var whenBinding: Binding<WhenSelection> {
        Binding(get: { draftFilters.whenSelection }, set: { draftFilters.setWhenSelection($0) })
    }

    /// Draft amount bounds are invalid when both ends parse and
    /// min > max — a validation state, not an empty result (same
    /// as the list's Filters sheet).
    private var draftAmountInvalid: Bool {
        guard let min = TransactionFormatting.parseDollarsStrict(minText),
              let max = TransactionFormatting.parseDollarsStrict(maxText) else { return false }
        return min > max
    }

    /// The rows the export covers: the DRAFT filter + sort,
    /// applied to the fetched history. The preview and the file
    /// are built from this same array, so the count, the preview,
    /// and the file can never disagree. Live — it updates as the
    /// user changes any Filter By control.
    private var rowsForScope: [Transaction] {
        guard let allRows else { return [] }
        return draftFilters.apply(to: allRows)
    }

    /// The filter summary under "Filter By": the DRAFT's active
    /// filters as "This Week · Spending", or the no-filters line.
    /// Live — it updates as the user picks.
    private var filterSummary: String {
        let chips = draftFilters.activeChips(customNames: viewModel.fundNames)
        if chips.isEmpty { return "No filters active — this exports every transaction." }
        return chips.map(\.label).joined(separator: " · ")
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Export Transactions", onClose: onDismiss)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Build 68 (item 21): ONE filter set — the
                        // Filter By controls below, seeded from the
                        // page's filters on open. No scope switch.
                        filterSection
                        formatSection
                        statusSection
                    }
                    .padding()
                }
                // Dragging the sheet dismisses the keyboard too —
                // the number pad has no return key, so Done + drag
                // are the two ways out (owner, Nov 13, 2026).
                .scrollDismissesKeyboard(.interactively)
                // Build 75 (F-10): the action bar is pinned below
                // the scrolling sections, so Generate + Clear
                // Filters are always reachable — they used to sit
                // inside the ScrollView at the bottom, past the
                // sections.
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    // Build 70, item 5 (owner, Nov 24, 2026):
                    // the Cancel button is gone — the SheetHeader
                    // X + swipe-right dismiss without exporting,
                    // so Cancel was a third redundant way out.
                    Button(format == .pdf ? "Preview PDF" : "Export as CSV") { generate() }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("export.generate")
                        // A min-above-max range disables
                        // Generate the same way the list's
                        // Filters sheet disables Apply —
                        // the error box above already says
                        // why. Build 74 (B7): dimmed to 0.6
                        // while disabled (the Funds pattern).
                        .disabled(draftAmountInvalid)
                        .opacity(draftAmountInvalid ? 0.6 : 1.0)
                    // Clear Filters is a real button (owner, Nov
                    // 14, 2026 — a plain grey link under the
                    // buttons did not read as tappable).
                    // Full-width outline, below the Generate /
                    // Cancel row — a third button in a different
                    // treatment, so no two adjacent buttons
                    // share a colour. Build 68 (item 21): it
                    // resets every Filter By control to "All"
                    // (all kinds, all dates, all cards, no
                    // min/max), so a fresh filter can be built.
                    Button("Clear Filters") { clearDraftFilters() }
                        .buttonStyle(OutlineButtonStyle())
                        .accessibilityIdentifier("export.filter.clear")
                    // Progress, inline: the Generate button is
                    // never greyed out — a duplicate tap while a
                    // file is being built is ignored instead.
                    if isGenerating {
                        Text("Preparing your file…")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "#6b7280"))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding()
            }
            .frame(width: horizontalSizeClass == .regular ? 600 : nil)
            .accessibilityIdentifier("export.popup")
            // Build 70, item 2 (owner, Nov 24, 2026): re-enable
            // the navigation pop gesture so swipe-right pops the
            // Choose Dates page back to Export. (The cover's
            // SheetHeader already supplies swipe-right-to-dismiss
            // for the cover itself.)
            .enableSwipeBack()
        }
        .task {
            resolvedHouseholdName = householdName
            if resolvedHouseholdName == nil {
                resolvedHouseholdName = await viewModel.fetchHouseholdName()
            }
            await fetchAllRows()
        }
        .toolbar {
            // Keyboard Done (owner, Nov 13, 2026): the decimal
            // pad has no return key and no other way to dismiss
            // it — this button resigns the amount field.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
            }
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let shareURL {
                FileShareSheet(url: shareURL)
            }
        }
        // PDF preview (build 59): the finished statement,
        // in-app, before anything is shared. The preview sheet
        // owns the share step — Share opens the share sheet
        // from inside the preview.
        .sheet(isPresented: Binding(
            get: { previewURL != nil },
            set: { if !$0 { previewURL = nil } }
        )) {
            if let previewURL {
                TransactionExportPreviewSheet(url: previewURL)
            }
        }
    }

    // MARK: - Sections

    /// The filter picker (build 61, Nov 22, 2026 — owner: "Once
    /// choosing filtered you should have to select how to
    /// filter"): kind, date range, amount, and account. Every
    /// pick is optional — an unset pick means "any" — and picks
    /// combine (AND), so kind + account + date + amount narrows
    /// to the intersection. The controls reuse the list's Filters
    /// sheet treatment (white field, 1pt #e5e7eb border,
    /// cornerRadius 12, 48pt, ink tint) and its patterns: the Kind
    /// and Card menu pickers, the one-button-one-calendar When
    /// control, and the Min/Max amount fields with a $ prefix and
    /// a decimal pad. The count and the summary above update live
    /// as the user picks — the draft applies to the fetched rows
    /// on every change.
    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Filter By")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            // Build 68 (item 21): the live summary of what the
            // export covers — it used to sit under the deleted
            // scope switch. Updates as the user picks.
            Text(filterSummary)
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "#6b7280"))
            // Kind — the picker value says it.
            Picker("Kind", selection: kindBinding) {
                Text("All kinds").tag(nil as TransactionKind?)
                ForEach(Self.filterKinds, id: \.self) { kind in
                    Text(TransactionExport.kindName(forKind: kind)).tag(kind as TransactionKind?)
                }
            }
            .pickerStyle(.menu)
            .tint(DesignTokens.ink)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 14)
            .background(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("export.filter.kind")

            // When — ONE button + ONE calendar (owner, Nov 11,
            // 2026). The button shows the range; the calendar
            // picks a start date, then an end date.
            NavigationLink {
                DateRangeCalendarView(selection: whenBinding)
            } label: {
                HStack {
                    Text(draftFilters.whenSelection.label)
                        .font(.system(size: 15))
                        .foregroundStyle(DesignTokens.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            // Identifier for a UI test to find the date-range
            // control (the NavigationLink to the calendar).
            .accessibilityIdentifier("export.filter.when")

            // Card / Account — the picker value says it. The
            // options come from the fetched full history, so an
            // account with only older rows still appears.
            Picker("Card", selection: $draftFilters.card) {
                Text("All cards").tag("all")
                ForEach(cardsInHistory, id: \.self) { card in
                    Text("••\(card)").tag(card)
                }
            }
            .pickerStyle(.menu)
            .tint(DesignTokens.ink)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 14)
            .background(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("export.filter.card")

            // Amount — Min / Max side by side, same as the list's
            // Filters sheet.
            amountBlock
        }
    }

    /// Amount — draft-held like the rest; the validation reads
    /// the draft text, not the live filter. Min / Max carry
    /// visible labels above the fields, and the fields share the
    /// sheet's white-bg + 1pt #e5e7eb border + cornerRadius 10
    /// treatment. The $ is a fixed prefix inside the field
    /// (owner, Nov 13, 2026) — display only, never part of the
    /// typed text, so parsing is unchanged. Bounds compare to the
    /// SIGNED amount, same as the list's filter; either end alone
    /// works; blank / unparseable = no limit.
    private var amountBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Min")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    HStack(spacing: 2) {
                        Text("$")
                            .font(.system(size: 17))
                            .foregroundStyle(DesignTokens.ink)
                        TextField("0.00", text: $minText)
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .min)
                            .accessibilityIdentifier("export.filter.min")
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: 140, minHeight: 48, alignment: .leading)
                    .background(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Max")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    HStack(spacing: 2) {
                        Text("$")
                            .font(.system(size: 17))
                            .foregroundStyle(DesignTokens.ink)
                        TextField("0.00", text: $maxText)
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .max)
                            .accessibilityIdentifier("export.filter.max")
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: 140, minHeight: 48, alignment: .leading)
                    .background(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            if draftAmountInvalid {
                SoftErrorBox("Minimum amount is above the maximum amount — change one of them to see transactions.")
            }
        }
        // The bounds live in the draft, so the count updates as
        // the user types — the parse runs on every keystroke.
        .onChange(of: minText) { _, new in
            draftFilters.minCents = TransactionFormatting.parseDollarsStrict(new)
        }
        .onChange(of: maxText) { _, new in
            draftFilters.maxCents = TransactionFormatting.parseDollarsStrict(new)
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Format")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            // Build 74 (B4): the Funds slider (SquarishPicker),
            // not a segmented pill — 48pt tall, like the
            // segmented control it replaces.
            SquarishPicker([(TransactionExportFormat.pdf, "PDF"), (TransactionExportFormat.csv, "CSV")], selection: $format, minHeight: 48)
                .accessibilityIdentifier("export.format")
            // Build 68 (item 14): the format sentence lives behind
            // a blue info icon now, not as inline text — the short
            // line beside it is all that stays visible.
            HStack(spacing: 6) {
                Button { showingFormatInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About This Format")
                Text(format == .pdf ? "Preview it before sharing." : "Opens in any spreadsheet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
            .alert("Format", isPresented: $showingFormatInfo) {
                Button("OK") {}
            } message: {
                Text(format == .pdf
                     ? "A branded statement with charts — preview it before sharing."
                     : "One row per transaction, opens in any spreadsheet.")
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let fetchError {
            SoftErrorBox(fetchError)
            Button("Try Again") {
                Task { await fetchAllRows() }
            }
            // Build 74 (B20): every other "Try Again" is the grey
            // tertiary — the blue outline here was the odd one out
            // (and a second blue next to the blue primary).
            .buttonStyle(TertiaryButtonStyle())
        } else if allRows == nil {
            // Shimmer skeletons shaped like the count line, no
            // spinner, no "Loading..." text (owner loading language).
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(width: 180, height: 14)
                SkeletonBlock(width: 260, height: 14)
            }
            .accessibilityLabel("Loading transactions")
        } else if rowsForScope.isEmpty {
            // Build 64 (F-21): "no match" is a normal state, not
            // an error — a quiet neutral line, never a red box
            // (soft-red is for real errors only). A min > max
            // range is a validation state, not an empty result —
            // the amount block above already says why, so this
            // section stays quiet instead of stacking a second,
            // misleading "no match" line.
            if !draftAmountInvalid {
                Text("No transactions match the current filters — change the filters or clear them.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#6b7280"))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("export.empty")
            }
        } else {
            // Build 64 (F-21): the count line carries the net
            // total, so the filtered set's worth reads at a
            // glance — "12 transactions · Net −$340.20".
            // `formatCents` (not `netTotalText`): the export net
            // is In − Out, so a negative net is money out and
            // reads with a minus, not the list count line's "+".
            let totals = TransactionExport.totals(transactions: rowsForScope)
            Text("\(rowsForScope.count) transactions · Net \(TransactionFormatting.formatCents(totals.netCents))")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "#6b7280"))
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("export.count")
        }
    }

    // MARK: - Fetch + generate

    /// The whole history, in the background: the fetch runs in a
    /// Task and the list never blanks — the popup shows skeletons
    /// until the rows arrive.
    private func fetchAllRows() async {
        fetchError = nil
        do {
            allRows = try await viewModel.fetchExportRows(scope: .all)
        } catch let error as OnBudgetError {
            fetchError = error.displayMessage
        } catch {
            fetchError = "Could not load transactions — check your connection and try again."
        }
    }

    /// Clear the export picks (build 61): kind, when, card,
    /// amount bounds, and status back to defaults. The list's
    /// search text rides along unchanged — the export sheet never
    /// edits search, and clearing it here would leave the list's
    /// search box showing text the filter no longer has. Sort is
    /// untouched (not an export pick). The count and the summary
    /// update live from the cleared draft.
    private func clearDraftFilters() {
        var cleared = TransactionFilters()
        cleared.search = draftFilters.search
        cleared.sort = draftFilters.sort
        draftFilters = cleared
        minText = ""
        maxText = ""
    }

    /// Generate the file. A PDF opens the in-app preview
    /// first — the user confirms the finished statement, then
    /// shares it from the preview. A CSV has no preview and
    /// goes straight to the share sheet. Duplicate taps while
    /// a file is being built are ignored (never a greyed-out
    /// button); a tap before the rows arrive, or with nothing
    /// matching, now says so (build 64, F-34) instead of
    /// dead-tapping — via the app-shell toast, which renders
    /// above this full-screen cover.
    ///
    /// Generate commits the draft to the shared filter (build 64,
    /// F-7, as revised by build 68 item 21): there is no scope
    /// switch any more — the Filter By controls ARE the export's
    /// filters, so the list and the export always agree after a
    /// generate. When the commit happens, the app-shell toast says
    /// what the list now shows ("List now shows…").
    /// `persistFilters()` only (NOT `filterChanged()`): an export
    /// must never yank the list out of week mode.
    private func generate() {
        guard !isGenerating else { return }
        // Build 64 (F-34): a tap with nothing to export is not
        // silence — it says why, via the app-shell toast.
        guard allRows != nil else {
            appState.showToast("Still loading transactions — try again in a moment.", kind: .info)
            return
        }
        guard !rowsForScope.isEmpty else {
            appState.showToast("Nothing matches those filters — change the filters or clear them.", kind: .info)
            return
        }
        // Build 68 (item 21): always commit the draft — the
        // export's filters are the list's filters now.
        viewModel.filters = draftFilters
        viewModel.persistFilters()
        let chips = draftFilters.activeChips(customNames: viewModel.fundNames)
        if chips.isEmpty {
            appState.showToast("List now shows all transactions.", kind: .info)
        } else {
            appState.showToast("List now shows \(chips.map(\.label).joined(separator: " · ")).", kind: .info)
        }
        let scopeRows = rowsForScope
        let fundNames = viewModel.fundNames
        let household = resolvedHouseholdName ?? "Household"
        let chosenFormat = format
        isGenerating = true
        Task.detached {
            let fileName = chosenFormat.fileName()
            let data: Data
            switch chosenFormat {
            case .csv:
                data = Data(TransactionExport.csvString(transactions: scopeRows, fundNames: fundNames).utf8)
            case .pdf:
                // Build 74: the filter rides into the statement
                // as its subtitle (the "when" chip is left out —
                // the date range already says it), so a filtered
                // export reads as what it is.
                let filterChips = draftFilters.activeChips(customNames: fundNames)
                    .filter { $0.key != "when" }
                    .map(\.label)
                let statement = TransactionExport.pdfStatement(
                    transactions: scopeRows,
                    householdName: household,
                    filterLine: filterChips.isEmpty ? nil : filterChips.joined(separator: " · ")
                )
                data = TransactionExportPDFRenderer.data(statement: statement)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try? data.write(to: url, options: .atomic)
            await MainActor.run {
                isGenerating = false
                if chosenFormat == .pdf {
                    previewURL = url
                } else {
                    shareURL = url
                }
            }
        }
    }
}

// MARK: - PDF preview (build 59, Nov 22, 2026)

/// The pre-export preview: the finished PDF, in-app, rendered
/// by PDFKit from the very file that gets shared — so the preview
/// and the shared file are the same document by construction.
/// Share opens the iOS share sheet from inside the preview;
/// Close dismisses without sharing anything.
public struct TransactionExportPreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL? = nil

    public init(url: URL) { self.url = url }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Preview", onClose: { dismiss() })
            PDFKitView(url: url)
                // Identifier for a UI test to find the rendered
                // preview and prove the finished PDF shows before
                // anything is shared.
                .accessibilityIdentifier("export.preview.pdf")
            // Build 70, item 5 (owner, Nov 24, 2026): the Close
            // button is gone — the SheetHeader X + swipe-right
            // dismiss, so Close was a third redundant way out.
            Button("Share") { shareURL = url }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("export.preview.share")
            .padding()
        }
        .accessibilityIdentifier("export.preview")
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let shareURL {
                FileShareSheet(url: shareURL)
            }
        }
    }
}

/// PDFKit's PDFView, wrapped for SwiftUI: a scrollable,
/// pinch-to-zoom rendering of the finished statement.
private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGray6
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

// MARK: - PDF renderer (UIGraphicsPDFRenderer)

/// Draws a `TransactionExportPDFStatement` as a branded STAGE
/// statement (build 59, Nov 22, 2026): the S + wordmark lockup in
/// exact brand blue #0288dd, a Summary section with donut charts
/// (Money In vs Out, Spending by Kind, Tzedaka Share) built from
/// the same transactions as the table — build 74: a chart appears
/// only with 2+ slices, and the whole Summary is omitted when
/// none qualify (a donations-only set gets no Summary at all) —
/// the table (date, merchant — ALL CAPS, build 65 — amount, kind)
/// with a banded header, alternating row shading, roomy 26pt rows
/// (build 74, was 20pt), and amounts and kinds in the transaction
/// colour code, footer totals under a stage-blue rule (a total
/// line appears only when its total is non-zero — build 74), and
/// a page number on every page. Letter pages. The content model
/// is kit-tested; this is only the drawing.
public enum TransactionExportPDFRenderer {
    private static let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let margin: CGFloat = 40
    private static var contentWidth: CGFloat { pageRect.width - margin * 2 }

    private static let stageBlue = UIColor(red: 0x02 / 255, green: 0x88 / 255, blue: 0xdd / 255, alpha: 1)
    private static let deep = UIColor(red: 0x1d / 255, green: 0x4e / 255, blue: 0xd8 / 255, alpha: 1)
    private static let ink = UIColor(red: 0x0f / 255, green: 0x17 / 255, blue: 0x2a / 255, alpha: 1)
    private static let muted = UIColor(red: 0x6b / 255, green: 0x72 / 255, blue: 0x80 / 255, alpha: 1)
    private static let divider = UIColor(red: 0xe5 / 255, green: 0xe7 / 255, blue: 0xeb / 255, alpha: 1)

    /// A UIColor from a "#rrggbb" hex string (the kit's colour
    /// code). Falls back to ink for malformed input.
    private static func color(hex: String) -> UIColor {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else { return ink }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    public static func data(statement: TransactionExportPDFStatement) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "STAGE Transactions"]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        return renderer.pdfData { context in
            var pageNumber = 1
            func drawPageFooter() {
                let text = "Page \(pageNumber)"
                let font = UIFont.systemFont(ofSize: 10)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: muted]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(
                    at: CGPoint(x: (pageRect.width - size.width) / 2, y: pageRect.height - 28),
                    withAttributes: attributes
                )
            }
            func beginNewPage() {
                drawPageFooter()
                pageNumber += 1
                context.beginPage()
            }

            var y = margin
            context.beginPage()
            // Branded header (build 68, item 19b): the proper S +
            // wordmark lockup — the real S logo asset (AppLogo, the
            // same circular mark as the loading page) beside
            // "T · A · G · E" in the exact brand blue #0288dd. The
            // old text-only "S · T · A · G · E" rendered teal-ish
            // and without the S mark.
            y = drawWordmark(at: y)
            y = draw("TRANSACTION STATEMENT", at: y + 8, font: .boldSystemFont(ofSize: 10), color: muted)
            y = draw(statement.householdName, at: y + 6, font: .boldSystemFont(ofSize: 18), color: ink)
            y = draw(statement.dateRange, at: y + 4, font: .systemFont(ofSize: 13), color: muted)
            // Build 74: the active filter, when the export is
            // filtered — so a Tzedaka-gifts export reads as what
            // it is, not as a generic statement. The date range
            // stays its own line.
            if let filterLine = statement.filterLine {
                y = draw(filterLine, at: y + 2, font: .systemFont(ofSize: 13, weight: .semibold), color: stageBlue)
            }
            y = draw(statement.generatedLine, at: y + 2, font: .systemFont(ofSize: 12), color: muted)
            y += 16
            drawThickDivider(at: y, color: stageBlue)
            y += 14
            // Summary charts (donuts) — the same transactions as
            // the table, so the visuals and the rows agree.
            if !statement.charts.isEmpty {
                let height = chartsSectionHeight(statement.charts)
                if y + height > pageRect.height - margin {
                    beginNewPage()
                    y = margin
                }
                y = drawCharts(statement.charts, at: y)
                y += 12
                drawDivider(at: y)
                y += 12
            }
            // Table.
            y = drawTableHeader(at: y)
            for (index, row) in statement.rows.enumerated() {
                if y + 26 > pageRect.height - margin - 80 {
                    beginNewPage()
                    y = margin
                    y = drawTableHeader(at: y)
                }
                y = drawTableRow(row, at: y, index: index)
            }
            // Footer totals: a new page when they would not fit.
            // Build 74: a total line appears only when it has
            // something to say — "Total In" is omitted when
            // nothing came in (a donations-only export showed a
            // "$0.00 Total In" line that made no sense), and
            // likewise Total Out when nothing went out. Net always
            // shows. The page-break reserve follows the lines
            // actually drawn.
            var totalLines: [(label: String, value: String, bold: Bool, valueColor: UIColor)] = []
            if statement.totals.totalInCents > 0 {
                totalLines.append((label: "Total In", value: statement.totalInText, bold: false, valueColor: deep))
            }
            if statement.totals.totalOutCents > 0 {
                totalLines.append((label: "Total Out", value: statement.totalOutText, bold: false, valueColor: ink))
            }
            totalLines.append((label: "Net", value: statement.netText, bold: true, valueColor: stageBlue))
            if y + 8 + 12 + CGFloat(totalLines.count * 20) > pageRect.height - margin {
                beginNewPage()
                y = margin
            }
            y += 8
            // Build 68 (item 19c): the totals close under a thick
            // stage-blue rule, like the header — the statement
            // opens and closes on the brand.
            drawThickDivider(at: y, color: stageBlue)
            y += 12
            for line in totalLines {
                y = drawTotal(label: line.label, value: line.value, at: y, bold: line.bold, valueColor: line.valueColor)
            }
            drawPageFooter()
            _ = y
        }
    }

    // MARK: - Charts

    /// The height of the whole Summary section, so the caller
    /// can page-break before it: Summary title + chart titles
    /// + donuts + the tallest legend (two lines per slice).
    private static func chartsSectionHeight(_ charts: [TransactionExportChart]) -> CGFloat {
        let maxSlices = charts.map(\.slices.count).max() ?? 0
        return 18 + 10 + 14 + 8 + 96 + 8 + CGFloat(maxSlices * 26)
    }

    /// The Summary section: one column per chart, each with a
    /// title, a donut, and a two-line-per-slice legend (dot +
    /// label, then amount and share). Returns the y below it.
    private static func drawCharts(_ charts: [TransactionExportChart], at y: CGFloat) -> CGFloat {
        var y = y
        y = draw("Summary", at: y, font: .boldSystemFont(ofSize: 14), color: ink)
        y += 10
        let columnWidth = contentWidth / CGFloat(charts.count)
        let maxSlices = charts.map(\.slices.count).max() ?? 0
        let donutRadius: CGFloat = 48
        let holeRadius: CGFloat = 24
        let sectionTop = y
        for (index, chart) in charts.enumerated() {
            let columnX = margin + CGFloat(index) * columnWidth
            let centerX = columnX + columnWidth / 2
            // Title, centered over the donut.
            _ = drawCentered(chart.title, at: centerX, y: sectionTop, font: .boldSystemFont(ofSize: 11), color: ink)
            // Donut, centered in the column. (Build 74: every
            // chart here has 2+ slices — a single-slice chart is
            // omitted in the kit model, so there is no
            // single-slice dot branch anymore.)
            let donutCenter = CGPoint(x: centerX, y: sectionTop + 14 + 8 + donutRadius)
            drawDonut(chart: chart, center: donutCenter, outerRadius: donutRadius, holeRadius: holeRadius)
            // Legend, left-aligned in the column.
            let legendX = columnX + 8
            let legendY = sectionTop + 14 + 8 + donutRadius * 2 + 8
            _ = drawLegend(slices: chart.slices, total: chart.totalCents, at: legendX, y: legendY, width: columnWidth - 16)
        }
        return sectionTop + 14 + 8 + donutRadius * 2 + 8 + CGFloat(maxSlices * 26)
    }

    /// One donut: a filled wedge per slice from the top, going
    /// clockwise, then a white hole punched in the middle.
    private static func drawDonut(chart: TransactionExportChart, center: CGPoint, outerRadius: CGFloat, holeRadius: CGFloat) {
        let total = chart.totalCents
        guard total > 0 else { return }
        var startAngle = -CGFloat.pi / 2
        for slice in chart.slices {
            let fraction = CGFloat(slice.cents) / CGFloat(total)
            let endAngle = startAngle + fraction * 2 * CGFloat.pi
            let path = UIBezierPath()
            path.move(to: center)
            path.addArc(withCenter: center, radius: outerRadius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
            path.close()
            color(hex: slice.colorHex).setFill()
            path.fill()
            startAngle = endAngle
        }
        let hole = UIBezierPath(ovalIn: CGRect(
            x: center.x - holeRadius, y: center.y - holeRadius,
            width: holeRadius * 2, height: holeRadius * 2
        ))
        UIColor.white.setFill()
        hole.fill()
    }

    /// The STAGE lockup for the PDF header: the real S logo
    /// asset (AppLogo) clipped to a circle, beside "T · A · G · E"
    /// in the exact brand blue #0288dd (DesignTokens.stageBlueHex).
    /// Build 74: the same one-line connected lockup as the app —
    /// the mark + letters tight together (4pt gap, was 8pt),
    /// medium weight (was bold), reading left to right as a
    /// single word. Falls back to the text-only wordmark when the
    /// asset is unavailable. Returns the y below the lockup.
    private static func drawWordmark(at y: CGFloat) -> CGFloat {
        let logoSize: CGFloat = 26
        let font = UIFont.systemFont(ofSize: 20, weight: .medium)
        let text = "T · A · G · E"
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: stageBlue]
        let textSize = (text as NSString).size(withAttributes: attributes)
        guard let logo = UIImage(named: "AppLogo") else {
            return draw("S · T · A · G · E", at: y, font: font, color: stageBlue)
        }
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        let logoRect = CGRect(x: margin, y: y, width: logoSize, height: logoSize)
        UIBezierPath(ovalIn: logoRect).addClip()
        logo.draw(in: logoRect)
        context?.restoreGState()
        let textY = y + (logoSize - textSize.height) / 2
        (text as NSString).draw(at: CGPoint(x: margin + logoSize + 4, y: textY), withAttributes: attributes)
        return y + logoSize
    }

    /// The legend under one donut: per slice, a colour dot +
    /// label, then the amount and share on the line below. The
    /// shares are whole percents that sum to 100 (the last slice
    /// takes the remainder, so rounding never leaves 99 or 101).
    /// Returns the y below the legend.
    private static func drawLegend(slices: [TransactionExportChartSlice], total: Int, at x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        var lineY = y
        let dotRadius: CGFloat = 4
        let labelFont = UIFont.boldSystemFont(ofSize: 10)
        let valueFont = UIFont.systemFont(ofSize: 10)
        var pctSoFar = 0
        for (index, slice) in slices.enumerated() {
            let dotCenter = CGPoint(x: x + dotRadius, y: lineY + 5)
            let dot = UIBezierPath(ovalIn: CGRect(
                x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            ))
            color(hex: slice.colorHex).setFill()
            dot.fill()
            let labelX = x + dotRadius * 2 + 4
            (slice.label as NSString).draw(
                in: CGRect(x: labelX, y: lineY, width: width - dotRadius * 2 - 4, height: 13),
                withAttributes: [.font: labelFont, .foregroundColor: ink, .paragraphStyle: truncatingParagraphStyle()]
            )
            let pct: Int
            if index == slices.count - 1 {
                pct = max(0, 100 - pctSoFar)
            } else {
                pct = Int((Double(slice.cents) / Double(total) * 100).rounded())
                pctSoFar += pct
            }
            let valueText = "\(slice.amountText) · \(pct)%"
            (valueText as NSString).draw(
                at: CGPoint(x: labelX, y: lineY + 13),
                withAttributes: [.font: valueFont, .foregroundColor: muted]
            )
            lineY += 26
        }
        return lineY
    }

    // MARK: - Text helpers

    @discardableResult
    private static func draw(_ text: String, at y: CGFloat, font: UIFont, color: UIColor) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attributes)
        return y + size.height
    }

    @discardableResult
    private static func drawCentered(_ text: String, at centerX: CGFloat, y: CGFloat, font: UIFont, color: UIColor) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: centerX - size.width / 2, y: y), withAttributes: attributes)
        return y + size.height
    }

    private static func drawDivider(at y: CGFloat) {
        divider.setFill()
        UIRectFill(CGRect(x: margin, y: y, width: contentWidth, height: 1))
    }

    private static func drawThickDivider(at y: CGFloat, color: UIColor) {
        color.setFill()
        UIRectFill(CGRect(x: margin, y: y, width: contentWidth, height: 2))
    }

    private static func drawTableHeader(at y: CGFloat) -> CGFloat {
        // Build 68 (item 19c): the header sits on a light band
        // with small-caps labels, so the table reads as a proper
        // statement table instead of loose rows.
        let band = UIColor(red: 0xf8 / 255, green: 0xfa / 255, blue: 0xfc / 255, alpha: 1)
        band.setFill()
        UIRectFill(CGRect(x: margin, y: y - 4, width: contentWidth, height: 24))
        let font = UIFont.boldSystemFont(ofSize: 10)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: muted]
        ("DATE" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attributes)
        ("MERCHANT" as NSString).draw(at: CGPoint(x: margin + 100, y: y), withAttributes: attributes)
        drawRightAligned("AMOUNT", at: CGPoint(x: margin + 348, y: y), width: 92, font: font, color: muted)
        ("KIND" as NSString).draw(at: CGPoint(x: margin + 448, y: y), withAttributes: attributes)
        let nextY = y + 16
        drawDivider(at: nextY + 4)
        return nextY + 12
    }

    private static func drawTableRow(_ row: TransactionExportPDFRow, at y: CGFloat, index: Int = 0) -> CGFloat {
        // Build 68 (item 19c): alternating row shading — even rows
        // on a whisper-light fill — so long tables stay scannable.
        // Build 74: rows are 26pt tall (was 20pt) — the table was
        // cramped/claustrophobic, and the breathing room is the
        // fix. The shading does the separation; no per-row
        // hairline on top of it.
        if index % 2 == 0 {
            let shade = UIColor(red: 0xf9 / 255, green: 0xfa / 255, blue: 0xfb / 255, alpha: 1)
            shade.setFill()
            UIRectFill(CGRect(x: margin, y: y - 2, width: contentWidth, height: 26))
        }
        let font = UIFont.systemFont(ofSize: 12)
        let rowColor = color(hex: row.colorHex)
        let merchantAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink,
            .paragraphStyle: truncatingParagraphStyle(),
        ]
        (row.date as NSString).draw(
            at: CGPoint(x: margin, y: y),
            withAttributes: [.font: font, .foregroundColor: ink]
        )
        // Merchant names ALL CAPS (build 65, owner Nov 23, 2026):
        // display-only, via the one shared `displayMerchant`
        // helper — the statement row itself is built in kit
        // (`TransactionExport.merchantDisplay`, still Title-Case),
        // so the caps are applied here, at the draw site. The CSV
        // file is built whole in kit (`csvString`) and is NOT
        // covered by this file — the kit's `merchantDisplay`
        // needs the same one-line change for CSV names to match.
        (TransactionFormatting.displayMerchant(row.merchant) as NSString).draw(
            in: CGRect(x: margin + 100, y: y, width: 240, height: 16),
            withAttributes: merchantAttributes
        )
        drawRightAligned(row.amount, at: CGPoint(x: margin + 348, y: y), width: 92, font: font, color: rowColor)
        (row.kind as NSString).draw(
            at: CGPoint(x: margin + 448, y: y),
            withAttributes: [.font: font, .foregroundColor: rowColor]
        )
        return y + 26
    }

    @discardableResult
    private static func drawTotal(label: String, value: String, at y: CGFloat, bold: Bool, valueColor: UIColor) -> CGFloat {
        let font = bold ? UIFont.boldSystemFont(ofSize: 13) : UIFont.systemFont(ofSize: 13)
        (label as NSString).draw(
            at: CGPoint(x: margin, y: y),
            withAttributes: [.font: font, .foregroundColor: ink]
        )
        drawRightAligned(value, at: CGPoint(x: margin + 340, y: y), width: 192, font: font, color: valueColor)
        return y + 20
    }

    private static func drawRightAligned(_ text: String, at origin: CGPoint, width: CGFloat, font: UIFont, color: UIColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        (text as NSString).draw(
            in: CGRect(x: origin.x, y: origin.y, width: width, height: 16),
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
    }

    private static func truncatingParagraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return paragraph
    }
}
