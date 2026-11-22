import Foundation

/// Decides whether an extracted page should enter the recipe-first share UI.
/// Site discovery remains useful for the optional subscription footer, but it
/// must not turn a collection or a genuine feed into a fabricated recipe.
enum ShareRecipeImportPolicy {
    static func accepts(
        _ recipe: ImportedRecipe,
        classification: SharedRecipeURLKind?
    ) -> Bool {
        let hasName = !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasIngredients = recipe.ingredientLines.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasInstructions = !(recipe.instructions ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard hasName && (hasIngredients || hasInstructions) else { return false }

        switch classification {
        case .feed:
            return false
        case .recipeSite(let candidate):
            return !isCollectionPath(candidate.contentURL.path)
        default:
            return true
        }
    }

    private static func isCollectionPath(_ rawPath: String) -> Bool {
        let path = rawPath.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return true }
        let components = path.split(separator: "/").map(String.init)
        guard let first = components.first else { return true }
        if ["category", "categories", "collection", "collections", "search", "suche", "tag", "tags", "author", "authors", "blog"].contains(first) {
            return true
        }
        return ["recipes", "rezepte"].contains(path)
    }
}
