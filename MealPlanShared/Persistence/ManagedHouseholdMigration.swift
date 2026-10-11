import CoreData
import Foundation
import SwiftData

/// The migration reads stable identity directly from SwiftData models. It does
/// not depend on the legacy CloudKit record codec, which is removed after the
/// verified cutover.
private protocol LegacyMigrationModel {
    var uuid: UUID { get }
    var modifiedAt: Date { get }
}

extension Household: LegacyMigrationModel {}
extension HouseholdMember: LegacyMigrationModel {}
extension MealType: LegacyMigrationModel {}
extension Dish: LegacyMigrationModel {}
extension DishImage: LegacyMigrationModel {}
extension Ingredient: LegacyMigrationModel {}
extension IngredientAlias: LegacyMigrationModel {}
extension IngredientPackageSize: LegacyMigrationModel {}
extension IngredientMatchRule: LegacyMigrationModel {}
extension DishIngredient: LegacyMigrationModel {}
extension MealPlanEntry: LegacyMigrationModel {}
extension MealRoutine: LegacyMigrationModel {}
extension CookedLog: LegacyMigrationModel {}
extension ShoppingListItem: LegacyMigrationModel {}
extension WeekTemplate: LegacyMigrationModel {}
extension WeekTemplateEntry: LegacyMigrationModel {}
extension RecipeFeed: LegacyMigrationModel {}
extension RecipeFeedItem: LegacyMigrationModel {}
extension RecipeBookmark: LegacyMigrationModel {}

/// A scalar value copied from the legacy SwiftData graph. Keeping this value
/// type explicit makes the migration testable without launching SwiftUI or a
/// CloudKit transport, and prevents an accidental semantic rematch of recipes
/// or ingredients during the copy.
enum ManagedHouseholdMigrationValue: Equatable, Sendable {
    case null
    case string(String)
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case date(Date)
    case uuid(UUID)
    case data(Data)

    var objectValue: Any? {
        switch self {
        case .null: nil
        case .string(let value): value
        case .bool(let value): value
        case .integer(let value): value
        case .double(let value): value
        case .date(let value): value
        case .uuid(let value): value
        case .data(let value): value
        }
    }

    func matches(_ value: Any?) -> Bool {
        switch self {
        case .null: return value == nil || value is NSNull
        case .string(let expected): return value as? String == expected
        case .bool(let expected): return (value as? NSNumber)?.boolValue == expected
        case .integer(let expected): return (value as? NSNumber)?.int64Value == expected
        case .double(let expected): return (value as? NSNumber)?.doubleValue == expected
        case .date(let expected):
            guard let actual = value as? Date else { return false }
            return actual == expected
        case .uuid(let expected): return value as? UUID == expected
        case .data(let expected): return value as? Data == expected
        }
    }
}

/// One legacy row and its to-one relationship endpoints. To-many relationships
/// are reconstructed from these endpoints, preserving the original graph
/// rather than assuming that names, recipes, or ingredients are equivalent.
struct ManagedHouseholdMigrationRecord: Equatable, Sendable {
    let entity: ManagedHouseholdEntity
    let uuid: UUID
    let modifiedAt: Date
    let scope: ManagedHouseholdStoreScope
    let attributes: [String: ManagedHouseholdMigrationValue]
    let relationships: [String: UUID]
}

struct ManagedHouseholdMigrationInventory: Equatable, Sendable {
    /// Exact source identities, preserving multiplicity. A duplicate UUID is
    /// invalid source data and must never be collapsed by a Set during migration.
    let identifiersByEntity: [ManagedHouseholdEntity: [UUID]]

    /// Persist both totals and every UUID occurrence in the existing checkpoint
    /// dictionary. This makes a delete+insert with the same entity count detectable
    /// on resume without changing the on-disk state schema.
    var counts: [String: Int] {
        var result: [String: Int] = [:]
        for (entity, identifiers) in identifiersByEntity {
            result["entity:\(entity.rawValue):count"] = identifiers.count
            for (uuid, occurrences) in Dictionary(grouping: identifiers, by: { $0 }) {
                result["entity:\(entity.rawValue):uuid:\(uuid.uuidString)"] = occurrences.count
            }
        }
        return result
    }
}

@MainActor
protocol LegacyHouseholdMigrationSource {
    func inventory() throws -> ManagedHouseholdMigrationInventory
    func records(for entity: ManagedHouseholdEntity) throws -> [ManagedHouseholdMigrationRecord]
    /// Identifiers produced by the existing SwiftData ingredient auditor.
    /// They let the importer reject any new mechanical integrity finding
    /// without attempting to repair, normalize, or reinterpret user data.
    func integrityIssueIDs() throws -> Set<String>
}

extension LegacyHouseholdMigrationSource {
    func integrityIssueIDs() throws -> Set<String> { [] }
}

enum ManagedHouseholdMigrationPhase: String, Codable, Sendable {
    case notStarted
    case inventoryCreated
    case copying
    case copied
    case verified
    case legacyRetainedForRollback
    case failed
}

/// Stored outside both persistent object graphs. An interruption can therefore
/// be resumed without treating either database as proof that a copy completed.
struct ManagedHouseholdMigrationState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var phase: ManagedHouseholdMigrationPhase
    var sourceCounts: [String: Int]
    var entityCheckpoints: [String: String]
    var updatedAt: Date
    var failureCode: String?

    static func new() -> Self {
        .init(
            version: currentVersion,
            phase: .notStarted,
            sourceCounts: [:],
            entityCheckpoints: [:],
            updatedAt: .now,
            failureCode: nil
        )
    }
}

@MainActor
protocol ManagedHouseholdMigrationStateStore: AnyObject {
    func load() throws -> ManagedHouseholdMigrationState?
    func save(_ state: ManagedHouseholdMigrationState) throws
}

/// The app-group marker survives process termination, while the old SwiftData
/// SQLite file remains entirely untouched. Atomic replacement means a crash
/// yields either the previous checkpoint or the next complete checkpoint.
@MainActor
final class FileManagedHouseholdMigrationStateStore: ManagedHouseholdMigrationStateStore {
    let url: URL

