// OnBudgetWidget — OnBudgetWidget.swift
//
// Home-screen widget (native build 17, owner-approved Nov 12, 2026):
// the weekly spending balance and the charity balance — the same two
// numbers the Home screen shows, nothing else. Small and medium.
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

private func updatedText(_ computedAt: Date, stale: Bool) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    let text = "Updated \(formatter.string(from: computedAt))"
    return stale ? text + " · may be out of date" : text
}

struct WidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            let stale = snapshot.isStale(at: entry.date)
            switch family {
            case .systemMedium:
                medium(snapshot: snapshot, stale: stale)
            default:
                small(snapshot: snapshot, stale: stale)
            }
        } else {
            empty
        }
    }

    private func small(snapshot: WidgetSnapshot, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OnBudget")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DesignTokens.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Left this week")
                    .font(.caption2)
                    .foregroundStyle(DesignTokens.muted)
                Text(MoneyFormat.string(cents: snapshot.availableCents))
                    .font(.title3.bold())
                    .foregroundStyle(snapshot.availableCents < 0 ? DesignTokens.errorText : DesignTokens.ink)
                    .privacySensitive()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Charity left to give")
                    .font(.caption2)
                    .foregroundStyle(DesignTokens.muted)
                Text(MoneyFormat.string(cents: snapshot.charityRemainingCents))
                    .font(.headline)
                    .foregroundStyle(DesignTokens.charityDeep)
                    .privacySensitive()
            }
            Spacer(minLength: 0)
            Text(updatedText(snapshot.computedAt, stale: stale))
                .font(.caption2)
                .foregroundStyle(DesignTokens.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
    }

    private func medium(snapshot: WidgetSnapshot, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("OnBudget")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.primary)
                Spacer()
                if let week = shortWeekStart(snapshot.weekStart) {
                    Text("Week of \(week)")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.muted)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Left this week")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.muted)
                    Text(MoneyFormat.string(cents: snapshot.availableCents))
                        .font(.title2.bold())
                        .foregroundStyle(snapshot.availableCents < 0 ? DesignTokens.errorText : DesignTokens.ink)
                        .privacySensitive()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Charity left to give")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.muted)
                    Text(MoneyFormat.string(cents: snapshot.charityRemainingCents))
                        .font(.title2.bold())
                        .foregroundStyle(DesignTokens.charityDeep)
                        .privacySensitive()
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            Text(updatedText(snapshot.computedAt, stale: stale))
                .font(.caption2)
                .foregroundStyle(DesignTokens.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OnBudget")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DesignTokens.primary)
            Text("Open the app to refresh")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.ink)
            Text("Your weekly and charity balances will show here.")
                .font(.caption)
                .foregroundStyle(DesignTokens.muted)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
