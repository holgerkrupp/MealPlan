import SwiftUI
import SwiftData

@MainActor
struct DishLibraryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @State private var newDish: Dish?
    @State private var editingNewDish = false
    @State private var exportedArchive: ExportedRecipeArchive?
    @State private var exportError: String?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)]

    private var filteredDishes: [Dish] {
        appState.dishFilter.apply(to: allDishes)
    }

    private var collections: [String] {
        Array(Set(allDishes.flatMap(\.collectionNames))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        @Bindable var appState = appState

        ScrollView {
            SeasonalSuggestionsStrip()

            if filteredDishes.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filteredDishes) { dish in
                        NavigationLink(value: dish) {
                            DishGridCell(dish: dish)
                        }
                        .buttonStyle(.plain)
                        .draggable(DishReference(dishUUID: dish.uuid, name: dish.name))
                    }
                }
                .padding()
            }
        }
        .navigationTitle(AppSection.dishes.title)
        .navigationDestination(for: Dish.self) { DishDetailView(dish: $0) }
        .searchable(
            text: $appState.dishFilter.searchText,
            prompt: String(localized: "Search dishes")
        )
        .toolbar {
            if !appState.isGuest {
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "New dish"), systemImage: "plus") {
                        addDish()
                    }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                DishFilterMenu(filter: $appState.dishFilter, availableCollections: collections)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Export all recipes"), systemImage: "square.and.arrow.up") {
                    do {
                        exportedArchive = ExportedRecipeArchive(
                            url: try MealPlanRecipeArchive.temporaryFile(for: allDishes)
                        )
                    } catch {
                        exportError = error.localizedDescription
                    }
                }
                .disabled(allDishes.isEmpty)
            }
        }
        .sheet(isPresented: $editingNewDish) {
            if let newDish {
                NavigationStack {
                    DishEditorView(dish: newDish, isNew: true)
                }
            }
        }
        .sheet(item: $exportedArchive) { RecipeArchiveShareSheet(archive: $0) }
        .alert(
            String(localized: "Couldn’t export recipes"),
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .task(id: appState.pendingAddDish?.id) {
            guard let request = appState.pendingAddDish else { return }
            appState.pendingAddDish = nil
            await handleAddRequest(request)
        }
    }

    private func handleAddRequest(_ request: AppState.PendingAddDish) async {
        if let url = request.url {
            let recipe = (try? await RecipeSchemaParser().importRecipe(from: url))
                ?? ImportedRecipe(name: request.name ?? url.host() ?? String(localized: "New dish"), sourceURL: url)
            let dish = DishBuilder.makeDish(
                from: recipe, household: appState.currentHousehold,
                createdByName: appState.currentMemberName, context: context
            )
            newDish = dish
            editingNewDish = true
        } else {
            let dish = Dish(name: request.name ?? "")
            dish.household = appState.currentHousehold
            dish.createdByName = appState.currentMemberName
            dish.refreshAutoGlyph()
            context.insert(dish)
            newDish = dish
            editingNewDish = true
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No dishes yet"), systemImage: "fork.knife")
        } description: {
            Text("Add the meals your family likes. A name is enough to start — you can add a recipe and a photo later.")
        } actions: {
            Button(String(localized: "New dish")) { addDish() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func addDish() {
        let dish = Dish(name: "")
        dish.household = appState.currentHousehold
        dish.createdByName = appState.currentMemberName
        dish.refreshAutoGlyph()
        context.insert(dish)
        newDish = dish
        editingNewDish = true
    }
}

#Preview {
    NavigationStack { DishLibraryView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
