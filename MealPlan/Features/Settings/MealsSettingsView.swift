import SwiftUI
import SwiftData
import SFSymbolSelector
import CollaborationCore

/// Manage the household's meals (Breakfast, Lunch, Dinner, …). Users can
/// rename, reorder, add and remove them — nothing assumes a fixed set.
@MainActor
struct MealsSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\MealType.sortOrder), SortDescriptor(\MealType.name)])
    private var meals: [MealType]

    @State private var pendingDelete: MealType?
    @State private var newMeal: MealType?
    @State private var managedMeals: [ManagedMealTypeChoice]?
    @State private var managedEditing: ManagedMealTypeChoice?
    @State private var managedPendingDelete: ManagedMealTypeChoice?
    @State private var managedNewMealID: UUID?
    @State private var managedError: String?

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

    var body: some View {
        Group {
            if managedMode {
                managedContent
            } else {
                legacyContent
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Meals"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if managedMode && managedCanEdit {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            } else if !managedMode {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        #endif
        .navigationDestination(item: $newMeal) { meal in
            MealTypeEditorView(meal: meal, isNew: true)
        }
        .sheet(item: $managedEditing) { meal in
            NavigationStack {
                ManagedMealTypeEditorView(
                    meal: meal,
                    isNew: managedNewMealID == meal.id,
                    onSave: { name, symbolName in saveManagedMeal(meal, name: name, symbolName: symbolName) },
                    onDelete: { requestManagedDelete(meal) }
                )
            }
            .dismissesOnOutsideClick()
        }
        .onChange(of: managedEditing) { _, editing in
            if editing == nil { managedNewMealID = nil }
        }
        .confirmationDialog(
            deletePrompt,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete meal"), role: .destructive) {
                if let meal = pendingDelete {
                    MealTypeStore.delete(meal, context: context, appState: appState)
                }
                pendingDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { pendingDelete = nil }
        }
        .confirmationDialog(
            managedDeletePrompt,
            isPresented: Binding(get: { managedPendingDelete != nil }, set: { if !$0 { managedPendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete meal"), role: .destructive) {
                if let meal = managedPendingDelete { deleteManagedMeal(meal) }
                managedPendingDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { managedPendingDelete = nil }
        }
        .task(id: "\(appState.currentHousehold?.uuid.uuidString ?? "none")-\(managedMode)-\(appState.managedCollaboration != nil)") {
            reloadManagedMeals()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mealPlanManagedStoreDidChange)) { _ in
            reloadManagedMeals()
        }
        .alert(String(localized: "Meals unavailable"), isPresented: Binding(
            get: { managedError != nil }, set: { if !$0 { managedError = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) { managedError = nil }
        } message: {
            Text(managedError ?? String(localized: "Please try again."))
        }
    }

    private var legacyContent: some View {
        List {
            Section {
                ForEach(meals) { meal in
                    NavigationLink {
                        MealTypeEditorView(meal: meal)
                    } label: {
                        Label {
                            Text(meal.name.isEmpty ? String(localized: "Untitled meal") : meal.name)
                                .foregroundStyle(meal.name.isEmpty ? .secondary : .primary)
                        } icon: {
                            Image(systemName: meal.symbolName)
                                .foregroundStyle(.tint)
                        }
                    }
                    .contextMenu {
                        Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                            pendingDelete = meal
                        }
                    }
                }
                .onDelete(perform: requestDelete)
                .onMove(perform: move)
            } footer: {
                Text("These are the meals shown on every day of your plan. Removing one also deletes the meals already planned in it. For a one-off occasion, plan an extra from the day’s menu instead of adding a meal here.")
            }

            Section {
                Button {
                    addMeal()
                } label: {
                    Label(String(localized: "Add meal"), systemImage: "plus")
                }
            }
        }
    }

    private var managedContent: some View {
        List {
            managedMealSection
            managedAddSection
        }
    }

    private var managedMealSection: some View {
        Section {
            if managedMeals == nil {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                ForEach(managedMeals ?? []) { meal in
                    managedMealRow(meal)
                }
                .onMove(perform: moveManagedMeals)
                .onDelete(perform: requestManagedDelete)
            }
        } footer: {
            Text("These are the meals shown on every day of your plan. Removing one also deletes the meals already planned in it. For a one-off occasion, plan an extra from the day’s menu instead of adding a meal here.")
        }
    }

    @ViewBuilder
    private func managedMealRow(_ meal: ManagedMealTypeChoice) -> some View {
        Button { managedEditing = meal } label: {
            Label {
                Text(meal.name.isEmpty ? String(localized: "Untitled meal") : meal.name)
                    .foregroundStyle(meal.name.isEmpty ? .secondary : .primary)
            } icon: {
                Image(systemName: meal.symbolName.isEmpty ? "fork.knife" : meal.symbolName)
                    .foregroundStyle(.tint)
            }
        }
        .buttonStyle(.plain)
        .disabled(!managedCanEdit)
        .swipeActions(edge: .trailing) {
            if managedCanEdit {
                Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                    managedPendingDelete = meal
                }
            }
        }
        .contextMenu {
            if managedCanEdit {
                Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                    managedPendingDelete = meal
                }
            }
        }
    }

    @ViewBuilder
    private var managedAddSection: some View {
        if managedCanEdit {
            Section {
                Button(action: addManagedMeal) {
                    Label(String(localized: "Add meal"), systemImage: "plus")
                }
            }
        }
    }

    private var deletePrompt: String {
        guard let meal = pendingDelete else { return "" }
        let count = MealTypeStore.plannedCount(for: meal, context: context)
        if count == 0 {
            return String(localized: "Delete “\(meal.name)”?")
        }
        return String(localized: "Delete “\(meal.name)” and its \(count) planned meal(s)?")
    }

    private var managedDeletePrompt: String {
        guard let meal = managedPendingDelete else { return "" }
        let count = managedPlannedCount(for: meal)
        if count == 0 { return String(localized: "Delete “\(meal.name)”? ") }
        return String(localized: "Delete “\(meal.name)” and its \(count) planned meal(s)?")
    }

    // MARK: - Mutations

    private func addMeal() {
        let meal = MealType(
            key: UUID().uuidString,
            name: "",
            symbolName: "fork.knife",
            sortOrder: (meals.map(\.sortOrder).max() ?? -1) + 1
        )
        meal.household = appState.currentHousehold
        context.insert(meal)
        try? context.save()
        newMeal = meal
    }

    private func requestDelete(_ offsets: IndexSet) {
        guard let index = offsets.first else { return }
        pendingDelete = meals[index]
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = meals
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, meal) in ordered.enumerated() {
            meal.sortOrder = index
        }
        try? context.save()
        SharedStore.reloadWidgets()
    }

    private func reloadManagedMeals() {
        guard managedMode, let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else {
            managedMeals = nil
            managedError = nil
            return
        }
        do {
            managedMeals = try collaboration.mealTypeSnapshot(for: householdID)
            managedError = nil
        } catch {
            managedMeals = nil
            managedError = error.localizedDescription
        }
    }

    private func addManagedMeal() {
        guard managedCanEdit, let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return }
        do {
            let meal = try collaboration.addManagedMealType(in: householdID)
            managedMeals = try collaboration.mealTypeSnapshot(for: householdID)
            managedNewMealID = meal.id
            managedEditing = meal
        } catch {
            managedError = error.localizedDescription
        }
    }

    private func saveManagedMeal(_ meal: ManagedMealTypeChoice, name: String, symbolName: String) {
        guard managedCanEdit, let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return }
        do {
            try collaboration.updateManagedMealType(meal, name: name, symbolName: symbolName, in: householdID)
            managedMeals = try collaboration.mealTypeSnapshot(for: householdID)
        } catch {
            managedError = error.localizedDescription
        }
    }

    private func moveManagedMeals(from source: IndexSet, to destination: Int) {
        guard managedCanEdit, var ordered = managedMeals,
              let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return }
        ordered.move(fromOffsets: source, toOffset: destination)
        do {
            try collaboration.reorderManagedMealTypes(ordered, in: householdID)
            managedMeals = try collaboration.mealTypeSnapshot(for: householdID)
        } catch {
            managedError = error.localizedDescription
        }
    }

    private func requestManagedDelete(_ offsets: IndexSet) {
        guard managedCanEdit, let index = offsets.first, let managedMeals,
              managedMeals.indices.contains(index) else { return }
        managedPendingDelete = managedMeals[index]
    }

    private func requestManagedDelete(_ meal: ManagedMealTypeChoice) {
        managedEditing = nil
        managedPendingDelete = meal
    }

    private func managedPlannedCount(for meal: ManagedMealTypeChoice) -> Int {
        guard let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return 0 }
        return (try? collaboration.managedPlannedMealCount(for: meal.key, in: householdID)) ?? 0
    }

    private func deleteManagedMeal(_ meal: ManagedMealTypeChoice) {
        guard managedCanEdit, let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return }
        do {
            try collaboration.deleteManagedMealType(meal.id, in: householdID)
            managedMeals = try collaboration.mealTypeSnapshot(for: householdID)
        } catch {
            managedError = error.localizedDescription
        }
    }
}

