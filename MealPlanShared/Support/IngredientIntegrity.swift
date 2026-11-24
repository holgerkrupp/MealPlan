import Foundation
import OSLog
import SwiftData

/// A privacy-safe breadcrumb for the ingredient paths that can otherwise be
/// difficult to reconstruct from a customer report. Names and recipe text are
/// deliberately never recorded here.
enum IngredientIntegrityDiagnosticKind: String, Codable, Sendable {
    case importedNewIngredient
    case importIngredientResolution
    case importDishCreated
    case mergeSuggestionQueued
    case ignoredImportedMetadataForExistingIngredient
    case mergeCompleted
    case mergeReversed
    case persistenceSaveFailed
    case auditCompleted
    case repairCompleted
}

struct IngredientIntegrityDiagnostic: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: IngredientIntegrityDiagnosticKind
    let timestamp: Date
    let detail: String
    let importSessionID: UUID?
    let dishUUID: UUID?
    let dishIngredientUUID: UUID?
    let ingredientUUID: UUID?
    let matchClass: IngredientMatchClass?
    let matchReasons: [IngredientMatchReason]
    let reusedIngredient: Bool?
    let queuedMergeSuggestion: Bool?

    init(
        kind: IngredientIntegrityDiagnosticKind,
        detail: String = "",
        importSessionID: UUID? = nil,
        dishUUID: UUID? = nil,
        dishIngredientUUID: UUID? = nil,
        ingredientUUID: UUID? = nil,
        matchClass: IngredientMatchClass? = nil,
        matchReasons: [IngredientMatchReason] = [],
        reusedIngredient: Bool? = nil,
        queuedMergeSuggestion: Bool? = nil
    ) {
        id = UUID()
        self.kind = kind
        timestamp = .now
        self.detail = detail
        self.importSessionID = importSessionID
        self.dishUUID = dishUUID
        self.dishIngredientUUID = dishIngredientUUID
        self.ingredientUUID = ingredientUUID
        self.matchClass = matchClass
        self.matchReasons = matchReasons
        self.reusedIngredient = reusedIngredient
        self.queuedMergeSuggestion = queuedMergeSuggestion
    }
}

@MainActor
enum IngredientIntegrityDiagnostics {
    private static let limit = 100
    private static let logger = Logger(subsystem: "de.holgerkrupp.mealplan", category: "ingredient-integrity")
    private(set) static var recent: [IngredientIntegrityDiagnostic] = []

    static func record(
        _ kind: IngredientIntegrityDiagnosticKind,
        detail: String = "",
        importSessionID: UUID? = nil,
        dishUUID: UUID? = nil,
        dishIngredientUUID: UUID? = nil,
        ingredientUUID: UUID? = nil,
        matchClass: IngredientMatchClass? = nil,
        matchReasons: [IngredientMatchReason] = [],
        reusedIngredient: Bool? = nil,
        queuedMergeSuggestion: Bool? = nil
    ) {
        recent.append(.init(
            kind: kind, detail: detail, importSessionID: importSessionID, dishUUID: dishUUID,
            dishIngredientUUID: dishIngredientUUID, ingredientUUID: ingredientUUID,
            matchClass: matchClass, matchReasons: matchReasons, reusedIngredient: reusedIngredient,
            queuedMergeSuggestion: queuedMergeSuggestion
        ))
        if recent.count > limit { recent.removeFirst(recent.count - limit) }
        logger.notice("Ingredient integrity: \(kind.rawValue, privacy: .public) \(detail, privacy: .public)")
    }

    static func resetForTesting() {
        recent.removeAll()
    }
}

/// The durable information required to restore one confirmed merge. Snapshot
/// only the affected ingredient and relationship IDs; recipes themselves are
/// never copied or deleted by a merge.
struct IngredientMergeAuditRecord: Codable, Sendable, Equatable, Identifiable {
    struct InventoryState: Codable, Sendable, Equatable {
        var modeRaw: String
        var quantityValue: Double?
        var dimensionRaw: String?
        var bestBefore: Date?
        var storageLocationRaw: String?
        var customStorageLocation: String?
        var note: String?
        var updatedAt: Date?

        init(_ ingredient: Ingredient) {
            modeRaw = ingredient.inventoryModeRaw
            quantityValue = ingredient.inventoryCanonicalValue
            dimensionRaw = ingredient.inventoryDimensionRaw
            bestBefore = ingredient.inventoryBestBefore
            storageLocationRaw = ingredient.inventoryStorageLocationRaw
            customStorageLocation = ingredient.inventoryCustomStorageLocation
            note = ingredient.inventoryNote
            updatedAt = ingredient.inventoryUpdatedAt
        }

