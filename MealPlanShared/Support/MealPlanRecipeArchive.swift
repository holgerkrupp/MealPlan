import Foundation

/// Versioned, documented-by-structure JSON archive. `Data` values are encoded
/// as base64 by JSONEncoder, so the result is a single portable file that can
/// be inspected and recovered without MealPlan.
struct MealPlanRecipeArchive: Codable, Sendable {
    static let currentVersion = 1

    var format: String = "MealPlan Recipe Archive"
    var version: Int = currentVersion
    var exportedAt: Date = .now
    var recipes: [PortableRecipe]

    struct PortableRecipe: Codable, Sendable {
        var uuid: UUID
        var name: String
        var instructions: String?
        var sourceURL: String?
        var deepLinkURL: String?
        var servings: Int
        var prepTimeMinutes: Int?
        var cookTimeMinutes: Int?
        var mealTypes: [String]
        var dietaryTags: [String]
        var season: String?
        var isFavorite: Bool
        var rating: Int
        var collections: [String]
        /// Optional so archives written before tags existed still decode, and
        /// so an older MealPlan can read a newer file and simply ignore them.
        var tags: [String]?
        /// Variant grouping. Optional so older archives still decode; the
        /// identifier is reused verbatim on import, so re-importing a backup
        /// puts the same recipes back in the same group.
        var variantGroupID: UUID?
        var variantGroupName: String?
        var glyph: String?
        /// Per serving, when the recipe states its own figures. Optional so
        /// archives written before nutrition existed still decode.
        var statedEnergyKcalPerServing: Double? = nil
        var statedProteinGramsPerServing: Double? = nil
        var statedCarbGramsPerServing: Double? = nil
        var statedFatGramsPerServing: Double? = nil
        var images: [Data]
        var ingredients: [PortableIngredient]
    }

    struct PortableIngredient: Codable, Sendable {
        var name: String
        var category: String
        var customAisleName: String?
        var isPantryStaple: Bool
        var canonicalValue: Double?
        var dimension: String?
        var displayUnit: String?
        var isApproximate: Bool
        var note: String?
        var rawText: String?
        var nutritionEnergyKcal: Double? = nil
        var nutritionProteinGrams: Double? = nil
        var nutritionCarbGrams: Double? = nil
        var nutritionFatGrams: Double? = nil
        var nutritionReferenceRaw: String? = nil
    }

    @MainActor
    static func make(from dishes: [Dish]) -> MealPlanRecipeArchive {
        MealPlanRecipeArchive(recipes: dishes.map { dish in
            PortableRecipe(
                uuid: dish.uuid,
                name: dish.name,
                instructions: dish.recipeText,
                sourceURL: dish.sourceURLString,
                deepLinkURL: dish.deepLinkURLString,
                servings: dish.servings,
                prepTimeMinutes: dish.prepTimeMinutes,
                cookTimeMinutes: dish.cookTimeMinutes,
                mealTypes: dish.mealTypeTagsRaw,
                dietaryTags: dish.dietaryTagsRaw,
                season: dish.seasonRaw,
                isFavorite: dish.isFavorite,
                rating: dish.rating,
                collections: dish.collectionNames,
                tags: dish.tagNames,
                variantGroupID: dish.variantGroupID,
                variantGroupName: dish.variantGroupName,
                glyph: dish.glyphRaw,
                statedEnergyKcalPerServing: dish.statedEnergyKcalPerServing,
                statedProteinGramsPerServing: dish.statedProteinGramsPerServing,
                statedCarbGramsPerServing: dish.statedCarbGramsPerServing,
                statedFatGramsPerServing: dish.statedFatGramsPerServing,
                images: dish.sortedImages.compactMap(\.data),
                ingredients: dish.sortedIngredients.map { line in
                    PortableIngredient(
                        name: line.ingredient?.name ?? line.rawText ?? "Ingredient",
                        category: (line.ingredient?.category ?? .other).rawValue,
                        customAisleName: line.ingredient?.customAisleName,
                        isPantryStaple: line.ingredient?.isPantryStaple ?? false,
                        canonicalValue: line.canonicalValue,
                        dimension: line.canonicalDimensionRaw,
                        displayUnit: line.displayUnit,
                        isApproximate: line.isApproximate,
                        note: line.note,
                        rawText: line.rawText,
                        nutritionEnergyKcal: line.ingredient?.nutritionEnergyKcal,
                        nutritionProteinGrams: line.ingredient?.nutritionProteinGrams,
                        nutritionCarbGrams: line.ingredient?.nutritionCarbGrams,
                        nutritionFatGrams: line.ingredient?.nutritionFatGrams,
                        nutritionReferenceRaw: line.ingredient?.nutritionReferenceRaw
                    )
                }
            )
        })
    }