    init(url: URL? = nil) throws {
        if let url {
            self.url = url
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else {
            let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID)
                ?? URL.applicationSupportDirectory
            let directory = root
                .appending(path: "ManagedHouseholdMigration", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.url = directory.appending(path: "state-v\(ManagedHouseholdMigrationState.currentVersion).json")
        }
    }

    func load() throws -> ManagedHouseholdMigrationState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ManagedHouseholdMigrationState.self, from: Data(contentsOf: url))
    }

    func save(_ state: ManagedHouseholdMigrationState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }
}

enum ManagedHouseholdMigrationError: LocalizedError, Equatable {
    case unsupportedStateVersion(Int)
    case previousFailure(String?)
    case inventoryChanged(expected: [String: Int], actual: [String: Int])
    case duplicateSourceObject(ManagedHouseholdEntity, UUID)
    case duplicateTargetObject(ManagedHouseholdEntity, UUID)
    case missingRelationshipTarget(ManagedHouseholdEntity, UUID, String, UUID)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedStateVersion(let version): "A newer managed-household migration format (\(version)) is present."
        case .previousFailure(let code): "The managed-household migration previously failed\(code.map { ": \($0)" } ?? ".")."
        case .inventoryChanged: "The legacy household inventory changed while it was being copied."
        case .duplicateSourceObject(let entity, let uuid): "The legacy store contains duplicate \(entity.rawValue) records for \(uuid)."
        case .duplicateTargetObject(let entity, let uuid): "The destination contains duplicate \(entity.rawValue) records for \(uuid)."
        case .missingRelationshipTarget(let entity, let uuid, let relationship, let target): "\(entity.rawValue) \(uuid) refers to missing \(relationship) target \(target)."
        case .verificationFailed(let detail): "Managed-household migration verification failed: \(detail)"
        }
    }
}

/// Performs the one-way SwiftData → Core Data copy. It deliberately has no
/// reverse path: until #87 activates the new store, the old store remains the
/// live UI source and is retained as rollback input. After activation, rollback
/// must never silently fork user data back into SwiftData.
@MainActor
final class ManagedHouseholdMigration {
    private let source: any LegacyHouseholdMigrationSource
    private let destination: ManagedHouseholdPersistence
    private let stateStore: any ManagedHouseholdMigrationStateStore
    private let batchSize: Int

    init(
        source: any LegacyHouseholdMigrationSource,
        destination: ManagedHouseholdPersistence,
        stateStore: any ManagedHouseholdMigrationStateStore,
        batchSize: Int = 100
    ) {
        self.source = source
        self.destination = destination
        self.stateStore = stateStore
        self.batchSize = max(1, batchSize)
    }

    func run() async throws {
        var state = try stateStore.load() ?? .new()
        guard state.version <= ManagedHouseholdMigrationState.currentVersion else {
            throw ManagedHouseholdMigrationError.unsupportedStateVersion(state.version)
        }
        if state.phase == .legacyRetainedForRollback { return }
        if state.phase == .failed { throw ManagedHouseholdMigrationError.previousFailure(state.failureCode) }

        do {
            let inventory = try source.inventory()
            let existingIntegrityIssues = try source.integrityIssueIDs()
            if state.sourceCounts.isEmpty {
                state.sourceCounts = inventory.counts
                state.phase = .inventoryCreated
                state.updatedAt = .now
                try stateStore.save(state)
            } else if state.sourceCounts != inventory.counts {
                throw ManagedHouseholdMigrationError.inventoryChanged(expected: state.sourceCounts, actual: inventory.counts)
            }

            try await destination.load()
            state.phase = .copying
            state.updatedAt = .now
            try stateStore.save(state)

            for entity in ManagedHouseholdEntity.allCases {
                let records = try source.records(for: entity).sorted { $0.uuid.uuidString < $1.uuid.uuidString }
                let identifiers = records.map(\.uuid)
                if let duplicate = Dictionary(grouping: identifiers, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
                    throw ManagedHouseholdMigrationError.duplicateSourceObject(entity, duplicate)
                }
                guard identifiers == inventory.identifiersByEntity[entity, default: []].sorted(by: { $0.uuidString < $1.uuidString }) else {
                    throw ManagedHouseholdMigrationError.verificationFailed("source inventory differs for \(entity.rawValue)")
                }
                let checkpoint = state.entityCheckpoints[entity.rawValue]
                let remaining = records.filter { record in
                    checkpoint.map { record.uuid.uuidString > $0 } ?? true
                }
                for batch in remaining.chunked(into: batchSize) {
                    try copy(Array(batch))
                    if let last = batch.last {
                        state.entityCheckpoints[entity.rawValue] = last.uuid.uuidString
                        state.updatedAt = .now
                        try stateStore.save(state)
                    }
                }
            }

            try linkRelationships()
            state.phase = .copied
            state.updatedAt = .now
            try stateStore.save(state)

            try verify(inventory: inventory)
            let introducedIssues = try destinationIntegrityIssueIDs().subtracting(existingIntegrityIssues)
            guard introducedIssues.isEmpty else {
                throw ManagedHouseholdMigrationError.verificationFailed(
                    "migration introduced ingredient integrity findings: \(introducedIssues.sorted().joined(separator: ","))"
                )
            }
            state.phase = .verified
            state.updatedAt = .now
            try stateStore.save(state)

            // The completion marker intentionally records the rollback
            // boundary. #87 is the only phase allowed to accept new canonical
            // Core Data writes; before that, the original store is retained.
            state.phase = .legacyRetainedForRollback
            state.updatedAt = .now
            try stateStore.save(state)
        } catch {
            state.phase = .failed
            state.failureCode = String(describing: error)
            state.updatedAt = .now
            try stateStore.save(state)
            throw error
        }
    }