        func restore(to ingredient: Ingredient) {
            ingredient.inventoryModeRaw = modeRaw
            ingredient.inventoryCanonicalValue = quantityValue
            ingredient.inventoryDimensionRaw = dimensionRaw
            ingredient.inventoryBestBefore = bestBefore
            ingredient.inventoryStorageLocationRaw = storageLocationRaw
            ingredient.inventoryCustomStorageLocation = customStorageLocation
            ingredient.inventoryNote = note
            ingredient.inventoryUpdatedAt = updatedAt
        }
    }

    struct Alias: Codable, Sendable, Equatable {
        var uuid: UUID
        var name: String
        var sourceRaw: String
        var confidence: Double?
    }

    struct IngredientSnapshot: Codable, Sendable, Equatable {
        var uuid: UUID
        var name: String
        var normalizedName: String
        var categoryRaw: String
        var customAisleName: String?
        var isPantryStaple: Bool
        var inventoryModeRaw: String
        var inventoryCanonicalValue: Double?
        var inventoryDimensionRaw: String?
        var inventoryBestBefore: Date?
        var inventoryUpdatedAt: Date?
        var inventoryStorageLocationRaw: String?
        var inventoryCustomStorageLocation: String?
        var inventoryNote: String?
        var nutritionEnergyKcal: Double?
        var nutritionProteinGrams: Double?
        var nutritionCarbGrams: Double?
        var nutritionFatGrams: Double?
        var nutritionReferenceRaw: String?
        var nutritionSourceRaw: String?
        var rejectedMatchKeys: [String]
        var pendingMergeSuggestionsData: Data?
        var aliases: [Alias]

        init(_ ingredient: Ingredient) {
            uuid = ingredient.uuid
            name = ingredient.name
            normalizedName = ingredient.normalizedName
            categoryRaw = ingredient.categoryRaw
            customAisleName = ingredient.customAisleName
            isPantryStaple = ingredient.isPantryStaple
            inventoryModeRaw = ingredient.inventoryModeRaw
            inventoryCanonicalValue = ingredient.inventoryCanonicalValue
            inventoryDimensionRaw = ingredient.inventoryDimensionRaw
            inventoryBestBefore = ingredient.inventoryBestBefore
            inventoryUpdatedAt = ingredient.inventoryUpdatedAt
            inventoryStorageLocationRaw = ingredient.inventoryStorageLocationRaw
            inventoryCustomStorageLocation = ingredient.inventoryCustomStorageLocation
            inventoryNote = ingredient.inventoryNote
            nutritionEnergyKcal = ingredient.nutritionEnergyKcal
            nutritionProteinGrams = ingredient.nutritionProteinGrams
            nutritionCarbGrams = ingredient.nutritionCarbGrams
            nutritionFatGrams = ingredient.nutritionFatGrams
            nutritionReferenceRaw = ingredient.nutritionReferenceRaw
            nutritionSourceRaw = ingredient.nutritionSourceRaw
            rejectedMatchKeys = ingredient.rejectedMatchKeys
            pendingMergeSuggestionsData = ingredient.pendingMergeSuggestionsData
            aliases = (ingredient.aliases ?? []).map {
                Alias(uuid: $0.uuid, name: $0.name, sourceRaw: $0.sourceRaw, confidence: $0.confidence)
            }
        }
    }

    var id: UUID
    var createdAt: Date
    var canonicalUUID: UUID
    var canonicalNameBefore: String
    var canonicalNormalizedNameBefore: String
    var duplicate: IngredientSnapshot
    /// Stock before and after a merge, used to reverse only when the canonical
    /// row still carries the merged values.
    var canonicalInventoryBefore: InventoryState?
    var canonicalInventoryAfter: InventoryState?
    var canonicalPantryStapleBefore: Bool?
    var canonicalPantryStapleAfter: Bool?
    var dishIngredientUUIDs: [UUID]
    var shoppingItemUUIDs: [UUID]
    var aliasesAddedToCanonical: [UUID]
    var revertedAt: Date?
}

enum IngredientIntegrityIssueKind: String, Sendable, Equatable {
    case emptyIngredientName
    case normalizedNameMismatch
    case aliasNormalizedNameMismatch
    case duplicateCanonicalName
    case dishIngredientWithoutIngredient
    case shoppingItemWithoutIngredient
    case crossHouseholdDishIngredient
    case crossHouseholdShoppingItem
    case dishIngredientWithoutDish
    case duplicateDishIngredientUUID
    case duplicateDishIngredientReference
    case duplicateDishIngredientInverseReference
    case duplicateDishIngredientContent
    case dishIngredientWrongDish
    case dishIngredientInverseMismatch
    case dishIngredientRawTextMismatch
    case dishIngredientInvalidQuantity
    case orphanedIngredient
    case missingMergeSuggestionCandidate
}

