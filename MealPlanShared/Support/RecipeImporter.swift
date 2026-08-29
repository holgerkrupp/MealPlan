import Foundation

/// Result of trying to turn a URL or file into a dish.
struct ImportedRecipe: Sendable {
    var name: String
    var sourceURL: URL?
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

enum RecipeDuplicateDetector {
    @MainActor
    static func match(
        name: String,
        sourceURL: URL?,
        in dishes: [Dish],
        excluding excluded: Dish? = nil
    ) -> Dish? {
        let normalizedName = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return dishes.first { dish in
            guard dish !== excluded else { return false }
            let candidate = dish.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate == normalizedName
                || (sourceURL != nil && dish.sourceURL == sourceURL)
        }
    }

    @MainActor
    static func match(_ recipe: ImportedRecipe, in dishes: [Dish]) -> Dish? {
        match(name: recipe.name, sourceURL: recipe.sourceURL, in: dishes)
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
