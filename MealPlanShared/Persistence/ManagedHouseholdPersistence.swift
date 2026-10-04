import CloudKit
import CoreData
import Foundation

/// Entity names in the managed Core Data model introduced for the CloudKit
/// collaboration migration. The model is intentionally separate from the
/// existing SwiftData schema until the one-way migration is ready.
enum ManagedHouseholdEntity: String, CaseIterable, Sendable {
    case household = "Household"
    case householdMember = "HouseholdMember"
    case mealType = "MealType"
    case dish = "Dish"
    case dishImage = "DishImage"
    case ingredient = "Ingredient"
    case ingredientAlias = "IngredientAlias"
    case ingredientPackageSize = "IngredientPackageSize"
    case ingredientMatchRule = "IngredientMatchRule"
    case dishIngredient = "DishIngredient"
    case mealPlanEntry = "MealPlanEntry"
    case mealRoutine = "MealRoutine"
    case cookedLog = "CookedLog"
    case shoppingListItem = "ShoppingListItem"
    case weekTemplate = "WeekTemplate"
    case weekTemplateEntry = "WeekTemplateEntry"
    case recipeFeed = "RecipeFeed"
    case recipeFeedItem = "RecipeFeedItem"
    case recipeBookmark = "RecipeBookmark"
}

/// A written-down boundary for the new store. Every current SwiftData model
/// has exactly one classification; rebuildable web/article caches and SwiftUI
/// state deliberately have none in the managed CloudKit model.
enum ManagedHouseholdPersistenceClassification {
    static let privateOrSharedHouseholdData = Set(ManagedHouseholdEntity.allCases)

    /// These values may be persisted elsewhere (files, defaults, keychain),
    /// but must never become CloudKit-mirrored household records.
    static let localOnlyCaches: Set<String> = [
        "RecipeArticleCache",
        "RecipeDiscoverySnapshot",
        "RecipeFeedImageCache",
        "PublishedCalendarSettings",
        "BringCredentialStore",
        "HouseholdSyncMetadata",
        "HouseholdSyncDiagnostics",
    ]

    static let transientUIState: Set<String> = [
        "AppState",
        "CloudBootstrapState",
        "HouseholdCollaborationSession",
        "PurchaseManager",
        "CalendarContextStore",
        "SwiftUI navigation and sheet state",
    ]
}

enum ManagedHouseholdStoreScope: String, CaseIterable, Sendable {
    case `private`
    case shared

    fileprivate var configurationName: String {
        "MealPlanManaged.\(rawValue.capitalized)"
    }

    fileprivate var fileComponent: String { rawValue }

    fileprivate var cloudKitScope: CKDatabase.Scope {
        switch self {
        case .private: .private
        case .shared: .shared
        }
    }
}

enum ManagedHouseholdPersistenceError: LocalizedError {
    case loadingAlreadyInProgress
    case notLoaded
    case unknownStore
    case entityMissing(ManagedHouseholdEntity)

    var errorDescription: String? {
        switch self {
        case .loadingAlreadyInProgress: "The managed household stores are already loading."
        case .notLoaded: "The managed household stores have not loaded."
        case .unknownStore: "The object does not belong to a managed household store."
        case .entityMissing(let entity): "The managed household model is missing \(entity.rawValue)."
        }
    }
}

/// The new authoritative CloudKit persistence foundation.
///
/// It mirrors the same managed-object model to two physical stores: one for
/// the current account's private households and one for household shares that
/// account accepted. There is deliberately no SwiftData bridge and no
/// `CKSyncEngine` here. The migration phase can read the old store and write
/// this container exactly once; Core Data owns all subsequent mirroring.
@MainActor
final class ManagedHouseholdPersistence {
    static let modelName = "MealPlanManagedHousehold"
    static let transactionAuthor = "MealPlan"

    let container: NSPersistentCloudKitContainer
    let storeDirectory: URL
    let cloudKitEnabled: Bool
    let environment: CloudKitEnvironment