    private func copy(_ records: [ManagedHouseholdMigrationRecord]) throws {
        let context = destination.container.viewContext
        for record in records {
            let object = try targetObject(entity: record.entity, uuid: record.uuid, scope: record.scope, context: context)
                ?? destination.insert(record.entity, into: record.scope, context: context, uuid: record.uuid)
            object.setValue(record.modifiedAt, forKey: "modifiedAt")
            for (name, value) in record.attributes {
                object.setValue(value.objectValue, forKey: name)
            }
        }
        if context.hasChanges { try context.save() }
    }

    private func linkRelationships() throws {
        let context = destination.container.viewContext
        for entity in ManagedHouseholdEntity.allCases {
            for record in try source.records(for: entity) {
                guard let object = try targetObject(entity: entity, uuid: record.uuid, scope: record.scope, context: context) else {
                    throw ManagedHouseholdMigrationError.verificationFailed("missing copied \(entity.rawValue) \(record.uuid)")
                }
                for (name, targetID) in record.relationships {
                    guard let relationship = object.entity.relationshipsByName[name],
                          let destinationEntityName = relationship.destinationEntity?.name,
                          let destinationEntity = ManagedHouseholdEntity(rawValue: destinationEntityName),
                          let target = try targetObject(entity: destinationEntity, uuid: targetID, scope: record.scope, context: context)
                    else {
                        throw ManagedHouseholdMigrationError.missingRelationshipTarget(entity, record.uuid, name, targetID)
                    }
                    object.setValue(target, forKey: name)
                }
            }
        }
        if context.hasChanges { try context.save() }
    }

    private func verify(inventory: ManagedHouseholdMigrationInventory) throws {
        let context = destination.container.viewContext
        for entity in ManagedHouseholdEntity.allCases {
            let records = try source.records(for: entity)
            let sourceIDs = records.map(\.uuid).sorted(by: { $0.uuidString < $1.uuidString })
            let expectedIDs = inventory.identifiersByEntity[entity, default: []].sorted(by: { $0.uuidString < $1.uuidString })
            guard sourceIDs == expectedIDs else {
                throw ManagedHouseholdMigrationError.verificationFailed("source inventory changed for \(entity.rawValue)")
            }
            if let duplicate = Dictionary(grouping: sourceIDs, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
                throw ManagedHouseholdMigrationError.duplicateSourceObject(entity, duplicate)
            }
            let targetIDs = try allObjects(entity, context: context)
                .compactMap { $0.value(forKey: "uuid") as? UUID }
                .sorted(by: { $0.uuidString < $1.uuidString })
            guard targetIDs == expectedIDs else {
                throw ManagedHouseholdMigrationError.verificationFailed("destination inventory differs for \(entity.rawValue)")
            }
            for record in records {
                guard let object = try targetObject(entity: entity, uuid: record.uuid, scope: record.scope, context: context) else {
                    throw ManagedHouseholdMigrationError.verificationFailed("missing \(entity.rawValue) \(record.uuid)")
                }
                guard (object.value(forKey: "modifiedAt") as? Date) == record.modifiedAt else {
                    throw ManagedHouseholdMigrationError.verificationFailed("timestamp changed for \(entity.rawValue) \(record.uuid)")
                }
                for (name, value) in record.attributes where !value.matches(object.value(forKey: name)) {
                    throw ManagedHouseholdMigrationError.verificationFailed("attribute \(entity.rawValue).\(name) differs for \(record.uuid)")
                }
                for (name, targetID) in record.relationships {
                    guard let target = object.value(forKey: name) as? NSManagedObject,
                          target.value(forKey: "uuid") as? UUID == targetID
                    else {
                        throw ManagedHouseholdMigrationError.verificationFailed("relationship \(entity.rawValue).\(name) differs for \(record.uuid)")
                    }
                }
            }
        }
    }

