import SwiftUI
import SwiftData

/// What the household has at home, by where it's kept.
///
/// A regular screen on every device, built on the inventory fields each
/// `Ingredient` already carries — the same ones the shopping-list rebuild
/// subtracts from. Nothing here asks for a complete stock-take: only
/// ingredients someone chose to track (or marked as a staple) are listed,
/// and the search field starts tracking anything else in one tap.
@MainActor
struct PantryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @Query(sort: \Ingredient.name) private var allIngredients: [Ingredient]
    @Query(sort: \ShoppingListItem.sortIndex) private var allShoppingItems: [ShoppingListItem]

    @State private var searchText = ""
    @State private var filter: PantryLocationFilter = .all
    @State private var showingBarcodeScanner = false

    private var household: Household? { appState.currentHousehold }
    private var householdID: UUID? { household?.uuid }
    private var canEdit: Bool { PantryActions.canEdit(household, isGuest: appState.isGuest) }

    private var ingredients: [Ingredient] {
        allIngredients.filter { $0.household?.uuid == householdID }
    }

    private var shoppingItems: [ShoppingListItem] {
        allShoppingItems.filter { $0.household?.uuid == householdID }
    }

    private var groups: [PantryInventory.Group] {
        PantryInventory.groups(ingredients, filter: filter, search: searchText)
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The search text, when no ingredient in the catalogue is called that.
    private var newIngredientName: String? {
        guard !trimmedSearch.isEmpty,
              IngredientMatching.match(trimmedSearch, in: ingredients) == nil else { return nil }
        return trimmedSearch
    }

    private var filterLocation: InventoryStorageLocation? {
        if case .location(let location) = filter { return location }
        return nil
    }

    var body: some View {
        List {
            Section {
                Picker(String(localized: "Storage location"), selection: $filter) {
                    ForEach(PantryLocationFilter.allCases) { Text($0.localizedName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if groups.isEmpty, trimmedSearch.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Nothing tracked yet"), systemImage: AppSection.pantry.symbol)
                } description: {
                    Text("Search for an ingredient to start tracking it. Only what you choose to track is listed here — no need for a complete stock-take.")
                }
            }

            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.ingredients) { ingredient in
                        row(ingredient)
                    }
                }
            }

            if canEdit, !trimmedSearch.isEmpty {
                startTrackingSection
            }
        }
        .searchable(text: $searchText, prompt: String(localized: "Search or add an ingredient"))
        .navigationTitle(AppSection.pantry.title)
        .toolbar {
            if canEdit, BarcodeScanAvailability.isAvailable {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingBarcodeScanner = true
                    } label: {
                        Label(String(localized: "Scan barcode"), systemImage: "barcode.viewfinder")
                    }
                }
            }
        }
        .sheet(isPresented: $showingBarcodeScanner) {
            BarcodeAddSheet(defaultDestination: .pantry, location: filterLocation)
        }
        .macWindowMargins()
    }

    // MARK: - Rows

    private func row(_ ingredient: Ingredient) -> some View {
        NavigationLink {
            PantryItemEditor(ingredient: ingredient)
        } label: {
            PantryRowLabel(
                ingredient: ingredient,
                system: appState.unitSystem,
                isOnShoppingList: PantryActions.isOnShoppingList(ingredient, items: shoppingItems)
            )
        }
        .swipeActions(edge: .leading) {
            if canEdit {
                Button {
                    PantryActions.setMode(.have, for: ingredient, household: household, context: context)
                } label: {
                    Label(InventoryMode.have.localizedName, systemImage: "checkmark.circle")
                }
                .tint(.green)
                if ingredient.inventoryQuantity?.dimension == .count {
                    Button {
                        PantryActions.useOne(ingredient, household: household, context: context)
                    } label: {
                        Label(String(localized: "Used one"), systemImage: "minus.circle")
                    }
                    .tint(.indigo)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if canEdit {
                Button {
                    PantryActions.markUsedUp(ingredient, household: household, context: context)
                } label: {
                    Label(String(localized: "Used up"), systemImage: "xmark.circle")
                }
                .tint(.orange)
                if !PantryActions.isOnShoppingList(ingredient, items: shoppingItems) {
                    Button {
                        addToShoppingList(ingredient)
                    } label: {
                        Label(String(localized: "Add to shopping list"), systemImage: "cart.badge.plus")
                    }
                    .tint(.blue)
                }
            }
        }
        .contextMenu {
            if canEdit {
                Picker(String(localized: "Inventory"), selection: Binding(
                    get: { ingredient.inventoryMode },
                    set: { PantryActions.setMode($0, for: ingredient, household: household, context: context) }
                )) {
                    ForEach([InventoryMode.have, .low, .out]) { Text($0.localizedName).tag($0) }
                }
                if ingredient.inventoryQuantity?.dimension == .count {
                    Button(String(localized: "Used one"), systemImage: "minus.circle") {
                        PantryActions.useOne(ingredient, household: household, context: context)
                    }
                }
                Button(String(localized: "Used up"), systemImage: "xmark.circle") {
                    PantryActions.markUsedUp(ingredient, household: household, context: context)
                }
                if !PantryActions.isOnShoppingList(ingredient, items: shoppingItems) {
                    Button(String(localized: "Add to shopping list"), systemImage: "cart.badge.plus") {
                        addToShoppingList(ingredient)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var startTrackingSection: some View {
        let untracked = PantryInventory.untrackedMatches(ingredients, search: searchText)
        if newIngredientName != nil || !untracked.isEmpty {
            Section {
                if let newIngredientName {
                    Button {
                        startTracking(named: newIngredientName)
                    } label: {
                        Label(String(localized: "Add “\(newIngredientName)” to the pantry"), systemImage: "plus.circle")
                    }
                }
                ForEach(untracked.prefix(20)) { ingredient in
                    Button {
                        PantryActions.startTracking(ingredient, location: filterLocation, household: household, context: context)
                        searchText = ""
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ingredient.name).foregroundStyle(.primary)
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
                    .accessibilityLabel(String(localized: "Start tracking \(ingredient.name)"))
                }
            } header: {
                Text("Start tracking")
            } footer: {
                Text("Marks the ingredient as something you have. Rebuilding the shopping list then leaves it off.")
            }
        }
    }

    // MARK: - Actions

    private func startTracking(named name: String) {
        guard let household else { return }
        PantryActions.startTracking(named: name, location: filterLocation, household: household, context: context)
        searchText = ""
    }

    private func addToShoppingList(_ ingredient: Ingredient) {
        guard let household else { return }
        ShoppingListBuilder.addManualItem(for: ingredient, household: household, context: context)
    }
}

/// One pantry line: state, amount, best-before and note at a glance.
@MainActor
struct PantryRowLabel: View {
    let ingredient: Ingredient
    let system: UnitSystem
    let isOnShoppingList: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: PantryRowLabel.symbol(for: ingredient))
                .foregroundStyle(PantryRowLabel.tint(for: ingredient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ingredient.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let freshness = PantryInventory.freshness(of: ingredient),
                   let date = ingredient.inventoryBestBefore, freshness != .fine {
                    Label(
                        freshness == .expired
                            ? String(localized: "Past best before (\(date.formatted(date: .abbreviated, time: .omitted)))")
                            : String(localized: "Use soon (\(date.formatted(date: .abbreviated, time: .omitted)))"),
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(freshness == .expired ? .red : .orange)
                }
                if let note = ingredient.trimmedInventoryNote, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if isOnShoppingList {
                Image(systemName: "cart.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "On the shopping list"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var pieces: [String] = []
        if ingredient.inventoryMode != .none {
            pieces.append(ingredient.inventoryMode.localizedName)
        } else if ingredient.isPantryStaple {
            pieces.append(String(localized: "Pantry staple"))
        } else {
            pieces.append(InventoryMode.none.localizedName)
        }
        if let amount = PantryRowLabel.amountText(for: ingredient, system: system) {
            pieces.append(amount)
        }
        if let date = ingredient.inventoryBestBefore, PantryInventory.freshness(of: ingredient) == .fine {
            pieces.append(String(localized: "Best before \(date.formatted(date: .abbreviated, time: .omitted))"))
        }
        return pieces.joined(separator: " · ")
    }

    static func amountText(for ingredient: Ingredient, system: UnitSystem) -> String? {
        guard let quantity = ingredient.inventoryQuantity else { return nil }
        let display = UnitConversion.string(for: quantity, system: system, ingredientName: ingredient.name)
        return (display.isApproximate ? "≈ " : "") + display.text
    }

    static func symbol(for ingredient: Ingredient) -> String {
        switch ingredient.inventoryMode {
        case .have: "checkmark.circle.fill"
        case .low: "exclamationmark.circle.fill"
        case .out: "xmark.circle.fill"
        case .none: ingredient.isPantryStaple ? "shippingbox.fill" : "circle.dashed"
        }
    }

    static func tint(for ingredient: Ingredient) -> Color {
        switch ingredient.inventoryMode {
        case .have: .green
        case .low: .orange
        case .out: .red
        case .none: .secondary
        }
    }
}

#Preview {
    NavigationStack { PantryView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
