import CloudKit
import Foundation
import SwiftData
import OSLog

@MainActor
enum HouseholdRecordApplier {
    /// Small CloudKit batches fetch individual rows. Large imports materialize
    /// each model table once for the transaction. The cache never escapes it.
    @MainActor
    private final class BatchLookup {
        let context: ModelContext
        let usesTargetedFetches: Bool
        var tables: [ObjectIdentifier: Any] = [:]
        var targetedValues: [ObjectIdentifier: Any] = [:]
        var missingValues: [ObjectIdentifier: Set<UUID>] = [:]

        init(context: ModelContext, expectedRecordCount: Int) {
            self.context = context
            // A push normally contains only one meal edit. Materializing every
            // row of each SwiftData table on the UI actor makes that edit block
            // touches in a household with a large recipe library.
            usesTargetedFetches = expectedRecordCount <= 12
        }

        func find<T: HouseholdSyncModel>(_ type: T.Type, uuid: UUID) throws -> T? {
            let key = ObjectIdentifier(type)
            if usesTargetedFetches {
                if let value = (targetedValues[key] as? [UUID: T])?[uuid] { return value }
                if missingValues[key]?.contains(uuid) == true { return nil }
                if let value = try HouseholdRecordApplier.fetch(type, uuid: uuid, in: context) {
                    var values = targetedValues[key] as? [UUID: T] ?? [:]
                    values[uuid] = value
                    targetedValues[key] = values
                    return value
                }
                missingValues[key, default: []].insert(uuid)
                return nil
            }
            if let table = tables[key] as? [UUID: T] { return table[uuid] }
            let models: [T]
            do {
                models = try context.fetch(FetchDescriptor<T>())
            } catch {
                HouseholdRecordApplier.logLookupFailure(error, recordType: String(describing: type), stage: "tableFetch")
                throw HouseholdLookupError.fetchFailed(
                    recordType: String(describing: type), stage: "tableFetch", underlying: error
                )
            }
            let table = Dictionary(models.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
            tables[key] = table
            return table[uuid]
        }

        func insert<T: HouseholdSyncModel>(_ model: T) {
            let key = ObjectIdentifier(T.self)
            if usesTargetedFetches {
                var values = targetedValues[key] as? [UUID: T] ?? [:]
                values[model.uuid] = model
                targetedValues[key] = values
                missingValues[key]?.remove(model.uuid)
                return
            }
            guard var table = tables[key] as? [UUID: T] else { return }
            table[model.uuid] = model
            tables[key] = table
        }

        func remove<T: HouseholdSyncModel>(_ type: T.Type, uuid: UUID) {
            let key = ObjectIdentifier(type)
            if usesTargetedFetches {
                var values = targetedValues[key] as? [UUID: T] ?? [:]
                values.removeValue(forKey: uuid)
                targetedValues[key] = values
                missingValues[key, default: []].insert(uuid)
                return
            }
            guard var table = tables[key] as? [UUID: T] else { return }
            table.removeValue(forKey: uuid)
            tables[key] = table
        }
    }

    private enum HouseholdLookupError: LocalizedError {
        case fetchFailed(recordType: String, stage: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .fetchFailed(let recordType, let stage, let underlying):
                return "Household lookup failed (recordType=\(recordType), stage=\(stage)): \(underlying.localizedDescription)"
            }
        }
    }

    private static var batchLookup: BatchLookup?

    static func withBatchLookup<T>(in context: ModelContext, expectedRecordCount: Int = .max, _ operation: () throws -> T) rethrows -> T {
        let previous = batchLookup
        batchLookup = BatchLookup(context: context, expectedRecordCount: expectedRecordCount)
        defer { batchLookup = previous }
        return try operation()
    }

