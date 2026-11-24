import Foundation
import SwiftData

/// Creates a `Dish` (with parsed ingredients + image) from an `ImportedRecipe`.
/// Shared by the app's importer and the Share Extension so both behave alike.
enum DishBuilder {

    /// The fields a refresh is allowed to replace after the cook reviews the
    /// extraction. Personal recipe content is deliberately opt-in.
    struct RefreshSelection: Equatable, Sendable {
        var title = false
        var ingredients = false
        var instructions = false
        var servings = false
        var prepTime = false
        var cookTime = false
        var nutrition = false
        var sourceURL = true

        static func conservative(for dish: Dish, result: RecipeExtractionResult) -> Self {
            let ingredientsAvailable = result.fieldQuality[.ingredients, default: 0] >= 0.5
                && (!result.recipe.ingredientLines.isEmpty || result.recipe.structuredIngredients?.isEmpty == false)
            let instructionsAvailable = result.fieldQuality[.instructions, default: 0] >= 0.35
                && !(result.recipe.instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return Self(
                title: dish.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                ingredients: (dish.ingredients ?? []).isEmpty && ingredientsAvailable,
                instructions: (dish.recipeText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && instructionsAvailable,
                servings: dish.servings <= 0 && result.recipe.servings != nil,
                prepTime: dish.prepTimeMinutes == nil && result.recipe.prepTimeMinutes != nil,
                cookTime: dish.cookTimeMinutes == nil && result.recipe.cookTimeMinutes != nil,
                nutrition: dish.statedNutritionPerServing == nil && result.recipe.nutritionPerServing != nil,
                sourceURL: result.recipe.sourceURL != nil
            )
        }

        static let all = Self(
            title: true,
            ingredients: true,
            instructions: true,
            servings: true,
            prepTime: true,
            cookTime: true,
            nutrition: true,
            sourceURL: true
        )
    }

    /// State shared by every recipe in one bulk import. It avoids repeatedly
    /// traversing SwiftData relationships for the household's complete
    /// ingredient catalogue and tag vocabulary.
    @MainActor
    final class ImportSession {
        fileprivate let identifier = UUID()
        private var ingredientMatcher: IngredientMatcher
        private var resolvedIngredients: [String: Ingredient] = [:]
        private var newlyCreatedIngredientIDs: Set<UUID> = []
        private var metadataInitializedIngredientIDs: Set<UUID> = []
        fileprivate private(set) var tagVocabulary: [String]

        init(household: Household?) {
            tagVocabulary = DishTag.vocabulary(from: household?.dishes ?? [])
            ingredientMatcher = IngredientMatcher(
                ingredients: household?.ingredients ?? [],
                rules: household?.matchRules ?? []
            )
        }

        fileprivate func ingredient(
            named rawName: String,
            household: Household?,
            context: ModelContext
        ) -> Ingredient {
            let normalized = Ingredient.normalize(rawName)
            if !normalized.isEmpty, let cached = resolvedIngredients[normalized] {
                IngredientIntegrityDiagnostics.record(
                    .importIngredientResolution, importSessionID: identifier, ingredientUUID: cached.uuid, reusedIngredient: true
                )
                return cached
            }
            let match = ingredientMatcher.result(for: rawName)
            if let existing = match.candidate, match.isSafeForSilentReuse {
                resolvedIngredients[normalized] = existing
                IngredientIdentity.addAlias(
                    named: rawName,
                    to: existing,
                    source: .imported,
                    confidence: 0.8,
                    context: context
                )
                IngredientIntegrityDiagnostics.record(
                    .importIngredientResolution, importSessionID: identifier, ingredientUUID: existing.uuid,
                    matchClass: match.matchClass, matchReasons: match.reasons, reusedIngredient: true
                )
                return existing
            }

            let ingredient = Ingredient(name: rawName.isEmpty ? String(localized: "Ingredient") : rawName)
            ingredient.household = household
            context.insert(ingredient)
            newlyCreatedIngredientIDs.insert(ingredient.uuid)
            IngredientIntegrityDiagnostics.record(
                .importedNewIngredient, importSessionID: identifier, ingredientUUID: ingredient.uuid,
                matchClass: match.matchClass, matchReasons: match.reasons, reusedIngredient: false,
                queuedMergeSuggestion: match.matchClass == .needsConfirmation
            )
            IngredientIdentity.queueMergeSuggestion(for: rawName, result: match, on: ingredient)
            if !ingredient.pendingMergeSuggestions.isEmpty {
                IngredientIntegrityDiagnostics.record(
                    .mergeSuggestionQueued, importSessionID: identifier, ingredientUUID: ingredient.uuid,
                    matchClass: match.matchClass, matchReasons: match.reasons, queuedMergeSuggestion: true
                )
            }
            ingredientMatcher.add(ingredient)
            if !normalized.isEmpty { resolvedIngredients[normalized] = ingredient }
            return ingredient
        }

        /// Import payloads describe a recipe line, not an authority to rewrite
        /// a household-wide catalogue row. Only a row created by this import
        /// session receives source metadata; reused ingredients retain every
        /// setting made for the other recipes that already use them.
        fileprivate func applyImportedMetadata(_ value: ImportedIngredient, to ingredient: Ingredient) {
            guard newlyCreatedIngredientIDs.contains(ingredient.uuid),
                  metadataInitializedIngredientIDs.insert(ingredient.uuid).inserted
            else {
                let conflicts = [
                    ingredient.category != value.category,
                    ingredient.customAisleName != value.customAisleName,
                    value.isPantryStaple && !ingredient.isPantryStaple,
                    value.nutrition != nil && ingredient.nutritionFacts != value.nutrition,
                ].filter { $0 }.count
                if conflicts > 0 {
                    IngredientIntegrityDiagnostics.record(.ignoredImportedMetadataForExistingIngredient, detail: "fields=\(conflicts)")
                }
                return
            }
            ingredient.category = value.category
            ingredient.customAisleName = value.customAisleName
            ingredient.isPantryStaple = value.isPantryStaple
            if let facts = value.nutrition {
                ingredient.setNutrition(facts, reference: value.nutritionReference, source: .imported)
            }
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
        let ingredientSession = importSession ?? ImportSession(household: household)
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
        dish.yieldUnitRaw = recipe.yieldUnitRaw
        dish.yieldLabel = recipe.yieldLabel
        dish.prepTimeMinutes = recipe.prepTimeMinutes
        dish.cookTimeMinutes = recipe.cookTimeMinutes
        dish.needsReview = recipe.needsReview || importedName.isEmpty
        dish.isFavorite = recipe.isFavorite
        dish.rating = min(max(recipe.rating, 0), 5)
        dish.tagNames = DishLabelConsolidation.tags(
            existing: recipe.tagNames,
            dietaryRawValues: recipe.dietaryTags.map(\.rawValue)
        )
        dish.collectionNames = DishTag.merge(recipe.collectionNames)
        dish.mealTypeTags = recipe.mealTypeTags
        dish.season = recipe.season
        dish.setStatedNutritionPerServing(recipe.nutritionPerServing)
        if let glyph = recipe.glyph {
            dish.glyph = glyph
            dish.glyphIsAuto = false
        }
        context.insert(dish)
        IngredientIntegrityDiagnostics.record(.importDishCreated, importSessionID: ingredientSession.identifier, dishUUID: dish.uuid)

        for (index, imageData) in ([recipe.imageData].compactMap { $0 } + recipe.additionalImageData).enumerated() {
            let image = DishImage(data: imageData, sortIndex: index, isPrimary: index == 0)
            image.dish = dish
            context.insert(image)
        }

        if let structured = recipe.structuredIngredients {
            for (index, value) in structured.enumerated() {
                let ingredient = ingredientSession.ingredient(
                    named: value.name,
                    household: household,
                    context: context
                )
                ingredientSession.applyImportedMetadata(value, to: ingredient)
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
                IngredientIntegrityDiagnostics.record(
                    .importIngredientResolution, importSessionID: ingredientSession.identifier, dishUUID: dish.uuid,
                    dishIngredientUUID: line.uuid, ingredientUUID: ingredient.uuid
                )
            }
        } else {
            for (index, rawLine) in recipe.ingredientLines.enumerated() {
                let parsed = GermanUnitParser.parse(rawLine)
                let ingredient = ingredientSession.ingredient(
                    named: parsed.name,
                    household: household,
                    context: context
                )
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
                IngredientIntegrityDiagnostics.record(
                    .importIngredientResolution, importSessionID: ingredientSession.identifier, dishUUID: dish.uuid,
                    dishIngredientUUID: line.uuid, ingredientUUID: ingredient.uuid
                )
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

        if savesChanges { persist(context) }
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
            if dish.yieldUnitRaw == nil, let yieldUnitRaw = recipe.yieldUnitRaw {
                dish.yieldUnitRaw = yieldUnitRaw
                dish.yieldLabel = recipe.yieldLabel
            }
        }

        if (dish.images ?? []).isEmpty, let imageData = recipe.imageData {
            let image = DishImage(data: imageData, isPrimary: true)
            image.dish = dish
            context.insert(image)
        }

        if (dish.ingredients ?? []).isEmpty {
            let importSession = ImportSession(household: dish.household)
            for (index, rawLine) in recipe.ingredientLines.enumerated() {
                let parsed = GermanUnitParser.parse(rawLine)
                let ingredient = importSession.ingredient(
                    named: parsed.name,
                    household: dish.household,
                    context: context
                )
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
            existing: DishTag.merge(dish.tagNames, adding: recipe.tagNames),
            dietaryRawValues: recipe.dietaryTags.map(\.rawValue)
        )
        dish.collectionNames = DishTag.merge(dish.collectionNames, adding: recipe.collectionNames)
        addSuggestedTags(to: dish, household: dish.household)
        persist(context)
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
        context: ModelContext,
        selection: RefreshSelection = .all
    ) throws {
        let oldLines = dish.sortedIngredients
        let oldState = RefreshState(dish: dish)
        var newLines: [DishIngredient] = []

        do {
            try context.transaction {
                if selection.ingredients, let incoming = refreshIngredientValues(from: recipe), !incoming.isEmpty {
                    let importSession = ImportSession(household: dish.household)
                    newLines = incoming.enumerated().map { index, value in
                        let ingredient: Ingredient
                        let line: DishIngredient
                        switch value {
                        case .structured(let imported):
                            ingredient = importSession.ingredient(named: imported.name, household: dish.household, context: context)
                            importSession.applyImportedMetadata(imported, to: ingredient)
                            line = DishIngredient(
                                canonicalValue: imported.canonicalValue,
                                dimension: imported.dimension,
                                displayUnit: imported.displayUnit,
                                isApproximate: imported.isApproximate,
                                note: imported.note,
                                rawText: imported.rawText,
                                sortIndex: index
                            )
                        case .raw(let raw):
                            let parsed = GermanUnitParser.parse(raw)
                            ingredient = importSession.ingredient(named: parsed.name, household: dish.household, context: context)
                            line = DishIngredient(
                                canonicalValue: parsed.quantity?.value,
                                dimension: parsed.quantity?.dimension,
                                displayUnit: parsed.displayUnit,
                                isApproximate: parsed.isApproximate,
                                note: parsed.note,
                                rawText: parsed.rawText,
                                sortIndex: index
                            )
                        }
                        line.dish = dish
                        line.ingredient = ingredient
                        context.insert(line)
                        return line
                    }
                    oldLines.forEach(context.delete)
                    dish.ingredients = newLines
                }

                if selection.title {
                    let importedName = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !importedName.isEmpty { dish.name = importedName }
                }
                if selection.sourceURL, let sourceURL = recipe.sourceURL {
                    dish.sourceURL = sourceURL
                    dish.deepLinkURL = recipe.deepLinkURL ?? dish.deepLinkURL
                    dish.importedSourceApp = recipe.importedSourceApp ?? dish.importedSourceApp
                    dish.importedSourceID = recipe.sourceIdentifier ?? dish.importedSourceID
                }
                if selection.instructions, let instructions = recipe.instructions,
                   !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    dish.recipeText = instructions
                }
                if selection.servings, let servings = recipe.servings, servings > 0 {
                    dish.servings = servings
                    if dish.yieldUnitRaw == nil, let yieldUnitRaw = recipe.yieldUnitRaw {
                        dish.yieldUnitRaw = yieldUnitRaw
                        dish.yieldLabel = recipe.yieldLabel
                    }
                }
                if selection.prepTime, let prep = recipe.prepTimeMinutes { dish.prepTimeMinutes = prep }
                if selection.cookTime, let cook = recipe.cookTimeMinutes { dish.cookTimeMinutes = cook }
                if selection.nutrition, let nutrition = recipe.nutritionPerServing {
                    dish.setStatedNutritionPerServing(nutrition)
                }

                let contentChanged = selection.title || selection.ingredients || selection.instructions
                if contentChanged {
                    // Translations describe the old source wording, so retaining
                    // one after a content refresh would be misleading.
                    dish.clearTranslation()
                    dish.needsReview = recipe.needsReview
                    dish.refreshAutoGlyph()
                }
                try context.save()
            }
        } catch {
            for line in newLines { context.delete(line) }
            dish.ingredients = oldLines
            for line in oldLines { line.dish = dish }
            oldState.restore(on: dish)
            throw error
        }
    }

    /// Returns only exact normalized repeats. Different quantities, notes or
    /// sections remain distinct; this is a review signal, never automatic
    /// deduplication.
    static func suspiciousDuplicateIngredientIndices(_ recipe: ImportedRecipe) -> Set<Int> {
        let keys: [String]
        if let structured = recipe.structuredIngredients {
            keys = structured.map {
                let amount = $0.canonicalValue.map { String($0) } ?? ""
                return [Ingredient.normalize($0.name), amount, $0.dimension?.rawValue ?? "", $0.displayUnit ?? "", $0.note ?? ""].joined(separator: "|")
            }
        } else {
            keys = recipe.ingredientLines.map {
                let parsed = GermanUnitParser.parse($0)
                let amount = parsed.quantity.map { String($0.value) } ?? ""
                return [Ingredient.normalize(parsed.name), amount, parsed.quantity?.dimension.rawValue ?? "", parsed.displayUnit ?? "", parsed.note ?? ""].joined(separator: "|")
            }
        }
        var seen = Set<String>()
        var duplicates = Set<Int>()
        for (index, key) in keys.enumerated() where !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !seen.insert(key).inserted { duplicates.insert(index) }
        }
        return duplicates
    }

    private enum RefreshIngredientValue {
        case structured(ImportedIngredient)
        case raw(String)
    }

    private static func refreshIngredientValues(from recipe: ImportedRecipe) -> [RefreshIngredientValue]? {
        if let structured = recipe.structuredIngredients, !structured.isEmpty {
            return structured.map(RefreshIngredientValue.structured)
        }
        let raw = recipe.ingredientLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return raw.isEmpty ? nil : raw.map(RefreshIngredientValue.raw)
    }

    private struct RefreshState {
        let name: String
        let sourceURLString: String?
        let deepLinkURLString: String?
        let importedSourceApp: String?
        let importedSourceID: String?
        let recipeText: String?
        let servings: Int
        let yieldUnitRaw: String?
        let yieldLabel: String?
        let prepTimeMinutes: Int?
        let cookTimeMinutes: Int?
        let statedNutrition: NutritionFacts?
        let statedNutritionProvenanceRaw: String?
        let translationLanguageCode: String?
        let translatedName: String?
        let translatedRecipeText: String?
        let needsReview: Bool
        let glyphRaw: String?
        let glyphIsAuto: Bool

        init(dish: Dish) {
            name = dish.name
            sourceURLString = dish.sourceURLString
            deepLinkURLString = dish.deepLinkURLString
            importedSourceApp = dish.importedSourceApp
            importedSourceID = dish.importedSourceID
            recipeText = dish.recipeText
            servings = dish.servings
            yieldUnitRaw = dish.yieldUnitRaw
            yieldLabel = dish.yieldLabel
            prepTimeMinutes = dish.prepTimeMinutes
            cookTimeMinutes = dish.cookTimeMinutes
            statedNutrition = dish.statedNutritionPerServing
            statedNutritionProvenanceRaw = dish.statedNutritionProvenanceRaw
            translationLanguageCode = dish.translationLanguageCode
            translatedName = dish.translatedName
            translatedRecipeText = dish.translatedRecipeText
            needsReview = dish.needsReview
            glyphRaw = dish.glyphRaw
            glyphIsAuto = dish.glyphIsAuto
        }

        func restore(on dish: Dish) {
            dish.name = name
            dish.sourceURLString = sourceURLString
            dish.deepLinkURLString = deepLinkURLString
            dish.importedSourceApp = importedSourceApp
            dish.importedSourceID = importedSourceID
            dish.recipeText = recipeText
            dish.servings = servings
            dish.yieldUnitRaw = yieldUnitRaw
            dish.yieldLabel = yieldLabel
            dish.prepTimeMinutes = prepTimeMinutes
            dish.cookTimeMinutes = cookTimeMinutes
            dish.setStatedNutritionPerServing(statedNutrition)
            dish.statedNutritionProvenanceRaw = statedNutritionProvenanceRaw
            dish.translationLanguageCode = translationLanguageCode
            dish.translatedName = translatedName
            dish.translatedRecipeText = translatedRecipeText
            dish.needsReview = needsReview
            dish.glyphRaw = glyphRaw
            dish.glyphIsAuto = glyphIsAuto
        }
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
        copy.yieldUnitRaw = dish.yieldUnitRaw
        copy.yieldLabel = dish.yieldLabel
        copy.prepTimeMinutes = dish.prepTimeMinutes
        copy.cookTimeMinutes = dish.cookTimeMinutes
        copy.needsReview = dish.needsReview
        copy.rating = dish.rating
        copy.tagNames = dish.tagNames
        copy.collectionNames = dish.collectionNames
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
        persist(context)
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

    @MainActor
    private static func persist(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            IngredientIntegrityDiagnostics.record(.persistenceSaveFailed, detail: "dish-import")
        }
    }
}
