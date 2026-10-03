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
    case differentHouseholds
    case noReversibleMerge
}

/// Re-points every dependent row before removing a duplicate catalogue entry.
@MainActor
enum IngredientMergeService {
    static func merge(
        duplicate: Ingredient,
        into canonical: Ingredient,
        canonicalName: String? = nil,
        context: ModelContext
    ) throws {
        guard duplicate !== canonical else { throw IngredientMergeError.sameIngredient }
        guard let household = canonical.household, household === duplicate.household else {
            throw IngredientMergeError.differentHouseholds
        }
        var audit: IngredientMergeAuditRecord? = IngredientMergeAuditRecord(
                id: UUID(), createdAt: .now, canonicalUUID: canonical.uuid,
                canonicalNameBefore: canonical.name, canonicalNormalizedNameBefore: canonical.normalizedName,
                duplicate: .init(duplicate),
                dishIngredientUUIDs: (duplicate.dishIngredients ?? []).map(\.uuid),
                shoppingItemUUIDs: (duplicate.shoppingItems ?? []).map(\.uuid),
                aliasesAddedToCanonical: [], revertedAt: nil
        )
        let originalCanonicalAliasIDs = Set((canonical.aliases ?? []).map(\.uuid))

        let undoManager = context.undoManager
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }

        let requestedName = canonicalName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !requestedName.isEmpty, Ingredient.normalize(requestedName) != canonical.normalizedName {
            IngredientIdentity.addAlias(
                named: canonical.name,
                to: canonical,
                source: .userConfirmed,
                confidence: 1,
                context: context
            )
            canonical.name = requestedName
            canonical.normalizedName = Ingredient.normalize(requestedName)
            canonical.modifiedAt = .now
        }

        IngredientIdentity.addAlias(
            named: duplicate.name,
            to: canonical,
            source: .userConfirmed,
            confidence: 1,
            context: context
        )

        audit?.aliasesAddedToCanonical = (canonical.aliases ?? []).map(\.uuid)
            .filter { !originalCanonicalAliasIDs.contains($0) }

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
        for rejectedKey in duplicate.rejectedMatchKeys where !canonical.rejectedMatchKeys.contains(rejectedKey) {
            canonical.rejectedMatchKeys.append(rejectedKey)
        }
        var pending = canonical.pendingMergeSuggestions
        for suggestion in duplicate.pendingMergeSuggestions where suggestion.candidateUUID != canonical.uuid {
            guard !pending.contains(where: {
                $0.normalizedName == suggestion.normalizedName
                    && $0.candidateUUID == suggestion.candidateUUID
            }) else { continue }
            pending.append(suggestion)
        }
        canonical.pendingMergeSuggestions = pending
        canonical.pendingMergeSuggestions = canonical.pendingMergeSuggestions.filter {
            $0.candidateUUID != duplicate.uuid
        }

        if let audit {
            var trail = household.ingredientMergeAuditTrail
            trail.append(audit)
            if trail.count > 50 { trail.removeFirst(trail.count - 50) }
            household.ingredientMergeAuditTrail = trail
        }