    private let descriptions: [NSPersistentStoreDescription]
    private var stores: [ManagedHouseholdStoreScope: NSPersistentStore] = [:]
    private var pendingStoreLoads = 0
    private var loadError: Error?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var isLoading = false
    private var remoteChangeObserver: NSObjectProtocol?
    private var sharedHouseholdEditability: [UUID: Bool] = [:]

    var isLoaded: Bool { stores.count == ManagedHouseholdStoreScope.allCases.count }
    var persistentStoreDescriptions: [NSPersistentStoreDescription] { descriptions }

    init(
        storeDirectory: URL? = nil,
        cloudKitEnabled: Bool = true,
        inMemory: Bool = false,
        environment: CloudKitEnvironment = BuildEnvironment.cloudKit
    ) throws {
        let resolvedStoreDirectory = try storeDirectory ?? Self.defaultStoreDirectory()
        let shouldEnableCloudKit = cloudKitEnabled && !inMemory
        self.storeDirectory = resolvedStoreDirectory
        self.cloudKitEnabled = shouldEnableCloudKit
        self.environment = environment

        let model = ManagedHouseholdModel.make()
        container = NSPersistentCloudKitContainer(name: Self.modelName, managedObjectModel: model)
        descriptions = try ManagedHouseholdStoreScope.allCases.map {
            try Self.storeDescription(
                scope: $0,
                directory: resolvedStoreDirectory,
                cloudKitEnabled: shouldEnableCloudKit,
                inMemory: inMemory,
                environment: environment
            )
        }
        container.persistentStoreDescriptions = descriptions
        configure(container.viewContext)
    }

