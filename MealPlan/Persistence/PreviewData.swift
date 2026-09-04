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
        // A seeded household is past its first launch, so it carries the
        // default pantry staples the real one gets.
        household.didSeedPantryStaples = true
        salz.isPantryStaple = true
        let pfeffer = ingredient("Pfeffer", .spices)
        pfeffer.isPantryStaple = true

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

        // One evening out, so the restaurant picker has a regular to offer.
        let eatingOut = MealPlanEntry(date: Date.now.adding(days: 2), slot: .dinner)
        eatingOut.household = household
        eatingOut.isEatingOut = true
        eatingOut.placeName = "Trattoria da Vinci"
        eatingOut.placeAddress = "Hauptstraße 12"
        context.insert(eatingOut)

        // A variant group: two takes on the same dish, neither a duplicate.
        let groupID = UUID()
        for (name, glyph) in [("Klassischer Burger", "🍔"), ("Halloumi-Burger", "🧀")] {
            let variant = Dish(name: name)
            variant.household = household
            variant.variantGroupID = groupID
            variant.variantGroupName = "Burger"
            variant.setGlyphManually(.emoji(glyph))
            variant.mealTypeTags = [.dinner]
            context.insert(variant)
        }

        for (name, role) in [("Mama", MemberRole.owner), ("Jonas", .editor)] {
            let member = HouseholdMember(name: name, role: role, isCurrentUser: role == .owner)
            member.household = household
            context.insert(member)
        }

        let routine = MealRoutine(dish: bolognese, mealKey: MealSlot.dinner.rawValue, weekday: 6)
        routine.household = household
        context.insert(routine)

        let template = WeekTemplate(name: "Standardwoche")
        template.household = household
        template.createdByName = "Mama"
        context.insert(template)
        for (weekday, slot, dish) in [(1, MealSlot.dinner, bolognese), (3, .dinner, soup), (5, .breakfast, pancakes)] {
            let line = WeekTemplateEntry(weekday: weekday, slot: slot, dish: dish)
            line.template = template
            line.dish = dish
            context.insert(line)
        }

        let cooked = CookedLog(date: Date.now.adding(days: -12), dish: bolognese, servings: 4)
        cooked.household = household
        context.insert(cooked)

        let shopping: [(Ingredient, String, Bool)] = [
            (hack, "500 g", false),
            (spaghetti, "500 g", false),
            (tomaten, "800 g", true),
            (milch, "500 ml", false),
        ]
        for (index, (ingredient, amount, checked)) in shopping.enumerated() {
            let item = ShoppingListItem(name: ingredient.name, category: ingredient.category)
            item.household = household
            item.ingredient = ingredient
            item.displayText = amount
            item.isChecked = checked
            item.sortIndex = index
            item.sourceDishNames = ["Spaghetti Bolognese"]
            context.insert(item)
        }

        try? context.save()
    }

    // MARK: - Handles for previews

    /// Any dish whose name contains `fragment`, falling back to a transient one
    /// so a preview renders something rather than crashing on an empty store.
    static func dish(_ fragment: String) -> Dish {
        household.dishes?.first { $0.name.localizedCaseInsensitiveContains(fragment) }
            ?? household.dishes?.first
            ?? Dish(name: fragment)
    }

    static var dish: Dish { dish("Pfann") }

    /// A dish with ingredients, times and tags on it — the interesting case.
    static var richDish: Dish { dish("Bolognese") }

    /// Today's dinner — the entry the quick-actions sheet is usually opened on.
    static var entry: MealPlanEntry {
        let planned = (household.entries ?? []).filter { !$0.isEatingOut }
        return planned.first { $0.date.isSameDay(as: .now) && $0.slot == .dinner }
            ?? planned.first
            ?? MealPlanEntry(date: .now, slot: .dinner, dish: dish)
    }

    static var eatingOutEntry: MealPlanEntry {
        (household.entries ?? []).first { $0.isEatingOut } ?? entry
    }

    static var mealTypes: [MealType] { household.sortedMealTypes }

    static var mealType: MealType {
        mealTypes.first { $0.key == MealSlot.dinner.rawValue } ?? mealTypes.first ?? MealType(name: "Dinner")
    }

    static var dishes: [Dish] { (household.dishes ?? []).sorted { $0.name < $1.name } }

    static var member: HouseholdMember {
        (household.members ?? []).first ?? HouseholdMember(name: "Mama", role: .owner)
    }

    static var routine: MealRoutine {
        (household.mealRoutines ?? []).first ?? MealRoutine(dish: dish)
    }

    static var template: WeekTemplate {
        (household.weekTemplates ?? []).first ?? WeekTemplate(name: "Standardwoche")
    }

    static var shoppingItem: ShoppingListItem {
        (household.shoppingItems ?? []).first { !$0.isChecked }
            ?? ShoppingListItem(name: "Mehl", category: .pantry)
    }

    static var checkedShoppingItem: ShoppingListItem {
        (household.shoppingItems ?? []).first { $0.isChecked } ?? shoppingItem
    }

    /// What one meal card on one day holds.
    static func entries(on day: Date, mealKey: String) -> [MealPlanEntry] {
        (household.entries ?? [])
            .filter { $0.date.isSameDay(as: day) && $0.mealKey == mealKey }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    /// A catalogue entry by name, for screens that edit one ingredient.
    static func ingredient(_ fragment: String) -> Ingredient {
        (household.ingredients ?? []).first { $0.name.localizedCaseInsensitiveContains(fragment) }
            ?? Ingredient(name: fragment)
    }

    static var ingredientLine: DishIngredient {
        richDish.sortedIngredients.first ?? DishIngredient(canonicalValue: 250, dimension: .mass, displayUnit: "g")
    }

    /// The seeded variant group, for the group screen.
    static var variantGroup: DishVariantGroupRef {
        let member = (household.dishes ?? []).first { $0.variantGroupID != nil }
        return DishVariantGroupRef(
            id: member?.variantGroupID ?? UUID(),
            name: member?.variantGroupName ?? "Burger"
        )
    }

    /// The meals of a day, as the plan's day cards describe them.
    static var dayMeals: [DayMeal] {
        mealTypes.map { DayMeal(key: $0.key, name: $0.name, symbolName: $0.symbolName) }
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
