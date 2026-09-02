import WidgetKit
import SwiftUI

struct UpcomingMealsProvider: TimelineProvider {

    func placeholder(in context: Context) -> MealPlanWidgetEntry { .sampleUpcoming }

    func getSnapshot(in context: Context, completion: @escaping (MealPlanWidgetEntry) -> Void) {
        completion(context.isPreview ? .sampleUpcoming : entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MealPlanWidgetEntry>) -> Void) {
        let midnight = Date.now.adding(days: 1).startOfDay
        completion(Timeline(entries: [entry()], policy: .after(midnight)))
    }

    /// Unlike the other two this one skips over empty days, so a plan with a
    /// gap in it still fills the widget with the meals that come after it.
    private func entry() -> MealPlanWidgetEntry {
        let now = Date.now
        let days = WidgetPlanLoader.upcoming(from: now, limit: 8, thumbnailBudget: 10)
        return MealPlanWidgetEntry(
            date: now,
            days: days,
            link: WidgetLink.day(days.first?.date ?? now),
            reference: now
        )
    }
}

struct UpcomingMealsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UpcomingMealsWidget", provider: UpcomingMealsProvider()) { entry in
            UpcomingMealsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(entry.link)
        }
        .configurationDisplayName(String(localized: "Coming up"))
        .description(String(localized: "The next meals on the plan, skipping the days you haven’t filled in."))
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryInline,
        ])
    }
}

struct UpcomingMealsView: View {
    var entry: MealPlanWidgetEntry
    @Environment(\.widgetFamily) private var family

    /// Every meal in order, tagged with the day it falls on.
    private var meals: [(day: WidgetDay, meal: WidgetMeal)] { entry.flattened }

    var body: some View {
        switch family {
        case .accessoryInline:
            inline
        case .accessoryRectangular:
            rectangular
        case .systemLarge:
            grouped
        default:
            flat
        }
    }

    // MARK: - Home screen

    /// Small and medium: a plain run of meals, each labelled with its day.
    private var flat: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: String(localized: "Coming up"), symbol: "calendar")
            if meals.isEmpty {
                NothingPlannedNote()
            } else {
                ForEach(meals.prefix(family == .systemSmall ? 3 : 4), id: \.meal.id) { pair in
                    MealRow(
                        meal: pair.meal,
                        tileSize: family == .systemSmall ? 22 : 26,
                        titleFont: family == .systemSmall ? .system(size: 12) : .caption,
                        slotText: label(for: pair.day, meal: pair.meal)
                    )
                    .frame(maxHeight: 46)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Days that actually hold something. The loader already drops the empty
    /// ones, but a placeholder entry need not have.
    private var plannedDays: [WidgetDay] { entry.days.filter { !$0.isEmpty } }

    /// Large: the same run, but broken into day sections so the shape of the
    /// week ahead is visible.
    private var grouped: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: String(localized: "Coming up"), symbol: "calendar")
            if plannedDays.isEmpty {
                NothingPlannedNote(text: String(localized: "Nothing planned for the next few weeks"))
            } else {
                ForEach(plannedDays.trimmed(toRows: 11)) { day in
                    Link(destination: WidgetLink.day(day.date)) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text(day.name(relativeTo: entry.reference))
                                    .font(.caption.weight(.semibold))
                                Text(day.date.widgetShortDayLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            ForEach(day.meals) { meal in
                                MealRow(meal: meal, tileSize: 24, titleFont: .subheadline)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Lock screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(String(localized: "Coming up")).font(.headline)
            if meals.isEmpty {
                Text(String(localized: "Nothing planned")).font(.caption)
            } else {
                ForEach(meals.prefix(2), id: \.meal.id) { pair in
                    Text("\(label(for: pair.day, meal: pair.meal)): \(pair.meal.title)")
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var inline: some View {
        if let pair = meals.first {
            Text("\(label(for: pair.day, meal: pair.meal)) · \(pair.meal.title)")
        } else {
            Text(String(localized: "Nothing planned"))
        }
    }

    // MARK: -

    /// "Today · Dinner" for the next couple of days, "Thu · Dinner" after that.
    private func label(for day: WidgetDay, meal: WidgetMeal) -> String {
        let dayName = day.isToday(relativeTo: entry.reference)
            ? day.name(relativeTo: entry.reference)
            : day.shortName
        return "\(dayName) · \(meal.slotName)"
    }
}

#Preview("Small", as: .systemSmall) {
    UpcomingMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sampleUpcoming
}

#Preview("Medium", as: .systemMedium) {
    UpcomingMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sampleUpcoming
}

#Preview("Large", as: .systemLarge) {
    UpcomingMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sampleUpcoming
}

#Preview("Lock screen", as: .accessoryRectangular) {
    UpcomingMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sampleUpcoming
}

#Preview("Inline", as: .accessoryInline) {
    UpcomingMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sampleUpcoming
}

#Preview("Nothing planned", as: .systemMedium) {
    UpcomingMealsWidget()
} timeline: {
    MealPlanWidgetEntry.sampleEmpty
}