    @MainActor
    static func data(from dishes: [Dish]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(make(from: dishes))
    }

    static func decode(_ data: Data) throws -> MealPlanRecipeArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(MealPlanRecipeArchive.self, from: data)
        guard archive.format == "MealPlan Recipe Archive", archive.version <= currentVersion else {
            throw RecipeImportError.unreadableFile
        }
        return archive
    }

    static func importedRecipes(from data: Data) throws -> [ImportedRecipe] {
        try decode(data).recipes.map { stored in
            var recipe = ImportedRecipe(name: stored.name, sourceURL: stored.sourceURL.flatMap(URL.init(string:)))
            recipe.deepLinkURL = stored.deepLinkURL.flatMap(URL.init(string:))
            recipe.instructions = stored.instructions
            recipe.servings = stored.servings
            recipe.prepTimeMinutes = stored.prepTimeMinutes
            recipe.cookTimeMinutes = stored.cookTimeMinutes
            recipe.categories = stored.collections
            recipe.isFavorite = stored.isFavorite
            recipe.rating = stored.rating
            recipe.collectionNames = stored.collections
            recipe.tagNames = stored.tags ?? []
            recipe.variantGroupID = stored.variantGroupID
            recipe.variantGroupName = stored.variantGroupName
            recipe.mealTypeTags = Set(stored.mealTypes.compactMap(MealTypeTag.init(rawValue:)))
            recipe.dietaryTags = Set(stored.dietaryTags.compactMap(DietaryTag.init(rawValue:)))
            recipe.season = stored.season.flatMap(Season.init(rawValue:))
            recipe.glyph = stored.glyph.flatMap(DishGlyph.init(rawValue:))
            if let energy = stored.statedEnergyKcalPerServing {
                recipe.nutritionPerServing = NutritionFacts(
                    energyKcal: energy,
                    proteinGrams: stored.statedProteinGramsPerServing ?? 0,
                    carbGrams: stored.statedCarbGramsPerServing ?? 0,
                    fatGrams: stored.statedFatGramsPerServing ?? 0
                )
            }
            recipe.imageData = stored.images.first
            recipe.additionalImageData = Array(stored.images.dropFirst())
            recipe.ingredientLines = stored.ingredients.map { $0.rawText ?? $0.name }
            recipe.structuredIngredients = stored.ingredients.map { line in
                ImportedIngredient(
                    name: line.name,
                    category: IngredientCategory(rawValue: line.category) ?? .other,
                    customAisleName: line.customAisleName,
                    isPantryStaple: line.isPantryStaple,
                    canonicalValue: line.canonicalValue,
                    dimension: line.dimension.flatMap(QuantityDimension.init(rawValue:)),
                    displayUnit: line.displayUnit,
                    isApproximate: line.isApproximate,
                    note: line.note,
                    rawText: line.rawText,
                    nutrition: line.nutritionEnergyKcal.map {
                        NutritionFacts(
                            energyKcal: $0,
                            proteinGrams: line.nutritionProteinGrams ?? 0,
                            carbGrams: line.nutritionCarbGrams ?? 0,
                            fatGrams: line.nutritionFatGrams ?? 0
                        )
                    },
                    nutritionReference: line.nutritionReferenceRaw
                        .flatMap(NutritionReference.init(rawValue:)) ?? .per100Grams
                )
            }
            recipe.needsReview = false
            recipe.importedSourceApp = "MealPlan"
            // The exported dish's own id, so re-importing a backup recognises
            // its recipes even after they were renamed here.
            recipe.sourceIdentifier = stored.uuid.uuidString
            return recipe
        }
    }

    @MainActor
    static func temporaryFile(for dishes: [Dish]) throws -> URL {
        let base = dishes.count == 1 ? dishes[0].name : "MealPlan Recipes"
        let safe = base.replacingOccurrences(of: #"[^A-Za-z0-9À-ž _-]"#, with: "", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(safe.isEmpty ? "Recipes" : safe)-\(UUID().uuidString.prefix(8)).mealplanrecipes")
        try data(from: dishes).write(to: url, options: .atomic)
        return url
    }
}