    private func targetObject(
        entity: ManagedHouseholdEntity,
        uuid: UUID,
        scope: ManagedHouseholdStoreScope,
        context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity.rawValue)
        request.predicate = NSPredicate(format: "uuid == %@", uuid as CVarArg)
        let matches = try context.fetch(request).filter { destination.storeScope(for: $0) == scope }
        if matches.count > 1 { throw ManagedHouseholdMigrationError.duplicateTargetObject(entity, uuid) }
        return matches.first
    }

    /// Core Data counterpart to the mechanical parts of
    /// `IngredientIntegrityAuditor`. It intentionally reports identifiers in
    /// the same shape as the SwiftData auditor so the migration can prove it
    /// introduced no new broken ingredient/recipe endpoints.
    private func destinationIntegrityIssueIDs() throws -> Set<String> {
        let context = destination.container.viewContext
        let households = try allObjects(.household, context: context)
        let ingredients = try allObjects(.ingredient, context: context)
        let aliases = try allObjects(.ingredientAlias, context: context)
        let lines = try allObjects(.dishIngredient, context: context)
        let shoppingItems = try allObjects(.shoppingListItem, context: context)
        var issues: Set<String> = []

        let householdIDs = Set(households.compactMap { $0.value(forKey: "uuid") as? UUID })
        for rootHouseholdID in householdIDs {
            let scopedIngredients = ingredients.filter { householdID(of: $0) == rootHouseholdID }
            var normalizedNames: [String: [NSManagedObject]] = [:]
            for ingredient in scopedIngredients {
                guard let uuid = ingredient.value(forKey: "uuid") as? UUID else { continue }
                let name = ingredient.value(forKey: "name") as? String ?? ""
                let normalized = Ingredient.normalize(name)
                if normalized.isEmpty { issues.insert("ingredient-empty-\(uuid)") }
                if ingredient.value(forKey: "normalizedName") as? String != normalized {
                    issues.insert("ingredient-normalized-\(uuid)")
                }
                normalizedNames[normalized, default: []].append(ingredient)
                let ingredientAliases = aliases.filter { ($0.value(forKey: "ingredient") as? NSManagedObject) === ingredient }
                for alias in ingredientAliases {
                    guard let aliasID = alias.value(forKey: "uuid") as? UUID else { continue }
                    let aliasName = alias.value(forKey: "name") as? String ?? ""
                    if alias.value(forKey: "normalizedName") as? String != Ingredient.normalize(aliasName) {
                        issues.insert("alias-normalized-\(aliasID)")
                    }
                }
                let isUsedByDish = lines.contains { ($0.value(forKey: "ingredient") as? NSManagedObject) === ingredient }
                let isUsedByShopping = shoppingItems.contains { ($0.value(forKey: "ingredient") as? NSManagedObject) === ingredient }
                if !isUsedByDish && !isUsedByShopping { issues.insert("ingredient-orphan-\(uuid)") }
            }
            for collisions in normalizedNames.values where collisions.count > 1 {
                for ingredient in collisions {
                    if let uuid = ingredient.value(forKey: "uuid") as? UUID { issues.insert("duplicate-\(uuid)") }
                }
            }
        }

        for line in lines {
            guard let uuid = line.value(forKey: "uuid") as? UUID else { continue }
            guard let dish = line.value(forKey: "dish") as? NSManagedObject else {
                issues.insert("dish-missing-\(uuid)")
                continue
            }
            guard let ingredient = line.value(forKey: "ingredient") as? NSManagedObject else {
                issues.insert("dish-line-empty-\(uuid)")
                continue
            }
            if householdID(of: dish) != householdID(of: ingredient) {
                issues.insert("dish-line-scope-\(uuid)")
            }
        }
        for item in shoppingItems {
            guard let uuid = item.value(forKey: "uuid") as? UUID else { continue }
            guard let ingredient = item.value(forKey: "ingredient") as? NSManagedObject else {
                issues.insert("shopping-empty-\(uuid)")
                continue
            }
            if householdID(of: item) != householdID(of: ingredient) {
                issues.insert("shopping-scope-\(uuid)")
            }
        }
        return issues
    }

    private func allObjects(_ entity: ManagedHouseholdEntity, context: NSManagedObjectContext) throws -> [NSManagedObject] {
        try context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity.rawValue))
    }

    private func householdID(of object: NSManagedObject) -> UUID? {
        if object.entity.name == ManagedHouseholdEntity.household.rawValue {
            return object.value(forKey: "uuid") as? UUID
        }
        if let household = object.value(forKey: "household") as? NSManagedObject {
            return household.value(forKey: "uuid") as? UUID
        }
        if let dish = object.value(forKey: "dish") as? NSManagedObject,
           let household = dish.value(forKey: "household") as? NSManagedObject {
            return household.value(forKey: "uuid") as? UUID
        }
        return nil
    }
}

private extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}

/// Reads the existing SwiftData graph without mutating it. This source is
/// intentionally short-lived: it exists solely for the verified one-way
/// import, not as a synchronization adapter between the two persistence
/// systems.
@MainActor
final class SwiftDataLegacyHouseholdMigrationSource: LegacyHouseholdMigrationSource {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func inventory() throws -> ManagedHouseholdMigrationInventory {
        var identifiers: [ManagedHouseholdEntity: [UUID]] = [:]
        for entity in ManagedHouseholdEntity.allCases {
            identifiers[entity] = try records(for: entity).map(\.uuid).sorted(by: { $0.uuidString < $1.uuidString })
        }
        return .init(identifiersByEntity: identifiers)
    }

    func integrityIssueIDs() throws -> Set<String> {
        try context.fetch(FetchDescriptor<Household>()).reduce(into: Set<String>()) { result, household in
            result.formUnion(IngredientIntegrityAuditor.audit(household: household, context: context).issues.map(\.id))
        }
    }

