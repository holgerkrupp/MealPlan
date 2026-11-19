import Foundation
import SwiftData

enum IngredientStockConflictField: String, CaseIterable, Identifiable, Sendable {
    case status, amount, bestBefore, location, note

    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .status: String(localized: "Stock status")
        case .amount: String(localized: "Amount and unit")
        case .bestBefore: String(localized: "Best-before date")
        case .location: String(localized: "Storage location")
        case .note: String(localized: "Pantry note")
        }
    }
}

enum IngredientStockSource: String, CaseIterable, Identifiable, Sendable {
    case canonical, duplicate
    var id: String { rawValue }
}

struct IngredientStockMergeChoices: Equatable, Sendable {
    var sourceByField: [IngredientStockConflictField: IngredientStockSource] = [:]

    subscript(_ field: IngredientStockConflictField) -> IngredientStockSource? {
        get { sourceByField[field] }
        set { sourceByField[field] = newValue }
    }

    func resolves(_ fields: [IngredientStockConflictField]) -> Bool {
        fields.allSatisfy { sourceByField[$0] != nil }
    }
}

/// Combines unambiguous Pantry fields and requires an explicit choice whenever
/// both rows hold different values. Quantities are selected as recorded and
/// are never added together.
enum IngredientStockMerge {
    typealias State = IngredientMergeAuditRecord.InventoryState

    static func hasData(_ ingredient: Ingredient) -> Bool {
        ingredient.inventoryMode != .none
            || ingredient.inventoryQuantity != nil
            || ingredient.inventoryBestBefore != nil
            || ingredient.inventoryStorageLocationRaw != nil
            || !customLocation(ingredient).isEmpty
            || !inventoryNote(ingredient).isEmpty
    }

    static func conflicts(
        canonical: Ingredient,
        duplicate: Ingredient
    ) -> [IngredientStockConflictField] {
        var result: [IngredientStockConflictField] = []
        if hasValue(canonical.inventoryMode) && hasValue(duplicate.inventoryMode),
           canonical.inventoryMode != duplicate.inventoryMode { result.append(.status) }
        if let left = canonical.inventoryQuantity, let right = duplicate.inventoryQuantity,
           left != right { result.append(.amount) }
        if let left = canonical.inventoryBestBefore, let right = duplicate.inventoryBestBefore,
           !Calendar.current.isDate(left, inSameDayAs: right) { result.append(.bestBefore) }
        if hasLocation(canonical), hasLocation(duplicate), !sameLocation(canonical, duplicate) {
            result.append(.location)
        }
        if let left = note(canonical), let right = note(duplicate), left != right { result.append(.note) }
        return result
    }

    static func mergedState(
        canonical: Ingredient,
        duplicate: Ingredient,
        choices: IngredientStockMergeChoices?
    ) throws -> State {
        let conflicts = conflicts(canonical: canonical, duplicate: duplicate)
        if !conflicts.isEmpty, choices?.resolves(conflicts) != true {
            throw IngredientMergeError.stockConflictsUnresolved
        }
        let choices = choices ?? IngredientStockMergeChoices()

        let before = State(canonical)
        var merged = before
        let statusSource = source(for: .status, conflicts: conflicts, choices: choices,
                                  canonicalHasValue: hasValue(canonical.inventoryMode), duplicateHasValue: hasValue(duplicate.inventoryMode))
        merged.modeRaw = selected(statusSource, canonical.inventoryModeRaw, duplicate.inventoryModeRaw)

        let amountSource = source(for: .amount, conflicts: conflicts, choices: choices,
                                  canonicalHasValue: canonical.inventoryQuantity != nil, duplicateHasValue: duplicate.inventoryQuantity != nil)
        let amount = amountSource == .duplicate ? State(duplicate) : before
        merged.quantityValue = amount.quantityValue
        merged.dimensionRaw = amount.dimensionRaw

        let dateSource = source(for: .bestBefore, conflicts: conflicts, choices: choices,
                                canonicalHasValue: canonical.inventoryBestBefore != nil, duplicateHasValue: duplicate.inventoryBestBefore != nil)
        merged.bestBefore = (dateSource == .duplicate ? duplicate : canonical).inventoryBestBefore

        let locationSource = source(for: .location, conflicts: conflicts, choices: choices,
                                   canonicalHasValue: hasLocation(canonical), duplicateHasValue: hasLocation(duplicate))
        let location = locationSource == .duplicate ? State(duplicate) : before
        merged.storageLocationRaw = location.storageLocationRaw
        merged.customStorageLocation = location.customStorageLocation

        let noteSource = source(for: .note, conflicts: conflicts, choices: choices,
                                canonicalHasValue: note(canonical) != nil, duplicateHasValue: note(duplicate) != nil)
        merged.note = (noteSource == .duplicate ? duplicate : canonical).inventoryNote

        if merged != before { merged.updatedAt = .now }
        return merged
    }

    private static func source(
        for field: IngredientStockConflictField,
        conflicts: [IngredientStockConflictField],
        choices: IngredientStockMergeChoices,
        canonicalHasValue: Bool,
        duplicateHasValue: Bool
    ) -> IngredientStockSource {
        if conflicts.contains(field) { return choices[field] ?? .canonical }
        if canonicalHasValue || !duplicateHasValue { return .canonical }
        return .duplicate
    }

