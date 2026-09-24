import Foundation
import SwiftData

/// The one place where a raw recipe spelling becomes a catalogue identity.
@MainActor
enum IngredientIdentity {
    static func resolve(named rawName: String, in ingredients: [Ingredient]) -> Ingredient? {
        IngredientMatching.match(rawName, in: ingredients)
    }

    @discardableResult
    static func addAlias(
        named rawName: String,
        to ingredient: Ingredient,
        source: IngredientAliasSource,
        confidence: Double? = nil,
        context: ModelContext
    ) -> IngredientAlias? {
        let normalized = Ingredient.normalize(rawName)
        guard !normalized.isEmpty, normalized != ingredient.normalizedName else { return nil }
        if let existing = (ingredient.aliases ?? []).first(where: { $0.normalizedName == normalized }) {
            // A later explicit confirmation is stronger evidence than an
            // automatic/imported observation of the same spelling.
            if source == .userConfirmed, existing.source != .userConfirmed {
                existing.source = source
                existing.confidence = confidence ?? 1
                existing.modifiedAt = .now
            }
            return existing
        }

        let alias = IngredientAlias(name: rawName, source: source, confidence: confidence)
        alias.ingredient = ingredient
        context.insert(alias)
        return alias
    }

    @discardableResult
    static func upsert(
        named rawName: String,
        household: Household?,
        context: ModelContext,
        source: IngredientAliasSource = .automatic,
        confidence: Double? = nil
    ) -> Ingredient {
        if let existing = resolve(named: rawName, in: household?.ingredients ?? []) {
            addAlias(
                named: rawName,
                to: existing,
                source: source,
                confidence: confidence,
                context: context
            )
            return existing
        }

        let ingredient = Ingredient(name: rawName.isEmpty ? String(localized: "Ingredient") : rawName)
        ingredient.household = household
        context.insert(ingredient)
        return ingredient
    }
}

enum IngredientMergeError: Error, Equatable {
    case sameIngredient
}

/// Re-points every dependent row before removing a duplicate catalogue entry.
@MainActor
enum IngredientMergeService {
    static func merge(
        duplicate: Ingredient,
        into canonical: Ingredient,
        context: ModelContext
    ) throws {
        guard duplicate !== canonical else { throw IngredientMergeError.sameIngredient }

        IngredientIdentity.addAlias(
            named: duplicate.name,
            to: canonical,
            source: .userConfirmed,
            confidence: 1,
            context: context
        )

        for alias in duplicate.aliases ?? [] {
            guard alias.ingredient !== canonical else { continue }
            alias.ingredient = canonical
        }
        for line in duplicate.dishIngredients ?? [] {
            line.ingredient = canonical
        }
        for item in duplicate.shoppingItems ?? [] {
            item.ingredient = canonical
        }

        // Persist the reassignment first. If deletion fails, the duplicate is
        // still present but no recipe or shopping relationship is lost.
        try context.save()
        context.delete(duplicate)
        try context.save()
    }
}
