import SwiftUI
import SwiftData

@MainActor
struct WeekSectionView: View {
    let weekStart: Date
    let style: CalendarStyle

    @Query private var entries: [MealPlanEntry]
    @Query(sort: [SortDescriptor(\MealType.sortOrder), SortDescriptor(\MealType.name)])
    private var mealTypes: [MealType]
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    /// Optional: absent in previews and whenever calendar integration is off.
    @Environment(CalendarContextStore.self) private var calendarStore: CalendarContextStore?

    private let calendar = Date.mondayCalendar
    /// Keep meal cards in two equal-width cells. An adaptive column is allowed
    /// to grow from a card's ideal content width, which lets long dish names
    /// make one card extend into the next column.
    private let mealColumns = [
        GridItem(.flexible(minimum: 0), spacing: 10),
        GridItem(.flexible(minimum: 0), spacing: 10),
    ]

    init(weekStart: Date, style: CalendarStyle) {
        self.weekStart = weekStart
        self.style = style
        let end = weekStart.adding(weeks: 1)
        _entries = Query(
            filter: #Predicate<MealPlanEntry> { $0.date >= weekStart && $0.date < end },
            sort: \MealPlanEntry.sortIndex
        )
    }

    private var days: [Date] {
        (0..<7).map { weekStart.adding(days: $0) }
    }

