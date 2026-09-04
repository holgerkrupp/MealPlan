import Foundation

/// Result of trying to turn a URL or file into a dish.
struct ImportedRecipe: Sendable {
    var name: String
    var sourceURL: URL?
    /// An optional custom-scheme or universal link that opens the recipe in
    /// its source app. Kept separate from the browser-friendly source URL.
    var deepLinkURL: URL?
    var imageData: Data?
    var imageURLString: String?
    var ingredientLines: [String] = []
    var instructions: String?
    var servings: Int?
    var prepTimeMinutes: Int?
    var cookTimeMinutes: Int?
    var categories: [String] = []
    var isFavorite: Bool = false
    var rating: Int = 0
    var collectionNames: [String] = []
    /// Free-form tags carried over from the source (schema.org keywords,
    /// Paprika categories, a MealPlan archive). Merged with the tags the app
    /// derives itself in `DishBuilder`.
    var tagNames: [String] = []
    var mealTypeTags: Set<MealTypeTag> = []
    var dietaryTags: Set<DietaryTag> = []
    var season: Season?
    var glyph: DishGlyph?
    /// Present for MealPlan's own portable format. Other importers continue
    /// to provide raw ingredient lines and use the locale-aware parser.
    var structuredIngredients: [ImportedIngredient]?
    var additionalImageData: [Data] = []
    /// Identifier of the app the recipe came from, e.g. "Paprika".
    var importedSourceApp: String?
    /// The source app's own stable identifier for the recipe (Paprika's
    /// `uid`). Used by the duplicate check, which trusts it over the name.
    var sourceIdentifier: String?
    /// Variant grouping carried by MealPlan's own archive format, so a backup
    /// restores the groups it was exported with.
    var variantGroupID: UUID?
    var variantGroupName: String?
    /// What the source said one serving contains, when it said anything.
    /// schema.org recipes carry a `NutritionInformation` block often enough to
    /// be worth reading, and a figure the recipe's own author published beats
    /// anything MealPlan can add up from an ingredient list.
    var nutritionPerServing: NutritionFacts?
    /// True when the data came from HTML guesswork rather than structured markup.
    var needsReview: Bool = true

    init(name: String, sourceURL: URL? = nil) {
        self.name = name
        self.sourceURL = sourceURL
    }
}

struct ImportedIngredient: Sendable {
    var name: String
    var category: IngredientCategory
    var customAisleName: String? = nil
    var isPantryStaple: Bool
    var canonicalValue: Double?
    var dimension: QuantityDimension?
    var displayUnit: String?
    var isApproximate: Bool
    var note: String?
    var rawText: String?
    /// Values the exporting household had entered for this ingredient, so a
    /// shared recipe arrives knowing what its ingredients contain instead of
    /// falling back to generic reference figures.
    var nutrition: NutritionFacts? = nil
    var nutritionReference: NutritionReference = .per100Grams
}

enum RecipeImportError: LocalizedError {
    case notReachable
    case noRecipeFound
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .notReachable: String(localized: "Couldn’t reach that page.")
        case .noRecipeFound: String(localized: "No recipe found on that page.")
        case .unreadableFile: String(localized: "That file couldn’t be read.")
        }
    }
}

/// Turns a recipe URL into an `ImportedRecipe`.
protocol RecipeImporter: Sendable {
    func importRecipe(from url: URL) async throws -> ImportedRecipe
}

/// Records only the URL + site name. Kept as a fallback / for tests.
struct StubRecipeImporter: RecipeImporter {
    func importRecipe(from url: URL) async throws -> ImportedRecipe {
        let name = url.host()?
            .replacingOccurrences(of: "www.", with: "")
            ?? String(localized: "Imported recipe")
        var recipe = ImportedRecipe(name: name.capitalized, sourceURL: url)
        recipe.needsReview = true
        return recipe
    }
}
