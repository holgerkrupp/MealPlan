import Foundation
import SwiftData

/// A persisted catalogue pair that deserves a person's decision.
///
/// The service deliberately keeps the `IngredientMatchResult` that produced
/// the pair. The cleanup UI can therefore explain the decision using the same
/// matcher as imports and recipe editing, instead of growing a second set of
/// fuzzy-matching rules.
@MainActor
struct IngredientCleanupSuggestion: Identifiable {
    let canonical: Ingredient
    let duplicate: Ingredient
    let match: IngredientMatchResult

    var id: String {
        [canonical.uuid.uuidString, duplicate.uuid.uuidString].sorted().joined(separator: "-")
    }

    var confidence: Double { match.confidence }
    var reasons: [IngredientMatchReason] { match.reasons }

    var canonicalDishes: [Dish] {
        (canonical.dishIngredients ?? [])
            .compactMap(\.dish)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .deduplicatedByUUID()
    }

    var duplicateDishes: [Dish] {
        (duplicate.dishIngredients ?? [])
            .compactMap(\.dish)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .deduplicatedByUUID()
    }

    var categoryDiffers: Bool { canonical.category != duplicate.category }
    var aisleDiffers: Bool { canonical.aisleName != duplicate.aisleName }
    var pantryStatusDiffers: Bool { canonical.isPantryStaple != duplicate.isPantryStaple }
    var nutritionDiffers: Bool {
        canonical.nutritionFacts != duplicate.nutritionFacts
            || canonical.nutritionReference != duplicate.nutritionReference
    }

    var hasMetadataConflict: Bool {
        categoryDiffers || aisleDiffers || pantryStatusDiffers || nutritionDiffers
    }

    var isHighConfidenceAndNonConflicting: Bool {
        match.matchClass == .highConfidence && !hasMetadataConflict
    }
}

extension Array where Element == Dish {
    fileprivate func deduplicatedByUUID() -> [Dish] {
        var seen = Set<UUID>()
        return filter { seen.insert($0.uuid).inserted }
    }
}

/// Finds catalogue-wide duplicate candidates and applies a confirmed choice.
///
/// Pending suggestions from imports are included even when the current
/// catalogue scan would rank another candidate first. That keeps a person's
/// earlier context visible, while the scan also finds duplicates created by
/// older app versions or backups that never queued a suggestion.
@MainActor
enum IngredientCleanupService {
    static func suggestions(in household: Household?) -> [IngredientCleanupSuggestion] {
        guard let household else { return [] }
        let ingredients = household.ingredients ?? []
        guard ingredients.count > 1 else { return [] }

        var pairs: [String: (canonical: Ingredient, duplicate: Ingredient)] = [:]

        for source in ingredients {
            for pending in source.pendingMergeSuggestions {
                guard let candidate = ingredients.first(where: { $0.uuid == pending.candidateUUID }),
                      candidate !== source,
                      !isRejected(source: source, candidate: candidate)
                else { continue }
                let chosen = canonicalAndDuplicate(candidate, source)
                pairs[pairKey(chosen.0, chosen.1)] = chosen
            }

            let peers = ingredients.filter { $0 !== source }
            let result = IngredientMatching.result(for: source.name, in: peers)
            let candidates = result.candidate.map { [$0] } ?? result.candidates
            for candidate in candidates where candidate !== source {
                guard !isRejected(source: source, candidate: candidate) else { continue }
                let chosen = canonicalAndDuplicate(candidate, source)
                let key = pairKey(chosen.0, chosen.1)
                if pairs[key] == nil { pairs[key] = chosen }
            }
        }

        return pairs.values.compactMap { pair in
            guard !isRejected(source: pair.duplicate, candidate: pair.canonical) else { return nil }
            let result = IngredientMatching.result(for: pair.duplicate.name, in: [pair.canonical])
            guard result.matchClass != .noMatch else { return nil }
            return IngredientCleanupSuggestion(
                canonical: pair.canonical,
                duplicate: pair.duplicate,
                match: result
            )
        }
        .sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.duplicate.name.localizedCaseInsensitiveCompare($1.duplicate.name) == .orderedAscending
        }
    }

    static func highConfidenceNonConflicting(in household: Household?) -> [IngredientCleanupSuggestion] {
        suggestions(in: household).filter(\.isHighConfidenceAndNonConflicting)
    }

    static func keepSeparate(_ suggestion: IngredientCleanupSuggestion) {
        IngredientIdentity.rejectMatch(
            named: suggestion.duplicate.name,
            for: suggestion.canonical,
            on: suggestion.duplicate
        )
    }

    @discardableResult
    static func merge(
        _ suggestion: IngredientCleanupSuggestion,
        canonicalName: String? = nil,
        context: ModelContext
    ) throws -> Ingredient {
        try IngredientMergeService.merge(
            duplicate: suggestion.duplicate,
            into: suggestion.canonical,
            canonicalName: canonicalName,
            context: context
        )
        return suggestion.canonical
    }

    private static func pairKey(_ canonical: Ingredient, _ duplicate: Ingredient) -> String {
        [canonical.uuid.uuidString, duplicate.uuid.uuidString].sorted().joined(separator: "-")
    }

    private static func canonicalAndDuplicate(_ lhs: Ingredient, _ rhs: Ingredient) -> (Ingredient, Ingredient) {
        let lhsUsage = (lhs.dishIngredients ?? []).count + (lhs.shoppingItems ?? []).count
        let rhsUsage = (rhs.dishIngredients ?? []).count + (rhs.shoppingItems ?? []).count
        if lhsUsage != rhsUsage { return lhsUsage > rhsUsage ? (lhs, rhs) : (rhs, lhs) }
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt ? (lhs, rhs) : (rhs, lhs) }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            ? (lhs, rhs) : (rhs, lhs)
    }

    private static func isRejected(source: Ingredient, candidate: Ingredient) -> Bool {
        source.rejectsMatch(for: candidate.name) || candidate.rejectsMatch(for: source.name)
    }
}
