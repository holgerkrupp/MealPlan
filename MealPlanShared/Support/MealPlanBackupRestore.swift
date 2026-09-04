import Foundation
import SwiftData

/// Puts a `MealPlanBackup` back into a store, replacing whatever is there.
///
/// Replace rather than merge is deliberate. The job this exists for is moving
/// a library into a build that talks to a different CloudKit environment, and
/// that target store holds at most an empty household seeded on first launch.
/// Merging would leave that seed's meal types and household settings fighting
/// the restored ones; replacing lands exactly what was exported.
///
/// Identifiers are preserved, so restoring the same file twice is idempotent
/// and recipe archives exported from the old build still de-duplicate against
/// the restored library.
enum MealPlanBackupRestore {

    /// Wipes every model in the store and re-creates the backup's household.
    /// The caller must re-run `AppState.bootstrap` afterwards: the previous
    /// `currentHousehold` is one of the objects this deletes.
    ///
    /// On a CloudKit-backed store this both deletes and re-uploads, so it
    /// propagates to every device signed into the same account *in the same
    /// environment*.
    @MainActor
    @discardableResult
    static func replaceEverything(
        with backup: MealPlanBackup,
        context: ModelContext
    ) throws -> MealPlanBackup.Contents {
        // A restore is thousands of deletes and inserts; registering all of it
        // for undo would blow past the main context's 20 levels and hold every
        // deleted object alive while it did.
        let undoManager = context.undoManager
        context.undoManager = nil
        defer { context.undoManager = undoManager }

        try deleteEverything(in: context)
        try context.save()
        insert(backup, into: context)
        try context.save()
        return backup.contents
    }

    /// Every model type, children before parents so a cascade never has to
    /// reach an object that is already gone.
    @MainActor
    static func deleteEverything(in context: ModelContext) throws {
        try deleteAll(WeekTemplateEntry.self, in: context)
        try deleteAll(WeekTemplate.self, in: context)
        try deleteAll(ShoppingListItem.self, in: context)
        try deleteAll(CookedLog.self, in: context)
        try deleteAll(MealRoutine.self, in: context)
        try deleteAll(MealPlanEntry.self, in: context)
        try deleteAll(DishIngredient.self, in: context)
        try deleteAll(DishImage.self, in: context)
        try deleteAll(Dish.self, in: context)
        try deleteAll(Ingredient.self, in: context)
        try deleteAll(MealType.self, in: context)
        try deleteAll(HouseholdMember.self, in: context)
        try deleteAll(Household.self, in: context)
    }

