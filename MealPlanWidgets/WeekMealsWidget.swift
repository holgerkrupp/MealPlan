import WidgetKit
import SwiftUI

struct WeekMealsProvider: TimelineProvider {

    func placeholder(in context: Context) -> MealPlanWidgetEntry { .sampleWeek }

    func getSnapshot(in context: Context, completion: @escaping (MealPlanWidgetEntry) -> Void) {
        completion(context.isPreview ? .sampleWeek : entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MealPlanWidgetEntry>) -> Void) {
        // Only the "today" highlight and, on Sundays, the week itself change
        // overnight — one entry a day is plenty.
        let midnight = Date.now.adding(days: 1).startOfDay
        completion(Timeline(entries: [entry()], policy: .after(midnight)))
    }

    private func entry() -> MealPlanWidgetEntry {
        let now = Date.now
        let start = now.startOfWeek()
        return MealPlanWidgetEntry(
            date: now,
            days: WidgetPlanLoader.days(from: start, count: 7, thumbnailBudget: 14),
            link: WidgetLink.day(now),
            reference: now
        )
    }
}

struct WeekMealsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WeekMealsWidget", provider: WeekMealsProvider()) { entry in
            WeekMealsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(entry.link)
        }
        .configurationDisplayName(String(localized: "This week"))
        .description(String(localized: "The whole week’s plan at a glance."))
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct WeekMealsView: View {
    var entry: MealPlanWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var subtitle: String {
        guard let first = entry.days.first, let last = entry.days.last else { return "" }
        return "\(first.date.widgetShortDayLabel) – \(last.date.widgetShortDayLabel)"
    }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            rectangular
        case .systemLarge:
            grid(tileSize: 22, rowSpacing: 5, showsTiles: true)
        default:
            grid(tileSize: 0, rowSpacing: 2, showsTiles: false)
        }
    }

    private func grid(tileSize: CGFloat, rowSpacing: CGFloat, showsTiles: Bool) -> some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            WidgetHeader(title: String(localized: "This week"), subtitle: subtitle)
                .padding(.bottom, 1)
            ForEach(entry.days) { day in
                Link(destination: WidgetLink.day(day.date)) {
                    row(for: day, tileSize: tileSize, showsTiles: showsTiles)
                }
                .buttonStyle(.plain)
                .frame(maxHeight: showsTiles ? .infinity : nil)
            }
            if !showsTiles { Spacer(minLength: 0) }
        }
    }

    /// One day: its weekday column, then either a strip of dish tiles (large)
    /// or just the names (medium), with today picked out.
    private func row(for day: WidgetDay, tileSize: CGFloat, showsTiles: Bool) -> some View {
        let isToday = day.isToday(relativeTo: entry.reference)
        return HStack(spacing: 7) {
            Text(day.shortName)
                .font(.system(size: showsTiles ? 12 : 11, weight: isToday ? .bold : .medium))
                .foregroundStyle(isToday ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: showsTiles ? 34 : 28, alignment: .leading)

            if day.isEmpty {
                Text(verbatim: "—")
                    .font(.system(size: showsTiles ? 12 : 11))
                    .foregroundStyle(.tertiary)
            } else {
                if showsTiles {
                    HStack(spacing: 3) {
                        ForEach(day.meals.prefix(3)) { meal in
                            MealTile(meal: meal, size: tileSize)
                        }
                    }
                }
                Text(day.summaryLine)
                    .font(.system(size: showsTiles ? 12 : 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, showsTiles ? 3 : 1)
        .padding(.horizontal, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isToday ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
    }

    /// Lock screen: the days that are still ahead, as compact as it gets.
    private var rectangular: some View {
        let remaining = entry.days.filter { $0.date >= entry.reference.startOfDay && !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 1) {
            Text(String(localized: "This week")).font(.headline)
            if remaining.isEmpty {
                Text(String(localized: "Nothing planned")).font(.caption)
            } else {
                ForEach(remaining.prefix(2)) { day in
                    Text("\(day.shortName): \(day.summaryLine)").font(.caption).lineLimit(1)
                }
            }
        }
    }
}

#Preview("Medium", as: .systemMedium) {
    WeekMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sampleWeek
}

#Preview("Large", as: .systemLarge) {
    WeekMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sampleWeek
}

#Preview("Lock screen", as: .accessoryRectangular) {
    WeekMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sampleWeek
}

#Preview("Nothing planned", as: .systemLarge) {
    WeekMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sampleEmpty
}
