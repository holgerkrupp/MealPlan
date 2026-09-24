import Foundation
import SwiftData

/// The one place where a raw recipe spelling becomes a catalogue identity.
@MainActor
enum IngredientIdentity {
    static func resolve(named rawName: String, in ingredients: [Ingredient]) -> Ingredient? {
        IngredientMatching.match(rawName, in: ingredients)
    }

    static func matchResult(named rawName: String, in ingredients: [Ingredient]) -> IngredientMatchResult {
        IngredientMatching.result(for: rawName, in: ingredients)
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
        let result = matchResult(named: rawName, in: household?.ingredients ?? [])
        if let existing = result.candidate, result.isSafeForSilentReuse {
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
        queueMergeSuggestion(for: rawName, result: result, on: ingredient)
        return ingredient
    }

    /// Records every uncertain candidate on the newly-created spelling. The
    /// imported/editing line stays attached to that spelling until a person
    /// chooses what it means.
    static func queueMergeSuggestion(
        for rawName: String,
        result: IngredientMatchResult,
        on newIngredient: Ingredient
    ) {
        guard result.matchClass == .needsConfirmation else { return }
        let candidates = result.candidates.isEmpty
            ? result.candidate.map { [$0] } ?? []
            : result.candidates
        guard !candidates.isEmpty else { return }

        var suggestions = newIngredient.pendingMergeSuggestions
        for candidate in candidates where candidate !== newIngredient {
            let suggestion = IngredientMergeSuggestion(
                rawName: rawName,
                normalizedName: Ingredient.normalize(rawName),
                candidateUUID: candidate.uuid,
                confidence: result.confidence,
                reasons: result.reasons.map(\.rawValue),
                createdAt: .now
            )
            guard !suggestions.contains(where: {
                $0.normalizedName == suggestion.normalizedName
                    && $0.candidateUUID == suggestion.candidateUUID
            }) else { continue }
            suggestions.append(suggestion)
        }
        newIngredient.pendingMergeSuggestions = suggestions
    }

    /// Learns an explicit “same ingredient” choice and removes the duplicate
    /// row, while preserving every recipe line's raw wording and notes.
    @discardableResult
    static func confirmMatch(
        newIngredient: Ingredient,
        canonical: Ingredient,
        context: ModelContext
    ) throws -> Ingredient {
        try IngredientMergeService.merge(duplicate: newIngredient, into: canonical, context: context)
        return canonical
    }

    /// Learns an explicit “keep separate” choice for this spelling and
    /// candidate. The spelling remains a real ingredient and will no longer
    /// produce the same suggestion for that candidate.
    static func rejectMatch(
        named rawName: String,
        for candidate: Ingredient,
        on newIngredient: Ingredient? = nil
    ) {
        let normalized = Ingredient.normalize(rawName)
        let key = IngredientMatching.key(for: rawName)
        for value in [normalized, key] where !value.isEmpty && !candidate.rejectedMatchKeys.contains(value) {
            candidate.rejectedMatchKeys.append(value)
        }
        if let newIngredient {
            newIngredient.pendingMergeSuggestions = newIngredient.pendingMergeSuggestions.filter {
                !($0.normalizedName == normalized && $0.candidateUUID == candidate.uuid)
            }
        }
        candidate.modifiedAt = .now
        newIngredient?.modifiedAt = .now
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
        canonical.pendingMergeSuggestions = canonical.pendingMergeSuggestions.filter {
            $0.candidateUUID != duplicate.uuid
        }

        // Persist the reassignment first. If deletion fails, the duplicate is
        // still present but no recipe or shopping relationship is lost.
        try context.save()
        context.delete(duplicate)
        try context.save()
    }
}
