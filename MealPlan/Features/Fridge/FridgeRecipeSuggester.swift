import Foundation

struct FridgeRecipeSuggestion: Identifiable {
    var id: UUID { dish.uuid }
    let dish: Dish
    let matchedIngredients: [String]
    let missingIngredients: [String]
    let useSoonIngredients: [String]
    let score: Double
}

/// A presentation-only ranking over the existing dish and ingredient models.
/// It intentionally does not persist anything and uses the same ingredient
/// matcher as shopping-list generation and recipe editing.
enum FridgeRecipeSuggester {
    static func suggestions(
        dishes: [Dish],
        available: [Ingredient],
        useSoon: [Ingredient],
        selected: [Ingredient] = [],
        limit: Int = 6
    ) -> [FridgeRecipeSuggestion] {
        let source = selected.isEmpty ? available : selected
        guard !source.isEmpty else { return [] }
        let soon = useSoon.map { IngredientMatching.key(for: $0.name) }

        return dishes.compactMap { dish in
            guard !dish.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            let names = dish.sortedIngredients.compactMap { line -> String? in
                let name = line.ingredient?.name ?? line.rawText
                return name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name : nil
            }
            guard !names.isEmpty else { return nil }

            var matched: [String] = []
            var missing: [String] = []
            var soonMatches: [String] = []
            for name in names {
                if source.contains(where: { IngredientMatching.keysMatch(IngredientMatching.key(for: $0.name), IngredientMatching.key(for: name)) }) {
                    matched.append(name)
                    if soon.contains(where: { IngredientMatching.keysMatch($0, IngredientMatching.key(for: name)) }) {
                        soonMatches.append(name)
                    }
                } else {
                    missing.append(name)
                }
            }

            guard !matched.isEmpty else { return nil }
            let coverage = Double(matched.count) / Double(names.count)
            let score = coverage * 100
                + Double(soonMatches.count) * 20
                - Double(missing.count) * 12
                + (missing.isEmpty ? 25 : 0)

            return FridgeRecipeSuggestion(
                dish: dish,
                matchedIngredients: matched,
                missingIngredients: missing,
                useSoonIngredients: soonMatches,
                score: score
            )
        }
        .sorted {
            if abs($0.score - $1.score) > 0.000_001 { return $0.score > $1.score }
            return $0.dish.name.localizedCaseInsensitiveCompare($1.dish.name) == .orderedAscending
        }
        .prefix(max(0, limit))
        .map { $0 }
    }
}