enum IngredientIntegritySeverity: String, Sendable, Equatable {
    case info
    case warning
    case error
}

enum IngredientIntegrityClassification: String, Sendable, Equatable {
    case safeAutomaticRepair
    case reviewRecommended
    case cannotDetermine

    var localizedName: String {
        switch self {
        case .safeAutomaticRepair: String(localized: "Safe automatic repair")
        case .reviewRecommended: String(localized: "Review recommended")
        case .cannotDetermine: String(localized: "Cannot determine safely")
        }
    }
}

struct IngredientIntegrityIssue: Identifiable, Sendable, Equatable {
    var id: String
    var kind: IngredientIntegrityIssueKind
    var ingredientUUID: UUID?
    var detail: String
    var severity: IngredientIntegritySeverity = .warning
    /// Only mechanical normalization repairs are automatic. Everything that
    /// could change a recipe's meaning remains a review item.
    var isSafeToRepair: Bool
    var classification: IngredientIntegrityClassification = .reviewRecommended
    var dishUUID: UUID? = nil
    var dishIngredientUUID: UUID? = nil
    var relatedDishIngredientUUIDs: [UUID] = []
    var rawText: String?
    var canonicalName: String?
    var quantityValue: Double?
    var quantityDimensionRaw: String?
    /// A candidate is surfaced as evidence only. The auditor never applies it
    /// automatically because the raw line remains the user's source of truth.
    var suggestedIngredientUUID: UUID?

    init(
        id: String,
        kind: IngredientIntegrityIssueKind,
        ingredientUUID: UUID? = nil,
        detail: String,
        severity: IngredientIntegritySeverity = .warning,
        isSafeToRepair: Bool,
        classification: IngredientIntegrityClassification? = nil,
        dishUUID: UUID? = nil,
        dishIngredientUUID: UUID? = nil,
        relatedDishIngredientUUIDs: [UUID] = [],
        rawText: String? = nil,
        canonicalName: String? = nil,
        quantityValue: Double? = nil,
        quantityDimensionRaw: String? = nil,
        suggestedIngredientUUID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.ingredientUUID = ingredientUUID
        self.detail = detail
        self.severity = severity
        self.isSafeToRepair = isSafeToRepair
        self.classification = classification ?? (isSafeToRepair ? .safeAutomaticRepair : .reviewRecommended)
        self.dishUUID = dishUUID
        self.dishIngredientUUID = dishIngredientUUID
        self.relatedDishIngredientUUIDs = relatedDishIngredientUUIDs
        self.rawText = rawText
        self.canonicalName = canonicalName
        self.quantityValue = quantityValue
        self.quantityDimensionRaw = quantityDimensionRaw
        self.suggestedIngredientUUID = suggestedIngredientUUID
    }

    var isRecipeIngredientFinding: Bool {
        dishIngredientUUID != nil || dishUUID != nil
    }
}

struct IngredientIntegrityAudit: Sendable, Equatable {
    var householdUUID: UUID
    var inspectedAt: Date
    var issues: [IngredientIntegrityIssue]
    var isHealthy: Bool { issues.isEmpty }
    var recipeIngredientIssues: [IngredientIntegrityIssue] {
        issues.filter(\.isRecipeIngredientFinding)
    }
    var safeRecipeRepairs: [IngredientIntegrityIssue] {
        recipeIngredientIssues.filter { $0.classification == .safeAutomaticRepair }
    }
}

@MainActor
enum IngredientIntegrityAuditor {
    /// SwiftData normally normalizes duplicate relationship entries while a
    /// model is being materialized. Keep the grouping logic explicit so an
    /// auditor run against a damaged/in-memory relationship can still prove
    /// that repeated references to one object are lossless to remove.
    static func duplicateReferenceGroups(_ lines: [DishIngredient]) -> [[DishIngredient]] {
        Dictionary(grouping: lines, by: { ObjectIdentifier($0) })
            .values
            .filter { $0.count > 1 }
    }

