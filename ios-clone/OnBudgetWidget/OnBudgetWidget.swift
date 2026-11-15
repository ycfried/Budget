// OnBudgetWidget — OnBudgetWidget.swift
//
// Home-screen widget (native build 17, owner-approved Nov 12, 2026;
// redesigned build 26, owner Nov 14, 2026): the weekly spending
// balance and the charity balance — the same two numbers the Home
// screen shows, nothing else. Small, medium, large and extra-large
// (extra-large is iPad-only).
//
// Redesign (owner, Nov 14, 2026 — the medium widget was "super
// ugly.. basic.. like a kindergartener made it"): no more plain
// blue "OnBudget" text header and flat white — a quiet ink wordmark,
// muted small labels, big figures with tabular numerals, generous
// spacing, a subtle tinted background, and a hairline divider
// between the two numbers. The data is unchanged: the same two
// numbers (weekly balance, charity remaining) from the same
// WidgetSnapshot, the same freshness rule and "Updated …" line,
// the same privacySensitive figures. Large and extra-large add the
// week range and a donut — spent vs left of the weekly allowance
// (owner, Nov 15, 2026; the spent line the donut replaces is gone).
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
// Colours mirror Home: the weekly figure is brand blue, red when
// over budget (negative); the charity figure is ink (owner, Nov 15,
// 2026 — the green charity figure and the ink weekly figure were
// swapped: the main budget amount is blue, charity is black).
// All figures are whole dollars, no cents (owner, Nov 15, 2026).
// Figures are privacySensitive so they hide on the lock screen
// like other financial widgets. Tapping the widget opens the app
// (no widgetURL — the app has no deep link for the widget to
// land on).
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
        // The app calls reloadAllTimelines() on launch, on every
        // foreground, and on every Home refresh, so the timeline
        // only needs a backstop: re-read in 30 minutes so a stale
        // label flips even if the app is never opened again.
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
/// 7 days); nil when unparseable. The large and extra-large widgets
/// show the range; medium keeps the shorter "Week of Nov 7".
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
    /// True while WidgetKit renders the placeholder entry (the
    /// loading state): the redaction environment carries
    /// `.placeholder` for it, and never for a live timeline entry.
    @Environment(\.redactionReasons) private var redactionReasons
    let entry: WidgetEntry

    /// The loading state renders explicit skeleton bars sized to
    /// the loaded content (owner, Nov 15, 2026 — WidgetKit's own
    /// redacted text bars came out too small on the XL widget).
    private var isPlaceholder: Bool { redactionReasons.contains(.placeholder) }

    /// A loading bar shaped exactly like the text it stands for:
    /// same height as the loaded figure/label, same skeleton grey
    /// as the app's SkeletonBlock (#ececf1). Shown only while the
    /// view renders as a placeholder; the loaded entry always shows
    /// real text.
    private func skeletonBar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(DesignTokens.skeleton)
            .frame(width: width, height: height)
    }

    /// Soft tinted background (owner, Nov 14, 2026): a faint cool
    /// grey-blue instead of flat white. The figures stay brand blue
    /// / ink / red on it — a tint, not a wash. Owner, Nov 15, 2026
    /// (widget polish): a very pale blue tint #f2f7ff so the card
    /// reads less plain.
    private var background: Color { Color(hex: "#f2f7ff") }

    var body: some View {
        if let snapshot = entry.snapshot {
            let stale = snapshot.isStale(at: entry.date)
            switch family {
            case .systemExtraLarge:
                extraLarge(snapshot: snapshot, stale: stale)
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

    /// Quiet brandmark: the real logo mark beside the ink wordmark
    /// (owner, Nov 15, 2026 — the header showed only the plain
    /// "OnBudget" wordmark). AppLogo comes from the shared asset
    /// catalog, which the widget target includes.
    private var wordmark: some View {
        HStack(spacing: 6) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .clipShape(Circle())
            if isPlaceholder {
                skeletonBar(width: 88, height: 16)
            } else {
                Text("OnBudget")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.ink)
            }
        }
    }

    /// Donut: spent vs left of the weekly allowance (owner, Nov 15,
    /// 2026). Spent slice brand blue, over budget the muted red
    /// #991b1b (full ring), remaining slice pale light blue #dbeafe
    /// (owner, Nov 15, 2026 — widget polish: thicker ring, pale
    /// blue track instead of plain grey). The centre shows the
    /// spent percentage. Shown only when the snapshot carries a
    /// spent figure. privacySensitive like the figures.
    private func donut(snapshot: WidgetSnapshot, size: CGFloat) -> some View {
        let fraction = snapshot.spentFraction ?? 0
        let overBudget = snapshot.availableCents < 0
        return ZStack {
            Circle()
                .stroke(Color(hex: "#dbeafe"), lineWidth: 14)
            // While loading there is no real spent figure to show:
            // the placeholder snapshot's 70% arc is sample data, so
            // the ring stays a plain pale-blue track with a skeleton bar
            // in the centre instead of a coloured arc and a percent.
            if !isPlaceholder {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        overBudget ? DesignTokens.heroOverBudget : DesignTokens.primary,
                        style: StrokeStyle(lineWidth: 14, lineCap: fraction >= 1 ? .butt : .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            if isPlaceholder {
                skeletonBar(width: 36, height: 18)
            } else {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: size * 0.22, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.ink)
            }
        }
        .frame(width: size, height: size)
        .privacySensitive()
    }

    /// Muted small label above a figure.
    @ViewBuilder
    private func figureLabel(_ text: String) -> some View {
        if isPlaceholder {
            skeletonBar(width: 84, height: 12)
        } else {
            Text(text)
                .font(.caption)
                .foregroundStyle(DesignTokens.muted)
        }
    }

    /// A figure: big, bold, tabular numerals so the amount never
    /// reflows as it changes. Whole dollars, no cents (owner,
    /// Nov 15, 2026 — widget polish). Single line, never wrapped:
    /// a wide amount wrapping to two lines would blow the small
    /// widget's height (owner, Nov 15, 2026 — the small size
    /// overflowed its 155pt canvas).
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
                .foregroundStyle(color)
                .privacySensitive()
        }
    }

    @ViewBuilder
    private func updatedLine(snapshot: WidgetSnapshot, stale: Bool) -> some View {
        if isPlaceholder {
            skeletonBar(width: 130, height: 11)
        } else {
            Text(updatedText(snapshot.computedAt, stale: stale))
                .font(.caption2)
                .foregroundStyle(DesignTokens.muted)
        }
    }

    /// Small (155pt square): the two figures stack vertically,
    /// so the layout is compact — tight spacing and slightly
    /// smaller figures than medium, or the content overflows the
    /// canvas (owner, Nov 15, 2026 — the small size did not load /
    /// render properly: wordmark + two figure blocks + updated line
    /// came to ~153pt in a 155pt canvas, ~2pt of slack, so it
    /// clipped. Spacing 6 and figures 22/18 leave ~19pt of slack).
    private func small(snapshot: WidgetSnapshot, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            wordmark
            VStack(alignment: .leading, spacing: 2) {
                figureLabel("Left this week")
                figure(
                    cents: snapshot.availableCents,
                    color: snapshot.availableCents < 0 ? DesignTokens.errorText : DesignTokens.primary,
                    size: 22
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                figureLabel("Charity left")
                figure(cents: snapshot.charityRemainingCents, color: DesignTokens.ink, size: 18)
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
                    if isPlaceholder {
                        skeletonBar(width: 110, height: 12)
                    } else {
                        Text("Week of \(week)")
                            .font(.caption)
                            .foregroundStyle(DesignTokens.muted)
                    }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    figureLabel("Left this week")
                    figure(
                        cents: snapshot.availableCents,
                        color: snapshot.availableCents < 0 ? DesignTokens.errorText : DesignTokens.primary,
                        size: 28
                    )
                }
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    figureLabel("Charity left")
                    figure(cents: snapshot.charityRemainingCents, color: DesignTokens.ink, size: 28)
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
                    if isPlaceholder {
                        skeletonBar(width: 110, height: 12)
                    } else {
                        Text(range)
                            .font(.caption)
                            .foregroundStyle(DesignTokens.muted)
                    }
                }
            }
            // Two spacers, not one (owner, Nov 15, 2026): the
            // single spacer above "Updated" left one dead gap —
            // the slack is now split above and below the content.
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 20) {
                if snapshot.spentCents != nil {
                    donut(snapshot: snapshot, size: 110)
                }
                VStack(alignment: .leading, spacing: 2) {
                    figureLabel("Left this week")
                    figure(
                        cents: snapshot.availableCents,
                        color: snapshot.availableCents < 0 ? DesignTokens.errorText : DesignTokens.primary,
                        size: 36
                    )
                    if let spent = snapshot.spentCents {
                        if isPlaceholder {
                            skeletonBar(width: 170, height: 15)
                        } else {
                            Text("of \(MoneyFormat.wholeDollars(cents: spent + snapshot.availableCents)) allowance")
                                .font(.subheadline)
                                .foregroundStyle(DesignTokens.muted)
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                figureLabel("Charity left")
                figure(cents: snapshot.charityRemainingCents, color: DesignTokens.ink, size: 36)
            }
            Spacer(minLength: 0)
            updatedLine(snapshot: snapshot, stale: stale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(background, for: .widget)
    }

    /// Extra-large (iPad-only): the large layout's design language
    /// on the wide canvas — weekly block (donut + figure) and
    /// charity block side by side with a vertical divider between
    /// them, same two numbers, same freshness line.
    private func extraLarge(snapshot: WidgetSnapshot, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                wordmark
                Spacer()
                if let range = weekRange(snapshot.weekStart) {
                    if isPlaceholder {
                        skeletonBar(width: 110, height: 12)
                    } else {
                        Text(range)
                            .font(.caption)
                            .foregroundStyle(DesignTokens.muted)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 32) {
                HStack(alignment: .center, spacing: 20) {
                    if snapshot.spentCents != nil {
                        donut(snapshot: snapshot, size: 120)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        figureLabel("Left this week")
                        figure(
                            cents: snapshot.availableCents,
                            color: snapshot.availableCents < 0 ? DesignTokens.errorText : DesignTokens.primary,
                            size: 44
                        )
                        if let spent = snapshot.spentCents {
                            if isPlaceholder {
                                skeletonBar(width: 170, height: 15)
                            } else {
                                Text("of \(MoneyFormat.wholeDollars(cents: spent + snapshot.availableCents)) allowance")
                                    .font(.subheadline)
                                    .foregroundStyle(DesignTokens.muted)
                            }
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    figureLabel("Charity left")
                    figure(cents: snapshot.charityRemainingCents, color: DesignTokens.ink, size: 44)
                }
                Spacer(minLength: 0)
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
        // Extra-large is iPad-only — it never appears on iPhone,
        // where large stays the biggest.
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