    func records(for entity: ManagedHouseholdEntity) throws -> [ManagedHouseholdMigrationRecord] {
        switch entity {
        case .household:
            return try context.fetch(FetchDescriptor<Household>()).map { household in
                try record(.household, household, scope: scope(for: household), attributes: attributes(
                    "name", string(household.name),
                    "unitSystemRaw", string(household.unitSystemRaw),
                    "unitPresentationOverrideRaw", household.unitPresentationOverrideRaw.map(ManagedHouseholdMigrationValue.string) as Any,
                    "roundsDisplayedAmounts", bool(household.roundsDisplayedAmounts),
                    "calendarStyleRaw", string(household.calendarStyleRaw),
                    "standardServings", integer(household.standardServings),
                    "showsNutritionEstimates", bool(household.showsNutritionEstimates),
                    "leftoverSuggestionsEnabled", bool(household.leftoverSuggestionsEnabled),
                    "inventoryEnabled", bool(household.inventoryEnabled),
                    "packageSizeCountryCode", string(household.packageSizeCountryCode),
                    "energyUnitRaw", string(household.energyUnitRaw),
                    "localeIdentifier", string(household.localeIdentifier),
                    "dateCreated", date(household.dateCreated),
                    "didSeedPantryStaples", bool(household.didSeedPantryStaples),
                    "ingredientMergeAuditData", household.ingredientMergeAuditData.map(ManagedHouseholdMigrationValue.data) as Any,
                    "unlockedByPurchase", bool(household.unlockedByPurchase),
                    "bringListUuid", household.bringListUuid.map(ManagedHouseholdMigrationValue.string) as Any,
                    "bringListName", household.bringListName.map(ManagedHouseholdMigrationValue.string) as Any,
                    "bringShadowKeys", try json(household.bringShadowKeys),
                    "bringAutoSync", bool(household.bringAutoSync),
                    "bringLastSyncedAt", household.bringLastSyncedAt.map(ManagedHouseholdMigrationValue.date) as Any
                ))
            }
        case .householdMember:
            return try context.fetch(FetchDescriptor<HouseholdMember>()).map { member in
                try record(.householdMember, member, scope: scope(for: member.household), attributes: attributes(
                    "cloudKitParticipantID", member.cloudKitParticipantID.map(ManagedHouseholdMigrationValue.string) as Any,
                    "isActive", bool(member.isActive),
                    "name", string(member.name),
                    "roleRaw", string(member.roleRaw),
                    "isCurrentUser", bool(member.isCurrentUser),
                    "dateAdded", date(member.dateAdded),
                    "shareMetadataModifiedAt", date(member.shareMetadataModifiedAt),
                    "profileModifiedAt", date(member.profileModifiedAt),
                    "allergies", try json(member.allergies),
                    "mustAvoidIngredients", try json(member.mustAvoidIngredients),
                    "dietaryPatterns", try json(member.dietaryPatterns),
                    "dislikes", try json(member.dislikes),
                    "favorites", try json(member.favorites),
                    "preferredCuisines", try json(member.preferredCuisines),
                    "spiceTolerance", member.spiceTolerance.map(integer) as Any
                ), relationships: relationship("household", member.household?.uuid))
            }
        case .mealType:
            return try context.fetch(FetchDescriptor<MealType>()).map { meal in
                try record(.mealType, meal, scope: scope(for: meal.household), attributes: attributes(
                    "key", string(meal.key), "name", string(meal.name), "symbolName", string(meal.symbolName), "sortOrder", integer(meal.sortOrder)
                ), relationships: relationship("household", meal.household?.uuid))
            }
        case .dish:
            return try context.fetch(FetchDescriptor<Dish>()).map { dish in
                try record(.dish, dish, scope: scope(for: dish.household), attributes: attributes(
                    "name", string(dish.name), "recipeText", dish.recipeText.map(ManagedHouseholdMigrationValue.string) as Any, "sourceURLString", dish.sourceURLString.map(ManagedHouseholdMigrationValue.string) as Any, "deepLinkURLString", dish.deepLinkURLString.map(ManagedHouseholdMigrationValue.string) as Any, "importedSourceApp", dish.importedSourceApp.map(ManagedHouseholdMigrationValue.string) as Any, "importedSourceID", dish.importedSourceID.map(ManagedHouseholdMigrationValue.string) as Any, "variantGroupID", dish.variantGroupID.map(ManagedHouseholdMigrationValue.uuid) as Any, "variantGroupName", dish.variantGroupName.map(ManagedHouseholdMigrationValue.string) as Any, "isFavorite", bool(dish.isFavorite), "rating", integer(dish.rating), "collectionNames", try json(dish.collectionNames), "tagNames", try json(dish.tagNames), "servings", integer(dish.servings), "prepTimeMinutes", dish.prepTimeMinutes.map(integer) as Any, "cookTimeMinutes", dish.cookTimeMinutes.map(integer) as Any, "mealTypeTagsRaw", try json(dish.mealTypeTagsRaw), "dietaryTagsRaw", try json(dish.dietaryTagsRaw), "seasonRaw", dish.seasonRaw.map(ManagedHouseholdMigrationValue.string) as Any, "createdByName", dish.createdByName.map(ManagedHouseholdMigrationValue.string) as Any, "dateCreated", date(dish.dateCreated), "lastUsedDate", dish.lastUsedDate.map(ManagedHouseholdMigrationValue.date) as Any, "usageCount", integer(dish.usageCount), "needsReview", bool(dish.needsReview), "statedEnergyKcalPerServing", dish.statedEnergyKcalPerServing.map(ManagedHouseholdMigrationValue.double) as Any, "statedProteinGramsPerServing", dish.statedProteinGramsPerServing.map(ManagedHouseholdMigrationValue.double) as Any, "statedCarbGramsPerServing", dish.statedCarbGramsPerServing.map(ManagedHouseholdMigrationValue.double) as Any, "statedFatGramsPerServing", dish.statedFatGramsPerServing.map(ManagedHouseholdMigrationValue.double) as Any, "statedSaturatedFatGramsPerServing", dish.statedSaturatedFatGramsPerServing.map(ManagedHouseholdMigrationValue.double) as Any, "statedFiberGramsPerServing", dish.statedFiberGramsPerServing.map(ManagedHouseholdMigrationValue.double) as Any, "statedSugarGramsPerServing", dish.statedSugarGramsPerServing.map(ManagedHouseholdMigrationValue.double) as Any, "statedSodiumMilligramsPerServing", dish.statedSodiumMilligramsPerServing.map(ManagedHouseholdMigrationValue.double) as Any, "statedCholesterolMilligramsPerServing", dish.statedCholesterolMilligramsPerServing.map(ManagedHouseholdMigrationValue.double) as Any, "statedNutritionProvenanceRaw", dish.statedNutritionProvenanceRaw.map(ManagedHouseholdMigrationValue.string) as Any, "recipeLanguageCode", dish.recipeLanguageCode.map(ManagedHouseholdMigrationValue.string) as Any, "translationLanguageCode", dish.translationLanguageCode.map(ManagedHouseholdMigrationValue.string) as Any, "translatedName", dish.translatedName.map(ManagedHouseholdMigrationValue.string) as Any, "translatedRecipeText", dish.translatedRecipeText.map(ManagedHouseholdMigrationValue.string) as Any, "glyphRaw", dish.glyphRaw.map(ManagedHouseholdMigrationValue.string) as Any, "glyphIsAuto", bool(dish.glyphIsAuto)
                ), relationships: relationship("household", dish.household?.uuid))
            }
        case .dishImage:
            return try context.fetch(FetchDescriptor<DishImage>()).map { image in
                try record(.dishImage, image, scope: scope(for: image.dish?.household), attributes: attributes(
                    "data", image.data.map(ManagedHouseholdMigrationValue.data) as Any, "sortIndex", integer(image.sortIndex), "isPrimary", bool(image.isPrimary), "dateAdded", date(image.dateAdded)
                ), relationships: relationship("dish", image.dish?.uuid))
            }
        case .ingredient:
            return try context.fetch(FetchDescriptor<Ingredient>()).map { ingredient in
                try record(.ingredient, ingredient, scope: scope(for: ingredient.household), attributes: attributes(
                    "name", string(ingredient.name), "normalizedName", string(ingredient.normalizedName), "categoryRaw", string(ingredient.categoryRaw), "customAisleName", ingredient.customAisleName.map(ManagedHouseholdMigrationValue.string) as Any, "isPantryStaple", bool(ingredient.isPantryStaple), "inventoryModeRaw", string(ingredient.inventoryModeRaw), "inventoryCanonicalValue", ingredient.inventoryCanonicalValue.map(ManagedHouseholdMigrationValue.double) as Any, "inventoryDimensionRaw", ingredient.inventoryDimensionRaw.map(ManagedHouseholdMigrationValue.string) as Any, "inventoryBestBefore", ingredient.inventoryBestBefore.map(ManagedHouseholdMigrationValue.date) as Any, "inventoryStorageLocationRaw", ingredient.inventoryStorageLocationRaw.map(ManagedHouseholdMigrationValue.string) as Any, "inventoryCustomStorageLocation", ingredient.inventoryCustomStorageLocation.map(ManagedHouseholdMigrationValue.string) as Any, "inventoryUpdatedAt", ingredient.inventoryUpdatedAt.map(ManagedHouseholdMigrationValue.date) as Any, "rejectedMatchKeys", try json(ingredient.rejectedMatchKeys), "pendingMergeSuggestionsData", ingredient.pendingMergeSuggestionsData.map(ManagedHouseholdMigrationValue.data) as Any, "nutritionEnergyKcal", ingredient.nutritionEnergyKcal.map(ManagedHouseholdMigrationValue.double) as Any, "nutritionProteinGrams", ingredient.nutritionProteinGrams.map(ManagedHouseholdMigrationValue.double) as Any, "nutritionCarbGrams", ingredient.nutritionCarbGrams.map(ManagedHouseholdMigrationValue.double) as Any, "nutritionFatGrams", ingredient.nutritionFatGrams.map(ManagedHouseholdMigrationValue.double) as Any, "nutritionReferenceRaw", ingredient.nutritionReferenceRaw.map(ManagedHouseholdMigrationValue.string) as Any, "nutritionSourceRaw", ingredient.nutritionSourceRaw.map(ManagedHouseholdMigrationValue.string) as Any
                ), relationships: relationship("household", ingredient.household?.uuid))
            }
        case .ingredientAlias:
            return try context.fetch(FetchDescriptor<IngredientAlias>()).map { alias in
                try record(.ingredientAlias, alias, scope: scope(for: alias.ingredient?.household), attributes: attributes(
                    "name", string(alias.name), "normalizedName", string(alias.normalizedName), "sourceRaw", string(alias.sourceRaw), "confidence", alias.confidence.map(ManagedHouseholdMigrationValue.double) as Any
                ), relationships: relationship("ingredient", alias.ingredient?.uuid))
            }
        case .ingredientPackageSize:
            return try context.fetch(FetchDescriptor<IngredientPackageSize>()).map { package in
                try record(.ingredientPackageSize, package, scope: scope(for: package.household), attributes: attributes(
                    "ingredientKey", string(package.ingredientKey), "ingredientName", string(package.ingredientName), "countryCode", string(package.countryCode), "quantityValue", double(package.quantityValue), "quantityDimensionRaw", string(package.quantityDimensionRaw), "containerTypeRaw", string(package.containerTypeRaw), "priorityRaw", string(package.priorityRaw), "provenanceRaw", string(package.provenanceRaw), "sourceNote", package.sourceNote.map(ManagedHouseholdMigrationValue.string) as Any, "sourceDate", package.sourceDate.map(ManagedHouseholdMigrationValue.date) as Any, "sourceVersion", package.sourceVersion.map(ManagedHouseholdMigrationValue.string) as Any, "stableBundledID", package.stableBundledID.map(ManagedHouseholdMigrationValue.string) as Any, "overridesBundledID", package.overridesBundledID.map(ManagedHouseholdMigrationValue.string) as Any, "overridesProfile", bool(package.overridesProfile), "isEnabled", bool(package.isEnabled), "isPreferred", bool(package.isPreferred)
                ), relationships: relationship("household", package.household?.uuid))
            }
        case .ingredientMatchRule:
            return try context.fetch(FetchDescriptor<IngredientMatchRule>()).map { rule in
                try record(.ingredientMatchRule, rule, scope: scope(for: rule.household), attributes: attributes(
                    "leftKey", string(rule.leftKey), "rightKey", string(rule.rightKey), "kindRaw", string(rule.kindRaw)
                ), relationships: relationship("household", rule.household?.uuid))
            }
        case .dishIngredient:
            return try context.fetch(FetchDescriptor<DishIngredient>()).map { line in
                try record(.dishIngredient, line, scope: scope(for: line.dish?.household), attributes: attributes(
                    "canonicalValue", line.canonicalValue.map(ManagedHouseholdMigrationValue.double) as Any, "canonicalDimensionRaw", line.canonicalDimensionRaw.map(ManagedHouseholdMigrationValue.string) as Any, "displayUnit", line.displayUnit.map(ManagedHouseholdMigrationValue.string) as Any, "isApproximate", bool(line.isApproximate), "note", line.note.map(ManagedHouseholdMigrationValue.string) as Any, "rawText", line.rawText.map(ManagedHouseholdMigrationValue.string) as Any, "translatedName", line.translatedName.map(ManagedHouseholdMigrationValue.string) as Any, "translatedNote", line.translatedNote.map(ManagedHouseholdMigrationValue.string) as Any, "sortIndex", integer(line.sortIndex)
                ), relationships: relationships("dish", line.dish?.uuid, "ingredient", line.ingredient?.uuid))
            }
        case .mealPlanEntry:
            return try context.fetch(FetchDescriptor<MealPlanEntry>()).map { entry in
                try record(.mealPlanEntry, entry, scope: scope(for: entry.household), attributes: attributes(
                    "placementModifiedAt", date(entry.placementModifiedAt), "contentModifiedAt", date(entry.contentModifiedAt), "date", date(entry.date), "mealSlotRaw", string(entry.mealSlotRaw), "servingsOverride", entry.servingsOverride.map(integer) as Any, "note", entry.note.map(ManagedHouseholdMigrationValue.string) as Any, "sortIndex", integer(entry.sortIndex), "reactionRaw", entry.reactionRaw.map(ManagedHouseholdMigrationValue.string) as Any, "skipped", bool(entry.skipped), "prepReminder", bool(entry.prepReminder), "plannedByName", entry.plannedByName.map(ManagedHouseholdMigrationValue.string) as Any, "lastEditedByName", entry.lastEditedByName.map(ManagedHouseholdMigrationValue.string) as Any, "lastEditedDate", entry.lastEditedDate.map(ManagedHouseholdMigrationValue.date) as Any, "participatingMemberUUIDs", try json(entry.participatingMemberUUIDs), "isEatingOut", bool(entry.isEatingOut), "placeName", entry.placeName.map(ManagedHouseholdMigrationValue.string) as Any, "placeAddress", entry.placeAddress.map(ManagedHouseholdMigrationValue.string) as Any, "placeLatitude", entry.placeLatitude.map(ManagedHouseholdMigrationValue.double) as Any, "placeLongitude", entry.placeLongitude.map(ManagedHouseholdMigrationValue.double) as Any, "routineUUID", entry.routineUUID.map(ManagedHouseholdMigrationValue.uuid) as Any
                ), relationships: relationships("dish", entry.dish?.uuid, "household", entry.household?.uuid))
            }
        case .mealRoutine:
            return try context.fetch(FetchDescriptor<MealRoutine>()).map { routine in
                try record(.mealRoutine, routine, scope: scope(for: routine.household), attributes: attributes(
                    "mealKey", string(routine.mealKey), "weekday", integer(routine.weekday), "intervalWeeks", integer(routine.intervalWeeks), "startDate", date(routine.startDate), "isActive", bool(routine.isActive), "plannedThrough", routine.plannedThrough.map(ManagedHouseholdMigrationValue.date) as Any, "dateCreated", date(routine.dateCreated)
                ), relationships: relationships("dish", routine.dish?.uuid, "household", routine.household?.uuid))
            }
        case .cookedLog:
            return try context.fetch(FetchDescriptor<CookedLog>()).map { log in
                try record(.cookedLog, log, scope: scope(for: log.household), attributes: attributes(
                    "date", date(log.date), "dishName", log.dishName.map(ManagedHouseholdMigrationValue.string) as Any, "servings", log.servings.map(integer) as Any, "photoData", log.photoData.map(ManagedHouseholdMigrationValue.data) as Any
                ), relationships: relationships("entry", log.entry?.uuid, "dish", log.dish?.uuid, "household", log.household?.uuid))
            }
        case .shoppingListItem:
            return try context.fetch(FetchDescriptor<ShoppingListItem>()).map { item in
                try record(.shoppingListItem, item, scope: scope(for: item.household), attributes: attributes(
                    "contentModifiedAt", date(item.contentModifiedAt), "checkStateModifiedAt", date(item.checkStateModifiedAt), "name", string(item.name), "normalizedName", string(item.normalizedName), "categoryRaw", string(item.categoryRaw), "customAisleName", item.customAisleName.map(ManagedHouseholdMigrationValue.string) as Any, "canonicalValue", item.canonicalValue.map(ManagedHouseholdMigrationValue.double) as Any, "canonicalDimensionRaw", item.canonicalDimensionRaw.map(ManagedHouseholdMigrationValue.string) as Any, "additionalAmountsRaw", try json(item.additionalAmountsRaw), "unmeasuredCount", integer(item.unmeasuredCount), "displayText", item.displayText.map(ManagedHouseholdMigrationValue.string) as Any, "displayUnit", item.displayUnit.map(ManagedHouseholdMigrationValue.string) as Any, "isChecked", bool(item.isChecked), "isManual", bool(item.isManual), "isApproximate", bool(item.isApproximate), "sortIndex", integer(item.sortIndex), "rangeStart", item.rangeStart.map(ManagedHouseholdMigrationValue.date) as Any, "rangeEnd", item.rangeEnd.map(ManagedHouseholdMigrationValue.date) as Any, "sourceDishNames", try json(item.sourceDishNames), "dateCreated", date(item.dateCreated)
                ), relationships: relationships("ingredient", item.ingredient?.uuid, "household", item.household?.uuid))
            }
        case .weekTemplate:
            return try context.fetch(FetchDescriptor<WeekTemplate>()).map { template in
                try record(.weekTemplate, template, scope: scope(for: template.household), attributes: attributes(
                    "name", string(template.name), "createdByName", template.createdByName.map(ManagedHouseholdMigrationValue.string) as Any, "dateCreated", date(template.dateCreated)
                ), relationships: relationship("household", template.household?.uuid))
            }
        case .weekTemplateEntry:
            return try context.fetch(FetchDescriptor<WeekTemplateEntry>()).map { entry in
                try record(.weekTemplateEntry, entry, scope: scope(for: entry.template?.household), attributes: attributes(
                    "weekday", integer(entry.weekday), "mealSlotRaw", string(entry.mealSlotRaw), "servingsOverride", entry.servingsOverride.map(integer) as Any, "sortIndex", integer(entry.sortIndex)
                ), relationships: relationships("dish", entry.dish?.uuid, "template", entry.template?.uuid))
            }
        case .recipeFeed:
            return try context.fetch(FetchDescriptor<RecipeFeed>()).map { feed in
                try record(.recipeFeed, feed, scope: scope(for: feed.household), attributes: attributes(
                    "title", string(feed.title), "siteURLString", string(feed.siteURLString), "feedURLString", string(feed.feedURLString), "sourceKindRaw", string(feed.sourceKindRaw), "sourceID", feed.sourceID.map(ManagedHouseholdMigrationValue.string) as Any, "contentURLString", feed.contentURLString.map(ManagedHouseholdMigrationValue.string) as Any, "etag", feed.etag.map(ManagedHouseholdMigrationValue.string) as Any, "lastModified", feed.lastModified.map(ManagedHouseholdMigrationValue.string) as Any, "lastFetchedAt", feed.lastFetchedAt.map(ManagedHouseholdMigrationValue.date) as Any, "firstFailureAt", feed.firstFailureAt.map(ManagedHouseholdMigrationValue.date) as Any, "consecutiveFailures", integer(feed.consecutiveFailures), "nextRetryAt", feed.nextRetryAt.map(ManagedHouseholdMigrationValue.date) as Any, "lastHTTPStatus", feed.lastHTTPStatus.map(integer) as Any, "lastErrorMessage", feed.lastErrorMessage.map(ManagedHouseholdMigrationValue.string) as Any, "dateAdded", date(feed.dateAdded)
                ), relationships: relationship("household", feed.household?.uuid))
            }
        case .recipeFeedItem:
            return try context.fetch(FetchDescriptor<RecipeFeedItem>()).map { item in
                try record(.recipeFeedItem, item, scope: scope(for: item.feed?.household), attributes: attributes(
                    "stableID", string(item.stableID), "title", string(item.title), "urlString", string(item.urlString), "author", item.author.map(ManagedHouseholdMigrationValue.string) as Any, "summary", item.summary.map(ManagedHouseholdMigrationValue.string) as Any, "publishedAt", item.publishedAt.map(ManagedHouseholdMigrationValue.date) as Any, "fetchedAt", date(item.fetchedAt), "imageURLString", item.imageURLString.map(ManagedHouseholdMigrationValue.string) as Any, "imageLookupAt", item.imageLookupAt.map(ManagedHouseholdMigrationValue.date) as Any, "archivedAt", item.archivedAt.map(ManagedHouseholdMigrationValue.date) as Any
                ), relationships: relationship("feed", item.feed?.uuid))
            }
        case .recipeBookmark:
            return try context.fetch(FetchDescriptor<RecipeBookmark>()).map { bookmark in
                try record(.recipeBookmark, bookmark, scope: scope(for: bookmark.household), attributes: attributes(
                    "title", string(bookmark.title), "urlString", string(bookmark.urlString), "dateAdded", date(bookmark.dateAdded)
                ), relationships: relationship("household", bookmark.household?.uuid))
            }
        }
    }