    static func audit(household: Household) -> IngredientIntegrityAudit {
        var issues: [IngredientIntegrityIssue] = []
        let ingredients = household.ingredients ?? []
        var names: [String: [Ingredient]] = [:]

        for ingredient in ingredients {
            let normalized = Ingredient.normalize(ingredient.name)
            if normalized.isEmpty {
                issues.append(.init(id: "ingredient-empty-\(ingredient.uuid)", kind: .emptyIngredientName,
                                    ingredientUUID: ingredient.uuid, detail: "Ingredient has no name.", isSafeToRepair: false))
            }
            if ingredient.normalizedName != normalized {
                issues.append(.init(id: "ingredient-normalized-\(ingredient.uuid)", kind: .normalizedNameMismatch,
                                    ingredientUUID: ingredient.uuid, detail: "Ingredient search key is stale.", isSafeToRepair: true))
            }
            names[normalized, default: []].append(ingredient)
            for alias in ingredient.aliases ?? [] where alias.normalizedName != Ingredient.normalize(alias.name) {
                issues.append(.init(id: "alias-normalized-\(alias.uuid)", kind: .aliasNormalizedNameMismatch,
                                    ingredientUUID: ingredient.uuid, detail: "Ingredient alias search key is stale.", isSafeToRepair: true))
            }
        }
        for (_, collisions) in names where collisions.count > 1 {
            for ingredient in collisions {
                issues.append(.init(id: "duplicate-\(ingredient.uuid)", kind: .duplicateCanonicalName,
                                    ingredientUUID: ingredient.uuid, detail: "Another catalogue row has the same name.", isSafeToRepair: false))
            }
        }

        for dish in household.dishes ?? [] {
            for line in dish.ingredients ?? [] {
                guard let ingredient = line.ingredient else {
                    issues.append(.init(id: "dish-line-empty-\(line.uuid)", kind: .dishIngredientWithoutIngredient,
                                        ingredientUUID: nil, detail: "A recipe line is not linked to an ingredient.", isSafeToRepair: false))
                    continue
                }
                if ingredient.household !== household {
                    issues.append(.init(id: "dish-line-scope-\(line.uuid)", kind: .crossHouseholdDishIngredient,
                                        ingredientUUID: ingredient.uuid, detail: "A recipe line points outside this household.", isSafeToRepair: false))
                }
            }
        }
        for item in household.shoppingItems ?? [] {
            guard let ingredient = item.ingredient else {
                issues.append(.init(id: "shopping-empty-\(item.uuid)", kind: .shoppingItemWithoutIngredient,
                                    ingredientUUID: nil, detail: "A shopping item is not linked to an ingredient.", isSafeToRepair: false))
                continue
            }
            if ingredient.household !== household {
                issues.append(.init(id: "shopping-scope-\(item.uuid)", kind: .crossHouseholdShoppingItem,
                                    ingredientUUID: ingredient.uuid, detail: "A shopping item points outside this household.", isSafeToRepair: false))
            }
        }
        IngredientIntegrityDiagnostics.record(.auditCompleted, detail: "issues=\(issues.count)")
        return .init(householdUUID: household.uuid, inspectedAt: .now, issues: issues)
    }

    /// Store-wide pass for the opt-in Settings workflow. Fetching the graph
    /// catches orphaned rows that cannot be reached through a household's
    /// inverse relationships; it does not mutate or materialize replacements.
    static func audit(household: Household, context: ModelContext) -> IngredientIntegrityAudit {
        var report = audit(household: household)
        let ingredients = household.ingredients ?? []
        let ingredientIDs = Set(ingredients.map(\.uuid))
        let knownSuggestionCandidates = ingredientIDs
        let lines = (try? context.fetch(FetchDescriptor<DishIngredient>())) ?? []
        var lineUUIDCounts: [UUID: Int] = [:]
        var lineUUIDMembers: [UUID: [DishIngredient]] = [:]
        for line in lines {
            lineUUIDCounts[line.uuid, default: 0] += 1
            lineUUIDMembers[line.uuid, default: []].append(line)
        }
        for line in lines {
            if line.dish == nil {
                report.issues.append(.init(id: "dish-missing-\(line.uuid)", kind: .dishIngredientWithoutDish,
                                           ingredientUUID: line.ingredient?.uuid,
                                           detail: "A recipe line has no owning recipe.", severity: .error, isSafeToRepair: false,
                                           classification: .cannotDetermine,
                                           dishIngredientUUID: line.uuid,
                                           rawText: line.rawText,
                                           canonicalName: line.ingredient?.name,
                                           quantityValue: line.canonicalValue,
                                           quantityDimensionRaw: line.canonicalDimensionRaw))
            }
            if lineUUIDCounts[line.uuid, default: 0] > 1 {
                report.issues.append(.init(id: "dish-line-uuid-\(line.uuid)", kind: .duplicateDishIngredientUUID,
                                           ingredientUUID: line.ingredient?.uuid,
                                           detail: "More than one recipe line shares an identifier.", severity: .error, isSafeToRepair: false,
                                           classification: .cannotDetermine,
                                           dishUUID: line.dish?.uuid,
                                           dishIngredientUUID: line.uuid,
                                           relatedDishIngredientUUIDs: lineUUIDMembers[line.uuid, default: []].map(\.uuid),
                                           rawText: line.rawText,
                                           canonicalName: line.ingredient?.name,
                                           quantityValue: line.canonicalValue,
                                           quantityDimensionRaw: line.canonicalDimensionRaw))
            }
        }

        appendRecipeIngredientIssues(to: &report, household: household, context: context, lines: lines)
        for ingredient in ingredients {
            if (ingredient.dishIngredients ?? []).isEmpty && (ingredient.shoppingItems ?? []).isEmpty {
                report.issues.append(.init(id: "ingredient-orphan-\(ingredient.uuid)", kind: .orphanedIngredient,
                                           ingredientUUID: ingredient.uuid,
                                           detail: "Catalogue ingredient is not currently used by a recipe or shopping item.", severity: .info, isSafeToRepair: false))
            }
            for suggestion in ingredient.pendingMergeSuggestions where !knownSuggestionCandidates.contains(suggestion.candidateUUID) {
                report.issues.append(.init(id: "suggestion-missing-\(ingredient.uuid)-\(suggestion.candidateUUID)",
                                           kind: .missingMergeSuggestionCandidate, ingredientUUID: ingredient.uuid,
                                           detail: "A pending merge suggestion points to a missing ingredient.", severity: .warning, isSafeToRepair: false))
            }
        }
        IngredientIntegrityDiagnostics.record(.auditCompleted, detail: "storeIssues=\(report.issues.count)")
        return report
    }

