import Foundation
import SwiftData

/// In-memory container with a small seeded household for `#Preview`s and tests.
@MainActor
enum PreviewData {

    static let container: ModelContainer = {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        seed(into: container.mainContext)
        return container
    }()

    static var household: Household {
        let descriptor = FetchDescriptor<Household>()
        return (try? container.mainContext.fetch(descriptor).first) ?? Household(name: "Familie")
    }

    static func seed(into context: ModelContext) {
        let household = Household(name: "Familie Muster")
        context.insert(household)

        for (index, seed) in MealType.defaultSeeds.enumerated() {
            let meal = MealType(key: seed.key, name: seed.name, symbolName: seed.symbol, sortOrder: index)
            meal.household = household
            context.insert(meal)
        }

        func ingredient(_ name: String, _ category: IngredientCategory) -> Ingredient {
            let ing = Ingredient(name: name, category: category)
            ing.household = household
            context.insert(ing)
            return ing
        }

        let mehl = ingredient("Mehl", .pantry)
        let eier = ingredient("Eier", .dairy)
        let milch = ingredient("Milch", .dairy)
        let zwiebel = ingredient("Zwiebel", .produce)
        let hack = ingredient("Hackfleisch", .meat)
        let tomaten = ingredient("Gehackte Tomaten", .pantry)
        let spaghetti = ingredient("Spaghetti", .pantry)
        let salz = ingredient("Salz", .spices)

        let pancakes = Dish(name: "Pfannkuchen")
        pancakes.household = household
        pancakes.servings = 4
        pancakes.prepTimeMinutes = 10
        pancakes.cookTimeMinutes = 20
        pancakes.mealTypeTags = [.breakfast]
        pancakes.dietaryTags = [.vegetarian, .kidFriendly]
        pancakes.recipeText = "Alles verrühren, ausbacken."
        pancakes.lastUsedDate = Date.now.adding(days: -75)
        pancakes.usageCount = 6
        context.insert(pancakes)
        addIngredient(pancakes, mehl, 250, .mass, "g", context)
        addIngredient(pancakes, eier, 3, .count, "Stück", context)
        addIngredient(pancakes, milch, 500, .volume, "ml", context)
        addIngredient(pancakes, salz, 0.3, .mass, "Prise", context, approximate: true)

        let bolognese = Dish(name: "Spaghetti Bolognese")
        bolognese.household = household
        bolognese.servings = 4
        bolognese.prepTimeMinutes = 15
        bolognese.cookTimeMinutes = 40
        bolognese.mealTypeTags = [.lunch, .dinner]
        bolognese.dietaryTags = [.kidFriendly]
        bolognese.lastUsedDate = Date.now.adding(days: -12)
        bolognese.usageCount = 14
        context.insert(bolognese)
        addIngredient(bolognese, hack, 500, .mass, "g", context)
        addIngredient(bolognese, zwiebel, 2, .count, "Stück", context)
        addIngredient(bolognese, tomaten, 800, .mass, "g", context)
        addIngredient(bolognese, spaghetti, 500, .mass, "g", context)

        let soup = Dish(name: "Kürbissuppe")
        soup.household = household
        soup.servings = 4
        soup.mealTypeTags = [.dinner]
        soup.dietaryTags = [.vegetarian, .vegan]
        soup.season = .autumn
        context.insert(soup)

        // A few planned entries around today.
        let plans: [(Int, MealSlot, Dish)] = [
            (-2, .dinner, bolognese),
            (0, .breakfast, pancakes),
            (0, .dinner, soup),
            (1, .dinner, bolognese),
            (3, .lunch, bolognese),
        ]
        for (offset, slot, dish) in plans {
            let entry = MealPlanEntry(date: Date.now.adding(days: offset), slot: slot, dish: dish)
            entry.household = household
            entry.plannedByName = "Mama"
            context.insert(entry)
        }

        try? context.save()
    }

    private static func addIngredient(
        _ dish: Dish,
        _ ingredient: Ingredient,
        _ value: Double,
        _ dimension: QuantityDimension,
        _ unit: String,
        _ context: ModelContext,
        approximate: Bool = false
    ) {
        let di = DishIngredient(
            canonicalValue: value,
            dimension: dimension,
            displayUnit: unit,
            isApproximate: approximate,
            sortIndex: dish.ingredients?.count ?? 0
        )
        di.dish = dish
        di.ingredient = ingredient
        context.insert(di)
    }
}