    private static func selected(_ source: IngredientStockSource, _ canonical: String, _ duplicate: String) -> String {
        source == .duplicate ? duplicate : canonical
    }

    private static func hasValue(_ mode: InventoryMode) -> Bool { mode != .none }
    private static func note(_ ingredient: Ingredient) -> String? {
        let value = inventoryNote(ingredient)
        return value.isEmpty ? nil : value
    }
    private static func hasLocation(_ ingredient: Ingredient) -> Bool {
        ingredient.inventoryStorageLocationRaw != nil || !customLocation(ingredient).isEmpty
    }
    private static func sameLocation(_ lhs: Ingredient, _ rhs: Ingredient) -> Bool {
        lhs.inventoryStorageLocationRaw == rhs.inventoryStorageLocationRaw
            && customLocation(lhs).localizedCaseInsensitiveCompare(customLocation(rhs)) == .orderedSame
    }
    private static func customLocation(_ ingredient: Ingredient) -> String {
        ingredient.inventoryCustomStorageLocation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private static func inventoryNote(_ ingredient: Ingredient) -> String {
        ingredient.inventoryNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

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
    var stockConflicts: [IngredientStockConflictField] {
        IngredientStockMerge.conflicts(canonical: canonical, duplicate: duplicate)
    }
    var hasStockConflict: Bool { !stockConflicts.isEmpty }
    var nutritionDiffers: Bool {
        canonical.nutritionFacts != duplicate.nutritionFacts
            || canonical.nutritionReference != duplicate.nutritionReference
    }

    var hasMetadataConflict: Bool {
        categoryDiffers || aisleDiffers || pantryStatusDiffers || nutritionDiffers || hasStockConflict
    }

    var isHighConfidenceAndNonConflicting: Bool {
        (match.matchClass == .certain || match.matchClass == .highConfidence) && !hasMetadataConflict
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
        let matcher = IngredientMatcher(ingredients: ingredients)
        let ingredientsByUUID = Dictionary(ingredients.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })

        var pairs: [String: (canonical: Ingredient, duplicate: Ingredient)] = [:]

        for source in ingredients {
            for pending in source.pendingMergeSuggestions {
                guard let candidate = ingredientsByUUID[pending.candidateUUID],
                      candidate !== source,
                      !isRejected(source: source, candidate: candidate)
                else { continue }
                let chosen = canonicalAndDuplicate(candidate, source)
                pairs[pairKey(chosen.0, chosen.1)] = chosen
            }

            let result = matcher.result(for: source.name, excluding: source)
            let candidates = result.candidate.map { [$0] } ?? result.candidates
            let equivalentIdentity = IngredientVocabulary.identity(for: source.name)
            let isKnownIdentityGroup = equivalentIdentity != nil
                && candidates.allSatisfy { IngredientVocabulary.identity(for: $0.name) == equivalentIdentity }
            let isSameNameGroup = candidates.allSatisfy {
                IngredientMatching.key(for: $0.name) == IngredientMatching.key(for: source.name)
            }
            if !candidates.isEmpty, isKnownIdentityGroup || isSameNameGroup {
                let group = distinctIngredients([source] + candidates)
                guard let canonical = group.min(by: preferredCanonical) else { continue }
                if canonical !== source {
                    let key = pairKey(canonical, source)
                    pairs[key] = (canonical, source)
                }
                // Exact and vocabulary groups form a star around the oldest
                // row, so a batch merge never contains stale pair references.
                continue
            }
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
        stockChoices: IngredientStockMergeChoices? = nil,
        context: ModelContext
    ) throws -> Ingredient {
        try IngredientMergeService.merge(
            duplicate: suggestion.duplicate,
            into: suggestion.canonical,
            canonicalName: canonicalName,
            stockChoices: stockChoices,
            context: context
        )
        return suggestion.canonical
    }

    private static func pairKey(_ canonical: Ingredient, _ duplicate: Ingredient) -> String {
        [canonical.uuid.uuidString, duplicate.uuid.uuidString].sorted().joined(separator: "-")
    }

    private static func canonicalAndDuplicate(_ lhs: Ingredient, _ rhs: Ingredient) -> (Ingredient, Ingredient) {
        // Keep the established catalogue row as canonical. A misspelled row
        // is often the one with usage because it came from an import, so
        // preferring relationship count would discard the older row's name
        // and curated metadata precisely when cleanup is meant to preserve it.
        return preferredCanonical(lhs, rhs) ? (lhs, rhs) : (rhs, lhs)
    }

    private static func preferredCanonical(_ lhs: Ingredient, _ rhs: Ingredient) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
        let lhsUsage = (lhs.dishIngredients ?? []).count + (lhs.shoppingItems ?? []).count
        let rhsUsage = (rhs.dishIngredients ?? []).count + (rhs.shoppingItems ?? []).count
        if lhsUsage != rhsUsage { return lhsUsage > rhsUsage }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func distinctIngredients(_ ingredients: [Ingredient]) -> [Ingredient] {
        var seen = Set<ObjectIdentifier>()
        return ingredients.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private static func isRejected(source: Ingredient, candidate: Ingredient) -> Bool {
        source.rejectsMatch(for: candidate.name) || candidate.rejectsMatch(for: source.name)
    }
}
