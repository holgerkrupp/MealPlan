import WidgetKit
import SwiftUI

/// Hour of the evening after which the widget stops looking back at today and
/// leads with tomorrow — by then the question is what to defrost, not what's
/// for lunch.
private let rolloverHour = 18

struct TodayMealsProvider: TimelineProvider {

    func placeholder(in context: Context) -> MealPlanWidgetEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (MealPlanWidgetEntry) -> Void) {
        completion(context.isPreview ? .sample : entries().first ?? .sample)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MealPlanWidgetEntry>) -> Void) {
        let list = entries()
        let midnight = Date.now.adding(days: 1).startOfDay
        completion(Timeline(entries: list, policy: .after(midnight)))
    }

    /// Three days are loaded once and sliced into the entries the day still
    /// has coming: now, the evening rollover to tomorrow, and midnight — the
    /// last of which keeps the widget honest if the system is late refreshing.
    private func entries() -> [MealPlanWidgetEntry] {
        let now = Date.now
        let days = WidgetPlanLoader.days(from: now, count: 3, thumbnailBudget: 10)
        let calendar = Calendar.current
        let rollover = calendar.date(bySettingHour: rolloverHour, minute: 0, second: 0, of: now)
        let midnight = now.adding(days: 1).startOfDay

        func entry(at date: Date, leadingWith index: Int) -> MealPlanWidgetEntry {
            let slice = Array(days.dropFirst(index).prefix(2))
            return MealPlanWidgetEntry(
                date: date,
                days: slice,
                link: WidgetLink.day(slice.first?.date ?? now),
                reference: date
            )
        }

        let pastRollover = calendar.component(.hour, from: now) >= rolloverHour
        var result = [entry(at: now, leadingWith: pastRollover ? 1 : 0)]
        if let rollover, rollover > now {
            result.append(entry(at: rollover, leadingWith: 1))
        }
        result.append(entry(at: midnight, leadingWith: 1))
        return result
    }
}

struct TodayMealsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayMealsWidget", provider: TodayMealsProvider()) { entry in
            TodayMealsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(entry.link)
        }
        .configurationDisplayName(String(localized: "Today’s meals"))
        .description(String(localized: "What’s planned for today, and what’s coming tomorrow."))
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryInline,
        ])
    }
}

struct TodayMealsView: View {
    var entry: MealPlanWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var day: WidgetDay { entry.primary ?? WidgetDay(date: entry.reference.startOfDay) }
    private var title: String { day.name(relativeTo: entry.reference) }

    var body: some View {
        switch family {
        case .accessoryInline:
            inline
        case .accessoryRectangular:
            rectangular
        case .systemLarge:
            large
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // MARK: - Home screen

    private var small: some View { column(for: day, title: title, limit: 3) }

    /// Medium is wide enough for two days, which is the more useful answer
    /// than a single column of the same three meals with air beside it.
    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            column(for: day, title: title, limit: 4)
            if let next = entry.secondary {
                Divider()
                Link(destination: WidgetLink.day(next.date)) {
                    column(for: next, title: next.name(relativeTo: entry.reference), limit: 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func column(for day: WidgetDay, title: String, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: title, subtitle: day.date.widgetShortDayLabel)
            if day.isEmpty {
                NothingPlannedNote(compact: true)
            } else {
                ForEach(day.meals.prefix(limit)) { meal in
                    MealRow(meal: meal, tileSize: 22, titleFont: .system(size: 12))
                        // Grows to fill a sparse day, but only so far — three
                        // meals should not drift to the corners of the widget.
                        .frame(maxHeight: 46)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(title: title, subtitle: day.date.widgetDayLabel)

            if day.isEmpty {
                NothingPlannedNote()
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(day.meals.prefix(5)) { meal in
                        MealRow(meal: meal, tileSize: 42, titleFont: .subheadline, slotFont: .caption2.weight(.semibold))
                            .frame(maxHeight: 58)
                    }
                }
                Spacer(minLength: 0)
            }

            if let next = entry.secondary {
                Divider()
                Link(destination: WidgetLink.day(next.date)) {
                    VStack(alignment: .leading, spacing: 5) {
                        WidgetHeader(
                            title: next.name(relativeTo: entry.reference),
                            subtitle: next.date.widgetShortDayLabel
                        )
                        if next.isEmpty {
                            Text(String(localized: "Nothing planned"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(next.meals.prefix(3)) { meal in
                                MealRow(
                                    meal: meal,
                                    tileSize: 20,
                                    titleFont: .caption,
                                    slotFont: .system(size: 9, weight: .semibold)
                                )
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Lock screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.headline)
            if day.isEmpty {
                Text(String(localized: "Nothing planned")).font(.caption)
            } else {
                ForEach(day.meals.prefix(2)) { meal in
                    Text("\(meal.slotName): \(meal.title)").font(.caption).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var inline: some View {
        if let meal = day.meals.last {
            Text("\(meal.slotName) · \(meal.title)")
        } else {
            Text(String(localized: "Nothing planned"))
        }
    }
}

#Preview("Small", as: .systemSmall) {
    TodayMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sample
}

#Preview("Medium", as: .systemMedium) {
    TodayMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sample
}

#Preview("Large", as: .systemLarge) {
    TodayMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sample
}

#Preview("Lock screen", as: .accessoryRectangular) {
    TodayMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sample
}

#Preview("Inline", as: .accessoryInline) {
    TodayMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sample
}

#Preview("Nothing planned", as: .systemLarge) {
    TodayMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sampleEmpty
}
