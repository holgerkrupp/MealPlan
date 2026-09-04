import SwiftUI
import SwiftData

/// The plan stripe as used inside the app's planning sheets: a horizontally
/// scrolling band of upcoming days with a progress ring around each date and
/// one square per meal, so you can see which days are full and assign a dish
/// straight into a slot.
///
/// Two modes:
///
/// * **planning** — `planningDish` is set. Tapping a square plans that dish
///   there right away (with undo); the sheet stays open so the same dish can go
///   onto several days.
/// * **rescheduling** — `reschedulingEntry` is set. Tapping a square moves that
///   entry there.
///
/// Either way the tapped day + meal is written back through the bindings so the
/// rest of the sheet (servings, ingredients, note) stays in step. The drawing
/// and scrolling live in `MealPlannerStripCore`, shared with the Share
/// Extension.
@MainActor
struct MealPlannerStrip: View {
    var planningDish: Dish?
    /// Applied to meals planned through the strip (planning mode only).
    var planServings: Int?
    var planNote: String?
    var reschedulingEntry: MealPlanEntry?
    @Binding var selectedDate: Date
    @Binding var selectedMealKey: String

    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.modelContext) private var context

    @Query(sort: [SortDescriptor(\MealType.sortOrder), SortDescriptor(\MealType.name)])
    private var mealTypes: [MealType]
    /// Every entry from a fortnight ago onward. The floor is fixed at init so
    /// the query identity never changes as the strip grows; a household's plan
    /// is small enough to group in memory.
    @Query private var entries: [MealPlanEntry]
    @State private var showingPaywall = false

    private static let pastDays = 14

    init(
        planningDish: Dish? = nil,
        planServings: Int? = nil,
        planNote: String? = nil,
        reschedulingEntry: MealPlanEntry? = nil,
        selectedDate: Binding<Date>,
        selectedMealKey: Binding<String>
    ) {
        self.planningDish = planningDish
        self.planServings = planServings
        self.planNote = planNote
        self.reschedulingEntry = reschedulingEntry
        _selectedDate = selectedDate
        _selectedMealKey = selectedMealKey

        let floor = Date.now.startOfDay.adding(days: -Self.pastDays)
        _entries = Query(
            filter: #Predicate<MealPlanEntry> { $0.date >= floor },
            sort: \MealPlanEntry.date
        )
    }

    private var slots: [MealStripSlot] {
        mealTypes.map { MealStripSlot(key: $0.key, name: $0.name, symbolName: $0.symbolName) }
    }

    private var entrySlot: (day: Date, key: String)? {
        reschedulingEntry.map { ($0.date, $0.mealKey) }
    }

    /// Meal keys that already have at least one (non-skipped) entry, per day.
    private func plannedKeys(on day: Date) -> Set<String> {
        Set(
            entries
                .filter { $0.date.isSameDay(as: day) && !$0.skipped }
                .map(\.mealKey)
        )
    }

    var body: some View {
        MealPlannerStripCore(
            slots: slots,
            plannedKeys: plannedKeys(on:),
            entrySlot: entrySlot,
            selectedDate: $selectedDate,
            selectedMealKey: $selectedMealKey,
            onSelect: assign(to:mealKey:),
            isDateLocked: { !purchaseManager.canPlan(on: $0) },
            onSelectLockedDate: { _ in showingPaywall = true },
            isDisabled: appState.isGuest,
            selectHint: reschedulingEntry != nil
                ? String(localized: "Moves this meal here")
                : String(localized: "Plans this dish here")
        )
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
                .dismissesOnOutsideClick()
        }
    }

    // MARK: - Assign

    private func assign(to day: Date, mealKey: String) {
        guard !appState.isGuest else { return }
        guard purchaseManager.canPlan(on: day) else {
            showingPaywall = true
            return
        }
        selectedDate = day.startOfDay
        selectedMealKey = mealKey

        if let entry = reschedulingEntry {
            MealPlanner.move(
                entry, to: day, mealKey: mealKey,
                memberName: appState.currentMemberName, context: context
            )
            return
        }

        guard let dish = planningDish else { return }
        let entry = MealPlanner.plan(
            dish: dish, on: day, mealKey: mealKey,
            servings: planServings, note: planNote,
            household: appState.currentHousehold,
            memberName: appState.currentMemberName,
            context: context
        )
        let title = dish.name
        let when = day.formatted(.dateTime.weekday(.abbreviated).day())
        appState.offerUndo(String(localized: "Planned “\(title)” for \(when)")) {
            context.delete(entry)
            try? context.save()
            SharedStore.reloadWidgets()
        }
    }
}

#Preview {
    @Previewable @State var date = Date.now.startOfDay
    @Previewable @State var mealKey = "dinner"

    return MealPlannerStrip(
        planningDish: PreviewData.household.dishes?.first,
        selectedDate: $date,
        selectedMealKey: $mealKey
    )
    .environment(AppState.preview)
    .environment(PurchaseManager.shared)
    .modelContainer(PreviewData.container)
    .padding()
}