    /// Async wrapper used by Settings. SwiftData models must be inspected on
    /// the main actor, but yielding before the store-wide pass keeps the scan
    /// cancellable at the UI boundary and avoids starting it in the middle of
    /// a gesture or navigation transition.
    static func auditResponsive(household: Household, context: ModelContext) async -> IngredientIntegrityAudit {
        await Task.yield()
        return audit(household: household, context: context)
    }

    private static func appendRecipeIngredientIssues(
        to report: inout IngredientIntegrityAudit,
        household: Household,
        context: ModelContext,
        lines: [DishIngredient]
    ) {
        let dishes = household.dishes ?? []
        let ingredients = household.ingredients ?? []
        let householdDishIDs = Set(dishes.map(\.uuid))
        let householdIngredientIDs = Set(ingredients.map(\.uuid))
        let matcher = IngredientMatcher(ingredients: ingredients, rules: household.matchRules ?? [])

        func append(
            _ kind: IngredientIntegrityIssueKind,
            id: String,
            dish: Dish?,
            line: DishIngredient?,
            ingredient: Ingredient?,
            detail: String,
            severity: IngredientIntegritySeverity = .warning,
            safe: Bool = false,
            classification: IngredientIntegrityClassification? = nil,
            related: [UUID] = [],
            suggested: Ingredient? = nil
        ) {
            report.issues.append(.init(
                id: id,
                kind: kind,
                ingredientUUID: ingredient?.uuid,
                detail: detail,
                severity: severity,
                isSafeToRepair: safe,
                classification: classification,
                dishUUID: dish?.uuid,
                dishIngredientUUID: line?.uuid,
                relatedDishIngredientUUIDs: related,
                rawText: line?.rawText,
                canonicalName: ingredient?.name,
                quantityValue: line?.canonicalValue,
                quantityDimensionRaw: line?.canonicalDimensionRaw,
                suggestedIngredientUUID: suggested?.uuid
            ))
        }

        for dish in dishes {
            let dishLines = dish.ingredients ?? []
            var uuidOccurrences: [UUID: [DishIngredient]] = [:]
            for line in dishLines {
                uuidOccurrences[line.uuid, default: []].append(line)

                guard line.dish === dish else {
                    append(
                        .dishIngredientWrongDish,
                        id: "dish-line-wrong-dish-\(dish.uuid)-\(line.uuid)",
                        dish: dish,
                        line: line,
                        ingredient: line.ingredient,
                        detail: "This recipe contains a line whose owning recipe is \(line.dish?.name ?? "unknown"). It needs review before either relationship is changed."
                    )
                    continue
                }

                if let ingredient = line.ingredient {
                    if !householdIngredientIDs.contains(ingredient.uuid) || ingredient.household !== household {
                        append(
                            .crossHouseholdDishIngredient,
                            id: "dish-line-scope-\(line.uuid)",
                            dish: dish,
                            line: line,
                            ingredient: ingredient,
                            detail: "A recipe line points outside this household."
                        )
                    }
                    let inverseOccurrences = (ingredient.dishIngredients ?? []).filter { $0 === line }
                    if inverseOccurrences.isEmpty {
                        append(
                            .dishIngredientInverseMismatch,
                            id: "dish-line-inverse-\(line.uuid)-\(ingredient.uuid)",
                            dish: dish,
                            line: line,
                            ingredient: ingredient,
                            detail: "The recipe line points to this canonical ingredient, but the inverse relationship does not contain the same line object.",
                            classification: .cannotDetermine
                        )
                    }

                    if let rawText = line.rawText?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !rawText.isEmpty {
                        // Match the ingredient portion, not the leading
                        // amount/unit. The raw line itself remains untouched.
                        let ingredientText = GermanUnitParser.parse(rawText).name
                        let match = matcher.result(for: ingredientText)
                        if let candidate = match.candidate,
                           candidate !== ingredient,
                           match.matchClass == .certain || match.matchClass == .highConfidence {
                            append(
                                .dishIngredientRawTextMismatch,
                                id: "dish-line-raw-mismatch-\(line.uuid)",
                                dish: dish,
                                line: line,
                                ingredient: ingredient,
                                detail: "The original text matches \(candidate.name) more strongly than the current canonical ingredient. Raw text and quantity are preserved until you review it.",
                                classification: .reviewRecommended,
                                suggested: candidate
                            )
                        }
                    }
                }

                if let value = line.canonicalValue,
                   !value.isFinite || value < 0 || line.dimension == nil {
                    append(
                        .dishIngredientInvalidQuantity,
                        id: "dish-line-quantity-\(line.uuid)",
                        dish: dish,
                        line: line,
                        ingredient: line.ingredient,
                        detail: "The stored recipe quantity is incomplete or invalid. The original text is retained; do not infer a replacement unit.",
                        classification: .cannotDetermine
                    )
                } else if let expectedDimension = impliedDimension(for: line.displayUnit),
                          line.dimension != expectedDimension {
                    append(
                        .dishIngredientInvalidQuantity,
                        id: "dish-line-dimension-\(line.uuid)",
                        dish: dish,
                        line: line,
                        ingredient: line.ingredient,
                        detail: "The stored quantity dimension (\(line.dimension?.rawValue ?? "unknown")) conflicts with the entered unit \(line.displayUnit ?? "unknown"). Keep the original amount until reviewed.",
                        classification: .reviewRecommended
                    )
                }
            }

            for occurrences in duplicateReferenceGroups(dishLines) {
                guard let line = occurrences.first else { continue }
                append(
                    .duplicateDishIngredientReference,
                    id: "dish-line-reference-\(dish.uuid)-\(line.uuid)",
                    dish: dish,
                    line: line,
                    ingredient: line.ingredient,
                    detail: "The same persistent recipe-line object is referenced \(occurrences.count) times. Removing the redundant references is lossless.",
                    safe: true,
                    classification: .safeAutomaticRepair,
                    related: occurrences.map(\.uuid)
                )
            }

            for occurrences in uuidOccurrences.values
            where occurrences.count > 1 && Set(occurrences.map { ObjectIdentifier($0) }).count > 1 {
                guard let line = occurrences.first else { continue }
                append(
                    .duplicateDishIngredientUUID,
                    id: "dish-line-distinct-uuid-\(dish.uuid)-\(line.uuid)",
                    dish: dish,
                    line: line,
                    ingredient: line.ingredient,
                    detail: "Multiple distinct persistent recipe-line objects share this UUID. They cannot be safely collapsed automatically.",
                    severity: .error,
                    classification: .cannotDetermine,
                    related: occurrences.map(\.uuid)
                )
            }

            let uniqueLines = Dictionary(grouping: dishLines, by: contentSignature)
                .filter { !$0.key.isEmpty && Set($0.value.map { ObjectIdentifier($0) }).count > 1 }
            for occurrences in uniqueLines.values {
                guard let line = occurrences.first else { continue }
                append(
                    .duplicateDishIngredientContent,
                    id: "dish-line-content-\(dish.uuid)-\(contentSignature(line))",
                    dish: dish,
                    line: line,
                    ingredient: line.ingredient,
                    detail: "This recipe has \(occurrences.count) distinct lines with identical original text and quantity. Repeated ingredients can be intentional, so review the preparation sections before removing one.",
                    classification: .reviewRecommended,
                    related: occurrences.map(\.uuid)
                )
            }
        }

        // Inspect inverse arrays too. A repeated reference to the same object
        // is the only relationship repair this auditor can prove lossless.
        for ingredient in ingredients {
            let inverse = ingredient.dishIngredients ?? []
            for line in inverse {
                guard let dish = line.dish, householdDishIDs.contains(dish.uuid) else { continue }
                guard line.ingredient === ingredient else {
                    append(
                        .dishIngredientInverseMismatch,
                        id: "ingredient-inverse-mismatch-\(ingredient.uuid)-\(line.uuid)",
                        dish: dish,
                        line: line,
                        ingredient: ingredient,
                        detail: "The ingredient inverse contains a line whose canonical relationship points elsewhere.",
                        classification: .cannotDetermine
                    )
                    continue
                }
                guard (dish.ingredients ?? []).contains(where: { $0 === line }) else {
                    append(
                        .dishIngredientInverseMismatch,
                        id: "ingredient-inverse-missing-\(ingredient.uuid)-\(line.uuid)",
                        dish: dish,
                        line: line,
                        ingredient: ingredient,
                        detail: "The canonical ingredient inverse contains this line, but the owning recipe does not contain the same line object.",
                        classification: .cannotDetermine
                    )
                    continue
                }
            }
            for sameObject in duplicateReferenceGroups(inverse) {
                guard let line = sameObject.first else { continue }
                append(
                    .duplicateDishIngredientInverseReference,
                    id: "ingredient-inverse-reference-\(ingredient.uuid)-\(line.uuid)",
                    dish: line.dish,
                    line: line,
                    ingredient: ingredient,
                    detail: "The same persistent recipe-line object is repeated in the ingredient inverse relationship \(sameObject.count) times. Removing the redundant references is lossless.",
                    safe: true,
                    classification: .safeAutomaticRepair,
                    related: sameObject.map(\.uuid)
                )
            }
        }

        // `lines` is intentionally consumed above only for the store-wide
        // UUID check. Keep the parameter explicit so this method remains easy
        // to extend when another relationship representation is added.
        _ = lines
        _ = context
    }

