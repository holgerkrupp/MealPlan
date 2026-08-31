import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@MainActor
struct DishLibraryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @State private var newDish: Dish?
    @State private var editingNewDish = false
    @State private var exportedArchive: ExportedRecipeArchive?
    @State private var exportError: String?
    @State private var showingFilePicker = false
    @State private var importingFile: ImportableRecipeFile?
    @State private var importError: String?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)]

    private var filteredDishes: [Dish] {
        appState.dishFilter.apply(to: allDishes)
    }

    /// What the grid actually draws. A variant group collapses into one cell
    /// so five takes on a burger don't push everything else off the screen;
    /// the group's own screen lists them.
    private var libraryItems: [LibraryItem] {
        let groups = DishVariants.groups(in: filteredDishes)
        var seenGroups: Set<UUID> = []
        var items: [LibraryItem] = []
        for dish in filteredDishes {
            guard let groupID = dish.variantGroupID, let members = groups[groupID] else {
                items.append(.dish(dish))
                continue
            }
            guard seenGroups.insert(groupID).inserted else { continue }
            items.append(.group(
                DishVariantGroupRef(id: groupID, name: dish.variantGroupDisplayName),
                lead: members[0],
                count: members.count
            ))
        }
        return items
    }

    /// One cell in the grid: a plain dish, or a group of variants standing in
    /// for its members.
    private enum LibraryItem: Identifiable {
        case dish(Dish)
        case group(DishVariantGroupRef, lead: Dish, count: Int)

        var id: String {
            switch self {
            case .dish(let dish): "dish-\(dish.uuid)"
            case .group(let ref, _, _): "group-\(ref.id)"
            }
        }
    }

    private var tags: [String] {
        DishTag.vocabulary(from: allDishes)
    }

    /// What the strip under the search bar offers, in usage order.
    private var popularTags: [String] {
        DishTag.mostUsed(from: allDishes)
    }

    private var collections: [String] {
        Array(Set(allDishes.flatMap(\.collectionNames))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        @Bindable var appState = appState

        ScrollView {
            TagFilterStrip(filter: $appState.dishFilter, tags: popularTags)
                .padding(.top, 8)

            SeasonalSuggestionsStrip()

            if filteredDishes.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(libraryItems) { item in
                        switch item {
                        case .dish(let dish):
                            NavigationLink(value: dish) {
                                DishGridCell(dish: dish)
                            }
                            .buttonStyle(.plain)
                            .draggable(DishReference(dishUUID: dish.uuid, name: dish.name))
                        case .group(let ref, let lead, let count):
                            NavigationLink(value: ref) {
                                DishGridCell(dish: lead, variantGroupName: ref.name, variantCount: count)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(AppSection.dishes.title)
        .navigationDestination(for: Dish.self) { DishDetailView(dish: $0) }
        .navigationDestination(for: DishVariantGroupRef.self) { DishVariantGroupView(group: $0) }
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
                DishFilterMenu(
                    filter: $appState.dishFilter,
                    availableCollections: collections,
                    availableTags: tags
                )
            }
            if !appState.isGuest {
                ToolbarItem(placement: .secondaryAction) {
                    Button(String(localized: "Import recipes"), systemImage: "square.and.arrow.down") {
                        showingFilePicker = true
                    }
                }
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
        .sheet(item: $importingFile) { ImportRecipesSheet(fileURL: $0.url) }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: RecipeFileType.importableContentTypes
        ) { result in
            switch result {
            case .success(let url): importingFile = ImportableRecipeFile(url: url)
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .alert(
            String(localized: "Couldn’t import recipes"),
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
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

    /// An empty library and an empty result look nothing alike: one wants a
    /// first recipe, the other wants the filter turned off again.
    @ViewBuilder
    private var emptyState: some View {
        if allDishes.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No dishes yet"), systemImage: "fork.knife")
            } description: {
                Text("Add the meals your family likes. A name is enough to start — you can add a recipe and a photo later.")
            } actions: {
                Button(String(localized: "New dish")) { addDish() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            let hasFilters = appState.dishFilter.isActive
            ContentUnavailableView {
                Label(String(localized: "No dishes match"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(noMatchDescription)
            } actions: {
                Button(hasFilters
                       ? String(localized: "Clear filters")
                       : String(localized: "Clear search")) {
                    appState.dishFilter = DishFilter(sort: appState.dishFilter.sort)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Built with `String(localized:)` rather than two `Text` literals in a
    /// branch: those don’t make it into the string catalog.
    private var noMatchDescription: String {
        appState.dishFilter.isActive
            ? String(localized: "Nothing in your library fits the tags and filters you picked.")
            : String(localized: "Nothing in your library matches that search.")
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

/// Wraps the picked file so `.sheet(item:)` can drive the review sheet.
struct ImportableRecipeFile: Identifiable {
    let id = UUID()
    let url: URL
}

#Preview {
    NavigationStack { DishLibraryView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