    /// Loading does not change or open the existing SwiftData database. In
    /// particular, an offline account can open both SQLite stores with
    /// CloudKit mirroring deferred by the framework.
    func load() async throws {
        if isLoaded { return }
        guard !isLoading else { throw ManagedHouseholdPersistenceError.loadingAlreadyInProgress }
        isLoading = true
        pendingStoreLoads = descriptions.count
        loadError = nil

        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            container.loadPersistentStores { [weak self] description, error in
                Task { @MainActor in
                    self?.didLoad(description: description, error: error)
                }
            }
        }
    }

    func newBackgroundContext(author: String = transactionAuthor) throws -> NSManagedObjectContext {
        guard isLoaded else { throw ManagedHouseholdPersistenceError.notLoaded }
        let context = container.newBackgroundContext()
        context.transactionAuthor = author
        configure(context)
        return context
    }

    /// Creates a record directly in a known store. Store ownership is never
    /// guessed from a household UUID or relationship content.
    func insert(
        _ entity: ManagedHouseholdEntity,
        into scope: ManagedHouseholdStoreScope,
        context: NSManagedObjectContext,
        uuid: UUID = UUID()
    ) throws -> NSManagedObject {
        guard let store = stores[scope] else { throw ManagedHouseholdPersistenceError.notLoaded }
        guard let description = NSEntityDescription.entity(forEntityName: entity.rawValue, in: context) else {
            throw ManagedHouseholdPersistenceError.entityMissing(entity)
        }
        let object = NSManagedObject(entity: description, insertInto: context)
        context.assign(object, to: store)
        object.setValue(uuid, forKey: "uuid")
        object.setValue(Date.now, forKey: "modifiedAt")
        return object
    }

    func storeScope(for object: NSManagedObject) -> ManagedHouseholdStoreScope? {
        guard let store = object.objectID.persistentStore else { return nil }
        return stores.first { $0.value === store }?.key
    }

    /// Shared household permission comes from accepted-share metadata, not
    /// from heuristics about data residing in a shared store. #85 connects the
    /// system share's participant permission to this explicit value.
    func setEditable(_ editable: Bool, for household: NSManagedObject) throws {
        guard storeScope(for: household) != nil,
              let uuid = household.value(forKey: "uuid") as? UUID
        else { throw ManagedHouseholdPersistenceError.unknownStore }
        sharedHouseholdEditability[uuid] = editable
    }

    func isEditable(_ household: NSManagedObject) -> Bool {
        guard let scope = storeScope(for: household) else { return false }
        if scope == .private { return true }
        guard let uuid = household.value(forKey: "uuid") as? UUID else { return false }
        return sharedHouseholdEditability[uuid] ?? true
    }

    func isEditable(_ object: NSManagedObject, in household: NSManagedObject) -> Bool {
        guard storeScope(for: object) == storeScope(for: household) else { return false }
        return isEditable(household)
    }

    private func didLoad(description: NSPersistentStoreDescription, error: Error?) {
        if let error, loadError == nil { loadError = error }
        pendingStoreLoads -= 1
        guard pendingStoreLoads == 0 else { return }

        isLoading = false
        defer { loadContinuation = nil }
        if let loadError {
            loadContinuation?.resume(throwing: loadError)
            return
        }

        for scope in ManagedHouseholdStoreScope.allCases {
            guard let store = container.persistentStoreCoordinator.persistentStores.first(where: {
                // Configuration is the stable identity. Comparing only URLs
                // would make the in-memory/offline test configuration depend
                // on Core Data's implementation detail for a store URL.
                $0.configurationName == scope.configurationName
                    || $0.url == descriptionURL(for: scope)
            })
            else {
                loadContinuation?.resume(throwing: ManagedHouseholdPersistenceError.unknownStore)
                return
            }
            stores[scope] = store
        }
        installRemoteChangeObservation()
        loadContinuation?.resume()
    }

    private func descriptionURL(for scope: ManagedHouseholdStoreScope) -> URL? {
        descriptions.first { $0.configuration == scope.configurationName }?.url
    }

    private func configure(_ context: NSManagedObjectContext) {
        // The persisted/remote version wins when a UI context and a mirroring
        // import touch the same property. This keeps an old object fault from
        // overwriting CloudKit's resolved value during the migration window.
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType)
        context.automaticallyMergesChangesFromParent = true
        context.transactionAuthor = Self.transactionAuthor
    }

    private func installRemoteChangeObservation() {
        guard remoteChangeObserver == nil else { return }
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .mealPlanManagedStoreDidChange, object: nil)
        }
    }

    private static func defaultStoreDirectory() throws -> URL {
        let directory = URL.applicationSupportDirectory
            .appending(path: "MealPlan", directoryHint: .isDirectory)
            .appending(path: "ManagedHouseholdStores", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func storeDescription(
        scope: ManagedHouseholdStoreScope,
        directory: URL,
        cloudKitEnabled: Bool,
        inMemory: Bool,
        environment: CloudKitEnvironment
    ) throws -> NSPersistentStoreDescription {
        let suffix = environment.rawValue.lowercased()
        let url = directory.appending(path: "MealPlanManaged-\(suffix)-\(scope.fileComponent).sqlite")
        let description = NSPersistentStoreDescription(url: url)
        description.configuration = scope.configurationName
        description.type = inMemory ? NSInMemoryStoreType : NSSQLiteStoreType
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        if cloudKitEnabled {
            let options = NSPersistentCloudKitContainerOptions(containerIdentifier: SharedStore.cloudKitContainerID)
            options.databaseScope = scope.cloudKitScope
            description.cloudKitContainerOptions = options
        }
        return description
    }
}

extension Notification.Name {
    /// Posted after Core Data imports a remote transaction. The UI cutover and
    /// extension handoff can observe this without knowing CloudKit details.
    static let mealPlanManagedStoreDidChange = Notification.Name("de.holgerkrupp.mealplan.managedStoreDidChange")
}

private enum ManagedHouseholdModel {
    static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.versionIdentifiers = ["MealPlanManagedHousehold.v1"]

        var entities = Dictionary(uniqueKeysWithValues: ManagedHouseholdEntity.allCases.map {
            ($0, entity(for: $0))
        })
        addHouseholdRelationships(to: &entities)
        addDomainRelationships(to: &entities)
        model.entities = ManagedHouseholdEntity.allCases.compactMap { entities[$0] }

        // Both stores intentionally use the identical entity model. Routing is
        // explicit through `context.assign(_:to:)`, never inferred from rows.
        for scope in ManagedHouseholdStoreScope.allCases {
            model.setEntities(model.entities, forConfigurationName: scope.configurationName)
        }
        return model
    }

    private static func entity(for mappedEntity: ManagedHouseholdEntity) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = mappedEntity.rawValue
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = attributes(for: mappedEntity).map(\.description)
        // UUIDs are retained from SwiftData and remain the stable domain
        // identity, but CloudKit-backed Core Data stores do not support unique
        // constraints. The repository/migration layer validates uniqueness
        // explicitly before activation instead of encoding it in the model.
        return entity
    }

    /// Scalar attributes are declared directly rather than hiding the
    /// canonical object graph in a legacy sync payload. Collection values
    /// remain binary, JSON-encoded fields because Core Data/CloudKit does not
    /// mirror arbitrary Swift arrays as scalar attributes. The #82 importer
    /// owns that deterministic encoding; it is not a SwiftData ↔ Core Data
    /// bridge and it is never sent through `CKSyncEngine`.
    private static func attributes(for entity: ManagedHouseholdEntity) -> [ManagedHouseholdAttribute] {
        switch entity {
        case .household:
            attributes(.uuid, .modifiedAt, .string("name"), .string("unitSystemRaw"), .string("unitPresentationOverrideRaw", optional: true), .bool("roundsDisplayedAmounts"), .string("calendarStyleRaw"), .integer("standardServings"), .bool("showsNutritionEstimates"), .bool("leftoverSuggestionsEnabled"), .bool("inventoryEnabled"), .string("packageSizeCountryCode"), .string("energyUnitRaw"), .string("localeIdentifier"), .date("dateCreated"), .bool("didSeedPantryStaples"), .binary("ingredientMergeAuditData", external: true), .bool("unlockedByPurchase"), .string("bringListUuid", optional: true), .string("bringListName", optional: true), .binary("bringShadowKeys"), .bool("bringAutoSync"), .date("bringLastSyncedAt", optional: true))
        case .householdMember:
            attributes(.uuid, .modifiedAt, .string("cloudKitParticipantID", optional: true), .bool("isActive"), .string("name"), .string("roleRaw"), .bool("isCurrentUser"), .date("dateAdded"), .date("shareMetadataModifiedAt"), .date("profileModifiedAt"), .binary("allergies"), .binary("mustAvoidIngredients"), .binary("dietaryPatterns"), .binary("dislikes"), .binary("favorites"), .binary("preferredCuisines"), .integer("spiceTolerance", optional: true))
        case .mealType:
            attributes(.uuid, .modifiedAt, .string("key"), .string("name"), .string("symbolName"), .integer("sortOrder"))
        case .dish:
            attributes(.uuid, .modifiedAt, .string("name"), .string("recipeText", optional: true), .string("sourceURLString", optional: true), .string("deepLinkURLString", optional: true), .string("importedSourceApp", optional: true), .string("importedSourceID", optional: true), .uuid("variantGroupID", optional: true), .string("variantGroupName", optional: true), .bool("isFavorite"), .integer("rating"), .binary("collectionNames"), .binary("tagNames"), .integer("servings"), .integer("prepTimeMinutes", optional: true), .integer("cookTimeMinutes", optional: true), .binary("mealTypeTagsRaw"), .binary("dietaryTagsRaw"), .string("seasonRaw", optional: true), .string("createdByName", optional: true), .date("dateCreated"), .date("lastUsedDate", optional: true), .integer("usageCount"), .bool("needsReview"), .double("statedEnergyKcalPerServing", optional: true), .double("statedProteinGramsPerServing", optional: true), .double("statedCarbGramsPerServing", optional: true), .double("statedFatGramsPerServing", optional: true), .double("statedSaturatedFatGramsPerServing", optional: true), .double("statedFiberGramsPerServing", optional: true), .double("statedSugarGramsPerServing", optional: true), .double("statedSodiumMilligramsPerServing", optional: true), .double("statedCholesterolMilligramsPerServing", optional: true), .string("statedNutritionProvenanceRaw", optional: true), .string("recipeLanguageCode", optional: true), .string("translationLanguageCode", optional: true), .string("translatedName", optional: true), .string("translatedRecipeText", optional: true), .string("glyphRaw", optional: true), .bool("glyphIsAuto"))
        case .dishImage:
            attributes(.uuid, .modifiedAt, .binary("data", external: true), .integer("sortIndex"), .bool("isPrimary"), .date("dateAdded"))
        case .ingredient:
            attributes(.uuid, .modifiedAt, .string("name"), .string("normalizedName"), .string("categoryRaw"), .string("customAisleName", optional: true), .bool("isPantryStaple"), .string("inventoryModeRaw"), .double("inventoryCanonicalValue", optional: true), .string("inventoryDimensionRaw", optional: true), .date("inventoryBestBefore", optional: true), .string("inventoryStorageLocationRaw", optional: true), .string("inventoryCustomStorageLocation", optional: true), .date("inventoryUpdatedAt", optional: true), .binary("rejectedMatchKeys"), .binary("pendingMergeSuggestionsData", external: true), .double("nutritionEnergyKcal", optional: true), .double("nutritionProteinGrams", optional: true), .double("nutritionCarbGrams", optional: true), .double("nutritionFatGrams", optional: true), .string("nutritionReferenceRaw", optional: true), .string("nutritionSourceRaw", optional: true))
        case .ingredientAlias:
            attributes(.uuid, .modifiedAt, .string("name"), .string("normalizedName"), .string("sourceRaw"), .double("confidence", optional: true))
        case .ingredientPackageSize:
            attributes(.uuid, .modifiedAt, .string("ingredientKey"), .string("ingredientName"), .string("countryCode"), .double("quantityValue"), .string("quantityDimensionRaw"), .string("containerTypeRaw"), .string("priorityRaw"), .string("provenanceRaw"), .string("sourceNote", optional: true), .date("sourceDate", optional: true), .string("sourceVersion", optional: true), .string("stableBundledID", optional: true), .string("overridesBundledID", optional: true), .bool("overridesProfile"), .bool("isEnabled"), .bool("isPreferred"))
        case .ingredientMatchRule:
            attributes(.uuid, .modifiedAt, .string("leftKey"), .string("rightKey"), .string("kindRaw"))
        case .dishIngredient:
            attributes(.uuid, .modifiedAt, .double("canonicalValue", optional: true), .string("canonicalDimensionRaw", optional: true), .string("displayUnit", optional: true), .bool("isApproximate"), .string("note", optional: true), .string("rawText", optional: true), .string("translatedName", optional: true), .string("translatedNote", optional: true), .integer("sortIndex"))
        case .mealPlanEntry:
            attributes(.uuid, .modifiedAt, .date("placementModifiedAt"), .date("contentModifiedAt"), .date("date"), .string("mealSlotRaw"), .integer("servingsOverride", optional: true), .string("note", optional: true), .integer("sortIndex"), .string("reactionRaw", optional: true), .bool("skipped"), .bool("prepReminder"), .string("plannedByName", optional: true), .string("lastEditedByName", optional: true), .date("lastEditedDate", optional: true), .binary("participatingMemberUUIDs"), .bool("isEatingOut"), .string("placeName", optional: true), .string("placeAddress", optional: true), .double("placeLatitude", optional: true), .double("placeLongitude", optional: true), .uuid("routineUUID", optional: true))
        case .mealRoutine:
            attributes(.uuid, .modifiedAt, .string("mealKey"), .integer("weekday"), .integer("intervalWeeks"), .date("startDate"), .bool("isActive"), .date("plannedThrough", optional: true), .date("dateCreated"))
        case .cookedLog:
            attributes(.uuid, .modifiedAt, .date("date"), .string("dishName", optional: true), .integer("servings", optional: true), .binary("photoData", external: true))
        case .shoppingListItem:
            attributes(.uuid, .modifiedAt, .date("contentModifiedAt"), .date("checkStateModifiedAt"), .string("name"), .string("normalizedName"), .string("categoryRaw"), .string("customAisleName", optional: true), .double("canonicalValue", optional: true), .string("canonicalDimensionRaw", optional: true), .binary("additionalAmountsRaw"), .integer("unmeasuredCount"), .string("displayText", optional: true), .string("displayUnit", optional: true), .bool("isChecked"), .bool("isManual"), .bool("isApproximate"), .integer("sortIndex"), .date("rangeStart", optional: true), .date("rangeEnd", optional: true), .binary("sourceDishNames"), .date("dateCreated"))
        case .weekTemplate:
            attributes(.uuid, .modifiedAt, .string("name"), .string("createdByName", optional: true), .date("dateCreated"))
        case .weekTemplateEntry:
            attributes(.uuid, .modifiedAt, .integer("weekday"), .string("mealSlotRaw"), .integer("servingsOverride", optional: true), .integer("sortIndex"))
        case .recipeFeed:
            attributes(.uuid, .modifiedAt, .string("title"), .string("siteURLString"), .string("feedURLString"), .string("sourceKindRaw"), .string("sourceID", optional: true), .string("contentURLString", optional: true), .string("etag", optional: true), .string("lastModified", optional: true), .date("lastFetchedAt", optional: true), .date("firstFailureAt", optional: true), .integer("consecutiveFailures"), .date("nextRetryAt", optional: true), .integer("lastHTTPStatus", optional: true), .string("lastErrorMessage", optional: true), .date("dateAdded"))
        case .recipeFeedItem:
            attributes(.uuid, .modifiedAt, .string("stableID"), .string("title"), .string("urlString"), .string("author", optional: true), .string("summary", optional: true), .date("publishedAt", optional: true), .date("fetchedAt"), .string("imageURLString", optional: true), .date("imageLookupAt", optional: true), .date("archivedAt", optional: true))
        case .recipeBookmark:
            attributes(.uuid, .modifiedAt, .string("title"), .string("urlString"), .date("dateAdded"))
        }
    }

    private static func attributes(_ values: ManagedHouseholdAttribute...) -> [ManagedHouseholdAttribute] { values }

    private static func addHouseholdRelationships(to entities: inout [ManagedHouseholdEntity: NSEntityDescription]) {
        link(.household, "members", .householdMember, "household", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.household, "mealTypes", .mealType, "household", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.household, "dishes", .dish, "household", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.household, "ingredients", .ingredient, "household", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.household, "matchRules", .ingredientMatchRule, "household", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.household, "entries", .mealPlanEntry, "household", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.household, "shoppingItems", .shoppingListItem, "household", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.household, "cookedLogs", .cookedLog, "household", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.household, "weekTemplates", .weekTemplate, "household", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.household, "mealRoutines", .mealRoutine, "household", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.household, "recipeFeeds", .recipeFeed, "household", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.household, "recipeBookmarks", .recipeBookmark, "household", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.household, "packageSizeOverrides", .ingredientPackageSize, "household", deleteRule: .cascadeDeleteRule, entities: &entities)
    }

    private static func addDomainRelationships(to entities: inout [ManagedHouseholdEntity: NSEntityDescription]) {
        link(.dish, "images", .dishImage, "dish", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.dish, "ingredients", .dishIngredient, "dish", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.dish, "entries", .mealPlanEntry, "dish", deleteRule: .nullifyDeleteRule, entities: &entities)
        link(.dish, "cookedLogs", .cookedLog, "dish", deleteRule: .nullifyDeleteRule, entities: &entities)
        link(.dish, "templateEntries", .weekTemplateEntry, "dish", deleteRule: .nullifyDeleteRule, entities: &entities)
        link(.dish, "mealRoutines", .mealRoutine, "dish", deleteRule: .cascadeDeleteRule, entities: &entities)

        link(.ingredient, "aliases", .ingredientAlias, "ingredient", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.ingredient, "dishIngredients", .dishIngredient, "ingredient", deleteRule: .nullifyDeleteRule, entities: &entities)
        link(.ingredient, "shoppingItems", .shoppingListItem, "ingredient", deleteRule: .nullifyDeleteRule, entities: &entities)

        link(.mealPlanEntry, "cookedLog", .cookedLog, "entry", deleteRule: .cascadeDeleteRule, entities: &entities, toMany: false)
        link(.weekTemplate, "entries", .weekTemplateEntry, "template", deleteRule: .cascadeDeleteRule, entities: &entities)
        link(.recipeFeed, "items", .recipeFeedItem, "feed", deleteRule: .cascadeDeleteRule, entities: &entities)
    }

    private static func link(
        _ parent: ManagedHouseholdEntity,
        _ parentName: String,
        _ child: ManagedHouseholdEntity,
        _ childName: String,
        deleteRule: NSDeleteRule,
        entities: inout [ManagedHouseholdEntity: NSEntityDescription],
        toMany: Bool = true
    ) {
        guard let source = entities[parent], let destination = entities[child] else { return }
        let forward = NSRelationshipDescription()
        forward.name = parentName
        forward.destinationEntity = destination
        forward.minCount = 0
        forward.maxCount = toMany ? 0 : 1
        forward.isOptional = true
        forward.deleteRule = deleteRule

        let inverse = NSRelationshipDescription()
        inverse.name = childName
        inverse.destinationEntity = source
        inverse.minCount = 0
        inverse.maxCount = 1
        inverse.isOptional = true
        inverse.deleteRule = .nullifyDeleteRule

        forward.inverseRelationship = inverse
        inverse.inverseRelationship = forward
        source.properties.append(forward)
        destination.properties.append(inverse)
    }
}

