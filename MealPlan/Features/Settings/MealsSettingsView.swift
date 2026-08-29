import SwiftUI
import SwiftData
import SFSymbolSelector

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

    var body: some View {
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
                    .swipeActions(edge: .trailing) {
                        Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                            pendingDelete = meal
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
                Text("These are the meals shown on every day of your plan. Removing one also deletes the meals already planned in it.")
            }

            Section {
                Button {
                    addMeal()
                } label: {
                    Label(String(localized: "Add meal"), systemImage: "plus")
                }
            }
        }
        .navigationTitle(String(localized: "Meals"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        #endif
        .navigationDestination(item: $newMeal) { meal in
            MealTypeEditorView(meal: meal, isNew: true)
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
    }

    private var deletePrompt: String {
        guard let meal = pendingDelete else { return "" }
        let count = MealTypeStore.plannedCount(for: meal, context: context)
        if count == 0 {
            return String(localized: "Delete “\(meal.name)”?")
        }
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
