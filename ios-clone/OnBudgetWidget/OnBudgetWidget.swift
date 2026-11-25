// STAGEWidget — OnBudgetWidget.swift
//
// Home-screen widget (native build 17, owner-approved Nov 12, 2026;
// redesigned build 26, owner Nov 14, 2026): the weekly spending
// balance and the charity balance — the same two numbers the Home
// screen shows, nothing else. Small, medium, large and extra-large
// (extra-large is iPad-only).
//
// Redesign (owner, Nov 14, 2026 — the medium widget was "super
// ugly.. basic.. like a kindergartener made it"): no more plain
// blue "STAGE" text header and flat white — a quiet ink wordmark,
// muted small labels, big figures with tabular numerals, generous
// spacing, a subtle tinted background, and a hairline divider
// between the two numbers. The data is unchanged: the same two
// numbers (weekly balance, charity remaining) from the same
// WidgetSnapshot, the same freshness rule and "As of …" footer,
// the same privacySensitive figures. Large and extra-large add the
// week range and a donut — spent vs left of the weekly allowance
// (owner, Nov 15, 2026; the spent line the donut replaces is gone).
//
// Major upgrade (owner, Nov 15, 2026 — build 35, mockup-approved):
// the widget "looks dead and bland and not formatted properly" —
// bigger logo and wordmark, the week range shortened to "Nov 14–20"
// in brand blue (never truncated), a donut on medium too, a thin
// progress bar under each figure (budget: spent/allowance in brand
// blue; charity: given/committed in charity green), and a bigger
// freshness footer with a green/amber dot. Build 42 (owner, Nov 17,
// 2026): the "Spent $X" and "of $X allowance" lines are gone — the
// two halves mirror each other (label above, big amount, progress
// bar below), the left label is just "available", and the footer
// moved to the bottom-right as "As of 6:15PM".
// The mockup's extra solid blue circle beside the logo is a drawing
// artifact — the real header is just the one S mark — and its donut
// arc is drawn far too big for 8%: the real arc is the small sliver
// the snapshot's spent fraction gives.
//
// Data path: the app writes a WidgetSnapshot into the shared App
// Groups container at the end of every Home refresh; the widget only
// ever READS that snapshot. It never signs in, never calls Supabase,
// never holds a session. When there is no snapshot (never opened the
// app, or signed out) it says so plainly. When the snapshot is stale
// (over 1 hour old) it still shows the numbers, and the footer says
// so in plain words — "Updated 2h ago — tap to refresh" (build 64,
// F-38; the old developer word "Stale" is gone) — so a stale number
// is never presented as if it were live.
//
// Colours mirror Home: the weekly figure is brand blue, red when
// over budget (negative); the charity figure is ink (owner, Nov 15,
// 2026 — the green charity figure and the ink weekly figure were
// swapped: the main budget amount is blue, charity is black).
// All figures are whole dollars, no cents (owner, Nov 15, 2026).
// Figures are privacySensitive so they hide on the lock screen
// like other financial widgets. Tapping the widget's CONTENT
// opens Home (onbudget://home); tapping the refresh button runs
// the sync intent in place (build 54 — the button sits outside
// the content's widgetURL, so its tap reaches the intent).
//
// Label note (owner, Nov 14, 2026): his screenshot reads "Left left
// this week", but the label in every version of this file in the
// repo — including the build-17 original — was exactly "Left this
// week" (single). The doubling does not come from shipped code.
// Build 42 (owner, Nov 17, 2026): the label is now just
// "available" in all sizes.

import SwiftUI
import WidgetKit
import AppIntents
import OnBudgetKit

struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    /// True when `snapshot` is a REAL last-known snapshot, not the
    /// hardcoded sample. Build 48 (owner, Nov 19, 2026 — the
    /// medium iPad widget shows only placeholders): WidgetKit shows
    /// the placeholder entry with `.placeholder` redaction, and the
    /// view rendered skeleton bars for it even though the data was
    /// real. A real-data placeholder renders its real numbers
    /// (it opts out of the placeholder redaction); only the sample
    /// — the widget never loaded a snapshot — still skeletons.
    let isRealData: Bool

    init(date: Date, snapshot: WidgetSnapshot?, isRealData: Bool = false) {
        self.date = date
        self.snapshot = snapshot
        self.isRealData = isRealData
    }
}