    @MainActor
    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        for object in try context.fetch(FetchDescriptor<T>()) {
            context.delete(object)
        }
    }

    // MARK: - Inserting

    @MainActor
    private static func insert(_ backup: MealPlanBackup, into context: ModelContext) {
        let household = Household(name: backup.household.name)
        household.uuid = backup.household.uuid
        household.unitSystemRaw = backup.household.unitSystemRaw
        household.roundsDisplayedAmounts = backup.household.roundsDisplayedAmounts
        household.calendarStyleRaw = backup.household.calendarStyleRaw
        household.localeIdentifier = backup.household.localeIdentifier
        household.dateCreated = backup.household.dateCreated
        // A restored library brings its own staples with it; an older file
        // that already has an ingredient catalogue counts as set up too, so the
        // defaults aren't seeded over the top of it.
        household.didSeedPantryStaples = backup.household.didSeedPantryStaples ?? !backup.ingredients.isEmpty
        context.insert(household)

        for stored in backup.mealTypes {
            let mealType = MealType(
                key: stored.key,
                name: stored.name,
                symbolName: stored.symbolName,
                sortOrder: stored.sortOrder
            )
            mealType.uuid = stored.uuid
            mealType.household = household
            context.insert(mealType)
        }

        for stored in backup.members {
            let member = HouseholdMember(
                name: stored.name,
                role: MemberRole(rawValue: stored.roleRaw) ?? .editor,
                isCurrentUser: stored.isCurrentUser
            )
            member.dateAdded = stored.dateAdded
            member.household = household
            context.insert(member)
        }

        var ingredients: [String: Ingredient] = [:]
        for stored in backup.ingredients {
            let ingredient = Ingredient(
                name: stored.name,
                category: IngredientCategory(rawValue: stored.categoryRaw) ?? .other
            )
            ingredient.normalizedName = stored.normalizedName
            ingredient.customAisleName = stored.customAisleName
            ingredient.isPantryStaple = stored.isPantryStaple
            ingredient.household = household
            context.insert(ingredient)
            ingredients[stored.normalizedName] = ingredient
        }

        var dishes: [UUID: Dish] = [:]
        for stored in backup.dishes {
            let dish = makeDish(stored, household: household, ingredients: ingredients, context: context)
            dishes[stored.uuid] = dish
        }

        var entries: [UUID: MealPlanEntry] = [:]
        for stored in backup.entries {
            let entry = MealPlanEntry(
                date: stored.date,
                mealKey: stored.mealKey,
                dish: stored.dishUUID.flatMap { dishes[$0] }
            )
            entry.uuid = stored.uuid
            // Restore the stored instant rather than the `init`'s start-of-day
            // normalization, which would shift a plan made in another zone.
            entry.date = stored.date
            entry.servingsOverride = stored.servingsOverride
            entry.note = stored.note
            entry.sortIndex = stored.sortIndex
            entry.reactionRaw = stored.reactionRaw
            entry.skipped = stored.skipped
            entry.prepReminder = stored.prepReminder
            entry.plannedByName = stored.plannedByName
            entry.lastEditedByName = stored.lastEditedByName
            entry.lastEditedDate = stored.lastEditedDate
            entry.isEatingOut = stored.isEatingOut
            entry.placeName = stored.placeName
            entry.placeAddress = stored.placeAddress
            entry.placeLatitude = stored.placeLatitude
            entry.placeLongitude = stored.placeLongitude
            entry.routineUUID = stored.routineUUID
            entry.household = household
            context.insert(entry)
            entries[stored.uuid] = entry
        }

        for stored in backup.routines {
            let routine = MealRoutine(
                dish: stored.dishUUID.flatMap { dishes[$0] },
                mealKey: stored.mealKey,
                weekday: stored.weekday,
                intervalWeeks: stored.intervalWeeks,
                startDate: stored.startDate
            )
            routine.uuid = stored.uuid
            routine.isActive = stored.isActive
            routine.plannedThrough = stored.plannedThrough
            routine.dateCreated = stored.dateCreated
            routine.household = household
            context.insert(routine)
        }

        for stored in backup.cookedLogs {
            let log = CookedLog(
                date: stored.date,
                dish: stored.dishUUID.flatMap { dishes[$0] },
                servings: stored.servings
            )
            log.uuid = stored.uuid ?? UUID()
            // `init` snapshots the dish's current name; the backup's own
            // snapshot is the one that survives a since-deleted dish.
            log.dishName = stored.dishName
            log.photoData = stored.photoData
            log.entry = stored.entryUUID.flatMap { entries[$0] }
            log.household = household
            context.insert(log)
        }

        for stored in backup.shoppingItems {
            let item = ShoppingListItem(
                name: stored.name,
                category: IngredientCategory(rawValue: stored.categoryRaw) ?? .other,
                isManual: stored.isManual
            )
            item.uuid = stored.uuid ?? UUID()
            item.normalizedName = stored.normalizedName
            item.customAisleName = stored.customAisleName
            item.canonicalValue = stored.canonicalValue
            item.canonicalDimensionRaw = stored.canonicalDimensionRaw
            item.additionalAmountsRaw = stored.additionalAmountsRaw ?? []
            item.unmeasuredCount = stored.unmeasuredCount ?? 0
            item.displayText = stored.displayText
            item.displayUnit = stored.displayUnit
            item.isChecked = stored.isChecked
            item.isApproximate = stored.isApproximate
            item.sortIndex = stored.sortIndex
            item.rangeStart = stored.rangeStart
            item.rangeEnd = stored.rangeEnd
            item.sourceDishNames = stored.sourceDishNames
            item.dateCreated = stored.dateCreated
            item.ingredient = stored.ingredientKey.flatMap { ingredients[$0] }
            item.household = household
            context.insert(item)
        }

        for stored in backup.weekTemplates {
            let template = WeekTemplate(name: stored.name)
            template.uuid = stored.uuid
            template.createdByName = stored.createdByName
            template.dateCreated = stored.dateCreated
            template.household = household
            context.insert(template)

            for storedEntry in stored.entries {
                let entry = WeekTemplateEntry(
                    weekday: storedEntry.weekday,
                    mealKey: storedEntry.mealKey,
                    dish: storedEntry.dishUUID.flatMap { dishes[$0] }
                )
                entry.servingsOverride = storedEntry.servingsOverride
                entry.sortIndex = storedEntry.sortIndex
                entry.template = template
                context.insert(entry)
            }
        }
    }

    @MainActor
    private static func makeDish(
        _ stored: MealPlanBackup.PortableDish,
        household: Household,
        ingredients: [String: Ingredient],
        context: ModelContext
    ) -> Dish {
        let dish = Dish(name: stored.name)
        dish.uuid = stored.uuid
        dish.recipeText = stored.recipeText
        dish.sourceURLString = stored.sourceURLString
        dish.deepLinkURLString = stored.deepLinkURLString
        dish.importedSourceApp = stored.importedSourceApp
        dish.importedSourceID = stored.importedSourceID
        dish.variantGroupID = stored.variantGroupID
        dish.variantGroupName = stored.variantGroupName
        dish.isFavorite = stored.isFavorite
        dish.rating = stored.rating
        dish.collectionNames = stored.collectionNames
        dish.tagNames = stored.tagNames
        dish.servings = stored.servings
        dish.prepTimeMinutes = stored.prepTimeMinutes
        dish.cookTimeMinutes = stored.cookTimeMinutes
        dish.mealTypeTagsRaw = stored.mealTypeTagsRaw
        dish.dietaryTagsRaw = stored.dietaryTagsRaw
        dish.seasonRaw = stored.seasonRaw
        dish.createdByName = stored.createdByName
        dish.dateCreated = stored.dateCreated
        dish.lastUsedDate = stored.lastUsedDate
        dish.usageCount = stored.usageCount
        dish.needsReview = stored.needsReview
        dish.glyphRaw = stored.glyphRaw
        dish.glyphIsAuto = stored.glyphIsAuto
        dish.household = household
        context.insert(dish)

        for storedImage in stored.images {
            let image = DishImage(
                data: storedImage.data,
                sortIndex: storedImage.sortIndex,
                isPrimary: storedImage.isPrimary
            )
            image.dateAdded = storedImage.dateAdded
            image.dish = dish
            context.insert(image)
        }

        for storedLine in stored.ingredients {
            let line = DishIngredient(
                canonicalValue: storedLine.canonicalValue,
                dimension: storedLine.canonicalDimensionRaw.flatMap(QuantityDimension.init(rawValue:)),
                displayUnit: storedLine.displayUnit,
                isApproximate: storedLine.isApproximate,
                note: storedLine.note,
                rawText: storedLine.rawText,
                sortIndex: storedLine.sortIndex
            )
            line.dish = dish
            line.ingredient = storedLine.ingredientKey.flatMap { ingredients[$0] }
            context.insert(line)
        }

        return dish
    }
}
