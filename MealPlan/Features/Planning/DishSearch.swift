import Foundation
import SwiftData

/// Ranks the dish library for one free-text query, and remembers *why* each
/// dish surfaced. A dish found through its ingredients or tags looks like a
/// non sequitur next to one found by name, so every result carries the reason
/// the row can show.
enum DishSearch {
    struct Result: Identifiable {
        let dish: Dish
        let score: Double
        /// What matched, when it wasn't the dish's name — ready to display.
        let reason: String?

        var id: PersistentIdentifier { dish.persistentModelID }
    }

    /// Content matches rank below a name match of the same strength: someone
    /// typing "onion" wants "Onion soup" before every dish containing an onion.
    private static let ingredientWeight = 0.8
    private static let labelWeight = 0.75
    private static let methodScore = 0.6
    /// Below this a match is more noise than help.
    private static let threshold = 0.3

    /// The best matches for `query`, strongest first. An empty query keeps the
    /// order it was given, so the caller decides what an untouched field shows.
    static func rank(_ dishes: [Dish], query: String, limit: Int = 12) -> [Result] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return dishes.prefix(limit).map { Result(dish: $0, score: 0, reason: nil) }
        }
        let ranked = dishes
            .compactMap { result(for: $0, query: query) }
            .sorted {
                $0.score == $1.score
                    ? $0.dish.name.localizedCaseInsensitiveCompare($1.dish.name) == .orderedAscending
                    : $0.score > $1.score
            }
        return Array(ranked.prefix(limit))
    }

    /// True when a dish already carries exactly this name, i.e. there is
    /// nothing new to create.
    static func hasExactMatch(_ dishes: [Dish], name: String) -> Bool {
        let folded = name.searchFolded
        return !folded.isEmpty && dishes.contains { $0.name.searchFolded == folded }
    }

    /// The dish named exactly `name`, if there is one.
    static func exactMatch(_ dishes: [Dish], name: String) -> Dish? {
        let folded = name.searchFolded
        guard !folded.isEmpty else { return nil }
        return dishes.first { $0.name.searchFolded == folded }
    }

    private static func result(for dish: Dish, query: String) -> Result? {
        var best = dish.name.fuzzyScore(query: query)
        var reason: String?

        for line in dish.sortedIngredients {
            let name = (line.ingredient?.name ?? line.rawText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let score = name.fuzzyScore(query: query) * ingredientWeight
            if score > best {
                best = score
                reason = String(localized: "Contains \(name)")
            }
        }

        for label in dish.tagNames {
            let score = label.fuzzyScore(query: query) * labelWeight
            if score > best {
                best = score
                reason = label
            }
        }

        // The method is long enough that fuzzy matching it would pull in half
        // the library, so it only counts on the words as typed.
        if best < methodScore, let recipeText = dish.recipeText, !recipeText.isEmpty {
            let folded = recipeText.searchFolded
            let words = query.searchWords
            if !words.isEmpty, words.allSatisfy(folded.contains) {
                best = methodScore
                reason = String(localized: "Mentioned in the recipe")
            }
        }

        guard best >= threshold else { return nil }
        return Result(dish: dish, score: best, reason: reason)
    }
}
