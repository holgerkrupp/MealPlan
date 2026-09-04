import SwiftUI
import SwiftData

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
        let normalized = Ingredient.normalize(name)
        guard !ingredients.contains(where: { $0.normalizedName == normalized }) else { return nil }
        return name
    }

    private var canEdit: Bool { !appState.isGuest && appState.currentHousehold != nil }

    /// Guests can look, but not change what the family keeps in.
    private var deleteAction: ((IndexSet) -> Void)? {
        canEdit ? { offsets in removeStaples(at: offsets) } : nil
    }

    var body: some View {
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

            if canEdit, let newStapleName {
                Section {
                    Button {
                        addNewStaple(named: newStapleName)
                    } label: {
                        Label(String(localized: "Add “\(newStapleName)”"), systemImage: "plus.circle")
                    }
                }
            }

            if canEdit, !candidates.isEmpty {
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
        .searchable(text: $searchText, prompt: String(localized: "Search or add an ingredient"))
        .navigationTitle(String(localized: "Pantry staples"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
        shoppingItems.contains { $0.normalizedName == ingredient.normalizedName }
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
}

#Preview {
    NavigationStack { PantryStaplesView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
