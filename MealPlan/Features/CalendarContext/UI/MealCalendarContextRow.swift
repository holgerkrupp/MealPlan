import SwiftUI

/// The one line of calendar context inside a day of the plan.
///
/// Deliberately quiet: small, secondary, at most two chips, and never larger
/// than the meals themselves. Tapping it opens the detail — the week overview
/// stays compact.
@MainActor
struct MealCalendarContextRow: View {
    let day: Date
    let meals: [DayMeal]

    @Environment(CalendarContextStore.self) private var store: CalendarContextStore?
    @State private var showingDetail = false

    private static let maxChips = 2

    private var contexts: [MealPlanningContext] {
        store?.contexts(for: day, meals: meals) ?? []
    }

    var body: some View {
        let summary = MealCalendarDaySummary(contexts: contexts)
        if !summary.isEmpty {
            Button {
                showingDetail = true
            } label: {
                HStack(spacing: 8) {
                    ForEach(summary.chips.prefix(Self.maxChips)) { chip in
                        chipLabel(chip)
                    }
                    if summary.chips.count > Self.maxChips {
                        Text("+\(summary.chips.count - Self.maxChips)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenSummary(summary))
            .accessibilityHint(String(localized: "Shows the schedule around each meal."))
            .accessibilityAddTraits(.isButton)
            .sheet(isPresented: $showingDetail) {
                MealCalendarContextSheet(day: day, summary: summary)
            }
        }
    }

    private func chipLabel(_ chip: MealCalendarDaySummary.Chip) -> some View {
        // Busyness is carried by the symbol and the words, never by colour
        // alone.
        HStack(spacing: 4) {
            Image(systemName: chip.symbolName)
                .font(.caption2)
            Text(chip.text)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private func spokenSummary(_ summary: MealCalendarDaySummary) -> String {
        let parts = summary.chips.map(\.spokenText).joined(separator: ", ")
        return String(localized: "Calendar context: \(parts).")
    }
}

/// What one day's calendar context adds up to, with each event counted once.
///
/// Meals each get their own context, but an all-day event belongs to the *day*
/// — without this, "Holiday" would show up again under breakfast, lunch and
/// dinner, and the row would read as three separate things happening.
struct MealCalendarDaySummary {

    struct Chip: Identifiable {
        let id: String
        let symbolName: String
        /// Already prefixed with the meal name when there is more than one.
        let text: String
        let spokenText: String
    }

    /// Contexts that say something about their own meal. Meals whose only
    /// content was the day's all-day events are left out.
    let mealContexts: [MealPlanningContext]
    /// The day's all-day events, listed once no matter how many meals they
    /// overlap.
    let allDayLines: [MealContextDetailLine]

    init(contexts: [MealPlanningContext]) {
        mealContexts = contexts.filter(\.hasTimedEvents)

        var seen = Set<String>()
        allDayLines = contexts
            .flatMap(\.allDayDetailLines)
            .filter { seen.insert($0.id).inserted }
    }

    var isEmpty: Bool { mealContexts.isEmpty && allDayLines.isEmpty }

    var chips: [Chip] {
        var result: [Chip] = []
        if let allDay = allDayChip { result.append(allDay) }
        let showsMealName = mealContexts.count > 1
        result += mealContexts.map { context in
            let text = showsMealName ? "\(context.mealName): \(context.summary)" : context.summary
            return Chip(
                id: context.id,
                symbolName: context.symbolName,
                text: text,
                spokenText: "\(context.mealName): \(context.summary)"
            )
        }
        return result
    }

    private var allDayChip: Chip? {
        guard !allDayLines.isEmpty else { return nil }
        let text: String
        if allDayLines.count > 1 {
            text = String(localized: "\(allDayLines.count) all-day events")
        } else if let title = allDayLines[0].title, !title.isEmpty {
            text = String(localized: "All day: \(title)")
        } else {
            text = String(localized: "All-day event")
        }
        return Chip(id: "allDay", symbolName: "calendar", text: text, spokenText: text)
    }
}

/// The progressive-disclosure detail behind a context chip. Shows exactly as
/// much as the chosen privacy level allows — never more.
@MainActor
struct MealCalendarContextSheet: View {
    let day: Date
    let summary: MealCalendarDaySummary

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // All-day events belong to the day, so they are listed here
                // once instead of under every meal they overlap.
                if !summary.allDayLines.isEmpty {
                    Section {
                        ForEach(summary.allDayLines) { line in
                            row(line)
                        }
                    } header: {
                        Text("All day")
                    }
                }

                ForEach(summary.mealContexts) { context in
                    Section {
                        ForEach(context.timedDetailLines) { line in
                            row(line)
                        }
                        ForEach(context.householdAvailability) { person in
                            Label(person.localizedSummary, systemImage: "person")
                                .font(.subheadline)
                                .accessibilityLabel(person.localizedSummary)
                        }
                        if context.hasStaggeredAvailability {
                            Label(
                                String(localized: "People are free at different times."),
                                systemImage: "arrow.left.and.right"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    } header: {
                        header(context)
                    }
                }

                Section {
                    Text("From the calendars you chose for meal planning. MealPlan never changes your calendar.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).day().month()))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The meal, what the calendar makes of it, and — when it says someone is
    /// busy — which calendar that came from.
    private func header(_ context: MealPlanningContext) -> some View {
        let busyCalendars = context.indicatesBusyTime ? context.busyCalendarNames : []
        return VStack(alignment: .leading, spacing: 2) {
            Text(context.mealName)
            Text(context.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(nil)
            if !busyCalendars.isEmpty {
                Text("Busy time from \(busyCalendars.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
    }

    private func row(_ line: MealContextDetailLine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: line.isAllDay ? "calendar" : "clock")
                .foregroundStyle(.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                if let title = line.title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline)
                }
                Text(line.timeText)
                    .font(line.title == nil ? .subheadline : .caption)
                    .foregroundStyle(line.title == nil ? .primary : .secondary)
                if let calendarText = line.calendarText {
                    HStack(spacing: 5) {
                        CalendarColorDot(color: line.calendarColor, size: 8)
                        Text(calendarText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.spokenText)
    }
}
