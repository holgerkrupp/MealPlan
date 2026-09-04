import SwiftUI
import SwiftData

/// Plan an already-chosen dish onto a day and slot.
@MainActor
struct PlanDishSheet: View {
    let dish: Dish
    var defaultDate: Date = .now
    var defaultMealKey: String?

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\MealType.sortOrder), SortDescriptor(\MealType.name)])
    private var mealTypes: [MealType]

    @State private var date: Date = .now
    @State private var mealKey: String = ""
    @State private var servings: Int = 2
    @State private var note: String = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    DishThumbnail(dish: dish, size: 52)
                    Text(dish.name).font(.headline)
                }
            }

            Section {
                MealPlannerStrip(
                    planningDish: dish,
                    planServings: servings,
                    planNote: note.isEmpty ? nil : note,
                    selectedDate: $date,
                    selectedMealKey: $mealKey
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            } header: {
                Text(String(localized: "Tap a slot to plan it"))
            }

            Section {
                Stepper(value: $servings, in: 1...50) {
                    Text(String(localized: "\(servings) servings"))
                }
            }

            if !dish.sortedIngredients.isEmpty {
                Section(String(localized: "Ingredients for \(servings)")) {
                    ForEach(dish.sortedIngredients) { line in
                        HStack {
                            Text(line.ingredient?.name ?? line.rawText ?? "—")
                            Spacer()
                            if let amount = scaler.amountText(for: line) {
                                Text(amount).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }

            Section(String(localized: "Note (optional)")) {
                TextField(String(localized: "e.g. use up the spinach"), text: $note, axis: .vertical)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Plan meal"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { dismiss() }
            }
        }
        .onAppear {
            date = defaultDate
            mealKey = resolvedMealKey
            servings = appState.standardServings
        }
    }

    /// Prefer an explicit request, then the dish's own meal-type tag if the
    /// household has a matching meal, else the first configured meal.
    private var resolvedMealKey: String {
        let keys = Set(mealTypes.map(\.key))
        if let defaultMealKey, keys.contains(defaultMealKey) { return defaultMealKey }
        if let tagKey = dish.mealTypeTags.first?.slot.rawValue, keys.contains(tagKey) { return tagKey }
        return mealTypes.first?.key ?? ""
    }

    private var scaler: ServingScaler {
        ServingScaler(
            baseServings: dish.servings,
            targetServings: max(1, servings),
            system: appState.unitSystem,
            roundsAmounts: appState.roundsDisplayedAmounts
        )
    }
}

#Preview {
    NavigationStack {
        PlanDishSheet(dish: PreviewData.household.dishes?.first ?? Dish(name: "Test"))
    }
    .environment(AppState.preview)
    .environment(PurchaseManager.shared)
    .modelContainer(PreviewData.container)
}