    private static func contentSignature(_ line: DishIngredient) -> String {
        let parts = [
            line.ingredient.map { Ingredient.normalize($0.name) } ?? "",
            line.rawText.map(Ingredient.normalize) ?? "",
            line.canonicalValue.map { String($0) } ?? "",
            line.canonicalDimensionRaw ?? "",
            line.displayUnit.map(Ingredient.normalize) ?? "",
            line.note.map(Ingredient.normalize) ?? "",
            line.translatedName.map(Ingredient.normalize) ?? "",
            line.translatedNote.map(Ingredient.normalize) ?? "",
        ]
        guard parts.contains(where: { !$0.isEmpty }) else { return "" }
        return parts.joined(separator: "|")
    }

    private static func impliedDimension(for displayUnit: String?) -> QuantityDimension? {
        guard let displayUnit else { return nil }
        let unit = displayUnit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["g", "kg", "mg", "oz", "lb", "pound", "pounds", "ounce", "ounces"].contains(unit) {
            return .mass
        }
        if ["ml", "cl", "l", "el", "tl", "tsp", "tbsp", "cup", "cups", "glas"].contains(unit) {
            return .volume
        }
        if ["stück", "stk", "piece", "pieces", "zehe", "zehen", "scheibe", "scheiben", "pack", "pkg", "dose", "dosen"].contains(unit) {
            return .count
        }
        return nil
    }
}

