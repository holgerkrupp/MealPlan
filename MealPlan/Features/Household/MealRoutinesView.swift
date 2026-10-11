import SwiftUI
import SwiftData
import CollaborationCore

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
    @State private var managedEditing: ManagedMealRoutineDraft?
    @State private var managedSnapshot: ManagedMealRoutineSnapshot?
    @State private var managedError: String?

    var body: some View {
        Group {
            if managedMode {
                managedContent
            } else {
                legacyContent
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
        .sheet(item: $managedEditing) { draft in
            NavigationStack {
                ManagedMealRoutineEditor(
                    routine: draft,
                    dishes: managedSnapshot?.dishes ?? [],
                    mealTypes: managedSnapshot?.mealTypes ?? [],
                    onSave: { updated, horizon, memberName in
                        saveManagedRoutine(updated, through: horizon, memberName: memberName)
                    }
                )
            }
            .dismissesOnOutsideClick()
        }
        .task(id: "\(appState.currentHousehold?.uuid.uuidString ?? "none")-\(managedMode)-\(appState.managedCollaboration != nil)") {
            reloadManagedRoutines(schedule: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mealPlanManagedStoreDidChange)) { _ in
            reloadManagedRoutines(schedule: false)
        }
        .alert(String(localized: "Regular meals unavailable"), isPresented: Binding(
            get: { managedError != nil }, set: { if !$0 { managedError = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) { managedError = nil }
        } message: {
            Text(managedError ?? String(localized: "Please try again."))
        }
    }

    private var managedMode: Bool {
        guard let householdID = appState.currentHousehold?.uuid else { return false }
        return ManagedHouseholdRolloutAuthority.shared.usesManagedWriter(for: householdID)
    }

    private var managedCanEdit: Bool {
        guard managedMode, let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return false }
        let access = collaboration.effectiveAccess(for: householdID)
        return access == .owner || access == .editor
    }

    private var legacyContent: some View {
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
    }

    private var managedContent: some View {
        Form {
            Section {
                if (managedSnapshot?.routines ?? []).isEmpty {
                    Text(String(localized: "No regular meals yet."))
                        .foregroundStyle(.secondary)
                }
                ForEach(managedSnapshot?.routines ?? []) { routine in
                    Button {
                        managedEditing = ManagedMealRoutineDraft(
                            id: routine.id,
                            dishID: routine.dishID,
                            mealKey: routine.mealKey,
                            weekday: routine.weekday,
                            intervalWeeks: routine.intervalWeeks,
                            startDate: routine.startDate,
                            isActive: routine.isActive
                        )
                    } label: {
                        managedRoutineRow(routine)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: managedCanEdit ? { offsets in deleteManaged(at: offsets) } : nil)
            } header: {
                Text("Regular meals")
            } footer: {
                Text("Regular meals are planned \(MealRoutineScheduler.horizonWeeks) weeks ahead, and only into meals that are still empty. Change or remove a single week right in the plan — the routine keeps going.")
            }

            if managedCanEdit {
                Section {
                    Button(action: addManagedRoutine) {
                        Label(String(localized: "Add a regular meal"), systemImage: "repeat")
                    }
                    .disabled((managedSnapshot?.dishes ?? []).isEmpty)
                } footer: {
                    if (managedSnapshot?.dishes ?? []).isEmpty {
                        Text("Add a dish to your library first — a regular meal repeats one of your dishes.")
                    }
                }
            }
        }
        .overlay {
            if managedSnapshot == nil && managedError == nil {
                ProgressView()
            } else if managedSnapshot == nil, let managedError {
                ContentUnavailableView {
                    Label(String(localized: "Regular meals unavailable"), systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(managedError)
                } actions: {
                    Button(String(localized: "Try again")) { reloadManagedRoutines(schedule: false) }
                }
            }
        }
    }

    private func managedRoutineRow(_ routine: ManagedMealRoutineSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "repeat")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.dishName ?? String(localized: "Pick a dish"))
                    .foregroundStyle(routine.dishName == nil ? .secondary : .primary)
                Text("\(routine.scheduleDescription) · \(managedMealName(routine.mealKey))")
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

    private func managedMealName(_ key: String) -> String {
        managedSnapshot?.mealTypes.first { $0.key == key }?.name ?? MealType.legacyName(for: key)
    }

    private func reloadManagedRoutines(schedule: Bool) {
        guard managedMode else {
            managedSnapshot = nil
            managedError = nil
            return
        }
        guard let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else {
            managedSnapshot = nil
            return
        }
        do {
            if schedule && managedCanEdit {
                try collaboration.applyManagedMealRoutines(
                    for: householdID,
                    through: PurchaseManager.shared.latestPlanningDate(),
                    memberName: appState.currentMemberName
                )
            }
            managedSnapshot = try collaboration.mealRoutineSnapshot(for: householdID)
            managedError = nil
        } catch {
            managedSnapshot = nil
            managedError = error.localizedDescription
        }
    }

    private func addManagedRoutine() {
        guard let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return }
        do {
            managedEditing = try collaboration.addManagedMealRoutine(in: householdID)
            managedSnapshot = try collaboration.mealRoutineSnapshot(for: householdID)
            managedError = nil
        } catch {
            managedError = error.localizedDescription
        }
    }

    private func saveManagedRoutine(
        _ draft: ManagedMealRoutineDraft,
        through horizon: Date?,
        memberName: String
    ) -> String? {
        guard let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else {
            return String(localized: "The household is not available.")
        }
        do {
            try collaboration.saveManagedMealRoutine(draft, in: householdID, through: horizon, memberName: memberName)
            managedSnapshot = try collaboration.mealRoutineSnapshot(for: householdID)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func deleteManaged(at offsets: IndexSet) {
        guard let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return }
        let routines = managedSnapshot?.routines ?? []
        do {
            for index in offsets where routines.indices.contains(index) {
                try collaboration.deleteManagedMealRoutine(routines[index].id, in: householdID)
            }
            managedSnapshot = try collaboration.mealRoutineSnapshot(for: householdID)
        } catch {
            managedError = error.localizedDescription
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

@MainActor
private struct ManagedMealRoutineEditor: View {
    @State private var draft: ManagedMealRoutineDraft
    let dishes: [ManagedDishChoice]
    let mealTypes: [ManagedMealTypeChoice]
    let onSave: (ManagedMealRoutineDraft, Date?, String) -> String?

    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    private let intervals = [1, 2, 3, 4]

    init(
        routine: ManagedMealRoutineDraft,
        dishes: [ManagedDishChoice],
        mealTypes: [ManagedMealTypeChoice],
        onSave: @escaping (ManagedMealRoutineDraft, Date?, String) -> String?
    ) {
        _draft = State(initialValue: routine)
        self.dishes = dishes
        self.mealTypes = mealTypes
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section(String(localized: "What")) {
                Picker(String(localized: "Dish"), selection: $draft.dishID) {
                    Text(String(localized: "Pick a dish")).tag(UUID?.none)
                    ForEach(dishes) { dish in
                        Text(dish.name).tag(UUID?.some(dish.id))
                    }
                }
                Picker(String(localized: "Meal"), selection: $draft.mealKey) {
                    if !mealTypes.contains(where: { $0.key == draft.mealKey }) {
                        Text(MealType.legacyName(for: draft.mealKey)).tag(draft.mealKey)
                    }
                    ForEach(mealTypes) { meal in
                        Label(meal.name, systemImage: meal.symbolName).tag(meal.key)
                    }
                }
            }

            Section(String(localized: "When")) {
                Picker(String(localized: "Day"), selection: $draft.weekday) {
                    ForEach(MealRoutine.localeWeekdays, id: \.self) { weekday in
                        Text(MealRoutine.weekdayName(weekday)).tag(weekday)
                    }
                }
                Picker(String(localized: "Repeats"), selection: $draft.intervalWeeks) {
                    ForEach(intervals, id: \.self) { weeks in
                        Text(intervalName(weeks)).tag(weeks)
                    }
                }
                DatePicker(String(localized: "Starting"), selection: $draft.startDate, displayedComponents: .date)
            }

            Section {
                Toggle(String(localized: "Active"), isOn: $draft.isActive)
            } footer: {
                Text(summary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Regular meal"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done"), action: finish)
            }
        }
        .alert(String(localized: "Couldn’t save regular meal"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? String(localized: "Please try again."))
        }
    }

    private var summary: String {
        guard let dish = dishes.first(where: { $0.id == draft.dishID }) else {
            return String(localized: "Pick a dish to start this routine.")
        }
        let meal = mealTypes.first { $0.key == draft.mealKey }?.name ?? MealType.legacyName(for: draft.mealKey)
        let routine = MealRoutine(dish: nil, mealKey: draft.mealKey, weekday: draft.weekday, intervalWeeks: draft.intervalWeeks, startDate: draft.startDate)
        return String(localized: "\(dish.name) for \(meal). \(routine.scheduleDescription).")
    }

    private func intervalName(_ weeks: Int) -> String {
        switch weeks {
        case 1: String(localized: "Every week")
        case 2: String(localized: "Every second week")
        case 3: String(localized: "Every third week")
        default: String(localized: "Every fourth week")
        }
    }

    private func finish() {
        draft.startDate = draft.startDate.startOfDay
        if let error = onSave(draft, purchaseManager.latestPlanningDate(), appState.currentMemberName) {
            errorMessage = error
        } else {
            dismiss()
        }
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
