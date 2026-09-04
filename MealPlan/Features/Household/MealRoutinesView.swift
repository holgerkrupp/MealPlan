import SwiftUI
import SwiftData

/// The family's standing arrangements — Taco Tuesday, pizza every second
/// Sunday — and the editor for one of them. Routines fill the plan a few weeks
/// ahead; each planned meal stays editable like any other, so one week's tacos
/// can be swapped without touching the routine.
@MainActor
struct MealRoutinesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @Query(sort: \MealRoutine.dateCreated) private var routines: [MealRoutine]
    @Query(sort: \Dish.name) private var dishes: [Dish]
    @Query(sort: [SortDescriptor(\MealType.sortOrder), SortDescriptor(\MealType.name)])
    private var mealTypes: [MealType]

    @State private var editing: MealRoutine?

    var body: some View {
        Form {
            Section {
                if routines.isEmpty {
                    Text(String(localized: "No regular meals yet."))
                        .foregroundStyle(.secondary)
                }
                ForEach(routines) { routine in
                    Button {
                        editing = routine
                    } label: {
                        routineRow(routine)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteAction)
            } header: {
                Text("Regular meals")
            } footer: {
                Text("Regular meals are planned \(MealRoutineScheduler.horizonWeeks) weeks ahead, and only into meals that are still empty. Change or remove a single week right in the plan — the routine keeps going.")
            }

            if !appState.isGuest {
                Section {
                    Button {
                        addRoutine()
                    } label: {
                        Label(String(localized: "Add a regular meal"), systemImage: "repeat")
                    }
                    .disabled(dishes.isEmpty)
                } footer: {
                    if dishes.isEmpty {
                        Text("Add a dish to your library first — a regular meal repeats one of your dishes.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Regular meals"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $editing) { routine in
            NavigationStack {
                MealRoutineEditor(routine: routine, dishes: dishes, mealTypes: mealTypes)
            }
            .dismissesOnOutsideClick()
        }
    }

    /// Guests can look, but not remove.
    private var deleteAction: ((IndexSet) -> Void)? {
        appState.isGuest ? nil : { offsets in delete(at: offsets) }
    }

    private func routineRow(_ routine: MealRoutine) -> some View {
        HStack(spacing: 12) {
            DishThumbnail(dish: routine.dish, size: 40, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.dish?.name ?? String(localized: "Pick a dish"))
                    .foregroundStyle(routine.dish == nil ? .secondary : .primary)
                Text("\(routine.scheduleDescription) · \(mealName(routine.mealKey))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !routine.isActive {
                Text(String(localized: "Paused"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
        .contentShape(Rectangle())
    }

    private func mealName(_ key: String) -> String {
        mealTypes.first { $0.key == key }?.name ?? MealType.legacyName(for: key)
    }

    private func addRoutine() {
        let routine = MealRoutine(
            dish: dishes.first,
            mealKey: mealTypes.first(where: { $0.key == MealSlot.dinner.rawValue })?.key
                ?? mealTypes.first?.key
                ?? MealSlot.dinner.rawValue,
            weekday: Calendar.current.component(.weekday, from: .now)
        )
        routine.household = appState.currentHousehold
        context.insert(routine)
        try? context.save()
        editing = routine
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let routine = routines[index]
            // Take the meals it already planned ahead with it; history stays.
            MealRoutineScheduler.removeFutureEntries(of: routine, context: context)
            context.delete(routine)
        }
        try? context.save()
    }
}

/// Editor for one routine: which dish, which meal, which weekday, how often.
@MainActor
struct MealRoutineEditor: View {
    @Bindable var routine: MealRoutine
    let dishes: [Dish]
    let mealTypes: [MealType]

    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private let intervals = [1, 2, 3, 4]

    var body: some View {
        Form {
            Section(String(localized: "What")) {
                Picker(String(localized: "Dish"), selection: Binding(
                    get: { routine.dish?.uuid },
                    set: { uuid in routine.dish = dishes.first { $0.uuid == uuid } }
                )) {
                    Text(String(localized: "Pick a dish")).tag(UUID?.none)
                    ForEach(dishes) { dish in
                        Text(dish.name).tag(UUID?.some(dish.uuid))
                    }
                }

                Picker(String(localized: "Meal"), selection: $routine.mealKey) {
                    if !mealTypes.contains(where: { $0.key == routine.mealKey }) {
                        Text(MealType.legacyName(for: routine.mealKey)).tag(routine.mealKey)
                    }
                    ForEach(mealTypes) { meal in
                        Label(meal.name, systemImage: meal.symbolName).tag(meal.key)
                    }
                }
            }

            Section(String(localized: "When")) {
                Picker(String(localized: "Day"), selection: $routine.weekday) {
                    ForEach(MealRoutine.localeWeekdays, id: \.self) { weekday in
                        Text(MealRoutine.weekdayName(weekday)).tag(weekday)
                    }
                }

                Picker(String(localized: "Repeats"), selection: $routine.intervalWeeks) {
                    ForEach(intervals, id: \.self) { weeks in
                        Text(intervalName(weeks)).tag(weeks)
                    }
                }

                DatePicker(
                    String(localized: "Starting"),
                    selection: $routine.startDate,
                    displayedComponents: .date
                )
            }

            Section {
                Toggle(String(localized: "Active"), isOn: $routine.isActive)
            } footer: {
                Text(summary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Regular meal"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .disabled(appState.isGuest)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { finish() }
            }
        }
    }

    private func intervalName(_ weeks: Int) -> String {
        switch weeks {
        case 1: String(localized: "Every week")
        case 2: String(localized: "Every second week")
        case 3: String(localized: "Every third week")
        default: String(localized: "Every fourth week")
        }
    }

    private var summary: String {
        guard let dish = routine.dish else {
            return String(localized: "Pick a dish to start this routine.")
        }
        let meal = mealTypes.first { $0.key == routine.mealKey }?.name
            ?? MealType.legacyName(for: routine.mealKey)
        return String(localized: "\(dish.name) for \(meal). \(routine.scheduleDescription).")
    }

    /// Save, then plan the routine's meals right away so the family sees them
    /// without waiting for the next launch.
    private func finish() {
        routine.startDate = routine.startDate.startOfDay
        // A changed schedule should re-plan from today rather than from
        // wherever the old one had already reached.
        routine.plannedThrough = nil
        try? context.save()
        MealRoutineScheduler.apply(
            routine,
            household: appState.currentHousehold,
            context: context,
            through: purchaseManager.latestPlanningDate(),
            memberName: appState.currentMemberName
        )
        dismiss()
    }
}

#Preview("Routines") {
    NavigationStack { MealRoutinesView() }
        .environment(AppState.preview)
        .environment(PurchaseManager.shared)
        .modelContainer(PreviewData.container)
}

#Preview("Routine editor") {
    NavigationStack {
        MealRoutineEditor(
            routine: PreviewData.routine,
            dishes: PreviewData.dishes,
            mealTypes: PreviewData.mealTypes
        )
    }
    .environment(AppState.preview)
    .environment(PurchaseManager.shared)
    .modelContainer(PreviewData.container)
}
