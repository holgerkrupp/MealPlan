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

    private let calendar = Date.mondayCalendar

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

    /// The meals to show for a given day: every configured meal, plus any meal
    /// key that already has an entry on that day but no `MealType` (so nothing
    /// silently disappears when a meal is deleted or synced from an old build).
    private func meals(on day: Date) -> [DayMeal] {
        var result = mealTypes.map { DayMeal(key: $0.key, name: $0.name, symbolName: $0.symbolName) }
        let known = Set(mealTypes.map(\.key))
        let orphans = Set(entries.filter { $0.date.isSameDay(as: day) }.map(\.mealKey))
            .subtracting(known)
            .subtracting([""])
        for key in orphans.sorted() {
            result.append(DayMeal(key: key, name: MealType.legacyName(for: key), symbolName: MealType.legacySymbol(for: key)))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if style == .week {
                Text(weekHeader)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            ForEach(days, id: \.self) { day in
                DayCard(day: day, onCopyLastWeek: { copyFromLastWeek(to: day) }) {
                    let dayMeals = meals(on: day)
                    if dayMeals.isEmpty {
                        Text(String(localized: "Add meals in Settings to start planning."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
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
                .id(day.dayID)
            }
        }
        .padding(.vertical, 8)
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

/// A single day's card with a highlighted header for today.
private struct DayCard<Content: View>: View {
    let day: Date
    var onCopyLastWeek: () -> Void
    @ViewBuilder var content: Content

    private var isToday: Bool { day.isSameDay(as: .now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(day.formatted(.dateTime.weekday(.wide)))
                    .font(.subheadline.weight(.semibold))
                Text(day.formatted(.dateTime.day().month()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if isToday {
                    Text(String(localized: "Today"))
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
                Menu {
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

            Divider()

            content
                .padding(12)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isToday ? Color.accentColor : .clear, lineWidth: 2)
        )
        .padding(.horizontal)
    }
}
