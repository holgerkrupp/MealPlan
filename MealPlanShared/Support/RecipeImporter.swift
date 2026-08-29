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
    /// Identifier of the app the recipe came from, e.g. "Paprika".
    var importedSourceApp: String?
    /// True when the data came from HTML guesswork rather than structured markup.
    var needsReview: Bool = true

    init(name: String, sourceURL: URL? = nil) {
        self.name = name
        self.sourceURL = sourceURL
    }
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