@MainActor
private struct ManagedMealTypeEditorView: View {
    let meal: ManagedMealTypeChoice
    let isNew: Bool
    let onSave: (String, String) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbolName: String

    init(
        meal: ManagedMealTypeChoice,
        isNew: Bool,
        onSave: @escaping (String, String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.meal = meal
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: meal.name)
        _symbolName = State(initialValue: meal.symbolName)
    }

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "Meal name"), text: $name)
                    .onSubmit(save)
            }

            Section(String(localized: "Icon")) {
                HStack {
                    Image(systemName: symbolName.isEmpty ? "fork.knife" : symbolName)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 36)
                    Text(name.isEmpty ? String(localized: "Preview") : name)
                        .foregroundStyle(.secondary)
                }
                SFSymbolSelector(selection: $symbolName, suggestedSymbolName: symbolName)
            }

            Section {
                Button(String(localized: "Delete meal"), systemImage: "trash", role: .destructive) {
                    onDelete()
                }
            }
        }
        .navigationTitle(isNew ? String(localized: "New meal") : String(localized: "Edit meal"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: symbolName) { save() }
        .onDisappear {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = String(localized: "New meal")
            }
            save()
        }
    }

    private func save() {
        onSave(name, symbolName.isEmpty ? "fork.knife" : symbolName)
    }
}

