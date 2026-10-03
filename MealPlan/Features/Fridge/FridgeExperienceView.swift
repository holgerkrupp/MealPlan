import SwiftData
import SwiftUI

@MainActor
struct FridgeExperienceView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(sort: \Ingredient.name) private var allIngredients: [Ingredient]
    @Query(sort: \Dish.name) private var allDishes: [Dish]
    @Query(sort: \MealPlanEntry.date) private var allEntries: [MealPlanEntry]
    @Query(sort: \ShoppingListItem.sortIndex) private var allShoppingItems: [ShoppingListItem]

    @AppStorage(FridgeExperienceSettings.enabledKey) private var fridgeEnabled = false
    @AppStorage(FridgeExperienceSettings.simulatedFoldableKey) private var simulatedFoldable = false
    @AppStorage(FridgeExperienceSettings.simulatedPostureKey) private var simulatedPostureRaw = FoldingPosture.closed.rawValue

    @State private var posture: FoldingPosture = .closed
    @State private var selectedIngredientIDs: Set<UUID> = []
    @State private var showingAllIngredients = false
    @State private var showingSuggestions = false

    private var householdID: UUID? { appState.currentHousehold?.uuid }
    private var isFoldable: Bool { FoldingDeviceStateProvider.current.isFoldable || simulatedFoldable }
    private var isActive: Bool { fridgeEnabled && isFoldable }

    private var household: Household? { appState.currentHousehold }

    private var ingredients: [Ingredient] {
        allIngredients.filter { $0.household?.uuid == householdID }
    }

    private var dishes: [Dish] {
        allDishes.filter { $0.household?.uuid == householdID }
    }

    private var entries: [MealPlanEntry] {
        allEntries.filter { $0.household?.uuid == householdID }
    }

    private var shoppingItems: [ShoppingListItem] {
        allShoppingItems.filter { $0.household?.uuid == householdID && !$0.isChecked }
    }

    private var visibleIngredients: [Ingredient] {
        let tracked = ingredients.filter { $0.isPantryStaple || $0.inventoryMode != .none }
        return showingAllIngredients || tracked.isEmpty ? ingredients : tracked
    }

    private var availableIngredients: [Ingredient] {
        ingredients.filter { $0.isPantryStaple || $0.inventoryMode == .have || $0.inventoryMode == .low }
    }

    private var useSoonIngredients: [Ingredient] {
        let cutoff = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
        return availableIngredients.filter { ingredient in
            guard let bestBefore = ingredient.inventoryBestBefore else { return false }
            return bestBefore <= cutoff
        }
    }

    private var selectedIngredients: [Ingredient] {
        availableIngredients.filter { selectedIngredientIDs.contains($0.uuid) }
    }

    private var recipeSuggestions: [FridgeRecipeSuggestion] {
        FridgeRecipeSuggester.suggestions(
            dishes: dishes,
            available: availableIngredients,
            useSoon: useSoonIngredients,
            selected: selectedIngredients
        )
    }

    private var nextMeal: MealPlanEntry? {
        entries
            .filter { !$0.skipped && ($0.date >= Date.now.startOfDay || $0.date == Date.now.startOfDay) }
            .sorted { ($0.date, $0.sortIndex) < ($1.date, $1.sortIndex) }
            .first
    }

    private var upcomingMeals: [MealPlanEntry] {
        entries
            .filter { !$0.skipped && $0.date >= Date.now.startOfDay }
            .sorted { ($0.date, $0.sortIndex) < ($1.date, $1.sortIndex) }
            .prefix(4)
            .map { $0 }
    }

    var body: some View {
        Group {
            if isActive {
                activeFridge
            } else {
                fallback
            }
        }
        .navigationTitle(String(localized: "Fridge"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            let configured = FoldingPosture(rawValue: simulatedPostureRaw) ?? .closed
            posture = simulatedFoldable ? configured : (FoldingDeviceStateProvider.current.posture == .unknown ? .closed : FoldingDeviceStateProvider.current.posture)
        }
        .onChange(of: simulatedPostureRaw) { _, raw in
            if let value = FoldingPosture(rawValue: raw) { posture = value }
        }
    }

    private var activeFridge: some View {
        VStack(spacing: 0) {
            posturePicker
                .padding(.horizontal)
                .padding(.top, 8)

            ScrollView {
                Group {
                    switch posture {
                    case .closed:
                        doorView
                    case .partiallyOpen:
                        openingView
                    case .open, .tabletop, .unknown:
                        interiorView
                    }
                }
                .padding()
                .animation(reduceMotion ? nil : .snappy, value: posture)
            }
        }
    }

    private var posturePicker: some View {
        Picker(String(localized: "Fridge posture"), selection: $posture) {
            ForEach([FoldingPosture.closed, .partiallyOpen, .open], id: \.self) { value in
                Text(value.localizedName).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(String(localized: "Simulated fold posture"))
        .onChange(of: posture) { _, value in
            simulatedPostureRaw = value.rawValue
        }
    }

    private var doorView: some View {
        VStack(alignment: .leading, spacing: 16) {
            fridgeHeader(
                title: String(localized: "MealPlan Fridge"),
                subtitle: String(localized: "A useful door for the meals and ingredients already in MealPlan.")
            )

            HStack(alignment: .top, spacing: 12) {
                magnetCard(title: String(localized: "Tonight"), symbol: "fork.knife", tint: .orange) {
                    if let nextMeal {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(nextMeal.displayTitle).font(.headline)
                            Text(nextMeal.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let dish = nextMeal.dish {
                            NavigationLink(String(localized: "Open recipe")) { DishDetailView(dish: dish) }
                                .font(.caption.weight(.semibold))
                        }
                    } else {
                        Text(String(localized: "Nothing planned yet."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                magnetCard(title: String(localized: "Use soon"), symbol: "clock.badge.exclamationmark", tint: .pink) {
                    if useSoonIngredients.isEmpty {
                        Text(String(localized: "No dated ingredients."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(useSoonIngredients.prefix(3)) { ingredient in
                            Label(ingredient.name, systemImage: "leaf")
                                .font(.subheadline)
                        }
                    }
                }
            }

            magnetCard(title: String(localized: "Shopping"), symbol: "cart", tint: .blue) {
                if shoppingItems.isEmpty {
                    Text(String(localized: "The list is clear."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shoppingItems.prefix(5)) { item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            if let displayText = item.displayText, !displayText.isEmpty {
                                Text(displayText).foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)
                    }
                    Button(String(localized: "Open shopping list"), systemImage: "arrow.up.right") {
                        appState.requestedSection = .shopping
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            if !upcomingMeals.isEmpty {
                magnetCard(title: String(localized: "Coming up"), symbol: "calendar", tint: .green) {
                    ForEach(upcomingMeals) { entry in
                        HStack {
                            Text(entry.date.formatted(.dateTime.weekday(.abbreviated).day()))
                                .foregroundStyle(.secondary)
                            Text(entry.displayTitle)
                            Spacer()
                        }
                        .font(.subheadline)
                    }
                }
            }

            Button {
                posture = .open
            } label: {
                Label(String(localized: "Open the fridge"), systemImage: "door.left.hand.open")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(String(localized: "Shows ingredients and recipe ideas."))
        }
    }

    private var openingView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 52))
                .foregroundStyle(.yellow)
                .symbolEffect(.bounce, options: .repeating, isActive: !reduceMotion)
            Text(String(localized: "The fridge light is coming on"))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(String(localized: "Keep opening to see what is already at home and what you can make from it."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "Continue opening"), systemImage: "door.left.hand.open") {
                posture = .open
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .padding()
    }

    private var interiorView: some View {
        VStack(alignment: .leading, spacing: 18) {
            fridgeHeader(
                title: String(localized: "Inside the fridge"),
                subtitle: availableIngredients.isEmpty
                    ? String(localized: "Track only what is useful. MealPlan does not require a perfect inventory.")
                    : String(localized: "Select ingredients for a focused answer to “What can I make?”")
            )

            if availableIngredients.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Nothing tracked yet"), systemImage: "refrigerator")
                } description: {
                    Text(String(localized: "Mark an ingredient as Have or Low below. Your recipes and shopping list remain unchanged."))
                }
            }

            ingredientShelf

            Button {
                showingSuggestions = true
            } label: {
                Label(String(localized: "What can I make?"), systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(recipeSuggestions.isEmpty)
            .accessibilityHint(String(localized: "Suggests saved recipes using selected ingredients."))

            if showingSuggestions {
                suggestionsSection
            }
        }
    }

    private var ingredientShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(String(localized: "Ingredients"), systemImage: "carrot")
                    .font(.headline)
                Spacer()
                if !ingredients.isEmpty {
                    Button(showingAllIngredients ? String(localized: "Tracked only") : String(localized: "Show all")) {
                        showingAllIngredients.toggle()
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                ForEach(visibleIngredients) { ingredient in
                    ingredientCard(ingredient)
                }
            }
        }
    }

    private func ingredientCard(_ ingredient: Ingredient) -> some View {
        let isSelected = selectedIngredientIDs.contains(ingredient.uuid)
        return Button {
            guard availableIngredients.contains(where: { $0.uuid == ingredient.uuid }) else { return }
            if isSelected {
                selectedIngredientIDs.remove(ingredient.uuid)
            } else {
                selectedIngredientIDs.insert(ingredient.uuid)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: ingredient.category.symbolName)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : statusSymbol(for: ingredient))
                }
                Text(ingredient.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(statusText(for: ingredient))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { inventoryMenu(for: ingredient) }
        .accessibilityLabel(Text("\(ingredient.name), \(statusText(for: ingredient))"))
        .accessibilityHint(Text(String(localized: "Double tap to select for recipe suggestions.")))
    }

    @ViewBuilder
    private func inventoryMenu(for ingredient: Ingredient) -> some View {
        Menu(String(localized: "Inventory"), systemImage: "checkmark.circle") {
            Button(String(localized: "Have")) { mark(ingredient, as: .have) }
            Button(String(localized: "Low")) { mark(ingredient, as: .low) }
            Button(String(localized: "Out")) { mark(ingredient, as: .out) }
            Button(String(localized: "Not tracked")) { mark(ingredient, as: .none) }
        }
        if !appState.isGuest {
            Button(String(localized: "Add to shopping list"), systemImage: "cart.badge.plus") {
                guard let household else { return }
                ShoppingListBuilder.addManualItem(for: ingredient, household: household, context: context)
            }
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(String(localized: "You could make"), systemImage: "wand.and.stars")
                    .font(.headline)
                Spacer()
                if !selectedIngredients.isEmpty {
                    Text("Using " + String(selectedIngredients.count) + " selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(recipeSuggestions) { suggestion in
                NavigationLink {
                    DishDetailView(dish: suggestion.dish)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(suggestion.dish.name)
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        Text("Have: " + suggestion.matchedIngredients.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !suggestion.missingIngredients.isEmpty {
                            Text("Still need: " + suggestion.missingIngredients.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if !suggestion.useSoonIngredients.isEmpty {
                            Label("Uses soon: " + suggestion.useSoonIngredients.joined(separator: ", "), systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.pink)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary, in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Recipe suggestion: " + suggestion.dish.name))
            }
        }
    }

    private var fallback: some View {
        ContentUnavailableView {
            Label(String(localized: "Fridge Experience is off"), systemImage: "refrigerator")
        } description: {
            Text(isFoldable
                 ? String(localized: "Turn on Fridge Experience in Settings to use the optional refrigerator interface.")
                 : String(localized: "This device has no foldable capability. MealPlan's standard interface remains available."))
        } actions: {
            if !fridgeEnabled {
                Button(String(localized: "Open Settings")) { appState.requestedSection = .settings }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(String(localized: "Open standard MealPlan")) { appState.requestedSection = .plan }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func fridgeHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.bold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func magnetCard<Content: View>(title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(tint.gradient)
                .frame(width: 12, height: 12)
                .padding(10)
                .accessibilityHidden(true)
        }
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        .accessibilityElement(children: .contain)
    }

    private func mark(_ ingredient: Ingredient, as mode: InventoryMode) {
        guard !appState.isGuest else { return }
        ingredient.markInventory(mode, quantity: mode == .none ? nil : ingredient.inventoryQuantity, bestBefore: ingredient.inventoryBestBefore)
        if mode == .none { selectedIngredientIDs.remove(ingredient.uuid) }
        try? context.save()
    }

    private func statusSymbol(for ingredient: Ingredient) -> String {
        if ingredient.isPantryStaple { return "shippingbox.fill" }
        switch ingredient.inventoryMode {
        case .have: return "checkmark.circle.fill"
        case .low: return "exclamationmark.circle.fill"
        case .out: return "xmark.circle.fill"
        case .none: return "questionmark.circle"
        }
    }

    private func statusText(for ingredient: Ingredient) -> String {
        if ingredient.isPantryStaple { return String(localized: "Pantry staple") }
        if let quantity = ingredient.inventoryQuantity {
            let value = quantity.value.formatted(.number.precision(.fractionLength(0...1)))
            let unit: String
            switch quantity.dimension {
            case .mass: unit = "g"
            case .volume: unit = "ml"
            case .count: unit = ""
            }
            return "\(ingredient.inventoryMode.localizedName) · \(value)\(unit.isEmpty ? "" : " \(unit)")"
        }
        return ingredient.inventoryMode.localizedName
    }
}

#Preview("Fridge") {
    NavigationStack { FridgeExperienceView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
