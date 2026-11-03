import SwiftUI
import WidgetKit
import OnBudgetCore

struct BudgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}
struct BudgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BudgetEntry { BudgetEntry(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (BudgetEntry) -> Void) { completion(read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BudgetEntry>) -> Void) {
        completion(Timeline(entries: [read()], policy: .after(Date().addingTimeInterval(1800))))
    }
    private func read() -> BudgetEntry {
        var snapshot: WidgetSnapshot?
        if let group = Bundle.main.object(forInfoDictionaryKey: "OnBudgetAppGroup") as? String,
           !group.isEmpty, !group.contains("$("),
           let data = UserDefaults(suiteName: group)?.data(forKey: "displaySnapshot") {
            snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        }
        return BudgetEntry(date: Date(), snapshot: snapshot)
    }
}
struct BudgetWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BudgetEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OnBudget").font(.headline).foregroundStyle(Color(red: 47 / 255, green: 107 / 255, blue: 1))
            if let snapshot = entry.snapshot {
                Text(snapshot.isSample ? "SAMPLE · Available this week" : "Available this week").font(.caption)
                Text(snapshot.available.formatted).font(.title.bold()).monospacedDigit().privacySensitive()
                if family == .systemMedium { Text("Extra Fund \(snapshot.fundAvailable.formatted)").privacySensitive() }
                Label(snapshot.isStale(at: entry.date) ? "Stale · last known" : "Last known", systemImage: "clock").font(.caption)
                Text(snapshot.computedAt, format: .dateTime.month().day().hour().minute()).font(.caption2)
            } else {
                Text("Open OnBudget").font(.subheadline)
                Text("No shared snapshot. App Group setup is required.").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "onbudget-sample://home"))
        .accessibilityElement(children: .combine)
    }
}
@main
struct OnBudgetWidget: Widget {
    let kind = "OnBudgetSnapshot"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BudgetProvider()) { BudgetWidgetView(entry: $0) }
            .configurationDisplayName("OnBudget")
            .description("Last-known weekly availability and Extra Fund, with freshness.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