    private func record<Model: LegacyMigrationModel>(
        _ entity: ManagedHouseholdEntity,
        _ model: Model,
        scope: ManagedHouseholdStoreScope,
        attributes: [String: ManagedHouseholdMigrationValue],
        relationships: [String: UUID] = [:]
    ) throws -> ManagedHouseholdMigrationRecord {
        .init(entity: entity, uuid: model.uuid, modifiedAt: model.modifiedAt, scope: scope, attributes: attributes, relationships: relationships)
    }

    private func scope(for household: Household?) -> ManagedHouseholdStoreScope {
        guard let household,
              let locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier),
              locator.shareRecordName != nil,
              !locator.isOwner
        else { return .private }
        // A legacy guest graph is isolated in the shared store but is not
        // activated there yet. #86 replaces its legacy share with a managed
        // accepted share before this store becomes the live source of writes.
        return .shared
    }

    private func attributes(_ values: Any...) -> [String: ManagedHouseholdMigrationValue] {
        precondition(values.count.isMultiple(of: 2), "Migration attribute values must be name/value pairs.")
        var result: [String: ManagedHouseholdMigrationValue] = [:]
        for offset in stride(from: 0, to: values.count, by: 2) {
            guard let name = values[offset] as? String else {
                preconditionFailure("Migration attribute names must be strings.")
            }
            let raw = values[offset + 1]
            if let value = raw as? ManagedHouseholdMigrationValue {
                result[name] = value
                continue
            }

            // Optional.none arrives boxed as Any. Preserve it explicitly so an
            // interrupted migration can clear stale destination values and verify
            // nil just as strictly as non-nil attributes.
            let mirror = Mirror(reflecting: raw)
            if mirror.displayStyle == .optional {
                guard let child = mirror.children.first else {
                    result[name] = .null
                    continue
                }
                if let value = child.value as? ManagedHouseholdMigrationValue {
                    result[name] = value
                    continue
                }
            }
            preconditionFailure("Migration attribute values must be migration values or nil optionals.")
        }
        return result
    }

    private func relationship(_ name: String, _ uuid: UUID?) -> [String: UUID] {
        guard let uuid else { return [:] }
        return [name: uuid]
    }

    private func relationships(_ firstName: String, _ firstUUID: UUID?, _ secondName: String, _ secondUUID: UUID?) -> [String: UUID] {
        relationship(firstName, firstUUID).merging(relationship(secondName, secondUUID)) { _, latest in latest }
    }

    private func relationships(_ firstName: String, _ firstUUID: UUID?, _ secondName: String, _ secondUUID: UUID?, _ thirdName: String, _ thirdUUID: UUID?) -> [String: UUID] {
        relationships(firstName, firstUUID, secondName, secondUUID).merging(relationship(thirdName, thirdUUID)) { _, latest in latest }
    }

    private func integer(_ value: Int) -> ManagedHouseholdMigrationValue { .integer(Int64(value)) }
    private func string(_ value: String) -> ManagedHouseholdMigrationValue { .string(value) }
    private func bool(_ value: Bool) -> ManagedHouseholdMigrationValue { .bool(value) }
    private func double(_ value: Double) -> ManagedHouseholdMigrationValue { .double(value) }
    private func date(_ value: Date) -> ManagedHouseholdMigrationValue { .date(value) }
    private func uuid(_ value: UUID) -> ManagedHouseholdMigrationValue { .uuid(value) }
    private func data(_ value: Data) -> ManagedHouseholdMigrationValue { .data(value) }
    private func json<T: Encodable>(_ value: T) throws -> ManagedHouseholdMigrationValue { .data(try JSONEncoder().encode(value)) }
}