/// A compact, testable declaration of the Core Data schema. All collection
/// properties are encoded as versioned JSON `Data` by the one-way importer;
/// this avoids relying on an insecure transformable while retaining the
/// original property name and value semantics.
private struct ManagedHouseholdAttribute {
    let name: String
    let type: NSAttributeType
    let optional: Bool
    let externalBinary: Bool

    // CloudKit mirroring requires every non-optional attribute to have a
    // model default. UUID has no safe static default (one constant would break
    // identity), so persistence keeps it optional while insert/migration always
    // assigns and verifies a UUID before a record becomes canonical.
    static let uuid = ManagedHouseholdAttribute("uuid", .UUIDAttributeType, optional: true)
    static let modifiedAt = ManagedHouseholdAttribute("modifiedAt", .dateAttributeType, optional: false)

    static func string(_ name: String, optional: Bool = false) -> Self {
        Self(name, .stringAttributeType, optional: optional)
    }

    static func bool(_ name: String, optional: Bool = false) -> Self {
        Self(name, .booleanAttributeType, optional: optional)
    }

    static func integer(_ name: String, optional: Bool = false) -> Self {
        Self(name, .integer64AttributeType, optional: optional)
    }

    static func double(_ name: String, optional: Bool = false) -> Self {
        Self(name, .doubleAttributeType, optional: optional)
    }

