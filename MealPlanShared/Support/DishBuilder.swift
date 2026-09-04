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
        dish.deepLinkURL = recipe.deepLinkURL
        dish.importedSourceApp = recipe.importedSourceApp
        dish.importedSourceID = recipe.sourceIdentifier
        dish.variantGroupID = recipe.variantGroupID
        dish.variantGroupName = recipe.variantGroupName
        dish.recipeText = recipe.instructions
        dish.servings = recipe.servings ?? 2
        dish.prepTimeMinutes = recipe.prepTimeMinutes
        dish.cookTimeMinutes = recipe.cookTimeMinutes
        dish.needsReview = recipe.needsReview
        dish.isFavorite = recipe.isFavorite
        dish.rating = min(max(recipe.rating, 0), 5)
        dish.collectionNames = recipe.collectionNames
        dish.tagNames = DishTag.merge(recipe.tagNames)
        dish.mealTypeTags = recipe.mealTypeTags
        dish.dietaryTags = recipe.dietaryTags
        dish.season = recipe.season
        if let glyph = recipe.glyph {
            dish.glyph = glyph
            dish.glyphIsAuto = false
        }
        context.insert(dish)

        for (index, imageData) in ([recipe.imageData].compactMap { $0 } + recipe.additionalImageData).enumerated() {
            let image = DishImage(data: imageData, sortIndex: index, isPrimary: index == 0)
            image.dish = dish
            context.insert(image)
        }

        if let structured = recipe.structuredIngredients {
            for (index, value) in structured.enumerated() {
                let ingredient = upsertIngredient(named: value.name, household: household, context: context)
                ingredient.category = value.category
                ingredient.customAisleName = value.customAisleName
                ingredient.isPantryStaple = ingredient.isPantryStaple || value.isPantryStaple
                let line = DishIngredient(
                    canonicalValue: value.canonicalValue,
                    dimension: value.dimension,
                    displayUnit: value.displayUnit,
                    isApproximate: value.isApproximate,
                    note: value.note,
                    rawText: value.rawText,
                    sortIndex: index
                )
                line.dish = dish
                line.ingredient = ingredient
                context.insert(line)
            }
        } else {
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
        }

        // After the ingredients exist, so a nondescript name like "Omas
        // Rezept" can still fall back to what's in it. A photo from the site
        // takes precedence when rendering; the glyph is the fallback.
        dish.refreshAutoGlyph()
        addSuggestedTags(to: dish, household: household)

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
        dish.deepLinkURL = recipe.deepLinkURL ?? dish.deepLinkURL
        dish.importedSourceApp = recipe.importedSourceApp ?? dish.importedSourceApp
        dish.importedSourceID = recipe.sourceIdentifier ?? dish.importedSourceID

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
        dish.tagNames = DishTag.merge(dish.tagNames, adding: recipe.tagNames)
        addSuggestedTags(to: dish, household: dish.household)
        try? context.save()
    }

    /// Copies a dish, ingredients and photos included, and puts the copy in
    /// the original's variant group. This is how "another take on this" is
    /// made: the copy is a full dish that can be edited, planned and cooked
    /// without touching the one it came from.
    @MainActor
    @discardableResult
    static func duplicateAsVariant(
        of dish: Dish,
        named newName: String? = nil,
        context: ModelContext
    ) -> Dish {
        let copy = Dish(name: newName?.trimmedCollapsed.nilIfEmpty
            ?? String(localized: "\(dish.name) (variant)"))
        copy.household = dish.household
        copy.createdByName = dish.createdByName
        copy.sourceURLString = dish.sourceURLString
        copy.deepLinkURLString = dish.deepLinkURLString
        copy.importedSourceApp = dish.importedSourceApp
        // Not the source id: the copy is a new recipe, and inheriting the id
        // would make a later re-import mistake it for the original.
        copy.recipeText = dish.recipeText
        copy.servings = dish.servings
        copy.prepTimeMinutes = dish.prepTimeMinutes
        copy.cookTimeMinutes = dish.cookTimeMinutes
        copy.needsReview = dish.needsReview
        copy.rating = dish.rating
        copy.collectionNames = dish.collectionNames
        copy.tagNames = dish.tagNames
        copy.mealTypeTagsRaw = dish.mealTypeTagsRaw
        copy.dietaryTagsRaw = dish.dietaryTagsRaw
        copy.seasonRaw = dish.seasonRaw
        copy.glyphRaw = dish.glyphRaw
        copy.glyphIsAuto = dish.glyphIsAuto
        context.insert(copy)

        for image in dish.sortedImages.enumerated() {
            let duplicate = DishImage(
                data: image.element.data,
                sortIndex: image.offset,
                isPrimary: image.offset == 0
            )
            duplicate.dish = copy
            context.insert(duplicate)
        }

        for line in dish.sortedIngredients {
            let duplicate = DishIngredient(
                canonicalValue: line.canonicalValue,
                dimension: line.dimension,
                displayUnit: line.displayUnit,
                isApproximate: line.isApproximate,
                note: line.note,
                rawText: line.rawText,
                sortIndex: line.sortIndex
            )
            duplicate.dish = copy
            duplicate.ingredient = line.ingredient
            context.insert(duplicate)
        }

        DishVariants.join(copy, with: dish)
        try? context.save()
        return copy
    }

    /// Tops a dish up with automatically derived tags. Additive, and capped so
    /// an import contributes a handful rather than a wall of labels — the cook
    /// adds the rest themselves.
    @MainActor
    static func addSuggestedTags(to dish: Dish, household: Household?, limit: Int = 6) {
        let vocabulary = DishTag.vocabulary(from: household?.dishes ?? [dish])
        let suggested = DishTagSuggester.suggestions(
            for: dish,
            existingVocabulary: vocabulary,
            limit: max(0, limit - dish.tagNames.count)
        )
        dish.tagNames = DishTag.merge(dish.tagNames, adding: suggested)
    }

    @MainActor
    static func upsertIngredient(named rawName: String, household: Household?, context: ModelContext) -> Ingredient {
        let normalized = Ingredient.normalize(rawName)
        // Near matches count: an import that spells it "Salz*" should reuse the
        // household's "Salz" rather than leave two of them in the catalogue and
        // two rows on the shopping list.
        if !normalized.isEmpty,
           let existing = IngredientMatching.match(rawName, in: household?.ingredients ?? []) {
            return existing
        }
        let ingredient = Ingredient(name: rawName.isEmpty ? String(localized: "Ingredient") : rawName)
        ingredient.household = household
        context.insert(ingredient)
        return ingredient
    }
}
