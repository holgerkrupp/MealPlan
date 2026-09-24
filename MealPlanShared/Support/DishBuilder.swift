import Foundation
import SwiftData

/// Creates a `Dish` (with parsed ingredients + image) from an `ImportedRecipe`.
/// Shared by the app's importer and the Share Extension so both behave alike.
enum DishBuilder {

    /// State shared by every recipe in one bulk import. It avoids repeatedly
    /// traversing SwiftData relationships for the household's complete
    /// ingredient catalogue and tag vocabulary.
    @MainActor
    final class ImportSession {
        private struct IndexedIngredient {
            var ingredient: Ingredient
            var matchingKey: String
            var offset: Int
        }

        private var ingredientCount = 0
        private var ingredientsByKeyLength: [Int: [IndexedIngredient]] = [:]
        private var exactIngredients: [String: Ingredient] = [:]
        private var exactAliases: [String: [Ingredient]] = [:]
        private var resolvedIngredients: [String: Ingredient] = [:]
        fileprivate private(set) var tagVocabulary: [String]

        init(household: Household?) {
            tagVocabulary = DishTag.vocabulary(from: household?.dishes ?? [])
            for ingredient in household?.ingredients ?? [] {
                index(ingredient)
            }
        }

        fileprivate func ingredient(
            named rawName: String,
            household: Household?,
            context: ModelContext
        ) -> Ingredient {
            let normalized = Ingredient.normalize(rawName)
            if !normalized.isEmpty, let cached = resolvedIngredients[normalized] {
                return cached
            }
            if !normalized.isEmpty, let existing = matchingIngredient(
                named: rawName,
                normalized: normalized
            ) {
                resolvedIngredients[normalized] = existing
                IngredientIdentity.addAlias(
                    named: rawName,
                    to: existing,
                    source: .imported,
                    confidence: 0.8,
                    context: context
                )
                return existing
            }

            let ingredient = Ingredient(name: rawName.isEmpty ? String(localized: "Ingredient") : rawName)
            ingredient.household = household
            context.insert(ingredient)
            index(ingredient)
            if !normalized.isEmpty { resolvedIngredients[normalized] = ingredient }
            return ingredient
        }

        /// Exact names are constant-time. Fuzzy matching only examines keys
        /// whose lengths are close enough to be within the matcher's edit or
        /// inflection tolerance, instead of rescanning the entire catalogue.
        private func matchingIngredient(named rawName: String, normalized: String) -> Ingredient? {
            if let exact = exactIngredients[normalized] { return exact }
            if let aliases = exactAliases[normalized], aliases.count == 1 { return aliases[0] }
            if exactAliases[normalized]?.isEmpty == false { return nil }

            let wanted = IngredientMatching.key(for: rawName)
            var matches: [IndexedIngredient] = []
            for length in max(0, wanted.count - 2)...(wanted.count + 2) {
                for candidate in ingredientsByKeyLength[length] ?? []
                where IngredientMatching.keysMatch(candidate.matchingKey, wanted) {
                    matches.append(candidate)
                }
            }
            let distinct = Dictionary(grouping: matches, by: { $0.ingredient.uuid })
            return distinct.count == 1 ? distinct.values.first?.first?.ingredient : nil
        }

        private func index(_ ingredient: Ingredient) {
            let normalized = ingredient.normalizedName
            if !normalized.isEmpty, exactIngredients[normalized] == nil {
                exactIngredients[normalized] = ingredient
            }
            let key = IngredientMatching.key(for: ingredient.name)
            ingredientsByKeyLength[key.count, default: []].append(IndexedIngredient(
                ingredient: ingredient,
                matchingKey: key,
                offset: ingredientCount
            ))
            for alias in ingredient.aliases ?? [] where !alias.normalizedName.isEmpty {
                exactAliases[alias.normalizedName, default: []].append(ingredient)
                let aliasKey = IngredientMatching.key(for: alias.name)
                ingredientsByKeyLength[aliasKey.count, default: []].append(IndexedIngredient(
                    ingredient: ingredient,
                    matchingKey: aliasKey,
                    offset: ingredientCount
                ))
            }
            ingredientCount += 1
        }

        fileprivate func record(tags: [String]) {
            tagVocabulary = DishTag.merge(tagVocabulary, adding: tags)
        }
    }

