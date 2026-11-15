// OnBudgetWidget — OnBudgetWidget.swift
//
// Home-screen widget (native build 17, owner-approved Nov 12, 2026;
// redesigned build 26, owner Nov 14, 2026): the weekly spending
// balance and the charity balance — the same two numbers the Home
// screen shows, nothing else. Small, medium and large.
//
// Redesign (owner, Nov 14, 2026 — the medium widget was "super
// ugly.. basic.. like a kindergartener made it"): no more plain
// blue "OnBudget" text header and flat white — a quiet ink wordmark,
// muted small labels, big figures with tabular numerals, generous
// spacing, a subtle tinted background, and a hairline divider
// between the two numbers. The data is unchanged: the same two
// numbers (weekly balance, charity remaining) from the same
// WidgetSnapshot, the same freshness rule and "Updated …" line,
// the same privacySensitive figures. Large adds the week range and
// a spent-this-week line — only when the snapshot carries it.
//
// Data path: the app writes a WidgetSnapshot into the shared App
// Groups container at the end of every Home refresh; the widget only
// ever READS that snapshot. It never signs in, never calls Supabase,
// never holds a session. When there is no snapshot (never opened the
// app, or signed out) it says so plainly. When the snapshot is stale
// (over 1 hour old) it still shows the numbers but labels them with
// the update time and "may be out of date" — a stale number is never
// presented as if it were live.
//
// Colours mirror Home: the weekly figure is ink, red when over budget
// (negative); the charity figure is charity green, and stays green
// when negative (ahead on giving). Figures are privacySensitive so
// they hide on the lock screen like other financial widgets.
// Tapping the widget opens the app (no widgetURL — the app has no
// deep link for the widget to land on).
//
// Label note (owner, Nov 14, 2026): his screenshot reads "Left left
// this week", but the label in every version of this file in the
// repo — including the build-17 original — is exactly "Left this
// week" (single). The doubling does not come from shipped code; the
// redesign keeps the single clean label in all three sizes.

import SwiftUI
import WidgetKit
import OnBudgetKit

struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: Date(), snapshot: WidgetSnapshot(
            weekStart: "2026-11-08",
            availableCents: 17307,
            charityRemainingCents: 4200,
            spentCents: 40349,
            computedAt: Date()
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(WidgetEntry(date: Date(), snapshot: WidgetSnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        // The app calls reloadAllTimelines() on every Home refresh, so
        // the timeline only needs a backstop: re-read in 30 minutes so
        // a stale label flips even if the app is never opened again.
        let entry = WidgetEntry(date: Date(), snapshot: WidgetSnapshotStore.read())
        completion(Timeline(
            entries: [entry],
            policy: .after(Date().addingTimeInterval(1800))
        ))
    }
}

/// "Nov 9" from a "2026-11-09" week-start string; nil when unparseable.
private func shortWeekStart(_ weekStart: String) -> String? {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.timeZone = TimeZone(secondsFromGMT: 0)
    guard let date = parser.date(from: weekStart) else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
}

/// "Nov 7 – Nov 13" from a "2026-11-07" week-start string (weeks run
/// 7 days); nil when unparseable. The large widget shows the range;
/// medium keeps the shorter "Week of Nov 7".
private func weekRange(_ weekStart: String) -> String? {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.timeZone = TimeZone(secondsFromGMT: 0)
    guard let start = parser.date(from: weekStart) else { return nil }
    guard let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: 6, to: start) else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
}

private func updatedText(_ computedAt: Date, stale: Bool) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    let text = "Updated \(formatter.string(from: computedAt))"
    return stale ? text + " · may be out of date" : text
}

struct WidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetEntry

    /// Soft tinted background (owner, Nov 14, 2026): a faint cool
    /// grey-blue instead of flat white. The figures stay dark ink /
    /// red / green on it — a tint, not a wash.
    private var background: Color { Color(hex: "#f5f7fb") }

    var body: some View {
        if let snapshot = entry.snapshot {
            let stale = snapshot.isStale(at: entry.date)
            switch family {
            case .systemLarge:
                large(snapshot: snapshot, stale: stale)
            case .systemMedium:
                medium(snapshot: snapshot, stale: stale)
            default:
                small(snapshot: snapshot, stale: stale)
            }
        } else {
            empty
        }
    }

    /// Quiet wordmark: ink, semibold — not the old blue text.
    private var wordmark: some View {
        Text("OnBudget")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(DesignTokens.ink)
    }

    /// Muted small label above a figure.
    private func figureLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(DesignTokens.muted)
    }

    /// A figure: big, bold, tabular numerals so the amount never
    /// reflows as it changes.
    private func figure(cents: Int, color: Color, size: CGFloat) -> some View {
        Text(MoneyFormat.string(cents: cents))
            .font(.system(size: size, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .privacySensitive()
    }

    private func updatedLine(snapshot: WidgetSnapshot, stale: Bool) -> some View {
        Text(updatedText(snapshot.computedAt, stale: stale))
            .font(.caption2)
            .foregroundStyle(DesignTokens.muted)
    }

    private func small(snapshot: WidgetSnapshot, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            wordmark
            VStack(alignment: .leading, spacing: 2) {
                figureLabel("Left this week")
                figure(
                    cents: snapshot.availableCents,
                    color: snapshot.availableCents < 0 ? DesignTokens.errorText : DesignTokens.ink,
                    size: 24
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                figureLabel("Charity left to give")
                figure(cents: snapshot.charityRemainingCents, color: DesignTokens.charityDeep, size: 20)
            }
            Spacer(minLength: 0)
            updatedLine(snapshot: snapshot, stale: stale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(background, for: .widget)
    }

    private func medium(snapshot: WidgetSnapshot, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                wordmark
                Spacer()
                if let week = shortWeekStart(snapshot.weekStart) {
                    Text("Week of \(week)")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.muted)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    figureLabel("Left this week")
                    figure(
                        cents: snapshot.availableCents,
                        color: snapshot.availableCents < 0 ? DesignTokens.errorText : DesignTokens.ink,
                        size: 28
                    )
                }
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    figureLabel("Charity left to give")
                    figure(cents: snapshot.charityRemainingCents, color: DesignTokens.charityDeep, size: 28)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            updatedLine(snapshot: snapshot, stale: stale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(background, for: .widget)
    }

    private func large(snapshot: WidgetSnapshot, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                wordmark
                Spacer()
                if let range = weekRange(snapshot.weekStart) {
                    Text(range)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.muted)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                figureLabel("Left this week")
                figure(
                    cents: snapshot.availableCents,
                    color: snapshot.availableCents < 0 ? DesignTokens.errorText : DesignTokens.ink,
                    size: 36
                )
                // Spent line (only when the snapshot carries it —
                // snapshots written before build 26 have none).
                if let spent = snapshot.spentCents {
                    Text("Spent \(MoneyFormat.string(cents: spent)) this week")
                        .font(.subheadline)
                        .foregroundStyle(DesignTokens.muted)
                        .padding(.top, 2)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                figureLabel("Charity left to give")
                figure(cents: snapshot.charityRemainingCents, color: DesignTokens.charityDeep, size: 36)
            }
            Spacer(minLength: 0)
            updatedLine(snapshot: snapshot, stale: stale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(background, for: .widget)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            wordmark
            Text("Open the app to refresh")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.ink)
            Text("Your weekly and charity balances will show here.")
                .font(.caption)
                .foregroundStyle(DesignTokens.muted)
            Spacer(minLength: 0)
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
        }
        .configurationDisplayName("OnBudget")
        .description("Weekly spending balance and charity balance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
