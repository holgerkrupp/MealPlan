import CloudKit
import Foundation
import SwiftData

@MainActor
enum HouseholdRecordApplier {
    static func touch(
        _ identity: HouseholdRecordIdentity,
        at date: Date,
        changedGroups: Set<String>,
        context: ModelContext
    ) {
        switch identity.type {
        case .household:
            if let model = find(Household.self, identity.uuid, context) { model.modifiedAt = date }
        case .member: touch(HouseholdMember.self, identity.uuid, date, context)
        case .mealType: touch(MealType.self, identity.uuid, date, context)
        case .dish: touch(Dish.self, identity.uuid, date, context)
        case .dishImage: touch(DishImage.self, identity.uuid, date, context)
        case .ingredient: touch(Ingredient.self, identity.uuid, date, context)
        case .dishIngredient: touch(DishIngredient.self, identity.uuid, date, context)
        case .planEntry:
            if let model = find(MealPlanEntry.self, identity.uuid, context) {
                if changedGroups.contains("placement") { model.placementModifiedAt = date }
                if changedGroups.contains("content") { model.contentModifiedAt = date }
                model.modifiedAt = date
            }
        case .routine: touch(MealRoutine.self, identity.uuid, date, context)
        case .cookedLog, .cookedLogImage: touch(CookedLog.self, identity.uuid, date, context)
        case .shoppingItem:
            if let model = find(ShoppingListItem.self, identity.uuid, context) {
                if changedGroups.contains("content") { model.contentModifiedAt = date }
                if changedGroups.contains("check") { model.checkStateModifiedAt = date }
                model.modifiedAt = date
            }
        case .weekTemplate: touch(WeekTemplate.self, identity.uuid, date, context)
        case .weekTemplateEntry: touch(WeekTemplateEntry.self, identity.uuid, date, context)
        case .recipeFeed: touch(RecipeFeed.self, identity.uuid, date, context)
        case .recipeFeedItem: touch(RecipeFeedItem.self, identity.uuid, date, context)
        case .recipeBookmark: touch(RecipeBookmark.self, identity.uuid, date, context)
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
            household.energyUnitRaw = value.energyUnitRaw
            household.localeIdentifier = value.localeIdentifier
            household.dateCreated = value.dateCreated
            household.didSeedPantryStaples = value.didSeedPantryStaples
            household.bringListUuid = value.bringListUuid
            household.bringListName = value.bringListName
            household.bringShadowKeys = value.bringShadowKeys
            household.bringAutoSync = value.bringAutoSync
            household.bringLastSyncedAt = value.bringLastSyncedAt
            household.modifiedAt = modifiedAt

        case .member(let value):
            let model = find(HouseholdMember.self, identity.uuid, context) ?? insert(HouseholdMember(), identity.uuid, context)
            model.name = value.name
            model.roleRaw = value.roleRaw
            model.dateAdded = value.dateAdded
            model.cloudKitParticipantID = value.cloudKitParticipantID
            model.isActive = value.isActive
            model.modifiedAt = modifiedAt
            model.household = household

        case .mealType(let value):
            let model = find(MealType.self, identity.uuid, context) ?? insert(MealType(), identity.uuid, context)
            model.key = value.key
            model.name = value.name
            model.symbolName = value.symbolName
            model.sortOrder = value.sortOrder
            model.modifiedAt = modifiedAt
            model.household = household

        case .ingredient(let value):
            let model = find(Ingredient.self, identity.uuid, context) ?? insert(Ingredient(), identity.uuid, context)
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
            model.modifiedAt = modifiedAt
            model.household = household

        case .dish(let value):
            let model = find(Dish.self, identity.uuid, context) ?? insert(Dish(), identity.uuid, context)
            apply(value, to: model)
            model.modifiedAt = modifiedAt
            model.household = household

        case .dishImage(let value):
            guard let dish = find(Dish.self, value.dishID, context) else { throw HouseholdRecordCodecError.missingRelationship }
            let model = find(DishImage.self, identity.uuid, context) ?? insert(DishImage(data: nil), identity.uuid, context)
            model.data = assetData
            model.sortIndex = value.sortIndex
            model.isPrimary = value.isPrimary
            model.dateAdded = value.dateAdded
            model.modifiedAt = modifiedAt
            model.dish = dish

        case .dishIngredient(let value):
            guard let dish = find(Dish.self, value.dishID, context) else { throw HouseholdRecordCodecError.missingRelationship }
            let model = find(DishIngredient.self, identity.uuid, context) ?? insert(DishIngredient(), identity.uuid, context)
            model.canonicalValue = value.canonicalValue
            model.canonicalDimensionRaw = value.canonicalDimensionRaw
            model.displayUnit = value.displayUnit
            model.isApproximate = value.isApproximate
            model.note = value.note
            model.rawText = value.rawText
            model.sortIndex = value.sortIndex
            model.modifiedAt = modifiedAt
            model.dish = dish
            model.ingredient = value.ingredientID.flatMap { find(Ingredient.self, $0, context) }

        case .planEntry(let wrapped):
            let value = wrapped.value
            let model = find(MealPlanEntry.self, identity.uuid, context) ?? insert(MealPlanEntry(), identity.uuid, context)
            model.date = value.date
            model.mealSlotRaw = value.mealKey
            model.dish = value.dishUUID.flatMap { find(Dish.self, $0, context) }
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
            let model = find(MealRoutine.self, identity.uuid, context) ?? insert(MealRoutine(), identity.uuid, context)
            model.dish = value.dishUUID.flatMap { find(Dish.self, $0, context) }
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
            let model = find(CookedLog.self, identity.uuid, context) ?? insert(CookedLog(), identity.uuid, context)
            model.date = value.date
            model.dishName = value.dishName
            model.servings = value.servings
            model.dish = value.dishUUID.flatMap { find(Dish.self, $0, context) }
            model.entry = value.entryUUID.flatMap { find(MealPlanEntry.self, $0, context) }
            model.modifiedAt = modifiedAt
            model.household = household

        case .cookedLogImage(let value):
            guard let log = find(CookedLog.self, value.cookedLogID, context) else { throw HouseholdRecordCodecError.missingRelationship }
            log.photoData = assetData
            log.modifiedAt = max(log.modifiedAt, modifiedAt)

        case .shoppingItem(let wrapped):
            let value = wrapped.value
            let model = find(ShoppingListItem.self, identity.uuid, context) ?? insert(ShoppingListItem(), identity.uuid, context)
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
            model.ingredient = wrapped.ingredientID.flatMap { find(Ingredient.self, $0, context) }
            model.contentModifiedAt = wrapped.contentModifiedAt
            model.checkStateModifiedAt = wrapped.checkStateModifiedAt
            model.modifiedAt = modifiedAt
            model.household = household

        case .weekTemplate(let value):
            let model = find(WeekTemplate.self, identity.uuid, context) ?? insert(WeekTemplate(), identity.uuid, context)
            model.name = value.name
            model.createdByName = value.createdByName
            model.dateCreated = value.dateCreated
            model.modifiedAt = modifiedAt
            model.household = household

        case .weekTemplateEntry(let value):
            guard let template = find(WeekTemplate.self, value.templateID, context) else { throw HouseholdRecordCodecError.missingRelationship }
            let model = find(WeekTemplateEntry.self, identity.uuid, context) ?? insert(WeekTemplateEntry(), identity.uuid, context)
            model.weekday = value.weekday
            model.mealSlotRaw = value.mealKey
            model.dish = value.dishID.flatMap { find(Dish.self, $0, context) }
            model.servingsOverride = value.servingsOverride
            model.sortIndex = value.sortIndex
            model.modifiedAt = modifiedAt
            model.template = template

        case .recipeFeed(let value):
            guard let site = URL(string: value.siteURLString), let url = URL(string: value.feedURLString) else { return }
            let model = find(RecipeFeed.self, identity.uuid, context) ?? insert(RecipeFeed(siteURL: site, feedURL: url), identity.uuid, context)
            model.title = value.title
            model.siteURLString = value.siteURLString
            model.feedURLString = value.feedURLString
            model.etag = value.etag
            model.lastModified = value.lastModified
            model.lastFetchedAt = value.lastFetchedAt
            model.firstFailureAt = value.firstFailureAt
            model.consecutiveFailures = value.consecutiveFailures
            model.nextRetryAt = value.nextRetryAt
            model.lastHTTPStatus = value.lastHTTPStatus
            model.lastErrorMessage = value.lastErrorMessage
            model.dateAdded = value.dateAdded
            model.modifiedAt = modifiedAt
            model.household = household

        case .recipeFeedItem(let wrapped):
            guard let feed = find(RecipeFeed.self, wrapped.feedID, context), let url = URL(string: wrapped.value.urlString) else {
                throw HouseholdRecordCodecError.missingRelationship
            }
            let value = wrapped.value
            let model = find(RecipeFeedItem.self, identity.uuid, context) ?? insert(RecipeFeedItem(stableID: value.stableID, title: value.title, url: url), identity.uuid, context)
            model.stableID = value.stableID
            model.title = value.title
            model.urlString = value.urlString
            model.author = value.author
            model.summary = value.summary
            model.publishedAt = value.publishedAt
            model.fetchedAt = value.fetchedAt
            model.modifiedAt = modifiedAt
            model.feed = feed

        case .recipeBookmark(let value):
            guard let url = URL(string: value.urlString) else { return }
            let model = find(RecipeBookmark.self, identity.uuid, context) ?? insert(RecipeBookmark(title: value.title, url: url), identity.uuid, context)
            model.title = value.title
            model.urlString = value.urlString
            model.dateAdded = value.dateAdded
            model.modifiedAt = modifiedAt
            model.household = household

        case .deletionMarker(let marker):
            delete(type: marker.deletedType, uuid: marker.deletedUUID, context: context)
        }
    }