struct IngredientIntegrityRepairResult: Sendable, Equatable {
    var repairedIssueIDs: [String] = []
    var skippedIssueIDs: [String] = []
}

@MainActor
enum IngredientIntegrityRepairService {
    /// Applies only lossless repairs. Duplicate detection and broken links are
    /// reported for review; this workflow never guesses a replacement or
    /// deletes data.
    static func repairSafely(
        _ audit: IngredientIntegrityAudit,
        in household: Household,
        context: ModelContext
    ) throws -> IngredientIntegrityRepairResult {
        var result = IngredientIntegrityRepairResult()
        let byID = Dictionary(uniqueKeysWithValues: (household.ingredients ?? []).map { ($0.uuid, $0) })
        let undo = context.undoManager
        var didBeginUndoGroup = false
        do {
            if audit.issues.contains(where: \.isSafeToRepair) {
                // Keep a durable, whole-store recovery point in addition to
                // SwiftData's in-process undo stack. The stable operation key
                // bounds this to one latest pre-cleanup snapshot per household.
                _ = try recoverySnapshot(for: household, context: context)
            }
            for issue in audit.issues {
                guard issue.isSafeToRepair else { result.skippedIssueIDs.append(issue.id); continue }

                switch issue.kind {
                case .normalizedNameMismatch, .aliasNormalizedNameMismatch:
                    guard let ingredient = issue.ingredientUUID.flatMap({ byID[$0] }) else {
                        result.skippedIssueIDs.append(issue.id)
                        continue
                    }
                    if !didBeginUndoGroup {
                        undo?.beginUndoGrouping()
                        didBeginUndoGroup = true
                    }
                    if issue.kind == .normalizedNameMismatch {
                        ingredient.normalizedName = Ingredient.normalize(ingredient.name)
                    } else {
                        for alias in ingredient.aliases ?? [] { alias.normalizedName = Ingredient.normalize(alias.name) }
                    }
                    ingredient.modifiedAt = .now
                    result.repairedIssueIDs.append(issue.id)

                case .duplicateDishIngredientReference, .duplicateDishIngredientInverseReference:
                    guard let lineUUID = issue.dishIngredientUUID else {
                        result.skippedIssueIDs.append(issue.id)
                        continue
                    }
                    if !didBeginUndoGroup {
                        undo?.beginUndoGrouping()
                        didBeginUndoGroup = true
                    }
                    guard repairRepeatedReference(issue, lineUUID: lineUUID, household: household) else {
                        result.skippedIssueIDs.append(issue.id)
                        continue
                    }
                    result.repairedIssueIDs.append(issue.id)

                default:
                    result.skippedIssueIDs.append(issue.id)
                }
            }
            if !result.repairedIssueIDs.isEmpty { try context.save() }
            if didBeginUndoGroup { undo?.endUndoGrouping() }
        } catch {
            if didBeginUndoGroup { undo?.endUndoGrouping() }
            context.rollback()
            throw error
        }
        IngredientIntegrityDiagnostics.record(.repairCompleted, detail: "repaired=\(result.repairedIssueIDs.count) skipped=\(result.skippedIssueIDs.count)")
        return result
    }