    @MainActor
    @discardableResult
    static func makeDish(
        from recipe: ImportedRecipe,
        household: Household?,
        createdByName: String?,
        context: ModelContext,
        importSession: ImportSession? = nil,
        savesChanges: Bool = true
    ) -> Dish {
        // A parse that came back without a title still has to arrive under a
        // name — an untitled recipe is unfindable. The site it came from is a
        // better placeholder than "New dish", and either way the import is
        // flagged for review so the cook is asked to name it properly.
        let importedName = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let dish = Dish(name: importedName.isEmpty ? fallbackName(for: recipe) : importedName)
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
        dish.needsReview = recipe.needsReview || importedName.isEmpty
        dish.isFavorite = recipe.isFavorite
        dish.rating = min(max(recipe.rating, 0), 5)
        dish.tagNames = DishLabelConsolidation.tags(
            existing: recipe.tagNames,
            collections: recipe.collectionNames,
            dietaryRawValues: recipe.dietaryTags.map(\.rawValue)
        )
        dish.mealTypeTags = recipe.mealTypeTags
        dish.season = recipe.season
        dish.setStatedNutritionPerServing(recipe.nutritionPerServing)
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
                let ingredient = importSession?.ingredient(
                    named: value.name,
                    household: household,
                    context: context
                ) ?? upsertIngredient(named: value.name, household: household, context: context)
                ingredient.category = value.category
                ingredient.customAisleName = value.customAisleName
                ingredient.isPantryStaple = ingredient.isPantryStaple || value.isPantryStaple
                // Only fill a gap: a household that has typed its own values
                // for an ingredient keeps them when a recipe arrives with
                // different ones.
                if ingredient.nutritionFacts == nil, let facts = value.nutrition {
                    ingredient.setNutrition(facts, reference: value.nutritionReference, source: .imported)
                }
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
                let ingredient = importSession?.ingredient(
                    named: parsed.name,
                    household: household,
                    context: context
                ) ?? upsertIngredient(named: parsed.name, household: household, context: context)
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
        addSuggestedTags(
            to: dish,
            household: household,
            existingVocabulary: importSession?.tagVocabulary
        )
        importSession?.record(tags: dish.tagNames)

        if savesChanges { try? context.save() }
        return dish
    }

    /// What an untitled import is called until someone renames it: the site
    /// it came from, or a plain placeholder when there is not even that.
    private static func fallbackName(for recipe: ImportedRecipe) -> String {
        if let host = recipe.sourceURL?.host()?.replacingOccurrences(of: "www.", with: ""),
           !host.isEmpty {
            return String(localized: "Recipe from \(host)")
        }
        return String(localized: "New dish")
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
        dish.tagNames = DishLabelConsolidation.tags(
            existing: dish.tagNames,
            collections: recipe.collectionNames + recipe.tagNames,
            dietaryRawValues: recipe.dietaryTags.map(\.rawValue)
        )
        addSuggestedTags(to: dish, household: dish.household)
        try? context.save()
    }