    static func touch(
        _ identity: HouseholdRecordIdentity,
        at date: Date,
        changedGroups: Set<String>,
        context: ModelContext
    ) throws {
        switch identity.type {
        case .household:
            if let model = try find(Household.self, identity.uuid, context) { model.modifiedAt = date }
        case .member:
            if let model = try find(HouseholdMember.self, identity.uuid, context) {
                if changedGroups.contains("shareMetadata") { model.shareMetadataModifiedAt = date }
                if changedGroups.contains("profile") { model.profileModifiedAt = date }
                model.modifiedAt = date
            }
        case .mealType: try touch(MealType.self, identity.uuid, date, context)
        case .dish: try touch(Dish.self, identity.uuid, date, context)
        case .dishImage: try touch(DishImage.self, identity.uuid, date, context)
        case .ingredient: try touch(Ingredient.self, identity.uuid, date, context)
        case .ingredientAlias: try touch(IngredientAlias.self, identity.uuid, date, context)
        case .packageSize: try touch(IngredientPackageSize.self, identity.uuid, date, context)
        case .ingredientMatchRule: try touch(IngredientMatchRule.self, identity.uuid, date, context)
        case .dishIngredient: try touch(DishIngredient.self, identity.uuid, date, context)
        case .planEntry:
            if let model = try find(MealPlanEntry.self, identity.uuid, context) {
                if changedGroups.contains("placement") { model.placementModifiedAt = date }
                if changedGroups.contains("content") { model.contentModifiedAt = date }
                model.modifiedAt = date
            }
        case .routine: try touch(MealRoutine.self, identity.uuid, date, context)
        case .cookedLog, .cookedLogImage: try touch(CookedLog.self, identity.uuid, date, context)
        case .shoppingItem:
            if let model = try find(ShoppingListItem.self, identity.uuid, context) {
                if changedGroups.contains("content") { model.contentModifiedAt = date }
                if changedGroups.contains("check") { model.checkStateModifiedAt = date }
                model.modifiedAt = date
            }
        case .weekTemplate: try touch(WeekTemplate.self, identity.uuid, date, context)
        case .weekTemplateEntry: try touch(WeekTemplateEntry.self, identity.uuid, date, context)
        case .recipeFeed: try touch(RecipeFeed.self, identity.uuid, date, context)
        case .recipeFeedItem: try touch(RecipeFeedItem.self, identity.uuid, date, context)
        case .recipeBookmark: try touch(RecipeBookmark.self, identity.uuid, date, context)
        case .deletionMarker: break
        }
    }

