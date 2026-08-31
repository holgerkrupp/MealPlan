import Foundation
import SwiftData

/// What importing one recipe would do to the library.
///
/// The distinction that matters is between a recipe the household already has
/// (skip it) and *another take on the same dish* (keep it, as a variant). The
/// old check treated any name collision as a duplicate, which is why a second
/// Burger or Bolognese could never be imported at all.
enum RecipeImportOutcome: Equatable {
    /// Nothing like it in the library.
    case new
    /// Byte-for-byte the same recipe as one already stored.
    case duplicate(DishReferenceInfo)
    /// Same dish, different recipe — import it into a shared variant group.
    case variant(DishReferenceInfo)
    /// The export itself lists this recipe twice.
    case duplicateInFile(String)

    var isSkippedByDefault: Bool {
        switch self {
        case .duplicate, .duplicateInFile: true
        case .new, .variant: false
        }
    }
}

/// Enough about a matched dish to describe the match without holding the model
/// object in a `Sendable` value.
struct DishReferenceInfo: Equatable, Hashable {
    var uuid: UUID
    var name: String
}

/// One row of an import.
struct PlannedRecipeImport: Identifiable {
    let id = UUID()
    var recipe: ImportedRecipe
    var outcome: RecipeImportOutcome
    /// Whether the user wants this one. Pre-set from the outcome; the review
    /// sheet lets them override either way.
    var include: Bool
}

/// Works out, for a whole file at once, what is new, what is a variant and
/// what is already there — including recipes an export lists twice.
enum RecipeImportPlanner {

    @MainActor
    static func plan(_ recipes: [ImportedRecipe], against dishes: [Dish]) -> [PlannedRecipeImport] {
        var accepted: [ImportedRecipe] = []
        var planned: [PlannedRecipeImport] = []

        for recipe in recipes {
            let outcome: RecipeImportOutcome
            if let twin = accepted.first(where: { areSameRecipe($0, recipe) }) {
                outcome = .duplicateInFile(twin.name)
            } else if let match = RecipeDuplicateDetector.duplicate(of: recipe, in: dishes) {
                outcome = .duplicate(DishReferenceInfo(uuid: match.uuid, name: match.name))
            } else if let match = RecipeDuplicateDetector.sameDish(as: recipe, in: dishes) {
                outcome = .variant(DishReferenceInfo(uuid: match.uuid, name: match.name))
            } else {
                outcome = .new
            }
            if !outcome.isSkippedByDefault { accepted.append(recipe) }
            planned.append(PlannedRecipeImport(
                recipe: recipe, outcome: outcome, include: !outcome.isSkippedByDefault
            ))
        }
        return planned
    }

    /// Two incoming recipes describing the same thing. Same rules as the
    /// against-the-library check, minus the stored-dish plumbing.
    static func areSameRecipe(_ lhs: ImportedRecipe, _ rhs: ImportedRecipe) -> Bool {
        if let left = lhs.sourceIdentifier?.nilIfEmpty, let right = rhs.sourceIdentifier?.nilIfEmpty {
            return left == right
        }
        guard RecipeDuplicateDetector.normalizedName(lhs.name)
            == RecipeDuplicateDetector.normalizedName(rhs.name) else { return false }
        return RecipeDuplicateDetector.ingredientsOverlap(
            RecipeDuplicateDetector.signature(of: lhs.ingredientLines),
            RecipeDuplicateDetector.signature(of: rhs.ingredientLines)
        )
    }
}

enum RecipeDuplicateDetector {

    /// How much of two ingredient lists must coincide before the recipes count
    /// as the same one rather than two takes on the same dish. Deliberately
    /// high: mislabelling a genuine variant as a duplicate loses a recipe,
    /// while the opposite merely leaves one to merge by hand.
    static let sameRecipeOverlap = 0.8

    // MARK: - Matching against the library