    /// Replaces the web-sourced portion of an existing recipe. Unlike
    /// `apply(_:to:context:)`, this intentionally replaces old ingredient
    /// rows: a person has explicitly asked to refresh the recipe, often to
    /// recover from a source site's earlier incomplete or incorrect data.
    /// Personal organisation, photos, ratings and planning history remain
    /// untouched.
    @MainActor
    static func refresh(
        _ recipe: ImportedRecipe,
        to dish: Dish,
        context: ModelContext
    ) {
        let importedName = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !importedName.isEmpty { dish.name = importedName }
        dish.sourceURL = recipe.sourceURL ?? dish.sourceURL
        dish.deepLinkURL = recipe.deepLinkURL ?? dish.deepLinkURL
        dish.importedSourceApp = recipe.importedSourceApp ?? dish.importedSourceApp
        dish.importedSourceID = recipe.sourceIdentifier ?? dish.importedSourceID
        dish.recipeText = recipe.instructions ?? dish.recipeText
        if let servings = recipe.servings { dish.servings = servings }
        if let prep = recipe.prepTimeMinutes { dish.prepTimeMinutes = prep }
        if let cook = recipe.cookTimeMinutes { dish.cookTimeMinutes = cook }
        if let nutrition = recipe.nutritionPerServing {
            dish.setStatedNutritionPerServing(nutrition)
        }

        // A KptnCook import with no visible rows deliberately means there are
        // no trustworthy ingredients. Replace the old rows with nothing so a
        // later shopping-list rebuild can show its missing-ingredients alert.
        let replacesIngredients = !recipe.ingredientLines.isEmpty
            || recipe.structuredIngredients?.isEmpty == false
            || recipe.importedSourceApp == "KptnCook"
        if replacesIngredients {
            for line in dish.ingredients ?? [] { context.delete(line) }
            if let structured = recipe.structuredIngredients {
                for (index, value) in structured.enumerated() {
                    let ingredient = upsertIngredient(named: value.name, household: dish.household, context: context)
                    ingredient.category = value.category
                    ingredient.customAisleName = value.customAisleName
                    ingredient.isPantryStaple = ingredient.isPantryStaple || value.isPantryStaple
                    if ingredient.nutritionFacts == nil, let facts = value.nutrition {
                        ingredient.setNutrition(facts, reference: value.nutritionReference, source: .imported)
                    }
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
        }

        // Translations describe the old source wording, so retaining one
        // after a refresh would show a misleading recipe.
        dish.clearTranslation()
        dish.needsReview = recipe.needsReview
        dish.refreshAutoGlyph()
        dish.tagNames = DishLabelConsolidation.tags(
            existing: dish.tagNames,
            collections: recipe.collectionNames + recipe.tagNames,
            dietaryRawValues: recipe.dietaryTags.map(\.rawValue)
        )
        addSuggestedTags(to: dish, household: dish.household)
        try? context.save()
    }

    /// Replaces the photo the app shows for a dish while retaining any
    /// additional photos. Used when the image asset needs to be recovered from
    /// the dish's linked recipe page.
    @MainActor
    @discardableResult
    static func assignPrimaryImage(
        _ data: Data,
        to dish: Dish,
        context: ModelContext
    ) -> DishImage {
        // Dish thumbnails key their asynchronous photo request by this value,
        // so changing the primary image must invalidate that request as well
        // as the image record itself.
        dish.modifiedAt = .now
        if let primary = dish.primaryImage {
            primary.data = data
            primary.isPrimary = true
            primary.modifiedAt = .now
            for image in dish.images ?? [] where image !== primary && image.isPrimary {
                image.isPrimary = false
                image.modifiedAt = .now
            }
            return primary
        }

        let image = DishImage(data: data, sortIndex: 0, isPrimary: true)
        image.dish = dish
        context.insert(image)
        return image
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
        copy.tagNames = dish.tagNames
        copy.mealTypeTagsRaw = dish.mealTypeTagsRaw
        copy.seasonRaw = dish.seasonRaw
        copy.glyphRaw = dish.glyphRaw
        copy.glyphIsAuto = dish.glyphIsAuto
        // The variant starts out word-for-word the original, translation
        // included; editing it is what drops a translation that no longer
        // matches (see `DishEditorView.save`). The name is the cook's own.
        copy.recipeLanguageCode = dish.recipeLanguageCode
        copy.translationLanguageCode = dish.translationLanguageCode
        copy.translatedRecipeText = dish.translatedRecipeText
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
            duplicate.translatedName = line.translatedName
            duplicate.translatedNote = line.translatedNote
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
    static func addSuggestedTags(
        to dish: Dish,
        household: Household?,
        existingVocabulary: [String]? = nil,
        limit: Int = 6
    ) {
        let vocabulary = existingVocabulary ?? DishTag.vocabulary(from: household?.dishes ?? [dish])
        let suggested = DishTagSuggester.suggestions(
            for: dish,
            existingVocabulary: vocabulary,
            limit: max(0, limit - dish.tagNames.count)
        )
        dish.tagNames = DishTag.merge(dish.tagNames, adding: suggested)
    }

    @MainActor
    static func upsertIngredient(named rawName: String, household: Household?, context: ModelContext) -> Ingredient {
        IngredientIdentity.upsert(
            named: rawName,
            household: household,
            context: context,
            source: .imported,
            confidence: 0.8
        )
    }
}