    static func apply(
        payloadData: Data,
        identity: HouseholdRecordIdentity,
        modifiedAt: Date,
        assetData: Data?,
        household: Household,
        context: ModelContext
    ) throws {
        let payload = try HouseholdRecordCodec.decode(payloadData)
        switch payload {
        case .household(let value):
            household.name = value.name
            household.unitSystemRaw = value.unitSystemRaw
            household.roundsDisplayedAmounts = value.roundsDisplayedAmounts
            household.standardServings = value.standardServings
            household.showsNutritionEstimates = value.showsNutritionEstimates
            household.leftoverSuggestionsEnabled = value.leftoverSuggestionsEnabled ?? false
            household.unitPresentationOverrideRaw = value.unitPresentationOverrideRaw
            household.inventoryEnabled = value.inventoryEnabled ?? false
            household.packageSizeCountryCode = value.packageSizeCountryCode ?? Household.defaultPackageSizeCountryCode
            household.energyUnitRaw = value.energyUnitRaw
            household.localeIdentifier = value.localeIdentifier
            household.dateCreated = value.dateCreated
            household.didSeedPantryStaples = value.didSeedPantryStaples
            household.ingredientMergeAuditData = value.ingredientMergeAuditData
            household.unlockedByPurchase = value.unlockedByPurchase ?? false
            household.bringListUuid = value.bringListUuid
            household.bringListName = value.bringListName
            household.bringShadowKeys = value.bringShadowKeys
            household.bringAutoSync = value.bringAutoSync
            household.bringLastSyncedAt = value.bringLastSyncedAt
            household.modifiedAt = modifiedAt

        case .member(let value):
            let model = try find(HouseholdMember.self, identity.uuid, context) ?? insert(HouseholdMember(), identity.uuid, context)
            model.name = value.name
            model.roleRaw = value.roleRaw
            model.dateAdded = value.dateAdded
            model.cloudKitParticipantID = value.cloudKitParticipantID
            model.isActive = value.isActive
            model.allergies = value.allergies ?? []
            model.mustAvoidIngredients = value.mustAvoidIngredients ?? []
            model.dietaryPatterns = value.dietaryPatterns ?? []
            model.dislikes = value.dislikes ?? []
            model.favorites = value.favorites ?? []
            model.preferredCuisines = value.preferredCuisines ?? []
            model.spiceTolerance = value.spiceTolerance
            model.shareMetadataModifiedAt = value.shareMetadataModifiedAt ?? modifiedAt
            model.profileModifiedAt = value.profileModifiedAt ?? modifiedAt
            model.modifiedAt = modifiedAt
            model.household = household

        case .mealType(let value):
            let model = try find(MealType.self, identity.uuid, context) ?? insert(MealType(), identity.uuid, context)
            model.key = value.key
            model.name = value.name
            model.symbolName = value.symbolName
            model.sortOrder = value.sortOrder
            model.modifiedAt = modifiedAt
            model.household = household

        case .ingredient(let value):
            let model = try find(Ingredient.self, identity.uuid, context) ?? insert(Ingredient(), identity.uuid, context)
            model.name = value.name
            model.normalizedName = value.normalizedName
            model.categoryRaw = value.categoryRaw
            model.customAisleName = value.customAisleName
            model.isPantryStaple = value.isPantryStaple
            model.nutritionEnergyKcal = value.nutritionEnergyKcal
            model.nutritionProteinGrams = value.nutritionProteinGrams
            model.nutritionCarbGrams = value.nutritionCarbGrams
            model.nutritionFatGrams = value.nutritionFatGrams
            model.nutritionReferenceRaw = value.nutritionReferenceRaw
            model.nutritionSourceRaw = value.nutritionSourceRaw
            model.inventoryModeRaw = value.inventoryModeRaw ?? InventoryMode.none.rawValue
            model.inventoryCanonicalValue = value.inventoryCanonicalValue
            model.inventoryDimensionRaw = value.inventoryDimensionRaw
            model.inventoryBestBefore = value.inventoryBestBefore
            model.inventoryStorageLocationRaw = value.inventoryStorageLocationRaw
            model.inventoryCustomStorageLocation = value.inventoryCustomStorageLocation
            model.inventoryUpdatedAt = value.inventoryUpdatedAt
            model.rejectedMatchKeys = value.rejectedMatchKeys ?? []
            model.pendingMergeSuggestionsData = value.pendingMergeSuggestionsData
            model.modifiedAt = modifiedAt
            model.household = household

        case .ingredientAlias(let value):
            guard let ingredient = try find(Ingredient.self, value.ingredientID, context) else {
                throw HouseholdRecordCodecError.missingRelationship
            }
            let model = try find(IngredientAlias.self, identity.uuid, context) ?? insert(IngredientAlias(), identity.uuid, context)
            model.name = value.name
            model.normalizedName = value.normalizedName
            model.sourceRaw = value.sourceRaw
            model.confidence = value.confidence
            model.modifiedAt = modifiedAt
            model.ingredient = ingredient

        case .packageSize(let value):
            let model = try find(IngredientPackageSize.self, identity.uuid, context)
                ?? insert(IngredientPackageSize(
                    ingredientKey: value.ingredientKey, ingredientName: value.ingredientName,
                    countryCode: value.countryCode,
                    quantity: Quantity(value: value.quantityValue, dimension: QuantityDimension(rawValue: value.quantityDimensionRaw) ?? .mass),
                    containerType: PackageContainerType(rawValue: value.containerTypeRaw) ?? .other,
                    priority: PackageSizePriority(rawValue: value.priorityRaw) ?? .common,
                    provenance: PackageSizeProvenance(rawValue: value.provenanceRaw) ?? .user
                ), identity.uuid, context)
            model.ingredientKey = value.ingredientKey
            model.ingredientName = value.ingredientName
            model.countryCode = value.countryCode
            model.quantityValue = value.quantityValue
            model.quantityDimensionRaw = value.quantityDimensionRaw
            model.containerTypeRaw = value.containerTypeRaw
            model.priorityRaw = value.priorityRaw
            model.provenanceRaw = value.provenanceRaw
            model.sourceNote = value.sourceNote
            model.sourceDate = value.sourceDate
            model.sourceVersion = value.sourceVersion
            model.stableBundledID = value.stableBundledID
            model.overridesBundledID = value.overridesBundledID
            model.overridesProfile = value.overridesProfile
            model.isEnabled = value.isEnabled
            model.isPreferred = value.isPreferred
            model.modifiedAt = modifiedAt
            model.household = household

        case .ingredientMatchRule(let value):
            let model = try find(IngredientMatchRule.self, identity.uuid, context) ?? insert(IngredientMatchRule(), identity.uuid, context)
            model.leftKey = value.leftKey
            model.rightKey = value.rightKey
            model.kindRaw = value.kindRaw
            model.modifiedAt = modifiedAt
            model.household = household

        case .dish(let value):
            let model = try find(Dish.self, identity.uuid, context) ?? insert(Dish(), identity.uuid, context)
            apply(value, to: model)
            model.modifiedAt = modifiedAt
            model.household = household

        case .dishImage(let value):
            guard let dish = try find(Dish.self, value.dishID, context) else { throw HouseholdRecordCodecError.missingRelationship }
            let model = try find(DishImage.self, identity.uuid, context) ?? insert(DishImage(data: nil), identity.uuid, context)
            // A CKAsset URL can occasionally be unavailable by the time its
            // record is applied. The photo has its own record, so absence of
            // bytes is not a deletion signal and must not erase a good local
            // copy. An explicit record deletion is handled in `delete` below.
            if let assetData { model.data = assetData }
            model.sortIndex = value.sortIndex
            model.isPrimary = value.isPrimary
            model.dateAdded = value.dateAdded
            model.modifiedAt = modifiedAt
            model.dish = dish

        case .dishIngredient(let value):
            guard let dish = try find(Dish.self, value.dishID, context) else { throw HouseholdRecordCodecError.missingRelationship }
            let model = try find(DishIngredient.self, identity.uuid, context) ?? insert(DishIngredient(), identity.uuid, context)
            model.canonicalValue = value.canonicalValue
            model.canonicalDimensionRaw = value.canonicalDimensionRaw
            model.displayUnit = value.displayUnit
            model.isApproximate = value.isApproximate
            model.note = value.note
            model.rawText = value.rawText
            model.sortIndex = value.sortIndex
            model.translatedName = value.translatedName
            model.translatedNote = value.translatedNote
            model.modifiedAt = modifiedAt
            model.dish = dish
            model.ingredient = try findOptional(Ingredient.self, value.ingredientID, context)

        case .planEntry(let wrapped):
            let value = wrapped.value
            let model = try find(MealPlanEntry.self, identity.uuid, context) ?? insert(MealPlanEntry(), identity.uuid, context)
            model.date = value.date
            model.mealSlotRaw = value.mealKey
            model.dish = try findOptional(Dish.self, value.dishUUID, context)
            model.servingsOverride = value.servingsOverride
            model.note = value.note
            model.sortIndex = value.sortIndex
            model.reactionRaw = value.reactionRaw
            model.skipped = value.skipped
            model.prepReminder = value.prepReminder
            model.plannedByName = value.plannedByName
            model.lastEditedByName = value.lastEditedByName
            model.lastEditedDate = value.lastEditedDate
            model.isEatingOut = value.isEatingOut
            model.placeName = value.placeName
            model.placeAddress = value.placeAddress
            model.placeLatitude = value.placeLatitude
            model.placeLongitude = value.placeLongitude
            model.routineUUID = value.routineUUID
            model.placementModifiedAt = wrapped.placementModifiedAt
            model.contentModifiedAt = wrapped.contentModifiedAt
            model.modifiedAt = modifiedAt
            model.household = household

        case .routine(let value):
            let model = try find(MealRoutine.self, identity.uuid, context) ?? insert(MealRoutine(), identity.uuid, context)
            model.dish = try findOptional(Dish.self, value.dishUUID, context)
            model.mealKey = value.mealKey
            model.weekday = value.weekday
            model.intervalWeeks = value.intervalWeeks
            model.startDate = value.startDate
            model.isActive = value.isActive
            model.plannedThrough = value.plannedThrough
            model.dateCreated = value.dateCreated
            model.modifiedAt = modifiedAt
            model.household = household

        case .cookedLog(let value):
            let model = try find(CookedLog.self, identity.uuid, context) ?? insert(CookedLog(), identity.uuid, context)
            model.date = value.date
            model.dishName = value.dishName
            model.servings = value.servings
            model.dish = try findOptional(Dish.self, value.dishUUID, context)
            model.entry = try findOptional(MealPlanEntry.self, value.entryUUID, context)
            model.modifiedAt = modifiedAt
            model.household = household

        case .cookedLogImage(let value):
            guard let log = try find(CookedLog.self, value.cookedLogID, context) else { throw HouseholdRecordCodecError.missingRelationship }
            if let assetData { log.photoData = assetData }
            log.modifiedAt = max(log.modifiedAt, modifiedAt)

        case .shoppingItem(let wrapped):
            let value = wrapped.value
            let model = try find(ShoppingListItem.self, identity.uuid, context) ?? insert(ShoppingListItem(), identity.uuid, context)
            model.name = value.name
            model.normalizedName = value.normalizedName
            model.categoryRaw = value.categoryRaw
            model.customAisleName = value.customAisleName
            model.canonicalValue = value.canonicalValue
            model.canonicalDimensionRaw = value.canonicalDimensionRaw
            model.additionalAmountsRaw = value.additionalAmountsRaw ?? []
            model.unmeasuredCount = value.unmeasuredCount ?? 0
            model.displayText = value.displayText
            model.displayUnit = value.displayUnit
            model.isChecked = value.isChecked
            model.isManual = value.isManual
            model.isApproximate = value.isApproximate
            model.sortIndex = value.sortIndex
            model.rangeStart = value.rangeStart
            model.rangeEnd = value.rangeEnd
            model.sourceDishNames = value.sourceDishNames
            model.dateCreated = value.dateCreated
            model.ingredient = try findOptional(Ingredient.self, wrapped.ingredientID, context)
            model.contentModifiedAt = wrapped.contentModifiedAt
            model.checkStateModifiedAt = wrapped.checkStateModifiedAt
            model.modifiedAt = modifiedAt
            model.household = household

        case .weekTemplate(let value):
            let model = try find(WeekTemplate.self, identity.uuid, context) ?? insert(WeekTemplate(), identity.uuid, context)
            model.name = value.name
            model.createdByName = value.createdByName
            model.dateCreated = value.dateCreated
            model.modifiedAt = modifiedAt
            model.household = household

        case .weekTemplateEntry(let value):
            guard let template = try find(WeekTemplate.self, value.templateID, context) else { throw HouseholdRecordCodecError.missingRelationship }
            let model = try find(WeekTemplateEntry.self, identity.uuid, context) ?? insert(WeekTemplateEntry(), identity.uuid, context)
            model.weekday = value.weekday
            model.mealSlotRaw = value.mealKey
            model.dish = try findOptional(Dish.self, value.dishID, context)
            model.servingsOverride = value.servingsOverride
            model.sortIndex = value.sortIndex
            model.modifiedAt = modifiedAt
            model.template = template

        case .recipeFeed(let value):
            guard let site = URL(string: value.siteURLString) else { return }
            let url = value.feedURLString.isEmpty ? nil : URL(string: value.feedURLString)
            let kind = value.sourceKindRaw.flatMap(RecipeSiteSourceKind.init(rawValue:)) ?? .feed
            let model = try find(RecipeFeed.self, identity.uuid, context) ?? insert(RecipeFeed(
                siteURL: site, feedURL: url, sourceKind: kind,
                sourceID: value.sourceID, contentURL: value.contentURLString.flatMap(URL.init(string:))
            ), identity.uuid, context)
            model.title = value.title
            model.siteURLString = value.siteURLString
            model.feedURLString = value.feedURLString
            if let sourceKindRaw = value.sourceKindRaw {
                model.sourceKindRaw = sourceKindRaw
                model.sourceID = value.sourceID
                model.contentURLString = value.contentURLString
            }
            // Each device keeps its own ETag, retry schedule, and last fetch
            // result. A remote subscription edit must not reset that cache.
            model.dateAdded = value.dateAdded
            model.modifiedAt = modifiedAt
            model.household = household

        case .recipeFeedItem(let wrapped):
            guard let feed = try find(RecipeFeed.self, wrapped.feedID, context), let url = URL(string: wrapped.value.urlString) else {
                throw HouseholdRecordCodecError.missingRelationship
            }
            let value = wrapped.value
            let model = try find(RecipeFeedItem.self, identity.uuid, context) ?? insert(RecipeFeedItem(stableID: value.stableID, title: value.title, url: url), identity.uuid, context)
            model.stableID = value.stableID
            model.title = value.title
            model.urlString = value.urlString
            model.author = value.author
            model.summary = value.summary
            model.publishedAt = value.publishedAt
            model.fetchedAt = value.fetchedAt
            model.imageURLString = value.imageURLString
            model.archivedAt = value.archivedAt
            model.modifiedAt = modifiedAt
            model.feed = feed

        case .recipeBookmark(let value):
            guard let url = URL(string: value.urlString) else { return }
            let model = try find(RecipeBookmark.self, identity.uuid, context) ?? insert(RecipeBookmark(title: value.title, url: url), identity.uuid, context)
            model.title = value.title
            model.urlString = value.urlString
            model.dateAdded = value.dateAdded
            model.modifiedAt = modifiedAt
            model.household = household

        case .deletionMarker(let marker):
            try delete(type: marker.deletedType, uuid: marker.deletedUUID, context: context)
        }
    }