    static func date(_ name: String, optional: Bool = false) -> Self {
        Self(name, .dateAttributeType, optional: optional)
    }

    static func uuid(_ name: String, optional: Bool = false) -> Self {
        Self(name, .UUIDAttributeType, optional: optional)
    }

    static func binary(_ name: String, external: Bool = false, optional: Bool = true) -> Self {
        Self(name, .binaryDataAttributeType, optional: optional, externalBinary: external)
    }

    var description: NSAttributeDescription {
        let description = NSAttributeDescription()
        description.name = name
        description.attributeType = type
        description.isOptional = optional
        description.allowsExternalBinaryDataStorage = externalBinary
        // The typed repository introduced during the UI cutover supplies the
        // domain defaults. These Core Data defaults keep a newly inserted
        // graph valid before that repository has filled every field (and make
        // interrupted, resumable migration batches safe to save).
        guard !optional else { return description }
        switch type {
        case .stringAttributeType:
            description.defaultValue = ""
        case .booleanAttributeType:
            description.defaultValue = false
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType:
            description.defaultValue = 0
        case .doubleAttributeType:
            description.defaultValue = 0.0
        case .dateAttributeType:
            description.defaultValue = Date.distantPast
        default:
            break
        }
        return description
    }

    private init(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool,
        externalBinary: Bool = false
    ) {
        self.name = name
        self.type = type
        self.optional = optional
        self.externalBinary = externalBinary
    }
}
