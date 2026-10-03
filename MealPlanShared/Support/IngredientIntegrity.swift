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
        var inventoryStorageLocationRaw: String?
        var inventoryCustomStorageLocation: String?
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
            inventoryStorageLocationRaw = ingredient.inventoryStorageLocationRaw
            inventoryCustomStorageLocation = ingredient.inventoryCustomStorageLocation
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
    case orphanedIngredient
    case missingMergeSuggestionCandidate
}

enum IngredientIntegritySeverity: String, Sendable, Equatable {
    case info
    case warning
    case error
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
}

struct IngredientIntegrityAudit: Sendable, Equatable {
    var householdUUID: UUID
    var inspectedAt: Date
    var issues: [IngredientIntegrityIssue]
    var isHealthy: Bool { issues.isEmpty }
}

@MainActor
enum IngredientIntegrityAuditor {
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
        for line in lines { lineUUIDCounts[line.uuid, default: 0] += 1 }
        for line in lines {
            if line.dish == nil {
                report.issues.append(.init(id: "dish-missing-\(line.uuid)", kind: .dishIngredientWithoutDish,
                                           ingredientUUID: line.ingredient?.uuid,
                                           detail: "A recipe line has no owning recipe.", severity: .error, isSafeToRepair: false))
            }
            if lineUUIDCounts[line.uuid, default: 0] > 1 {
                report.issues.append(.init(id: "dish-line-uuid-\(line.uuid)", kind: .duplicateDishIngredientUUID,
                                           ingredientUUID: line.ingredient?.uuid,
                                           detail: "More than one recipe line shares an identifier.", severity: .error, isSafeToRepair: false))
            }
        }
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
        for issue in audit.issues {
            guard issue.isSafeToRepair else { result.skippedIssueIDs.append(issue.id); continue }
            guard let ingredient = issue.ingredientUUID.flatMap({ byID[$0] }) else {
                result.skippedIssueIDs.append(issue.id)
                continue
            }
            switch issue.kind {
            case .normalizedNameMismatch:
                ingredient.normalizedName = Ingredient.normalize(ingredient.name)
            case .aliasNormalizedNameMismatch:
                for alias in ingredient.aliases ?? [] { alias.normalizedName = Ingredient.normalize(alias.name) }
            default:
                result.skippedIssueIDs.append(issue.id)
                continue
            }
            ingredient.modifiedAt = .now
            result.repairedIssueIDs.append(issue.id)
        }
        if !result.repairedIssueIDs.isEmpty { try context.save() }
        IngredientIntegrityDiagnostics.record(.repairCompleted, detail: "repaired=\(result.repairedIssueIDs.count) skipped=\(result.skippedIssueIDs.count)")
        return result
    }
}