        // A single store save makes the repointing and deletion atomic from
        // the user's point of view: a failure leaves the durable graph as it
        // was before the confirmed merge.
        context.delete(duplicate)
        try context.save()
        IngredientIntegrityDiagnostics.record(.mergeCompleted, detail: "relationships=\(audit?.dishIngredientUUIDs.count ?? 0)")
    }

    /// Recreates the newest confirmed merge that has not already been
    /// reversed. It only moves rows that still point at the original
    /// canonical ingredient, so later deliberate edits are left untouched.
    @discardableResult
    static func reverseLatestMerge(in household: Household, context: ModelContext) throws -> Ingredient {
        var trail = household.ingredientMergeAuditTrail
        guard let index = trail.lastIndex(where: { $0.revertedAt == nil }),
              let canonical = (household.ingredients ?? []).first(where: { $0.uuid == trail[index].canonicalUUID })
        else { throw IngredientMergeError.noReversibleMerge }
        var audit = trail[index]
        let restored = restore(audit.duplicate, in: household, context: context)

        let lineIDs = Set(audit.dishIngredientUUIDs)
        for line in try context.fetch(FetchDescriptor<DishIngredient>())
        where lineIDs.contains(line.uuid) && line.ingredient === canonical {
            line.ingredient = restored
        }
        let itemIDs = Set(audit.shoppingItemUUIDs)
        for item in try context.fetch(FetchDescriptor<ShoppingListItem>())
        where itemIDs.contains(item.uuid) && item.ingredient === canonical {
            item.ingredient = restored
        }

        let originalAliasIDs = Set(audit.duplicate.aliases.map(\.uuid))
        let allAliases = try context.fetch(FetchDescriptor<IngredientAlias>())
        let survivingAliases = allAliases.filter { originalAliasIDs.contains($0.uuid) }
        for alias in survivingAliases {
            alias.ingredient = restored
        }
        let survivingIDs = Set(survivingAliases.map(\.uuid))
        for saved in audit.duplicate.aliases where !survivingIDs.contains(saved.uuid) {
            let alias = IngredientAlias(name: saved.name)
            alias.uuid = saved.uuid
            alias.sourceRaw = saved.sourceRaw
            alias.confidence = saved.confidence
            alias.ingredient = restored
            context.insert(alias)
        }
        for alias in canonical.aliases ?? [] where audit.aliasesAddedToCanonical.contains(alias.uuid) {
            context.delete(alias)
        }
        // Do not overwrite a later rename made after the merge.
        if canonical.name != audit.canonicalNameBefore,
           canonical.normalizedName != audit.canonicalNormalizedNameBefore {
            canonical.name = audit.canonicalNameBefore
            canonical.normalizedName = audit.canonicalNormalizedNameBefore
        }
        canonical.modifiedAt = .now
        audit.revertedAt = .now
        trail[index] = audit
        household.ingredientMergeAuditTrail = trail
        try context.save()
        IngredientIntegrityDiagnostics.record(.mergeReversed, detail: "relationships=\(audit.dishIngredientUUIDs.count)")
        return restored
    }

    private static func restore(
        _ snapshot: IngredientMergeAuditRecord.IngredientSnapshot,
        in household: Household,
        context: ModelContext
    ) -> Ingredient {
        let ingredient = Ingredient(name: snapshot.name)
        ingredient.uuid = snapshot.uuid
        ingredient.normalizedName = snapshot.normalizedName
        ingredient.categoryRaw = snapshot.categoryRaw
        ingredient.customAisleName = snapshot.customAisleName
        ingredient.isPantryStaple = snapshot.isPantryStaple
        ingredient.inventoryModeRaw = snapshot.inventoryModeRaw
        ingredient.inventoryCanonicalValue = snapshot.inventoryCanonicalValue
        ingredient.inventoryDimensionRaw = snapshot.inventoryDimensionRaw
        ingredient.inventoryBestBefore = snapshot.inventoryBestBefore
        ingredient.inventoryStorageLocationRaw = snapshot.inventoryStorageLocationRaw
        ingredient.inventoryCustomStorageLocation = snapshot.inventoryCustomStorageLocation
        ingredient.nutritionEnergyKcal = snapshot.nutritionEnergyKcal
        ingredient.nutritionProteinGrams = snapshot.nutritionProteinGrams
        ingredient.nutritionCarbGrams = snapshot.nutritionCarbGrams
        ingredient.nutritionFatGrams = snapshot.nutritionFatGrams
        ingredient.nutritionReferenceRaw = snapshot.nutritionReferenceRaw
        ingredient.nutritionSourceRaw = snapshot.nutritionSourceRaw
        ingredient.rejectedMatchKeys = snapshot.rejectedMatchKeys
        ingredient.pendingMergeSuggestionsData = snapshot.pendingMergeSuggestionsData
        ingredient.household = household
        context.insert(ingredient)
        return ingredient
    }
}