    /// Repoints only a reviewed recipe line. No source text, quantity, unit,
    /// notes, shopping items, pantry state, or household relationship is
    /// changed. The caller must have evidence for the choice; the auditor's
    /// suggestion is never applied here automatically.
    static func reassignRecipeLine(
        _ line: DishIngredient,
        to ingredient: Ingredient,
        context: ModelContext
    ) throws {
        guard let dish = line.dish,
              let household = dish.household,
              ingredient.household === household,
              (dish.ingredients ?? []).contains(where: { $0 === line })
        else { throw IngredientIntegrityRepairError.invalidRecipeLineScope }
        guard line.ingredient !== ingredient else { return }

        _ = try recoverySnapshot(for: household, context: context)
        let undo = context.undoManager
        undo?.beginUndoGrouping()
        do {
            line.ingredient = ingredient
            line.modifiedAt = .now
            try context.save()
            undo?.endUndoGrouping()
        } catch {
            undo?.endUndoGrouping()
            context.rollback()
            throw error
        }
    }

    /// Deletes one reviewed duplicate recipe-line row. It deliberately does
    /// not touch the Ingredient, shopping list, pantry, planning, or
    /// household rows. SwiftData's undo manager restores the complete line if
    /// the user chooses Undo immediately afterwards.
    static func removeReviewedDuplicateLine(
        _ line: DishIngredient,
        from dish: Dish,
        context: ModelContext
    ) throws {
        guard (dish.ingredients ?? []).contains(where: { $0 === line }), line.dish === dish else {
            throw IngredientIntegrityRepairError.invalidRecipeLineScope
        }
        guard let household = dish.household else {
            throw IngredientIntegrityRepairError.invalidRecipeLineScope
        }
        _ = try recoverySnapshot(for: household, context: context)
        let undo = context.undoManager
        undo?.beginUndoGrouping()
        do {
            context.delete(line)
            try context.save()
            undo?.endUndoGrouping()
        } catch {
            undo?.endUndoGrouping()
            context.rollback()
            throw error
        }
    }

    private static func repairRepeatedReference(
        _ issue: IngredientIntegrityIssue,
        lineUUID: UUID,
        household: Household
    ) -> Bool {
        guard let dishUUID = issue.dishUUID,
              let dish = (household.dishes ?? []).first(where: { $0.uuid == dishUUID }),
              let line = (dish.ingredients ?? []).first(where: { $0.uuid == lineUUID })
        else { return false }

        switch issue.kind {
        case .duplicateDishIngredientReference:
            var seen = false
            let original = dish.ingredients ?? []
            let unique = original.filter { candidate in
                guard candidate === line else { return true }
                if seen { return false }
                seen = true
                return true
            }
            guard unique.count < original.count else { return false }
            dish.ingredients = unique
            return true

        case .duplicateDishIngredientInverseReference:
            guard let ingredient = issue.ingredientUUID.flatMap({ uuid in
                (household.ingredients ?? []).first(where: { $0.uuid == uuid })
            }) else { return false }
            var seen = false
            let original = ingredient.dishIngredients ?? []
            let unique = original.filter { candidate in
                guard candidate === line else { return true }
                if seen { return false }
                seen = true
                return true
            }
            guard unique.count < original.count else { return false }
            ingredient.dishIngredients = unique
            return true

        default:
            return false
        }
    }

    @discardableResult
    private static func recoverySnapshot(for household: Household, context: ModelContext) throws -> URL {
        try HouseholdRecoveryService.archiveBeforeReplacement(
            context: context,
            operationID: "ingredient-integrity-\(household.uuid.uuidString)",
            preferredHouseholdID: household.uuid
        )
    }
}

enum IngredientIntegrityRepairError: LocalizedError, Sendable {
    case invalidRecipeLineScope

    var errorDescription: String? {
        switch self {
        case .invalidRecipeLineScope:
            String(localized: "The recipe line no longer belongs to this household and was not changed.")
        }
    }
}