    private func entries(on day: Date, mealKey: String) -> [MealPlanEntry] {
        entries
            .filter { $0.date.isSameDay(as: day) && $0.mealKey == mealKey }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    /// The queried meals with duplicate `key`s collapsed.
    ///
    /// CloudKit has no unique constraint, so a store can hold two "lunch"
    /// meals — two devices seeding the defaults before their first sync, or a
    /// duplicated household. `MealType.ensure` collapses them at launch; this
    /// is the guard for a duplicate that syncs in mid-session, because left in
    /// they collide on `DayMeal.id`: the grid reserves a row per element while
    /// `ForEach` draws only one card per id, so the day ends in an empty band
    /// the height of a meal row. Same survivor rule as `ensure` (smallest uuid
    /// string), kept at its first position in order.
    private var uniqueMealTypes: [MealType] {
        var winners: [String: MealType] = [:]
        var order: [String] = []
        for meal in mealTypes {
            guard let existing = winners[meal.key] else {
                winners[meal.key] = meal
                order.append(meal.key)
                continue
            }
            if meal.uuid.uuidString < existing.uuid.uuidString { winners[meal.key] = meal }
        }
        return order.compactMap { winners[$0] }
    }

    /// The meals to show for a given day: every configured meal, plus any meal
    /// key that already has an entry on that day but no `MealType` (so nothing
    /// silently disappears when a meal is deleted or synced from an old build).
    private func meals(on day: Date) -> [DayMeal] {
        let types = uniqueMealTypes
        var result = types.map { DayMeal(key: $0.key, name: $0.name, symbolName: $0.symbolName) }
        let known = Set(types.map(\.key))
        let orphans = Set(entries.filter { $0.date.isSameDay(as: day) }.map(\.mealKey))
            .subtracting(known)
            .subtracting([""])
        for key in orphans.sorted() {
            result.append(DayMeal(key: key, name: MealType.legacyName(for: key), symbolName: MealType.legacySymbol(for: key)))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if style == .week {
                Text(weekHeader)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            ForEach(days, id: \.self) { day in
                DayCard(
                    day: day,
                    isCollapsed: appState.isDayCollapsed(day),
                    onToggleCollapse: { appState.setDayCollapsed(!appState.isDayCollapsed(day), for: day) },
                    onCopyLastWeek: { copyFromLastWeek(to: day) }
                ) {
                    let dayMeals = meals(on: day)
                    if dayMeals.isEmpty {
                        Text(String(localized: "Add meals in Settings to start planning."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            // Calendar context sits above the meals and stays
                            // visually secondary to them.
                            MealCalendarContextRow(day: day, meals: dayMeals)

                            LazyVGrid(
                                columns: mealColumns,
                                alignment: .leading,
                                spacing: 10
                            ) {
                                ForEach(dayMeals) { meal in
                                    MealCard(
                                        date: day,
                                        mealKey: meal.key,
                                        title: meal.name,
                                        symbolName: meal.symbolName,
                                        entries: entries(on: day, mealKey: meal.key)
                                    )
                                }
                            }
                        }
                    }
                }
                .id(day.dayID)
                // Feeds the week strip's glass pill. `onDisappear` matters:
                // the lazy stack can tear a card down without a final
                // visibility callback.
                .onScrollVisibilityChange(threshold: 0.05) { visible in
                    appState.setDayVisible(visible, id: day.dayID)
                }
                .onDisappear { appState.setDayVisible(false, id: day.dayID) }
            }
        }
        .padding(.vertical, 8)
        .task {
            // Tell the calendar layer which week is on screen, so it only ever
            // queries the days the planner actually shows.
            calendarStore?.requestWeek(weekStart)
        }
    }

    private func copyFromLastWeek(to day: Date) {
        MealPlanner.copyDay(
            from: day.adding(weeks: -1), to: day,
            household: appState.currentHousehold,
            memberName: appState.currentMemberName,
            context: context
        )
    }

    private var weekHeader: String {
        let week = calendar.component(.weekOfYear, from: weekStart)
        let end = weekStart.adding(days: 6)
        let df = DateFormatter()
        df.locale = .current
        df.setLocalizedDateFormatFromTemplate("dMMM")
        return String(localized: "Week \(week) · \(df.string(from: weekStart)) – \(df.string(from: end))")
    }
}

/// A meal to render inside one day, resolved from a `MealType` (or a legacy
/// meal key that only exists on entries).
struct DayMeal: Identifiable {
    let key: String
    let name: String
    let symbolName: String
    var id: String { key }
}

/// A single day's card with a highlighted header for today. Tapping the date
/// collapses the day down to just its header, so weeks that are only partly
/// planned don't have to be scrolled through.
private struct DayCard<Content: View>: View {
    let day: Date
    var isCollapsed: Bool
    var onToggleCollapse: () -> Void
    var onCopyLastWeek: () -> Void
    @ViewBuilder var content: Content

    private var isToday: Bool { day.isSameDay(as: .now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onToggleCollapse) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        Text(day.formatted(.dateTime.weekday(.wide)))
                            .font(.subheadline.weight(.semibold))
                        Text(day.formatted(.dateTime.day().month()))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isCollapsed
                    ? String(localized: "Expands this day")
                    : String(localized: "Collapses this day"))

                if isToday {
                    Text(String(localized: "Today"))
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
                Menu {
                    Button(
                        isCollapsed ? String(localized: "Expand day") : String(localized: "Collapse day"),
                        systemImage: isCollapsed ? "chevron.down" : "chevron.up"
                    ) {
                        onToggleCollapse()
                    }
                    Button(String(localized: "Copy from last week"), systemImage: "arrow.uturn.backward") {
                        onCopyLastWeek()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !isCollapsed {
                Divider()

                content
                    .padding(10)
            }
        }
        .animation(.snappy, value: isCollapsed)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isToday ? Color.accentColor : .clear, lineWidth: 2)
        )
        .padding(.horizontal)
    }
}

#Preview("Week") {
    PreviewCalendarHost {
        ScrollView {
            WeekSectionView(weekStart: Date.now.startOfWeek(), style: .week)
                .padding()
        }
    }
    .environment(AppState.preview)
    .modelContainer(PreviewData.container)
}

#Preview("Day card") {
    VStack(spacing: 12) {
        DayCard(day: .now, isCollapsed: false, onToggleCollapse: {}, onCopyLastWeek: {}) {
            Text(verbatim: "…").padding()
        }
        DayCard(day: Date.now.adding(days: 1), isCollapsed: true, onToggleCollapse: {}, onCopyLastWeek: {}) {
            Text(verbatim: "…").padding()
        }
    }
    .padding()
}