    static func delete(type: HouseholdRecordType, uuid: UUID, context: ModelContext) throws {
        switch type {
        case .household: break // A share removal is handled as an account/zone event.
        case .member: try delete(HouseholdMember.self, uuid, context)
        case .mealType: try delete(MealType.self, uuid, context)
        case .dish: try delete(Dish.self, uuid, context)
        case .dishImage: try delete(DishImage.self, uuid, context)
        case .ingredient: try delete(Ingredient.self, uuid, context)
        case .ingredientAlias: try delete(IngredientAlias.self, uuid, context)
        case .packageSize: try delete(IngredientPackageSize.self, uuid, context)
        case .ingredientMatchRule: try delete(IngredientMatchRule.self, uuid, context)
        case .dishIngredient: try delete(DishIngredient.self, uuid, context)
        case .planEntry: try delete(MealPlanEntry.self, uuid, context)
        case .routine: try delete(MealRoutine.self, uuid, context)
        case .cookedLog: try delete(CookedLog.self, uuid, context)
        case .cookedLogImage:
            if let log = try find(CookedLog.self, uuid, context) { log.photoData = nil }
        case .shoppingItem: try delete(ShoppingListItem.self, uuid, context)
        case .weekTemplate: try delete(WeekTemplate.self, uuid, context)
        case .weekTemplateEntry: try delete(WeekTemplateEntry.self, uuid, context)
        case .recipeFeed: try delete(RecipeFeed.self, uuid, context)
        case .recipeFeedItem: try delete(RecipeFeedItem.self, uuid, context)
        case .recipeBookmark: try delete(RecipeBookmark.self, uuid, context)
        case .deletionMarker: break
        }
    }

