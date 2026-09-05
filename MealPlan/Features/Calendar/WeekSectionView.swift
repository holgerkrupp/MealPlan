import SwiftUI
import SwiftData

@MainActor
struct WeekSectionView: View {
    let weekStart: Date
    let style: CalendarStyle
    let mealTypes: [MealType]
    let entries: [MealPlanEntry]
    var onDayVisibilityChange: (Bool, String) -> Void

    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.modelContext) private var context
    /// Optional: absent in previews and whenever calendar integration is off.
    @Environment(CalendarContextStore.self) private var calendarStore: CalendarContextStore?
    @State private var showingPaywall = false
    @State private var nutritionSummary: WeekNutritionSummary?
    /// The day whose "plan an extra" picker is up. Presented from here rather
    /// than from a meal card: a day with no extra yet has no card to tap.
    @State private var extraPickerDay: IdentifiableDate?
    /// Raised by the picker when a freshly added dish wants its recipe filled
    /// in; owned here for the same reason as in `MealCard`.
    @State private var newDishToEdit: Dish?

    private let calendar = Date.mondayCalendar
    /// Keep meal cards in two equal-width cells. An adaptive column is allowed
    /// to grow from a card's ideal content width, which lets long dish names
    /// make one card extend into the next column.
    private let mealColumns = [
        GridItem(.flexible(minimum: 0), spacing: 10),
        GridItem(.flexible(minimum: 0), spacing: 10),
    ]

    init(
        weekStart: Date,
        style: CalendarStyle,
        mealTypes: [MealType] = [],
        entries: [MealPlanEntry] = [],
        onDayVisibilityChange: @escaping (Bool, String) -> Void = { _, _ in }
    ) {
        self.weekStart = weekStart
        self.style = style
        self.mealTypes = mealTypes
        self.entries = entries
        self.onDayVisibilityChange = onDayVisibilityChange
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

    /// The meals to show for a given day. See `DayMeal.forDay`.
    private func meals(on day: Date) -> [DayMeal] {
        DayMeal.forDay(
            mealTypes: uniqueMealTypes,
            plannedKeys: Set(entries.filter { $0.date.isSameDay(as: day) }.map(\.mealKey))
        )
    }

    var body: some View {
        // Built once per redraw rather than per day: a day's standing is
        // relative to the whole week, so every card needs the same summary.
        let nutrition = nutritionSummary

        return VStack(alignment: .leading, spacing: 10) {
            if style == .week {
                Text(weekHeader)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            ForEach(days, id: \.self) { day in
                if !purchaseManager.isUnlocked,
                   day.isSameDay(as: PlanningAccess.latestFreeDate().adding(days: 1)) {
                    Button { showingPaywall = true } label: {
                        Label(
                            String(localized: "Unlimited planning starts here"),
                            systemImage: "lock.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                    .accessibilityHint(String(localized: "Unlock to plan this day and later dates."))
                }
                DayCard(
                    day: day,
                    isCollapsed: appState.isDayCollapsed(day),
                    isPlanningLocked: !purchaseManager.canPlan(on: day),
                    nutrition: nutrition?.estimate(on: day),
                    nutritionStanding: nutrition?.standing(on: day),
                    energyUnit: appState.energyUnit,
                    onToggleCollapse: { appState.setDayCollapsed(!appState.isDayCollapsed(day), for: day) },
                    onUnlock: { showingPaywall = true },
                    onCopyLastWeek: { copyFromLastWeek(to: day) },
                    onAddExtra: addExtraAction(for: day),
                    onDropDish: { handleDrop($0, on: day) }
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
                            // visually secondary to them. Extras are left out:
                            // they have no time window of their own, so they
                            // would only repeat a real meal's chip.
                            MealCalendarContextRow(day: day, meals: dayMeals.filter { !$0.isExtra })

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
                                        entries: entries(on: day, mealKey: meal.key),
                                        nutritionSummary: nutrition
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
                    onDayVisibilityChange(visible, day.dayID)
                }
                .onDisappear { onDayVisibilityChange(false, day.dayID) }
            }
        }
        .padding(.vertical, 8)
        .task {
            // Tell the calendar layer which week is on screen, so it only ever
            // queries the days the planner actually shows.
            calendarStore?.requestWeek(weekStart)
        }
        .task(id: nutritionCacheKey) {
            guard appState.showsNutritionEstimates else {
                nutritionSummary = nil
                return
            }
            // Let scrolling settle before doing recipe math. SwiftUI cancels
            // this task when a week leaves the lazy stack, so fast scrolling
            // does not spend time calculating summaries nobody will see.
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            nutritionSummary = WeekNutritionSummary(entries: entries)
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
                .dismissesOnOutsideClick()
        }
        .sheet(item: $extraPickerDay) { wrapper in
            DishPickerView(
                date: wrapper.date,
                mealKey: MealType.extraKey,
                mealTitle: MealType.extraName,
                mealSymbol: MealType.extraSymbolName,
                onEditNewDish: { newDishToEdit = $0 }
            )
            .dismissesOnOutsideClick()
        }
        .sheet(item: $newDishToEdit) { dish in
            NavigationStack { DishEditorView(dish: dish, isNew: true) }
                .dismissesOnOutsideClick()
        }
    }

    /// Cheap revision key for the expensive ingredient-based calculation.
    /// Scroll visibility changes do not alter it, so they no longer rebuild
    /// nutrition for every week on screen.
    private var nutritionCacheKey: Int {
        guard appState.showsNutritionEstimates else { return 0 }
        var hasher = Hasher()
        hasher.combine(entries.count)
        for entry in entries {
            // These are scalar columns already present in the plan fetch.
            // Walking every ingredient relationship here defeated the delay
            // below and faulted recipe data during scroll-time rendering.
            hasher.combine(entry.uuid)
            hasher.combine(entry.modifiedAt)
            hasher.combine(entry.servingsOverride)
            hasher.combine(entry.skipped)
            hasher.combine(entry.dish?.uuid)
            hasher.combine(entry.dish?.modifiedAt)
        }
        return hasher.finalize()
    }

    /// A drop on the day's header, rather than on one of its meal cards: the
    /// meal keeps the meal it was planned in and only changes day, which is
    /// what dragging a card onto a day reads as. It is also the only way to
    /// drop onto a collapsed day, whose meal cards aren't on screen.
    private func handleDrop(_ references: [DishReference], on day: Date) -> Bool {
        guard !appState.isGuest, let reference = references.first else { return false }
        guard purchaseManager.canPlan(on: day) else {
            showingPaywall = true
            return false
        }
        return MealPlanner.drop(
            reference, onto: day, mealKey: nil,
            household: appState.currentHousehold,
            memberName: appState.currentMemberName,
            context: context
        )
    }

    /// The day menu's "plan an extra" action, or nil for a guest, who can read
    /// the plan but not add to it.
    private func addExtraAction(for day: Date) -> (() -> Void)? {
        guard !appState.isGuest else { return nil }
        return { planExtra(on: day) }
    }

    /// Plan a dish onto `day` without giving it one of the household's meals.
    /// The card it lands in shows up on this day only.
    private func planExtra(on day: Date) {
        guard purchaseManager.canPlan(on: day) else {
            showingPaywall = true
            return
        }
        extraPickerDay = IdentifiableDate(date: day)
    }

    private func copyFromLastWeek(to day: Date) {
        guard purchaseManager.canPlan(on: day) else {
            showingPaywall = true
            return
        }
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

/// A meal to render inside one day, resolved from a `MealType` (or a meal key
/// that only exists on entries: an extra, or a meal that has since been
/// deleted).
struct DayMeal: Identifiable {
    let key: String
    let name: String
    let symbolName: String
    var id: String { key }

    /// Whether this card is only there because the day has something in it —
    /// true for extras, which never show on a day nobody planned one for.
    var isExtra: Bool { MealType.isExtra(key) }
}

extension DayMeal {

    /// The cards one day shows: every configured meal, then any meal key that
    /// already has an entry on that day but no `MealType`, so nothing planned
    /// silently disappears when a meal is deleted or synced from an old build.
    ///
    /// Extras (`MealType.extraKey`) come last and only on the days that have
    /// one: a dish can be planned outside the household's meals without every
    /// other day growing a card for it.
    ///
    /// Pure, so it can be tested without a `ModelContext`.
    static func forDay(mealTypes: [MealType], plannedKeys: Set<String>) -> [DayMeal] {
        var result = mealTypes.map { DayMeal(key: $0.key, name: $0.name, symbolName: $0.symbolName) }
        let orphans = plannedKeys
            .subtracting(mealTypes.map(\.key))
            .subtracting([MealType.extraKey, ""])
        for key in orphans.sorted() {
            result.append(DayMeal(key: key, name: MealType.legacyName(for: key), symbolName: MealType.legacySymbol(for: key)))
        }
        if plannedKeys.contains(MealType.extraKey) {
            result.append(DayMeal(
                key: MealType.extraKey,
                name: MealType.extraName,
                symbolName: MealType.extraSymbolName
            ))
        }
        return result
    }
}

/// A single day's card with a highlighted header for today. Tapping the date
/// collapses the day down to just its header, so weeks that are only partly
/// planned don't have to be scrolled through.
private struct DayCard<Content: View>: View {
    let day: Date
    var isCollapsed: Bool
    var isPlanningLocked: Bool = false
    /// The day's estimate for one person, when nutrition is switched on and
    /// the day has enough planned to say anything.
    var nutrition: NutritionEstimate? = nil
    var nutritionStanding: NutritionDayStanding? = nil
    var energyUnit: EnergyUnit = .kilocalories
    var onToggleCollapse: () -> Void
    var onUnlock: () -> Void = {}
    var onCopyLastWeek: () -> Void
    /// Plans a dish on this day outside the household's meals. Nil for guests,
    /// who can look at the plan but not change it.
    var onAddExtra: (() -> Void)? = nil
    /// Handles a meal dragged onto the day's header. Returns false when there
    /// is nothing to do, so the drag animates back.
    var onDropDish: ([DishReference]) -> Bool = { _ in false }
    @ViewBuilder var content: Content

    @State private var isDropTargeted = false

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
                if isPlanningLocked {
                    Button(action: onUnlock) {
                        Label(String(localized: "Unlock App"), systemImage: "lock.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint(String(localized: "Unlocks planning beyond the next 7 days"))
                }
                if let nutrition {
                    DayNutritionBadge(
                        estimate: nutrition,
                        standing: nutritionStanding,
                        unit: energyUnit
                    )
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
                    .disabled(isPlanningLocked)
                    if let onAddExtra {
                        Button(String(localized: "Plan an extra…"), systemImage: MealType.extraSymbolName) {
                            onAddExtra()
                        }
                        .disabled(isPlanningLocked)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Dropping a meal on the day itself moves it to this day and
            // leaves it in its own meal. Collapsed days accept drops too —
            // their header is all there is to aim at.
            .background {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .padding(.horizontal, 4)
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: DishReference.self) { references, _ in
                onDropDish(references)
            } isTargeted: { isDropTargeted = $0 }

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
                .strokeBorder(
                    isDropTargeted || isToday ? Color.accentColor : .clear,
                    lineWidth: isDropTargeted ? 3 : 2
                )
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
    .environment(PurchaseManager.shared)
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
