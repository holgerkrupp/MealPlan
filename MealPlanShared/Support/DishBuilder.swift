import Foundation
import SwiftData

/// Creates a `Dish` (with parsed ingredients + image) from an `ImportedRecipe`.
/// Shared by the app's importer and the Share Extension so both behave alike.
enum DishBuilder {

    @MainActor
    @discardableResult
    static func makeDish(
        from recipe: ImportedRecipe,
        household: Household?,
        createdByName: String?,
        context: ModelContext
    ) -> Dish {
        let dish = Dish(name: recipe.name.isEmpty ? String(localized: "New dish") : recipe.name)
        dish.household = household
        dish.createdByName = createdByName
        dish.sourceURL = recipe.sourceURL
        dish.importedSourceApp = recipe.importedSourceApp
        dish.recipeText = recipe.instructions
        dish.servings = recipe.servings ?? 2
        dish.prepTimeMinutes = recipe.prepTimeMinutes
        dish.cookTimeMinutes = recipe.cookTimeMinutes
        dish.needsReview = recipe.needsReview
        context.insert(dish)

        if let imageData = recipe.imageData {
            let image = DishImage(data: imageData, isPrimary: true)
            image.dish = dish
            context.insert(image)
        }

        for (index, rawLine) in recipe.ingredientLines.enumerated() {
            let parsed = GermanUnitParser.parse(rawLine)
            let ingredient = upsertIngredient(named: parsed.name, household: household, context: context)
            let line = DishIngredient(
                canonicalValue: parsed.quantity?.value,
                dimension: parsed.quantity?.dimension,
                displayUnit: parsed.displayUnit,
                isApproximate: parsed.isApproximate,
                note: parsed.note,
                rawText: parsed.rawText,
                sortIndex: index
            )
            line.dish = dish
            line.ingredient = ingredient
            context.insert(line)
        }

        // After the ingredients exist, so a nondescript name like "Omas
        // Rezept" can still fall back to what's in it. A photo from the site
        // takes precedence when rendering; the glyph is the fallback.
        dish.refreshAutoGlyph()

        try? context.save()
        return dish
    }

    /// Fills an existing dish in from an imported recipe, for "find a recipe on
    /// the web and attach it to this dish".
    ///
    /// Additive on purpose: it fills gaps and never overwrites what the user
    /// already put in. The name they chose stays theirs, ingredients are only
    /// taken when the dish has none, and the site's photo is added only when
    /// there's no photo yet — where it then supersedes the placeholder glyph.
    /// The source link and review flag are always updated, since those describe
    /// where the recipe now comes from.
    @MainActor
    static func apply(
        _ recipe: ImportedRecipe,
        to dish: Dish,
        context: ModelContext
    ) {
        dish.sourceURL = recipe.sourceURL ?? dish.sourceURL
        dish.importedSourceApp = recipe.importedSourceApp ?? dish.importedSourceApp

        if (dish.recipeText ?? "").isEmpty {
            dish.recipeText = recipe.instructions
        }
        if dish.prepTimeMinutes == nil { dish.prepTimeMinutes = recipe.prepTimeMinutes }
        if dish.cookTimeMinutes == nil { dish.cookTimeMinutes = recipe.cookTimeMinutes }
        if let servings = recipe.servings, (dish.ingredients ?? []).isEmpty {
            dish.servings = servings
        }

        if (dish.images ?? []).isEmpty, let imageData = recipe.imageData {
            let image = DishImage(data: imageData, isPrimary: true)
            image.dish = dish
            context.insert(image)
        }

        if (dish.ingredients ?? []).isEmpty {
            for (index, rawLine) in recipe.ingredientLines.enumerated() {
                let parsed = GermanUnitParser.parse(rawLine)
                let ingredient = upsertIngredient(named: parsed.name, household: dish.household, context: context)
                let line = DishIngredient(
                    canonicalValue: parsed.quantity?.value,
                    dimension: parsed.quantity?.dimension,
                    displayUnit: parsed.displayUnit,
                    isApproximate: parsed.isApproximate,
                    note: parsed.note,
                    rawText: parsed.rawText,
                    sortIndex: index
                )
                line.dish = dish
                line.ingredient = ingredient
                context.insert(line)
            }
        }

        // Imports are guesswork, so ask the cook to check the result.
        dish.needsReview = recipe.needsReview
        dish.refreshAutoGlyph()
        try? context.save()
    }

    @MainActor
    static func upsertIngredient(named rawName: String, household: Household?, context: ModelContext) -> Ingredient {
        let normalized = Ingredient.normalize(rawName)
        if !normalized.isEmpty,
           let existing = (household?.ingredients ?? []).first(where: { $0.normalizedName == normalized }) {
            return existing
        }
        let ingredient = Ingredient(name: rawName.isEmpty ? String(localized: "Ingredient") : rawName)
        ingredient.household = household
        context.insert(ingredient)
        return ingredient
    }
}