    private static func delete<T: HouseholdSyncModel>(_ type: T.Type, _ uuid: UUID, _ context: ModelContext) throws {
        if let model = try find(type, uuid, context) {
            context.delete(model)
            if batchLookup?.context === context { batchLookup?.remove(type, uuid: uuid) }
        }
    }

    private static func find<T: HouseholdSyncModel>(_ type: T.Type, _ uuid: UUID, _ context: ModelContext) throws -> T? {
        if let batchLookup, batchLookup.context === context { return try batchLookup.find(type, uuid: uuid) }
        return try fetch(type, uuid: uuid, in: context)
    }

    private static func findOptional<T: HouseholdSyncModel>(_ type: T.Type, _ uuid: UUID?, _ context: ModelContext) throws -> T? {
        guard let uuid else { return nil }
        return try find(type, uuid, context)
    }

    private static func fetch<T: HouseholdSyncModel>(_ type: T.Type, uuid: UUID, in context: ModelContext) throws -> T? {
        // Keep every predicate statically typed: SwiftData cannot safely lower a
        // protocol requirement key path from HouseholdSyncModel in this path.
        func first<Model: HouseholdSyncModel>(
            _ model: Model.Type,
            predicate: Predicate<Model>
        ) throws -> T? {
            var descriptor = FetchDescriptor<Model>(predicate: predicate)
            descriptor.fetchLimit = 1
            do {
                return try context.fetch(descriptor).first as? T
            } catch {
                HouseholdRecordApplier.logLookupFailure(error, recordType: String(describing: model), stage: "targetedUUIDFetch")
                throw HouseholdLookupError.fetchFailed(
                    recordType: String(describing: model), stage: "targetedUUIDFetch", underlying: error
                )
            }
        }
        switch type {
        case is Household.Type:
            return try first(Household.self, predicate: #Predicate<Household> { $0.uuid == uuid })
        case is HouseholdMember.Type:
            return try first(HouseholdMember.self, predicate: #Predicate<HouseholdMember> { $0.uuid == uuid })
        case is MealType.Type:
            return try first(MealType.self, predicate: #Predicate<MealType> { $0.uuid == uuid })
        case is Dish.Type:
            return try first(Dish.self, predicate: #Predicate<Dish> { $0.uuid == uuid })
        case is DishImage.Type:
            return try first(DishImage.self, predicate: #Predicate<DishImage> { $0.uuid == uuid })
        case is Ingredient.Type:
            return try first(Ingredient.self, predicate: #Predicate<Ingredient> { $0.uuid == uuid })
        case is IngredientAlias.Type:
            return try first(IngredientAlias.self, predicate: #Predicate<IngredientAlias> { $0.uuid == uuid })
        case is IngredientPackageSize.Type:
            return try first(IngredientPackageSize.self, predicate: #Predicate<IngredientPackageSize> { $0.uuid == uuid })
        case is IngredientMatchRule.Type:
            return try first(IngredientMatchRule.self, predicate: #Predicate<IngredientMatchRule> { $0.uuid == uuid })
        case is DishIngredient.Type:
            return try first(DishIngredient.self, predicate: #Predicate<DishIngredient> { $0.uuid == uuid })
        case is MealPlanEntry.Type:
            return try first(MealPlanEntry.self, predicate: #Predicate<MealPlanEntry> { $0.uuid == uuid })
        case is MealRoutine.Type:
            return try first(MealRoutine.self, predicate: #Predicate<MealRoutine> { $0.uuid == uuid })
        case is CookedLog.Type:
            return try first(CookedLog.self, predicate: #Predicate<CookedLog> { $0.uuid == uuid })
        case is ShoppingListItem.Type:
            return try first(ShoppingListItem.self, predicate: #Predicate<ShoppingListItem> { $0.uuid == uuid })
        case is WeekTemplate.Type:
            return try first(WeekTemplate.self, predicate: #Predicate<WeekTemplate> { $0.uuid == uuid })
        case is WeekTemplateEntry.Type:
            return try first(WeekTemplateEntry.self, predicate: #Predicate<WeekTemplateEntry> { $0.uuid == uuid })
        case is RecipeFeed.Type:
            return try first(RecipeFeed.self, predicate: #Predicate<RecipeFeed> { $0.uuid == uuid })
        case is RecipeFeedItem.Type:
            return try first(RecipeFeedItem.self, predicate: #Predicate<RecipeFeedItem> { $0.uuid == uuid })
        case is RecipeBookmark.Type:
            return try first(RecipeBookmark.self, predicate: #Predicate<RecipeBookmark> { $0.uuid == uuid })
        default:
            throw HouseholdLookupError.fetchFailed(
                recordType: String(describing: type), stage: "unsupportedModel", underlying: HouseholdLookupUnsupportedModel()
            )
        }
    }

    private static func touch<T: HouseholdSyncModel>(_ type: T.Type, _ uuid: UUID, _ date: Date, _ context: ModelContext) throws {
        try find(type, uuid, context)?.modifiedAt = date
    }

    private struct HouseholdLookupUnsupportedModel: LocalizedError {
        var errorDescription: String? { "No concrete UUID fetch descriptor is registered for this synchronized model." }
    }

    private static func logLookupFailure(_ error: Error, recordType: String, stage: String) {
        let failure = error as NSError
        SharedStore.logger.error(
            "SwiftData household lookup failed (recordType=\(recordType, privacy: .public), stage=\(stage, privacy: .public), domain=\(failure.domain, privacy: .public), code=\(failure.code, privacy: .public))."
        )
    }

    private static func insert<T: HouseholdSyncModel>(_ model: T, _ uuid: UUID, _ context: ModelContext) -> T {
        model.uuid = uuid
        context.insert(model)
        if batchLookup?.context === context { batchLookup?.insert(model) }
        return model
    }

    private static func apply(_ value: MealPlanBackup.PortableDish, to dish: Dish) {
        dish.name = value.name
        dish.recipeText = value.recipeText
        dish.sourceURLString = value.sourceURLString
        dish.deepLinkURLString = value.deepLinkURLString
        dish.importedSourceApp = value.importedSourceApp
        dish.importedSourceID = value.importedSourceID
        dish.variantGroupID = value.variantGroupID
        dish.variantGroupName = value.variantGroupName
        dish.isFavorite = value.isFavorite
        dish.rating = value.rating
        dish.collectionNames = value.collectionNames
        dish.tagNames = value.tagNames
        dish.servings = value.servings
        dish.prepTimeMinutes = value.prepTimeMinutes
        dish.cookTimeMinutes = value.cookTimeMinutes
        dish.mealTypeTagsRaw = value.mealTypeTagsRaw
        dish.dietaryTagsRaw = value.dietaryTagsRaw
        DishLabelConsolidation.apply(to: dish)
        dish.seasonRaw = value.seasonRaw
        dish.createdByName = value.createdByName
        dish.dateCreated = value.dateCreated
        dish.lastUsedDate = value.lastUsedDate
        dish.usageCount = value.usageCount
        dish.needsReview = value.needsReview
        dish.glyphRaw = value.glyphRaw
        dish.glyphIsAuto = value.glyphIsAuto
        dish.statedEnergyKcalPerServing = value.statedEnergyKcalPerServing
        dish.statedProteinGramsPerServing = value.statedProteinGramsPerServing
        dish.statedCarbGramsPerServing = value.statedCarbGramsPerServing
        dish.statedFatGramsPerServing = value.statedFatGramsPerServing
        dish.recipeLanguageCode = value.recipeLanguageCode
        dish.translationLanguageCode = value.translationLanguageCode
        dish.translatedName = value.translatedName
        dish.translatedRecipeText = value.translatedRecipeText
    }
}