    static func delete(type: HouseholdRecordType, uuid: UUID, context: ModelContext) {
        switch type {
        case .household: break // A share removal is handled as an account/zone event.
        case .member: delete(HouseholdMember.self, uuid, context)
        case .mealType: delete(MealType.self, uuid, context)
        case .dish: delete(Dish.self, uuid, context)
        case .dishImage: delete(DishImage.self, uuid, context)
        case .ingredient: delete(Ingredient.self, uuid, context)
        case .dishIngredient: delete(DishIngredient.self, uuid, context)
        case .planEntry: delete(MealPlanEntry.self, uuid, context)
        case .routine: delete(MealRoutine.self, uuid, context)
        case .cookedLog: delete(CookedLog.self, uuid, context)
        case .cookedLogImage:
            if let log = find(CookedLog.self, uuid, context) { log.photoData = nil }
        case .shoppingItem: delete(ShoppingListItem.self, uuid, context)
        case .weekTemplate: delete(WeekTemplate.self, uuid, context)
        case .weekTemplateEntry: delete(WeekTemplateEntry.self, uuid, context)
        case .recipeFeed: delete(RecipeFeed.self, uuid, context)
        case .recipeFeedItem: delete(RecipeFeedItem.self, uuid, context)
        case .recipeBookmark: delete(RecipeBookmark.self, uuid, context)
        case .deletionMarker: break
        }
    }

    private static func delete<T: HouseholdSyncModel>(_ type: T.Type, _ uuid: UUID, _ context: ModelContext) {
        if let model = find(type, uuid, context) { context.delete(model) }
    }

    private static func find<T: HouseholdSyncModel>(_ type: T.Type, _ uuid: UUID, _ context: ModelContext) -> T? {
        (try? context.fetch(FetchDescriptor<T>()))?.first { $0.uuid == uuid }
    }

    private static func touch<T: HouseholdSyncModel>(_ type: T.Type, _ uuid: UUID, _ date: Date, _ context: ModelContext) {
        find(type, uuid, context)?.modifiedAt = date
    }

    private static func insert<T: HouseholdSyncModel>(_ model: T, _ uuid: UUID, _ context: ModelContext) -> T {
        model.uuid = uuid
        context.insert(model)
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
    }
}
