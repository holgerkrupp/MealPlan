import SwiftUI
import SwiftData
import CollaborationCore

/// The household's pantry staples — the things the family always has at home.
///
/// This is a family setting rather than a personal one, so it lives under
/// Household next to the regular meals: everyone shares one shopping list, and
/// what counts as "always in stock" has to be the same for all of them.
///
/// Staples never come out of the plan onto the shopping list. When one runs
/// out, the cart button here (or "Add a staple" on the list itself) puts it on
/// by hand, as a manual line that survives the next rebuild.
@MainActor
struct PantryStaplesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @Query(sort: \Ingredient.name) private var ingredients: [Ingredient]
    @Query private var shoppingItems: [ShoppingListItem]

    @State private var searchText = ""
    @State private var managedPantry: ManagedPantrySnapshot?
    @State private var managedError: String?

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matches(_ ingredient: Ingredient) -> Bool {
        trimmedSearch.isEmpty || ingredient.name.localizedCaseInsensitiveContains(trimmedSearch)
    }

    private var staples: [Ingredient] {
        ingredients.filter { $0.isPantryStaple && matches($0) }
    }

    /// Everything else in the household's catalogue — the ingredients recipes
    /// and shopping lines have brought in — so a staple can be picked rather
    /// than typed.
    private var candidates: [Ingredient] {
        ingredients.filter { !$0.isPantryStaple && matches($0) }
    }

    /// The search text, when it isn't already an ingredient: offered as a new
    /// staple so something the family has never cooked with can be added too.
    private var newStapleName: String? {
        let name = trimmedSearch
        guard !name.isEmpty else { return nil }
        guard IngredientMatching.match(name, in: ingredients) == nil else { return nil }
        return name
    }

    private var managedMode: Bool {
        guard let householdID = appState.currentHousehold?.uuid else { return false }
        return ManagedHouseholdRolloutAuthority.shared.usesManagedWriter(for: householdID)
    }

    private var legacyCanEdit: Bool { !appState.isGuest && appState.currentHousehold != nil }

    private var managedCanEdit: Bool {
        guard managedMode,
              let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return false }
        let access = collaboration.effectiveAccess(for: householdID)
        return access == .owner || access == .editor
    }

    private var canEdit: Bool { managedMode ? managedCanEdit : legacyCanEdit }

    private var managedStaples: [ManagedPantryIngredientSummary] {
        (managedPantry?.ingredients ?? []).filter { $0.isPantryStaple && managedMatches($0) }
    }

    private var managedCandidates: [ManagedPantryIngredientSummary] {
        (managedPantry?.ingredients ?? []).filter { !$0.isPantryStaple && managedMatches($0) }
    }

    private var managedNewStapleName: String? {
        let name = trimmedSearch
        guard !name.isEmpty, let managedPantry,
              IngredientMatching.matchID(
                name,
                in: managedPantry.ingredients.map(\.matchValue),
                rules: managedPantry.matchRules
              ) == nil else { return nil }
        return name
    }

    private func managedMatches(_ ingredient: ManagedPantryIngredientSummary) -> Bool {
        trimmedSearch.isEmpty || ingredient.name.localizedCaseInsensitiveContains(trimmedSearch)
    }

    /// Guests can look, but not change what the family keeps in.
    private var deleteAction: ((IndexSet) -> Void)? {
        canEdit ? { offsets in removeStaples(at: offsets) } : nil
    }

    var body: some View {
        Group {
            if managedMode {
                managedContent
            } else {
                legacyContent
            }
        }
        .searchable(text: $searchText, prompt: String(localized: "Search or add an ingredient"))
        .navigationTitle(String(localized: "Pantry staples"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: "\(appState.currentHousehold?.uuid.uuidString ?? "none")-\(managedMode)-\(appState.managedCollaboration != nil)") {
            reloadManagedPantry()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mealPlanManagedStoreDidChange)) { _ in
            reloadManagedPantry()
        }
        .alert(String(localized: "Pantry update failed"), isPresented: Binding(
            get: { managedError != nil },
            set: { if !$0 { managedError = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) { managedError = nil }
        } message: {
            Text(managedError ?? String(localized: "Please try again."))
        }
    }

    private var legacyContent: some View {
        List {
            Section {
                if staples.isEmpty {
                    Text(trimmedSearch.isEmpty
                         ? String(localized: "No staples yet.")
                         : String(localized: "No staples match “\(trimmedSearch)”."))
                        .foregroundStyle(.secondary)
                }
                ForEach(staples) { ingredient in
                    stapleRow(ingredient)
                }
                .onDelete(perform: deleteAction)
            } header: {
                Text("Always at home")
            } footer: {
                Text("Staples are left off the shopping list when it's rebuilt from the plan. Run out of one? Put it on the list yourself with the cart button.")
            }

            if legacyCanEdit, let newStapleName {
                Section {
                    Button {
                        addNewStaple(named: newStapleName)
                    } label: {
                        Label(String(localized: "Add “\(newStapleName)”"), systemImage: "plus.circle")
                    }
                }
            }

            if legacyCanEdit, !candidates.isEmpty {
                Section {
                    ForEach(candidates) { ingredient in
                        Button {
                            mark(ingredient, isStaple: true)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ingredient.name)
                                        .foregroundStyle(.primary)
                                    Text(ingredient.aisleName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("From your recipes and lists")
                } footer: {
                    Text("Everything your dishes and shopping lists have used so far. Pick the ones you always keep in.")
                }
            }
        }
    }

    private var managedContent: some View {
        List {
            Section {
                if managedStaples.isEmpty {
                    Text(trimmedSearch.isEmpty
                         ? String(localized: "No staples yet.")
                         : String(localized: "No staples match “\(trimmedSearch)”."))
                        .foregroundStyle(.secondary)
                }
                ForEach(managedStaples) { ingredient in
                    managedStapleRow(ingredient)
                }
                .onDelete(perform: managedCanEdit ? { offsets in removeManagedStaples(at: offsets) } : nil)
            } header: {
                Text("Always at home")
            } footer: {
                Text("Staples are left off the shopping list when it's rebuilt from the plan. Run out of one? Put it on the list yourself with the cart button.")
            }

            if managedCanEdit, let managedNewStapleName {
                Section {
                    Button {
                        addManagedStaple(named: managedNewStapleName)
                    } label: {
                        Label(String(localized: "Add “\(managedNewStapleName)”"), systemImage: "plus.circle")
                    }
                }
            }

            if managedCanEdit, !managedCandidates.isEmpty {
                Section {
                    ForEach(managedCandidates) { ingredient in
                        Button {
                            setManagedStaple(ingredient, isStaple: true)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ingredient.name).foregroundStyle(.primary)
                                    Text(ingredient.aisleName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("From your recipes and lists")
                } footer: {
                    Text("Everything your dishes and shopping lists have used so far. Pick the ones you always keep in.")
                }
            }
        }
        .overlay {
            if managedPantry == nil && managedError == nil {
                ProgressView()
            } else if managedPantry == nil, let managedError {
                ContentUnavailableView {
                    Label(String(localized: "Pantry unavailable"), systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(managedError)
                } actions: {
                    Button(String(localized: "Try again")) { reloadManagedPantry() }
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func stapleRow(_ ingredient: Ingredient) -> some View {
        let onList = isOnShoppingList(ingredient)

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ingredient.name)
                Text(ingredient.aisleName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if onList {
                Label(String(localized: "On the list"), systemImage: "cart.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "On the shopping list"))
            } else if canEdit {
                Button {
                    addToShoppingList(ingredient)
                } label: {
                    Image(systemName: "cart.badge.plus")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Add to the shopping list"))
                .accessibilityLabel(String(localized: "Add \(ingredient.name) to the shopping list"))
            }
        }
        .contextMenu {
            if canEdit {
                if !onList {
                    Button {
                        addToShoppingList(ingredient)
                    } label: {
                        Label(String(localized: "Add to the shopping list"), systemImage: "cart.badge.plus")
                    }
                }
                Button(role: .destructive) {
                    mark(ingredient, isStaple: false)
                } label: {
                    Label(String(localized: "Not a staple"), systemImage: "minus.circle")
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if canEdit {
                Button(role: .destructive) {
                    mark(ingredient, isStaple: false)
                } label: {
                    Label(String(localized: "Not a staple"), systemImage: "minus.circle")
                }
            }
        }
    }

    // MARK: - Actions

    private func isOnShoppingList(_ ingredient: Ingredient) -> Bool {
        let key = IngredientMatching.key(for: ingredient.name)
        return shoppingItems.contains { IngredientMatching.key(for: $0.name) == key }
    }

    private func mark(_ ingredient: Ingredient, isStaple: Bool) {
        ingredient.isPantryStaple = isStaple
        try? context.save()
    }

    private func removeStaples(at offsets: IndexSet) {
        let list = staples
        for index in offsets where list.indices.contains(index) {
            list[index].isPantryStaple = false
        }
        try? context.save()
    }

    private func addNewStaple(named name: String) {
        guard let household = appState.currentHousehold else { return }
        PantryStaples.add(named: name, to: household, context: context)
        try? context.save()
        searchText = ""
    }

    private func addToShoppingList(_ ingredient: Ingredient) {
        guard let household = appState.currentHousehold else { return }
        ShoppingListBuilder.addManualItem(for: ingredient, household: household, context: context)
    }

    // MARK: - Managed household actions

    private func managedIsOnShoppingList(_ ingredient: ManagedPantryIngredientSummary) -> Bool {
        managedPantry?.shoppingItemKeys.contains(IngredientMatching.key(for: ingredient.name)) ?? false
    }

    @ViewBuilder
    private func managedStapleRow(_ ingredient: ManagedPantryIngredientSummary) -> some View {
        let onList = managedIsOnShoppingList(ingredient)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ingredient.name)
                Text(ingredient.aisleName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if onList {
                Label(String(localized: "On the list"), systemImage: "cart.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "On the shopping list"))
            } else if managedCanEdit {
                Button {
                    addManagedStapleToShoppingList(ingredient)
                } label: {
                    Image(systemName: "cart.badge.plus")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Add to the shopping list"))
                .accessibilityLabel(String(localized: "Add \(ingredient.name) to the shopping list"))
            }
        }
        .contextMenu {
            if managedCanEdit {
                if !onList {
                    Button {
                        addManagedStapleToShoppingList(ingredient)
                    } label: {
                        Label(String(localized: "Add to the shopping list"), systemImage: "cart.badge.plus")
                    }
                }
                Button(role: .destructive) {
                    setManagedStaple(ingredient, isStaple: false)
                } label: {
                    Label(String(localized: "Not a staple"), systemImage: "minus.circle")
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if managedCanEdit {
                Button(role: .destructive) {
                    setManagedStaple(ingredient, isStaple: false)
                } label: {
                    Label(String(localized: "Not a staple"), systemImage: "minus.circle")
                }
            }
        }
    }

    private func reloadManagedPantry() {
        guard managedMode else {
            managedPantry = nil
            managedError = nil
            return
        }
        guard let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else {
            managedPantry = nil
            return
        }
        do {
            managedPantry = try collaboration.pantrySnapshot(for: householdID)
            managedError = nil
        } catch {
            managedPantry = nil
            managedError = error.localizedDescription
        }
    }

    private func setManagedStaple(_ ingredient: ManagedPantryIngredientSummary, isStaple: Bool) {
        guard let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return }
        do {
            try collaboration.setPantryStaple(isStaple, ingredientID: ingredient.id, in: householdID)
            reloadManagedPantry()
        } catch {
            managedError = error.localizedDescription
        }
    }

    private func removeManagedStaples(at offsets: IndexSet) {
        let list = managedStaples
        for index in offsets where list.indices.contains(index) {
            setManagedStaple(list[index], isStaple: false)
        }
    }

    private func addManagedStaple(named name: String) {
        guard let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return }
        do {
            try collaboration.addPantryStaple(named: name, in: householdID)
            searchText = ""
            reloadManagedPantry()
        } catch {
            managedError = error.localizedDescription
        }
    }

    private func addManagedStapleToShoppingList(_ ingredient: ManagedPantryIngredientSummary) {
        guard let householdID = appState.currentHousehold?.uuid,
              let collaboration = appState.managedCollaboration else { return }
        do {
            try collaboration.addPantryStapleToShoppingList(ingredientID: ingredient.id, in: householdID)
            reloadManagedPantry()
        } catch {
            managedError = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { PantryStaplesView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