/// Rename a meal, choose its icon, or delete it.
@MainActor
struct MealTypeEditorView: View {
    @Bindable var meal: MealType
    var isNew = false

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "Meal name"), text: $meal.name)
                    .onSubmit { save() }
            }

            Section(String(localized: "Icon")) {
                HStack {
                    Image(systemName: meal.symbolName.isEmpty ? "fork.knife" : meal.symbolName)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 36)
                    Text(meal.name.isEmpty ? String(localized: "Preview") : meal.name)
                        .foregroundStyle(.secondary)
                }
                SFSymbolSelector(
                    selection: $meal.symbolName,
                    suggestedSymbolName: meal.symbolName
                )
            }

            Section {
                Button(String(localized: "Delete meal"), systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
            }
        }
        .navigationTitle(isNew ? String(localized: "New meal") : String(localized: "Edit meal"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: meal.symbolName) { save() }
        .onDisappear {
            if meal.isDeleted { return }
            if meal.name.trimmingCharacters(in: .whitespaces).isEmpty {
                meal.name = String(localized: "New meal")
            }
            save()
        }
        .confirmationDialog(
            deletePrompt,
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete meal"), role: .destructive) {
                MealTypeStore.delete(meal, context: context, appState: appState)
                dismiss()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }

    private var deletePrompt: String {
        let count = MealTypeStore.plannedCount(for: meal, context: context)
        if count == 0 { return String(localized: "Delete “\(meal.name)”?") }
        return String(localized: "Delete “\(meal.name)” and its \(count) planned meal(s)?")
    }

    private func save() {
        guard !meal.isDeleted else { return }
        try? context.save()
    }
}

/// Shared meal-deletion logic (used from the list, swipe, context menu and the
/// editor), including cleanup of the meals already planned in that slot.
@MainActor
enum MealTypeStore {

    static func plannedCount(for meal: MealType, context: ModelContext) -> Int {
        let key = meal.key
        return (try? context.fetchCount(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.mealSlotRaw == key }
        ))) ?? 0
    }

    static func delete(_ meal: MealType, context: ModelContext, appState: AppState) {
        let key = meal.key
        let orphaned = (try? context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.mealSlotRaw == key }
        ))) ?? []
        orphaned.forEach(context.delete)
        context.delete(meal)
        try? context.save()
        SharedStore.reloadWidgets()

        if !orphaned.isEmpty {
            let undo = context.undoManager
            appState.offerUndo(String(localized: "Deleted “\(meal.name)”")) {
                undo?.undo(); try? context.save()
            }
        }
    }
}

#Preview {
    NavigationStack { MealsSettingsView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}

#Preview("Meal editor") {
    NavigationStack { MealTypeEditorView(meal: PreviewData.mealType) }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