    /// A stored dish that is the *same recipe*, so importing it again would
    /// add nothing.
    @MainActor
    static func duplicate(of recipe: ImportedRecipe, in dishes: [Dish], excluding excluded: Dish? = nil) -> Dish? {
        let candidates = dishes.filter { $0 !== excluded }

        // The source app's own identifier survives renaming and re-export.
        if let sourceID = recipe.sourceIdentifier?.nilIfEmpty,
           let match = candidates.first(where: { $0.importedSourceID == sourceID }) {
            return match
        }
        if let key = urlKey(recipe.sourceURL),
           let match = candidates.first(where: { urlKey($0.sourceURL) == key }) {
            return match
        }
        let name = normalizedName(recipe.name)
        guard !name.isEmpty else { return nil }
        let incoming = signature(of: recipe.ingredientLines)
        return candidates.first { dish in
            normalizedName(dish.name) == name
                && ingredientsOverlap(incoming, signature(of: dish))
        }
    }

    /// A stored dish that is the same *dish* but a different recipe — another
    /// Burger, another Bolognese. The caller groups the two as variants.
    @MainActor
    static func sameDish(as recipe: ImportedRecipe, in dishes: [Dish], excluding excluded: Dish? = nil) -> Dish? {
        let name = normalizedName(recipe.name)
        guard !name.isEmpty else { return nil }
        return dishes.first { $0 !== excluded && normalizedName($0.name) == name }
    }

    /// Kept for callers that only want to know "is this name already taken",
    /// such as the dish editor's rename check.
    ///
    /// Siblings in `excluded`'s own variant group never count: sharing a name
    /// with the other takes on the same dish is the whole point of a group.
    @MainActor
    static func match(
        name: String,
        sourceURL: URL?,
        in dishes: [Dish],
        excluding excluded: Dish? = nil
    ) -> Dish? {
        let normalized = normalizedName(name)
        let key = urlKey(sourceURL)
        let ownGroup = excluded?.variantGroupID
        return dishes.first { dish in
            guard dish !== excluded else { return false }
            if let ownGroup, dish.variantGroupID == ownGroup { return false }
            if !normalized.isEmpty, normalizedName(dish.name) == normalized { return true }
            return key != nil && urlKey(dish.sourceURL) == key
        }
    }

    @MainActor
    static func match(_ recipe: ImportedRecipe, in dishes: [Dish]) -> Dish? {
        match(name: recipe.name, sourceURL: recipe.sourceURL, in: dishes)
    }

    // MARK: - Signals

    static func normalizedName(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A source URL reduced to the part that identifies the recipe. Recipe
    /// sites append serving counts and tracking parameters, so the same
    /// Chefkoch recipe exported twice arrives under two URLs.
    static func urlKey(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.query = nil
        components.fragment = nil
        guard var key = components.string?.lowercased(), !key.isEmpty else { return nil }
        while key.hasSuffix("/") { key.removeLast() }
        return key.isEmpty ? nil : key
    }

    /// The set of ingredient names a recipe uses, which is what actually tells
    /// two recipes for the same dish apart.
    static func signature(of lines: [String]) -> Set<String> {
        Set(lines.compactMap { line in
            let name = Ingredient.normalize(GermanUnitParser.parse(line).name)
            return name.count > 1 ? name : nil
        })
    }

    @MainActor
    static func signature(of dish: Dish) -> Set<String> {
        Set(dish.sortedIngredients.compactMap { line in
            let raw = line.ingredient?.name ?? line.rawText ?? ""
            let name = Ingredient.normalize(raw)
            return name.count > 1 ? name : nil
        })
    }

    /// True when two ingredient sets are close enough to be the same recipe.
    /// Two recipes that both list nothing are compared on their names alone,
    /// which is all the information there is.
    static func ingredientsOverlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
        if lhs.isEmpty || rhs.isEmpty { return true }
        let shared = Double(lhs.intersection(rhs).count)
        return shared / Double(max(lhs.count, rhs.count)) >= sameRecipeOverlap
    }
}