/// Refresh the widget in place (build 36, owner Nov 16, 2026): the
/// owner asked for a sync button ON the widget. Tapping it runs this
/// intent in the widget extension — it does NOT open the app
/// (`openAppWhenRun` is false): `reloadAllTimelines()` makes
/// WidgetKit call `getTimeline`, which re-reads the latest snapshot
/// the app saved into the App Group and rebuilds the timeline, so
/// the numbers refresh in place. It does NOT fetch fresh numbers
/// from the server — the widget never signs in and never calls
/// Supabase, so only the app can write a new snapshot (on launch,
/// on every foreground, and on every Home refresh). If the app has
/// not saved new numbers yet, the button re-shows the last saved
/// ones; opening the app is still what gets new numbers.
/// Sync button (build 36, owner Nov 16, 2026 — made REAL in build
/// 40): a small refresh icon, top-right in the header row of every
/// size. Tapping it fetches FRESH dashboard numbers from Supabase —
/// the same week-left / charity figures the app shows — writes a NEW
/// snapshot, and reloads the timeline, so the new numbers appear
/// without opening the app. (Build 36 only reloaded the timeline
/// from the LAST SAVED snapshot, which is only written when the app
/// is opened — so if the app had not been opened, tapping sync
/// re-displayed the same stale numbers and looked dead. Owner, Nov
/// 16, 2026: "Sync button on widget doesn't look like it does
/// anything..")
///
/// HOW IT FETCHES (build 40, moved to the kit in build 43): the
/// app keeps its session in the shared Keychain item
/// (KeychainSessionStore, access group group.com.onbudget.ios —
/// build 64, F-17: the plaintext UserDefaults mirror is gone), and
/// writes the household id alongside the snapshot. The shared kit
/// refresher (WidgetSnapshotRefresher.refreshSnapshot) builds a
/// SupabaseClient on the shared Keychain item, calls
/// compute-week + the charity summary (active income, verified
/// gifts, cash gifts), and writes a new snapshot. The fund names
/// ride along from the existing snapshot (a rename does not change
/// the numbers, and the names are already pushed there on rename).
/// When there is no session / no household id / the fetch fails
/// (signed out, token expired, offline), the intent falls back to
/// reloading the last saved snapshot — the widget keeps showing its
/// last-known numbers with the stale dot, never a blank. The
/// visible result is the NEW numbers appearing — plus the button's
/// own state (build 42): a spinner while the fetch runs, a green
/// checkmark for ~15 seconds when fresh numbers land, a red refresh
/// icon when the fetch fails — and the red icon STAYS until the
/// next sync succeeds (build 51, owner Nov 20, 2026: the old
/// 15-second expiry made a failed tap look like nothing happened).
/// WidgetKit renders
/// widget views statically, so there is no press animation to add:
/// the intent writes the state into the App Group and reloads the
/// timeline, and the button re-renders in its new state. A very fast
/// sync may skip the spinner frame (WidgetKit coalesces reloads) —
/// then the checkmark is the feedback.
struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Widget"
    static var description = IntentDescription("Refresh the widget with fresh balances from the server.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // Build 42: write the in-flight state FIRST and reload, so
        // the button flips to its spinner while the fetch runs;
        // then write the landed state (success / failure) and
        // reload again, so it flips to a checkmark (or a red
        // refresh icon). The fetch itself is the shared kit path
        // (WidgetSnapshotRefresher, build 43): fresh numbers on
        // success, last snapshot on failure. The button state is
        // written ONLY here — the background refresh task uses the
        // same fetch but never touches the button state.
        WidgetSyncStateStore.write(.syncing)
        WidgetCenter.shared.reloadAllTimelines()
        let ok = await WidgetSnapshotRefresher.refreshSnapshot()
        WidgetSyncStateStore.write(ok ? .succeeded : .failed)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        // Build 36: the placeholder carries the last-known snapshot
        // when one exists, so even the placeholder entry shows real
        // numbers rather than sample data. Only when the widget has
        // NEVER loaded a snapshot (never opened the app, signed out)
        // does it fall back to the hardcoded sample — and the view
        // renders that entry as skeleton bars either way, because
        // the placeholder redaction applies to the entry, not the
        // data. The sample is pinned by
        // WidgetSnapshotTests.testPlaceholderSnapshotSpentFractionIsSeventyPercent.
        // Build 48: the entry says whether its snapshot is REAL —
        // the view renders real numbers for a real-data placeholder
        // (opting out of the redaction) and skeletons only for the
        // sample. Without the flag, the medium iPad widget showed
        // grey bars and an empty ring even though real numbers were
        // in hand (owner, Nov 19, 2026).
        let stored = WidgetSnapshotStore.read()
        return WidgetEntry(date: Date(), snapshot: stored ?? WidgetSnapshot(
            weekStart: "2026-11-08",
            availableCents: 17307,
            charityRemainingCents: 4200,
            spentCents: 40349,
            computedAt: Date()
        ), isRealData: stored != nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        let snapshot = WidgetSnapshotStore.read()
        completion(WidgetEntry(date: Date(), snapshot: snapshot, isRealData: snapshot != nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        // Build 36: 24 HOURLY entries spanning the next day, each
        // carrying the snapshot read once here, policy .after the
        // LAST entry's date — so there is always a valid entry and
        // WidgetKit never falls back to the placeholder once a
        // snapshot exists. A stale snapshot keeps showing its
        // last-known numbers with the amber dot + "As of …" footer;
        // the grey skeleton bars appear ONLY when the widget
        // has never loaded a snapshot.
        //
        // The build-35 single entry with a 15-minute backstop was
        // the bug, not the fix: the timeline expired 4×/hour, and
        // every expiry left a window with no valid entry while
        // WidgetKit fetched the next one — on an idle / throttled
        // device (overnight, low power) that window stretched
        // indefinitely and the widget got stuck on grey bars
        // (owner, Nov 16, 2026: small + one medium stuck on
        // placeholder while another medium showed real numbers).
        // Shortening the backstop again would only expire the
        // timeline MORE often — the wrong direction.
        //
        // The entry dates MUST advance hourly: the view computes
        // staleness from entry.date, so a single far-future entry
        // or a .never policy would never go stale. Freshness still
        // comes from the app — it calls reloadAllTimelines() on
        // launch, on every foreground, and on every Home refresh —
        // which re-reads the snapshot and rebuilds this timeline.
        // The entry-date math lives in OnBudgetKit.WidgetTimeline
        // (pure, unit-tested); this Provider just maps it.
        let now = Date()
        var entries = WidgetTimeline.entries(from: now, snapshot: WidgetSnapshotStore.read())
            .map { WidgetEntry(date: $0.date, snapshot: $0.snapshot, isRealData: $0.snapshot != nil) }
        // Build 42: while a transient sync state is live (syncing,
        // or a recent success mark), add one short entry 20 seconds
        // out, so WidgetKit re-renders then and the success mark
        // clears promptly instead of lingering on the rendered entry
        // until the next hourly one. The view itself also expires
        // the mark by time, so this entry is only the prompt
        // re-render. Build 54: a FAILED mark gets the same short
        // entry — the red mark must actually appear, so a failed
        // tap re-renders promptly like a success (the mark itself
        // still PERSISTS until the next sync; the entry only forces
        // the render). The decision lives in OnBudgetKit
        // (WidgetSyncStateStore.needsShortTimelineEntry) so the
        // package tests pin it.
        let (syncState, syncDate) = WidgetSyncStateStore.read()
        if WidgetSyncStateStore.needsShortTimelineEntry(state: syncState, at: syncDate, now: now) {
            entries.append(WidgetEntry(date: now.addingTimeInterval(WidgetSyncStateStore.clearAfter), snapshot: WidgetSnapshotStore.read()))
            entries.sort { $0.date < $1.date }
        }
        completion(Timeline(
            entries: entries,
            policy: .after(WidgetTimeline.reloadAfterDate(from: now))
        ))
    }
}

/// "Nov 14–20" from a "2026-11-14" week-start string (weeks run
/// 7 days); nil when unparseable. The compact form, no spaces around
/// the dash (owner, Nov 15, 2026 — build 35: the old "Week of Nov 7"
/// and "Nov 7 – Nov 13" forms were too long and the medium dates
/// clipped at the right edge). Every size that shows dates uses
/// this one form, in brand blue, on one line.
private func shortWeekRange(_ weekStart: String) -> String? {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.timeZone = TimeZone(secondsFromGMT: 0)
    guard let start = parser.date(from: weekStart) else { return nil }
    guard let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: 6, to: start) else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return "\(formatter.string(from: start))–\(formatter.string(from: end))"
}

/// "As of 6:15PM" from a computed-at date (build 42, owner Nov 17,
/// 2026): the footer moved to the bottom-right, dropped the
/// stale wording, and formats with no space before AM/PM.
private func asOfString(_ computedAt: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mma"
    return "As of \(formatter.string(from: computedAt))"
}

struct WidgetView: View {
    @Environment(\.widgetFamily) private var family
    /// True while WidgetKit renders the placeholder entry (the
    /// loading state): the redaction environment carries
    /// `.placeholder` for it, and never for a live timeline entry.
    @Environment(\.redactionReasons) private var redactionReasons
    let entry: WidgetEntry

    /// The loading state renders explicit skeleton bars sized to
    /// the loaded content (owner, Nov 15, 2026 — WidgetKit's own
    /// redacted text bars came out too small on the XL widget).
    /// Build 48 (owner, Nov 19, 2026): a placeholder entry that
    /// carries REAL data (the last-known snapshot) is NOT a loading
    /// state — it renders its real numbers. Only the sample
    /// placeholder (the widget never loaded a snapshot) skeletons.
    /// Without this, the medium iPad widget showed grey bars and
    /// an empty ring even though real numbers were in hand.
    private var isPlaceholder: Bool {
        redactionReasons.contains(.placeholder) && !entry.isRealData
    }

    /// A loading bar shaped exactly like the text it stands for:
    /// same height as the loaded figure/label, same skeleton grey
    /// as the app's SkeletonBlock (#ececf1). Shown only while the
    /// view renders as a placeholder; the loaded entry always shows
    /// real text. Build 78: the width is optional — omitted, the
    /// bar fills its column (the progress-bar placeholder, which
    /// must match the loaded bar that fills the same column).
    private func skeletonBar(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(DesignTokens.skeleton)
            .frame(width: width, height: height)
    }

    /// The app background (build 69, owner Nov 24, 2026 — the
    /// widget restyle): plain white, matching the app's current
    /// post-maturity-pass look. The pale blue tint #f2f7ff (owner,
    /// Nov 15, 2026) is gone — the widget reads as the app now.
    private var background: Color { DesignTokens.background }

    /// The Home deep link (build 54): applied to the widget's
    /// CONTENT only — wordmark, dates, figures, footer — never to
    /// the refresh button. Tapping the content opens HOME
    /// (onbudget://home → goHome()); tapping the button runs the
    /// sync intent in place. See the configuration comment above.
    private var homeURL: URL? { URL(string: "onbudget://home") }

    /// The Transactions deep link (background task, owner
    /// Nov 25, 2026): the Spending side opens the Transactions
    /// page. Applied to the Spending figure — and its donut —
    /// in every size. The innermost widgetURL wins, so it
    /// overrides the body container's home link for that column
    /// (the header, footer and gaps still open Home).
    private var transactionsURL: URL? { WidgetTransactionsDeepLink.url }

    /// The Funds deep link (background task, owner Nov 25,
    /// 2026): the Tzedaka side opens the Tzedaka fund. Applied
    /// to the Tzedaka figure in every size. The innermost
    /// widgetURL wins, so it overrides the body container's
    /// home link for that column.
    private var tzedakaURL: URL? { WidgetFundsDeepLink.url }

    var body: some View {
        // Build 48: a placeholder entry carrying REAL data opts out
        // of the system's automatic placeholder redaction, so its
        // real numbers render instead of redacted bars. (The
        // `isPlaceholder` flag above already swaps the custom
        // skeleton bars for real text; without this opt-out the
        // system's redaction would still blank the real text.)
        // The sample placeholder (no snapshot ever loaded) keeps
        // the redaction and the skeletons.
        if entry.isRealData {
            content.unredacted()
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot {
            let stale = snapshot.isStale(at: entry.date)
            switch family {
            case .systemExtraLarge:
                extraLarge(snapshot: snapshot, stale: stale, now: entry.date)
            case .systemLarge:
                large(snapshot: snapshot, stale: stale, now: entry.date)
            case .systemMedium:
                medium(snapshot: snapshot, stale: stale, now: entry.date)
            default:
                small(snapshot: snapshot, stale: stale, now: entry.date)
            }
        } else {
            empty
        }
    }

    /// Quiet brandmark: the real logo mark beside the ink wordmark
    /// (owner, Nov 15, 2026 — the header showed only the plain
    /// "STAGE" wordmark). AppLogo comes from the shared asset
    /// catalog, which the widget target includes. Build 35: bigger
    /// than the old 20pt logo / subheadline wordmark — 24pt logo and
    /// a headline wordmark by default; the small size takes the
    /// compact 22pt form so the stacked layout still fits.
    /// Build 54 (owner, Nov 21, 2026): the TAGE letters are bolder
    /// (black weight) and slightly larger — they were a drop too
    /// thin and small next to the S logo. Default 19pt (was
    /// headline 17pt semibold); the small layout passes 17pt
    /// (was subheadline 15pt semibold). Build 75 (owner, Nov 25,
    /// 2026 — audit): the wordmark is MEDIUM weight, matching
    /// the app's current wordmark (40pt medium, build 74 logo
    /// FINAL). The build-69 light weight (and the small layout's
    /// black weight) no longer match the app.
    private func wordmark(logoSize: CGFloat = 24, font: Font = .system(size: 19, weight: .medium)) -> some View {
        HStack(spacing: 6) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: logoSize, height: logoSize)
                .clipShape(Circle())
            if isPlaceholder {
                skeletonBar(width: 88, height: 16)
            } else {
                // The S logo IS the S of STAGE (owner, Nov 18,
                // 2026 — build 47): the logo + "T · A · G · E",
                // never the logo next to the full word "STAGE".
                StageWordmarkText(font: font)
            }
        }
    }

    /// Sync button (build 36, owner Nov 16, 2026; feedback build
    /// 42, owner Nov 17, 2026): a small refresh icon, top-right in
    /// the header row of every size. Tapping it runs
    /// RefreshWidgetIntent in place — it fetches FRESH numbers from
    /// the server (build 40) and reloads the timeline; it does not
    /// open the app. The button shows its state (build 42): a
    /// circular spinner while the fetch runs, a green checkmark for
    /// ~15 seconds when fresh numbers land, a red refresh icon when
    /// the fetch fails — and the red icon STAYS until the next sync
    /// succeeds (build 51, owner Nov 20, 2026). It is one Button in
    /// every state, so it stays tappable throughout (tapping the
    /// checkmark just syncs again). WidgetKit renders widget views
    /// statically — there is no custom press animation to add, and
    /// no @State that survives a tap; the system's tap highlight
    /// plus the state flip (spinner / checkmark) is the press
    /// response. The state is read live from the App Group
    /// (WidgetSyncStateStore, written by the intent), not from the
    /// timeline entry, so a reload re-renders it immediately.
    ///
    /// The success mark expires by time (15 seconds from when the
    /// intent wrote it) and the Provider adds a short timeline
    /// entry so the mark clears promptly. The failure mark has no
    /// expiry (build 51) — it shows until the next sync writes a
    /// new state, or the app writes a fresh snapshot. The spinner
    /// has no expiry — it shows until the intent writes its landed
    /// state and reloads; if the extension is killed mid-fetch the
    /// next reload (app refresh, hourly entry) re-reads the state
    /// as written and the button returns to the refresh icon.
    private var syncState: (state: WidgetSyncState, date: Date?) {
        WidgetSyncStateStore.read()
    }

    /// True while the mark for `state` should still show on the
    /// button. Success is transient (~15 seconds); failure PERSISTS
    /// until the next sync writes a new state (build 51, owner Nov
    /// 20, 2026) — the old 15-second expiry made a failed tap look
    /// like nothing happened. The stored state must match `state`:
    /// a stale date from a different state must not light the mark.
    private func isMarkVisible(_ state: WidgetSyncState) -> Bool {
        guard syncState.state == state else { return false }
        return WidgetSyncStateStore.isMarkVisible(state: state, at: syncState.date)
    }

    /// The refresh button's pressed feedback (build 69, owner
    /// Nov 24, 2026 — no immediate press feedback): the button
    /// used `.buttonStyle(.plain)`, which suppresses the system's
    /// press highlight — so a tap showed no sign it was touched
    /// until seconds later, when the intent's state flipped to
    /// the checkmark. This style draws a pale-blue disc behind
    /// the icon while pressed, so the press reads at once. Build
    /// 77 (owner, Nov 25, 2026 — the XL widget): the disc is the
    /// deeper pale blue #bfdbfe (DesignTokens.paleHex), not the
    /// very pale #dbeafe — the press highlight must be obvious.
    /// The spinner / checkmark / failure states are unchanged
    /// (build 42/51/58: spinner while syncing, green checkmark
    /// ~15s on success, red icon persists on failure; 44pt
    /// target, F-37).
    private struct WidgetRefreshButtonStyle: ButtonStyle {
        // NOTE: `ButtonStyle.Configuration` is qualified, not bare
        // `Configuration` — the bare name resolves to the widget's
        // own Configuration type here, so the style would not
        // conform (same trap as build 68's ExpenseDangerButtonStyle).
        func makeBody(configuration: ButtonStyle.Configuration) -> some View {
            configuration.label
                .background(
                    Circle()
                        .fill(Color(hex: "#bfdbfe"))
                        .opacity(configuration.isPressed ? 1 : 0)
                )
        }
    }

    private var refreshButton: some View {
        Button(intent: RefreshWidgetIntent()) {
            Group {
                if syncState.state == .syncing {
                    // Build 77 (owner, Nov 25, 2026 — the XL
                    // widget): the syncing spinner is BIGGER
                    // (22pt, on a solid 28pt pale-blue disc) so
                    // the in-flight state is unmissable at a
                    // glance — the old 14pt spinner alone was
                    // too easy to miss. WidgetKit renders views
                    // statically, so this is a bigger static
                    // mark, not a spinning animation; the disc
                    // stays for the whole sync, like the
                    // "Updating…" footer.
                    ZStack {
                        Circle()
                            .fill(Color(hex: "#dbeafe"))
                            .frame(width: 28, height: 28)
                        ProgressView()
                            .progressViewStyle(.circular)
                            // Build 58: brand blue, not muted — the
                            // spinner is the in-flight mark and must be
                            // visible at a glance next to "Updating…".
                            .tint(DesignTokens.primary)
                            .frame(width: 22, height: 22)
                    }
                } else if isMarkVisible(.succeeded) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DesignTokens.success)
                } else if isMarkVisible(.failed) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.errorText)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.muted)
                }
            }
            // The syncing mark is 28pt (disc + spinner); the idle
            // / success / failure icons stay 14pt.
            .frame(width: syncState.state == .syncing ? 28 : 14, height: syncState.state == .syncing ? 28 : 14)
            // Build 64 (F-37, owner Nov 23, 2026): 44×44pt hit
            // target — Apple's minimum. It was 26×26pt (14pt icon
            // + 6pt padding), too small to tap reliably, on the
            // smallest widget most of all. The icon stays 14pt,
            // centred in the 44pt target; the frame, not the
            // padding, sets the target, so the tap lands even when
            // the finger is nowhere near the 14pt glyph. The
            // layout still fits everywhere (small: ~22pt logo +
            // wordmark + 44pt button fits the 155pt canvas).
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        // Build 69 (owner, Nov 24, 2026): immediate press
        // feedback — a pale-blue disc while pressed (see
        // `WidgetRefreshButtonStyle` above). The old
        // `.buttonStyle(.plain)` suppressed the press highlight,
        // so a tap showed nothing until the checkmark arrived
        // seconds later.
        .buttonStyle(WidgetRefreshButtonStyle())
        // Identifier for a UI test to find the widget refresh button
        // and prove the syncing state shows immediately on tap.
        .accessibilityIdentifier("widget-refresh-button")
        .accessibilityLabel(syncState.state == .syncing ? "Syncing" : isMarkVisible(.succeeded) ? "Synced" : isMarkVisible(.failed) ? "Sync failed, tap to retry" : "Refresh widget")
    }

    /// Week-range dates for the header (build 35): the compact
    /// "Nov 14–20" form in brand blue, semibold, one line — never
    /// truncated. The minimum scale factor is a belt-and-braces
    /// against a long month name clipping at the right edge.
    /// `font` (build 77, owner Nov 25, 2026 — the XL widget):
    /// the header dates are bigger on the wide canvas so the top
    /// feels less empty; the default stays caption for the
    /// smaller sizes.
    @ViewBuilder
    private func headerDates(_ weekStart: String, font: Font = .caption.weight(.semibold)) -> some View {
        if let range = shortWeekRange(weekStart) {
            if isPlaceholder {
                skeletonBar(width: 64, height: 12)
            } else {
                Text(range)
                    .font(font)
                    .foregroundStyle(DesignTokens.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    /// Donut size that scales down on a narrow widget (build 64,
    /// F-37, owner Nov 23, 2026 — "just scale it so it works on a
    /// smaller screen"): the designed size holds while the widget
    /// is at least ~300pt wide; below that it shrinks
    /// proportionally, never below 40pt, so the ring + the two
    /// figure columns still fit instead of overflowing. On every
    /// current device the width is above 300pt, so the sizes are
    /// unchanged (medium 64, large 110, XL 120) — this is the
    /// safety net for narrower screens, not a redesign.
    private func adaptiveDonutSize(base: CGFloat, width: CGFloat) -> CGFloat {
        min(base, max(40, width * base / 300))
    }

    /// Donut: spent vs left of the weekly allowance (owner, Nov 15,
    /// 2026). Spent slice brand blue, over budget the muted red
    /// #991b1b (full ring), remaining slice pale light blue #dbeafe
    /// (owner, Nov 15, 2026 — widget polish: thicker ring, pale
    /// blue track instead of plain grey). The centre shows the
    /// spent percentage. Shown only when the snapshot carries a
    /// spent figure. privacySensitive like the figures.
    /// `availableWidth` (build 64, F-37): when the caller passes
    /// the row's measured width, the ring scales down on a narrow
    /// widget (adaptiveDonutSize) and the line width scales with
    /// it, so the ring keeps its proportions. Without a width the
    /// designed size is used as-is.
    private func donut(snapshot: WidgetSnapshot, size: CGFloat, lineWidth: CGFloat = 14, availableWidth: CGFloat? = nil) -> some View {
        let actualSize = availableWidth.map { adaptiveDonutSize(base: size, width: $0) } ?? size
        let actualLineWidth = lineWidth * actualSize / size
        let fraction = snapshot.spentFraction ?? 0
        let overBudget = snapshot.availableCents < 0
        return ZStack {
            Circle()
                .stroke(Color(hex: "#dbeafe"), lineWidth: actualLineWidth)
            // While loading there is no real spent figure to show:
            // the placeholder snapshot's 70% arc is sample data, so
            // the ring stays a plain pale-blue track with a skeleton bar
            // in the centre instead of a coloured arc and a percent.
            if !isPlaceholder {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        overBudget ? DesignTokens.heroOverBudget : DesignTokens.deep,
                        style: StrokeStyle(lineWidth: actualLineWidth, lineCap: fraction >= 1 ? .butt : .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            if isPlaceholder {
                skeletonBar(width: 36, height: 18)
            } else {
                // Build 78 (owner, Nov 25, 2026 — the XL widget):
                // the centre carries "used" under the percentage,
                // like the app's Home donut (spendingDonut's
                // showUsedLabel) — the bare % did not say what it
                // was a share of. Same sizes as the app's ring:
                // % at size × 0.22 bold, "used" at size × 0.125
                // muted. Every size that shows the donut gets it.
                VStack(spacing: 0) {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: actualSize * 0.22, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(DesignTokens.ink)
                    Text("used")
                        .font(.system(size: actualSize * 0.125))
                        .foregroundStyle(DesignTokens.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(width: actualSize, height: actualSize)
        .privacySensitive()
    }

    /// Muted small label above a figure. Build 78 (owner,
    /// Nov 25, 2026 — the XL widget): one line, never wrapped —
    /// the build-77 crush wrapped "Available" letter by letter
    /// when its column was squeezed, so the label carries the
    /// same lineLimit + minimumScaleFactor safety net as the
    /// figure below it.
    @ViewBuilder
    private func figureLabel(_ text: String) -> some View {
        if isPlaceholder {
            skeletonBar(width: 84, height: 12)
        } else {
            Text(text)
                .font(.caption)
                .foregroundStyle(DesignTokens.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// Small second line under a figure (build 78, owner
    /// Nov 25, 2026 — the XL widget): "Spent $367.01 so far"
    /// under Spending, "Given $761.29" under Tzedaka. One line,
    /// never wrapped — the same safety net as the label, so a
    /// narrow column shrinks it instead of wrapping it.
    private func figureSubline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(DesignTokens.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    /// A figure: big, bold, tabular numerals so the amount never
    /// reflows as it changes. Whole dollars, no cents (owner,
    /// Nov 15, 2026 — widget polish). Single line, never wrapped:
    /// a wide amount wrapping to two lines would blow the small
    /// widget's height (owner, Nov 15, 2026 — the small size
    /// overflowed its 155pt canvas). Build 36: minimumScaleFactor
    /// 0.6 — the amount SHRINKS to fit its column before it ever
    /// truncates. Without it, "$370" rendered as "$3..." in the
    /// owner's Nov 16 screenshot: lineLimit(1) alone truncates
    /// with an ellipsis when the text is wider than the column.
    @ViewBuilder
    private func figure(cents: Int, color: Color, size: CGFloat) -> some View {
        if isPlaceholder {
            // The bar is the figure's own height (24/28/36/44 by
            // family) and about as wide as a typical amount — the
            // same size the loaded figure stands in.
            skeletonBar(width: size * 3.9, height: size)
                .privacySensitive()
        } else {
            Text(MoneyFormat.wholeDollars(cents: cents))
                .font(.system(size: size, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(color)
                .privacySensitive()
        }
    }

    /// Thin horizontal progress bar (build 35): a pale track with a
    /// coloured fill of the given fraction, 8pt tall, ALWAYS
    /// filling its column width. The budget bar fills
    /// spent/allowance in deep blue (muted red when over budget);
    /// the charity bar fills given/committed in primary blue.
    /// Build 69 (owner, Nov 24, 2026 — the widget restyle): the
    /// charity bar is primary blue now, not charity green — the
    /// C-2 Tzedaka colour — and its track is the same pale blue
    /// #dbeafe as the budget bar. A zero fraction shows an empty
    /// track — no fill is ever faked. Build 78 (owner, Nov 25,
    /// 2026 — the XL widget): the bar fills its column — the
    /// build-77 FIXED width is gone (a fixed width
    /// over-constrained the XL row and crushed the Spending
    /// column). The two figure columns share the remaining width
    /// equally, so the two bars are the same length by
    /// construction, with no fixed number to overflow. 8pt thick
    /// (was 6pt), so it reads at a glance.
    private func progressBar(fraction: Double, fill: Color, track: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(track)
                RoundedRectangle(cornerRadius: 4)
                    .fill(fill)
                    .frame(width: geo.size.width * CGFloat(min(1.0, max(0.0, fraction))))
            }
        }
        .frame(height: 8)
    }

    /// Freshness footer (build 35; build 42, owner Nov 17, 2026):
    /// bottom-RIGHT in every size — a freshness dot (green when the
    /// snapshot is fresh, amber when stale) followed by "As of
    /// 6:15PM" in caption. Build 64 (F-38, owner Nov 23, 2026):
    /// a stale snapshot no longer says the developer word "Stale"
    /// (build 53) — it says what it means in plain words,
    /// "Updated 2h ago — tap to refresh", with the time since the
    /// snapshot was computed. The small widget takes the compact
    /// form (caption2). The leading Spacer is what pins it
    /// to the right edge.
    ///
    /// "Updated … ago" from a computed-at date and now (build 64,
    /// F-38): whole hours once an hour has passed, whole minutes
    /// before that, "just now" under a minute (or when the
    /// computed-at time is in the future — clock skew). The footer
    /// only calls this when the snapshot is stale, so the hours
    /// form is the one the user normally sees.
    private func staleText(computedAt: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(computedAt)
        if seconds < 60 {
            return "Updated just now — tap to refresh"
        }
        if seconds < 3600 {
            return "Updated \(Int(seconds / 60))m ago — tap to refresh"
        }
        return "Updated \(Int(seconds / 3600))h ago — tap to refresh"
    }

    @ViewBuilder
    private func footer(snapshot: WidgetSnapshot, stale: Bool, now: Date, compact: Bool = false) -> some View {
        if isPlaceholder {
            HStack {
                Spacer(minLength: 0)
                skeletonBar(width: 150, height: 12)
            }
        } else if syncState.state == .syncing {
            // Build 58 (owner, Nov 22, 2026 — iPad): pressing the
            // refresh button gave no feedback until the checkmark
            // landed seconds later — the tiny static spinner was
            // too easy to miss. WidgetKit renders views statically,
            // so there is no spinning animation to add; instead the
            // footer says so plainly while a sync runs — "Updating…"
            // in brand blue — an unmissable static signal that the
            // tap landed, until the new numbers arrive and the
            // footer goes back to "As of …". Build 77 (owner,
            // Nov 25, 2026 — the XL widget): the signal is BOLD
            // and one size up (subheadline, not caption) so it
            // reads at a glance next to the bigger spinner.
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                Text("Updating…")
                    .font((compact ? Font.caption : Font.subheadline).weight(.bold))
                    .foregroundStyle(DesignTokens.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        } else if compact {
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                // Build 64 (F-38): plain words, not the developer
                // word "Stale" (build 53) — the text says when the
                // numbers are from and what to do about it. It
                // replaces the dot + "As of …" pair in the stale
                // case; the fresh case below keeps them.
                if stale {
                    Text(staleText(computedAt: snapshot.computedAt, now: now))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DesignTokens.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Circle()
                        .fill(DesignTokens.success)
                        .frame(width: 7, height: 7)
                    Text(asOfString(snapshot.computedAt))
                        .font(.caption2)
                        .foregroundStyle(DesignTokens.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        } else {
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                if stale {
                    Text(staleText(computedAt: snapshot.computedAt, now: now))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DesignTokens.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    Circle()
                        .fill(DesignTokens.success)
                        .frame(width: 7, height: 7)
                    Text(asOfString(snapshot.computedAt))
                        .foregroundStyle(DesignTokens.muted)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    /// Small (155pt square): the two figures stack vertically,
    /// so the layout is compact — tight spacing and slightly
    /// smaller figures than medium, or the content overflows the
    /// canvas (owner, Nov 15, 2026 — the small size did not load /
    /// render properly: wordmark + two figure blocks + updated line
    /// came to ~153pt in a 155pt canvas, ~2pt of slack, so it
    /// clipped. Spacing 6 and figures 22/22 leave ~9pt of slack).
    /// Build 35: the compact wordmark (22pt logo), a thin
    /// progress bar under each figure, and the compact footer
    /// (dot + "As of …" time, bottom-right) — the additions cost
    /// ~10pt of that slack, so the layout still fits.
    /// Build 36 (owner, Nov 16, 2026): NO donut on small — the
    /// donut circle belongs only on the wide widgets (medium and
    /// large). Small stays clean: wordmark + refresh button, the
    /// available figure + thin blue progress bar, the Charity figure
    /// + its progress bar, and the compact footer. Nothing else.
    /// Build 42: both figures are 22pt, so the two halves mirror
    /// (label above, big amount, bar below).
    private func small(snapshot: WidgetSnapshot, stale: Bool, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Build 54: the wordmark opens Home; the refresh
                // button does NOT sit inside the link (it runs the
                // sync intent in place).
                wordmark(logoSize: 22, font: .system(size: 17, weight: .medium))
                    .widgetURL(homeURL)
                Spacer()
                refreshButton
            }
            // Build 54: the body below the header opens Home; the
            // header's button stays outside the link. The inner
            // VStack keeps the same 6pt spacing as the flat list
            // it replaces, so the layout is unchanged.
            VStack(alignment: .leading, spacing: 6) {
            // Build 42: the two halves mirror — label above, big
            // amount, progress bar below — in both blocks, with
            // both figures at 22pt. The label is just "available";
            // the allowance and Spent lines are gone (they live in
            // the app). The bar is always drawn: with no spent
            // figure it is an empty track, never a faked fill.
            VStack(alignment: .leading, spacing: 2) {
                figureLabel("Available")
                figure(
                    cents: snapshot.availableCents,
                    color: snapshot.availableCents < 0 ? DesignTokens.errorText : DesignTokens.deep,
                    size: 22
                )
                if isPlaceholder {
                    skeletonBar(height: 8)
                } else {
                    progressBar(
                        fraction: snapshot.spentFraction ?? 0,
                        fill: snapshot.availableCents < 0 ? DesignTokens.heroOverBudget : DesignTokens.deep,
                        track: Color(hex: "#dbeafe"))
                }
            }
            .widgetURL(transactionsURL)
            VStack(alignment: .leading, spacing: 2) {
                figureLabel(snapshot.charityLeftLabel)
                figure(cents: snapshot.charityRemainingCents, color: DesignTokens.primary, size: 22)
                if isPlaceholder {
                    skeletonBar(height: 8)
                } else {
                    progressBar(
                        fraction: snapshot.charityGivenFraction ?? 0,
                        fill: DesignTokens.primary,
                        track: Color(hex: "#dbeafe"))
                }
            }
            .widgetURL(tzedakaURL)
            Spacer(minLength: 0)
            footer(snapshot: snapshot, stale: stale, now: now, compact: true)
            }
            .widgetURL(homeURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(background, for: .widget)
    }

    /// Medium (build 35, mockup-approved): bigger header, the
    /// compact week range in brand blue, a donut beside the two
    /// figures, and a progress bar under each figure. Build 42: the
    /// two halves mirror (label above, big amount, bar below, both
    /// figures 28pt) — the "of $X allowance" and "Spent $X" lines
    /// are gone (they live in the app), and the left label is just
    /// "available". Height budget in the ~138pt content area:
    /// header 24 + spacing 8 + body ~52 + spacing 8 + footer 14 ≈
    /// 106, ~30pt of slack.
    private func medium(snapshot: WidgetSnapshot, stale: Bool, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                wordmark()
                    .widgetURL(homeURL)
                Spacer()
                headerDates(snapshot.weekStart)
                    .widgetURL(homeURL)
                refreshButton
            }
            // Build 54: the body below the header opens Home; the
            // header's button stays outside the link. Same 8pt
            // spacing as the flat list it replaces.
            VStack(alignment: .leading, spacing: 8) {
            // Build 64 (F-37): the row measures its own width so
            // the donut can scale down on a narrow screen
            // (adaptiveDonutSize, via donut's availableWidth). The
            // 64pt height is the donut's designed size — the row's
            // height when the donut is shown.
            GeometryReader { geo in
            HStack(alignment: .top, spacing: 14) {
                if snapshot.spentCents != nil {
                    donut(snapshot: snapshot, size: 64, lineWidth: 10, availableWidth: geo.size.width)
                        .widgetURL(transactionsURL)
                }
                VStack(alignment: .leading, spacing: 1) {
                    figureLabel("Available")
                    figure(
                        cents: snapshot.availableCents,
                        color: snapshot.availableCents < 0 ? DesignTokens.errorText : DesignTokens.deep,
                        size: 28
                    )
                    if isPlaceholder {
                        skeletonBar(height: 8)
                    } else {
                        progressBar(
                            fraction: snapshot.spentFraction ?? 0,
                            fill: snapshot.availableCents < 0 ? DesignTokens.heroOverBudget : DesignTokens.deep,
                            track: Color(hex: "#dbeafe"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetURL(transactionsURL)
                Divider()
                VStack(alignment: .leading, spacing: 1) {
                    figureLabel(snapshot.charityLeftLabel)
                    figure(cents: snapshot.charityRemainingCents, color: DesignTokens.primary, size: 28)
                    if isPlaceholder {
                        skeletonBar(height: 8)
                    } else {
                        progressBar(
                            fraction: snapshot.charityGivenFraction ?? 0,
                            fill: DesignTokens.primary,
                            track: Color(hex: "#dbeafe"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetURL(tzedakaURL)
            }
            }
            .frame(height: 64)
            Spacer(minLength: 0)
            footer(snapshot: snapshot, stale: stale, now: now)
            }
            .widgetURL(homeURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(background, for: .widget)
    }

    /// Large (build 42): the weekly and charity blocks stay stacked
    /// (tall canvas), but both now share the identical structure —
    /// label above, big amount, progress bar below, both figures
    /// 36pt — with the "of $X allowance" and "Spent $X" lines gone
    /// (they live in the app) and the left label just "available".
    private func large(snapshot: WidgetSnapshot, stale: Bool, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                // Build 77 (owner, Nov 25, 2026 — the XL widget):
                // a modestly bigger wordmark and date range on the
                // wide large canvas too — the XL sizes would crowd
                // this narrower canvas.
                wordmark(logoSize: 28, font: .system(size: 22, weight: .medium))
                    .widgetURL(homeURL)
                Spacer()
                headerDates(snapshot.weekStart, font: .system(size: 15, weight: .semibold))
                    .widgetURL(homeURL)
                refreshButton
            }
            // Build 54: the body below the header opens Home; the
            // header's button stays outside the link. Same 16pt
            // spacing as the flat list it replaces.
            VStack(alignment: .leading, spacing: 16) {
            // Two spacers, not one (owner, Nov 15, 2026): the
            // single spacer above "Updated" left one dead gap —
            // the slack is now split above and below the content.
            Spacer(minLength: 0)
            // Build 64 (F-37): the row measures its own width so
            // the donut can scale down on a narrow screen
            // (adaptiveDonutSize, via donut's availableWidth). The
            // 110pt height is the donut's designed size — the row's
            // height when the donut is shown.
            GeometryReader { geo in
            // Build 78 (owner, Nov 25, 2026 — the XL widget):
            // the donut-to-figure gap is 24pt, not 32 — the 32pt
            // build-77 gap was part of the over-constraint that
            // crushed the XL Spending column, and this vertical
            // layout has the same risk on a narrow canvas; 24pt
            // is still more than the 20pt the owner wanted more
            // than.
            HStack(alignment: .center, spacing: 24) {
                if snapshot.spentCents != nil {
                    donut(snapshot: snapshot, size: 110, availableWidth: geo.size.width)
                        .widgetURL(transactionsURL)
                }
                VStack(alignment: .leading, spacing: 2) {
                    figureLabel("Available")
                    figure(
                        cents: snapshot.availableCents,
                        color: snapshot.availableCents < 0 ? DesignTokens.errorText : DesignTokens.deep,
                        size: 36
                    )
                    if let spent = snapshot.spentCents, !isPlaceholder {
                        figureSubline("Spent \(MoneyFormat.formatCents(spent)) so far")
                    }
                    if isPlaceholder {
                        skeletonBar(height: 8)
                    } else {
                        // Build 78 (owner, Nov 25, 2026 — the XL
                        // widget): the bar fills its column — the
                        // build-77 FIXED 80pt width is gone (a
                        // fixed width cannot shrink, so the text
                        // took the hit when the row overflowed).
                        // This column takes the full remaining
                        // row width (maxWidth below); the Tzedaka
                        // bar fills its own column the same way,
                        // so the two bars are the same length.
                        progressBar(
                            fraction: snapshot.spentFraction ?? 0,
                            fill: snapshot.availableCents < 0 ? DesignTokens.heroOverBudget : DesignTokens.deep,
                            track: Color(hex: "#dbeafe"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetURL(transactionsURL)
            }
            }
            .frame(height: 110)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                figureLabel(snapshot.charityLeftLabel)
                figure(cents: snapshot.charityRemainingCents, color: DesignTokens.primary, size: 36)
                if let given = snapshot.charityGivenCents, !isPlaceholder {
                    figureSubline("Given \(MoneyFormat.formatCents(given))")
                }
                if isPlaceholder {
                    skeletonBar(height: 8)
                } else {
                    // Build 78 (owner, Nov 25, 2026 — the XL
                    // widget): the bar fills its column — the
                    // build-77 FIXED 80pt width is gone. This
                    // column is full-width, matching the Spending
                    // column above, so the two bars are the same
                    // length by construction.
                    progressBar(
                        fraction: snapshot.charityGivenFraction ?? 0,
                        fill: DesignTokens.primary,
                        track: Color(hex: "#dbeafe"))
                }
            }
            .widgetURL(tzedakaURL)
            Spacer(minLength: 0)
            footer(snapshot: snapshot, stale: stale, now: now)
            }
            .widgetURL(homeURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(background, for: .widget)
    }

    /// Extra-large (iPad-only): the large layout's design language
    /// on the wide canvas — weekly block (donut + figure) and
    /// charity block side by side with a vertical divider between
    /// them, same two numbers, same freshness line.
    /// Build 42: both blocks share the identical structure —
    /// label above, big amount, progress bar below, both figures
    /// 44pt — with the allowance and Spent lines gone and the left
    /// label just "available".
    private func extraLarge(snapshot: WidgetSnapshot, stale: Bool, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                // Build 77 (owner, Nov 25, 2026 — the XL widget):
                // a bigger wordmark (32pt logo, 24pt letters) and
                // a bigger date range (17pt) so the top of the
                // wide canvas feels less empty.
                wordmark(logoSize: 32, font: .system(size: 24, weight: .medium))
                    .widgetURL(homeURL)
                Spacer()
                headerDates(snapshot.weekStart, font: .system(size: 17, weight: .semibold))
                    .widgetURL(homeURL)
                refreshButton
            }
            // Build 54: the body below the header opens Home; the
            // header's button stays outside the link. Same 20pt
            // spacing as the flat list it replaces.
            VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            // Build 64 (F-37): the row measures its own width so
            // the donut can scale down on a narrow screen
            // (adaptiveDonutSize, via donut's availableWidth). The
            // 120pt height is the donut's designed size — the row's
            // height when the donut is shown.
            GeometryReader { geo in
            // Build 78 (owner, Nov 25, 2026 — the XL widget,
            // fixing the build-77 regression): the row is NO
            // LONGER over-constrained. Build 77's fixed 100pt
            // bars could not shrink, so when the row's fixed
            // content exceeded the canvas SwiftUI crushed the
            // Spending VStack — "Available" wrapped letter by
            // letter and "$105" clipped to "$". Now the two
            // figure columns share the remaining width EQUALLY
            // (equal maxWidth), the bars fill their column
            // (automatically the same length, no fixed width),
            // and the donut gap is 24pt (was 32 — the owner
            // only wanted more than 20pt, not a specific
            // number). Width budget on the XL canvas (~620pt
            // content): donut 120 + gaps 72 + Divider 1 leaves
            // ~425pt for the two columns (~212pt each) — a 44pt
            // "$105" figure needs ~105pt and the subline ~120pt,
            // so each column has ~90pt of slack.
            HStack(alignment: .center, spacing: 24) {
                if snapshot.spentCents != nil {
                    donut(snapshot: snapshot, size: 120, availableWidth: geo.size.width)
                        .widgetURL(transactionsURL)
                }
                VStack(alignment: .leading, spacing: 2) {
                    figureLabel("Available")
                    figure(
                        cents: snapshot.availableCents,
                        color: snapshot.availableCents < 0 ? DesignTokens.errorText : DesignTokens.deep,
                        size: 44
                    )
                    if let spent = snapshot.spentCents, !isPlaceholder {
                        figureSubline("Spent \(MoneyFormat.formatCents(spent)) so far")
                    }
                    if isPlaceholder {
                        skeletonBar(height: 8)
                    } else {
                        progressBar(
                            fraction: snapshot.spentFraction ?? 0,
                            fill: snapshot.availableCents < 0 ? DesignTokens.heroOverBudget : DesignTokens.deep,
                            track: Color(hex: "#dbeafe"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetURL(transactionsURL)
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    figureLabel(snapshot.charityLeftLabel)
                    figure(cents: snapshot.charityRemainingCents, color: DesignTokens.primary, size: 44)
                    if let given = snapshot.charityGivenCents, !isPlaceholder {
                        figureSubline("Given \(MoneyFormat.formatCents(given))")
                    }
                    if isPlaceholder {
                        skeletonBar(height: 8)
                    } else {
                        // Build 78 (owner, Nov 25, 2026 — the XL
                        // widget): the bar fills its column — the
                        // build-77 FIXED 100pt width is gone.
                        // This column shares the remaining width
                        // equally with the Spending column, so
                        // the two bars are the same length by
                        // construction.
                        progressBar(
                            fraction: snapshot.charityGivenFraction ?? 0,
                            fill: DesignTokens.primary,
                            track: Color(hex: "#dbeafe"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetURL(tzedakaURL)
            }
            }
            .frame(height: 120)
            Spacer(minLength: 0)
            footer(snapshot: snapshot, stale: stale, now: now)
            }
            .widgetURL(homeURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(background, for: .widget)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Build 53 (audit WG2): the empty state has a refresh
            // button now — the old text ("Open the app to refresh")
            // with no button left the user no way to try. The
            // button attempts the fetch; when the app has never
            // written a household id it fails and the failed mark
            // shows, and the text still says to open the app.
            HStack {
                wordmark()
                    .widgetURL(homeURL)
                Spacer()
                refreshButton
            }
            // Build 54: the text below the header opens Home; the
            // header's button stays outside the link. Same 6pt
            // spacing as the flat list it replaces.
            VStack(alignment: .leading, spacing: 6) {
            Text("Open the app to refresh")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.ink)
            Text("Your weekly and charity balances will show here.")
                .font(.caption)
                .foregroundStyle(DesignTokens.muted)
            Spacer(minLength: 0)
            }
            .widgetURL(homeURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(background, for: .widget)
    }
}

@main
struct OnBudgetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OnBudgetWidget", provider: Provider()) { entry in
            WidgetView(entry: entry)
            // Build 54 (owner, Nov 21, 2026 — the iPad sync button
            // tap did nothing, and the tap did not even open the
            // app): the whole-widget .widgetURL used to cover the
            // refresh button too, swallowing its tap before the
            // intent ran. The link now lives INSIDE WidgetView, on
            // the content only — the refresh button sits
            // unambiguously outside it, so its intent fires.
            // Tapping the widget still opens HOME (onbudget://home,
            // handled in OnBudgetApp's onOpenURL → goHome()).
        }
        .configurationDisplayName("STAGE")
        .description("Spending, saving, and giving balances for the week.")
        // Extra-large is iPad-only — it never appears on iPhone,
        // where large stays the biggest.
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

// MARK: - Previews (build 36)
//
// Regression previews for the Nov 16 truncation bug: "$370" rendered
// as "$3..." because figure() had lineLimit(1) with no
// minimumScaleFactor. Each size is previewed at $370 (the owner's
// screenshot amount) and at $3,700 (one digit wider, with a comma —
// the widest realistic weekly figure) so a future layout change that
// re-introduces truncation is visible in Xcode before it ships.
// These previews render the live WidgetView, not a mock, and are
// never shown to the owner — they exist for the developer to eyeball
// in Xcode. The simulator workflow compiles this file (so a preview
// typo breaks the build) but cannot render previews; the visual
// check itself happens in Xcode on a Mac.

private func previewSnapshot(availableCents: Int, spentCents: Int) -> WidgetSnapshot {
    WidgetSnapshot(
        weekStart: "2026-11-15",
        availableCents: availableCents,
        charityRemainingCents: 4200,
        spentCents: spentCents,
        charityGivenCents: 3000,
        charityCommittedCents: 10000,
        computedAt: Date()
    )
}

#Preview("Medium — $370 left") {
    WidgetView(entry: WidgetEntry(date: Date(), snapshot: previewSnapshot(availableCents: 37000, spentCents: 3000)))
        .previewContext(WidgetPreviewContext(family: .systemMedium))
}

#Preview("Medium — $3,700 left") {
    WidgetView(entry: WidgetEntry(date: Date(), snapshot: previewSnapshot(availableCents: 370000, spentCents: 30000)))
        .previewContext(WidgetPreviewContext(family: .systemMedium))
}

#Preview("Small — $370 left") {
    WidgetView(entry: WidgetEntry(date: Date(), snapshot: previewSnapshot(availableCents: 37000, spentCents: 3000)))
        .previewContext(WidgetPreviewContext(family: .systemSmall))
}

#Preview("Small — $3,700 left") {
    WidgetView(entry: WidgetEntry(date: Date(), snapshot: previewSnapshot(availableCents: 370000, spentCents: 30000)))
        .previewContext(WidgetPreviewContext(family: .systemSmall))
}

#Preview("Large — $3,700 left") {
    WidgetView(entry: WidgetEntry(date: Date(), snapshot: previewSnapshot(availableCents: 370000, spentCents: 30000)))
        .previewContext(WidgetPreviewContext(family: .systemLarge))
}
