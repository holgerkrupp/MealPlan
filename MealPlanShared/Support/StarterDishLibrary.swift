import Foundation
import SwiftData

/// A deliberately small, neutral library for a new household. The source ID
/// makes seeding idempotent while keeping each dish an ordinary, deletable
/// record after it has been added.
enum StarterDishLibrary {
    struct Definition: Identifiable, Hashable {
        let id: String
        let name: String
        let instructions: String
        let mealTypes: Set<MealTypeTag>
        let tags: [String]
    }

    static var all: [Definition] {
        [
            Definition(
                id: "tomato-pasta",
                name: String(localized: "Tomato pasta"),
                instructions: String(localized: "Cook the pasta. Warm the tomato sauce, combine, and season to taste."),
                mealTypes: [.lunch, .dinner],
                tags: [String(localized: "Quick")]
            ),
            Definition(
                id: "vegetable-stir-fry",
                name: String(localized: "Vegetable stir-fry"),
                instructions: String(localized: "Chop the vegetables, stir-fry until crisp-tender, then season and serve with rice."),
                mealTypes: [.lunch, .dinner],
                tags: [String(localized: "Vegetarian"), String(localized: "Quick")]
            ),
            Definition(
                id: "baked-potatoes",
                name: String(localized: "Baked potatoes"),
                instructions: String(localized: "Bake the potatoes until tender and serve with your favorite toppings."),
                mealTypes: [.lunch, .dinner],
                tags: [String(localized: "Easy")]
            ),
            Definition(
                id: "pancakes",
                name: String(localized: "Pancakes"),
                instructions: String(localized: "Mix a smooth batter and cook small portions in a lightly greased pan until golden."),
                mealTypes: [.breakfast],
                tags: [String(localized: "Family favorite")]
            ),
        ]
    }

    @MainActor
    @discardableResult
    static func seed(
        selectedIDs: Set<String>,
        household: Household,
        context: ModelContext
    ) -> Int {
        let source = "MealPlan Starter"
        let existing = Set((household.dishes ?? []).compactMap { dish in
            dish.importedSourceApp == source ? dish.importedSourceID : nil
        })
        var inserted = 0
        for definition in all where selectedIDs.contains(definition.id) && !existing.contains(definition.id) {
            let dish = Dish(name: definition.name)
            dish.household = household
            dish.importedSourceApp = source
            dish.importedSourceID = definition.id
            dish.recipeText = definition.instructions
            dish.servings = household.scalingServings
            dish.mealTypeTags = definition.mealTypes
            dish.tagNames = DishTag.merge(definition.tags)
            dish.refreshAutoGlyph()
            context.insert(dish)
            inserted += 1
        }
        if inserted > 0 { try? context.save() }
        return inserted
    }
}
