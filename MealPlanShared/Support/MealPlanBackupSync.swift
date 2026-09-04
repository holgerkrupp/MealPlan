import Foundation
import SwiftData

/// Applies a `MealPlanBackup` onto an existing store as an upsert: rows are
/// matched by their stable `uuid` (or, for `Ingredient`, by `normalizedName`)
/// and updated in place rather than deleted and recreated, so SwiftData
/// object identities that views already hold survive a sync.
///
/// This exists for `HouseholdCloudSharingService`, which needs to pull a
/// shared household's data into a store that may already hold local changes —
/// unlike `MealPlanBackupRestore`, which deliberately wipes the store for a
/// one-shot environment migration.
enum MealPlanBackupSync {

    /// Applies `backup` as authoritative: every row it doesn't mention is
    /// deleted locally. Use this for a plain pull (nothing changed locally
    /// since the last sync) or after `merging(_:)` has already combined both
    /// sides, so the merged result is what "authoritative" means here.
    @MainActor
    @discardableResult
    static func apply(
        _ backup: MealPlanBackup,
        to existingHousehold: Household?,
        context: ModelContext,
        shareIdentifier: String
    ) throws -> Household {
        let household = existingHousehold ?? Household(name: backup.household.name)
        if existingHousehold == nil {
            household.uuid = backup.household.uuid
            context.insert(household)
        }
        household.name = backup.household.name
        household.unitSystemRaw = backup.household.unitSystemRaw
        household.roundsDisplayedAmounts = backup.household.roundsDisplayedAmounts
        household.calendarStyleRaw = backup.household.calendarStyleRaw
        household.localeIdentifier = backup.household.localeIdentifier
        household.dateCreated = backup.household.dateCreated
        household.didSeedPantryStaples = backup.household.didSeedPantryStaples ?? household.didSeedPantryStaples
        household.cloudKitShareIdentifier = shareIdentifier

        // MARK: Meal types

        var mealTypes = partition(household.mealTypes ?? [], by: \.uuid)
        for stored in backup.mealTypes {
            let model = mealTypes.map[stored.uuid] ?? insert(
                MealType(key: stored.key, name: stored.name, symbolName: stored.symbolName, sortOrder: stored.sortOrder),
                uuid: stored.uuid, into: context, map: &mealTypes.map
            )
            model.key = stored.key
            model.name = stored.name
            model.symbolName = stored.symbolName
            model.sortOrder = stored.sortOrder
            model.household = household
        }
        deleteMissing(mealTypes, keeping: backup.mealTypes.map(\.uuid), context: context)

        // MARK: Ingredients (keyed by normalized name — there is no per-line uuid)

        var ingredients = Dictionary(uniqueKeysWithValues: (household.ingredients ?? []).map { ($0.normalizedName, $0) })
        for stored in backup.ingredients {
            let model = ingredients[stored.normalizedName] ?? {
                let m = Ingredient(name: stored.name, category: IngredientCategory(rawValue: stored.categoryRaw) ?? .other)
                context.insert(m)
                ingredients[stored.normalizedName] = m
                return m
            }()
            model.name = stored.name
            model.normalizedName = stored.normalizedName
            model.categoryRaw = stored.categoryRaw
            model.customAisleName = stored.customAisleName
            model.isPantryStaple = model.isPantryStaple || stored.isPantryStaple
            model.household = household
        }
        for (key, model) in ingredients where !backup.ingredients.contains(where: { $0.normalizedName == key }) {
            // Only drop an ingredient the shared side no longer references and
            // that has nothing local hanging off it — a line still in use
            // locally must not vanish out from under it.
            if (model.dishIngredients ?? []).isEmpty && (model.shoppingItems ?? []).isEmpty {
                context.delete(model)
            }
        }

        // MARK: Dishes (with their images and ingredient lines replaced wholesale)

        var dishes = partition(household.dishes ?? [], by: \.uuid)
        for stored in backup.dishes {
            let model = dishes.map[stored.uuid] ?? insert(Dish(name: stored.name), uuid: stored.uuid, into: context, map: &dishes.map)
            apply(stored, to: model, household: household, ingredients: ingredients, context: context)
        }
        deleteMissing(dishes, keeping: backup.dishes.map(\.uuid), context: context)

        // MARK: Plan entries

        var entries = partition(household.entries ?? [], by: \.uuid)
        for stored in backup.entries {
            let model = entries.map[stored.uuid] ?? insert(
                MealPlanEntry(date: stored.date, mealKey: stored.mealKey),
                uuid: stored.uuid, into: context, map: &entries.map
            )
            model.date = stored.date
            model.mealSlotRaw = stored.mealKey
            model.dish = stored.dishUUID.flatMap { dishes.map[$0] }
            model.servingsOverride = stored.servingsOverride
            model.note = stored.note
            model.sortIndex = stored.sortIndex
            model.reactionRaw = stored.reactionRaw
            model.skipped = stored.skipped
            model.prepReminder = stored.prepReminder
            model.plannedByName = stored.plannedByName
            model.lastEditedByName = stored.lastEditedByName
            model.lastEditedDate = stored.lastEditedDate
            model.isEatingOut = stored.isEatingOut
            model.placeName = stored.placeName
            model.placeAddress = stored.placeAddress
            model.placeLatitude = stored.placeLatitude
            model.placeLongitude = stored.placeLongitude
            model.routineUUID = stored.routineUUID
            model.household = household
        }
        deleteMissing(entries, keeping: backup.entries.map(\.uuid), context: context)

        // MARK: Routines

        var routines = partition(household.mealRoutines ?? [], by: \.uuid)
        for stored in backup.routines {
            let model = routines.map[stored.uuid] ?? insert(
                MealRoutine(mealKey: stored.mealKey, weekday: stored.weekday, intervalWeeks: stored.intervalWeeks, startDate: stored.startDate),
                uuid: stored.uuid, into: context, map: &routines.map
            )
            model.dish = stored.dishUUID.flatMap { dishes.map[$0] }
            model.mealKey = stored.mealKey
            model.weekday = stored.weekday
            model.intervalWeeks = stored.intervalWeeks
            model.startDate = stored.startDate
            model.isActive = stored.isActive
            model.plannedThrough = stored.plannedThrough
            model.dateCreated = stored.dateCreated
            model.household = household
        }
        deleteMissing(routines, keeping: backup.routines.map(\.uuid), context: context)

        // MARK: Cooked logs

        var cookedLogs = partition(household.cookedLogs ?? [], by: \.uuid)
        for stored in backup.cookedLogs {
            let uuid = stored.uuid ?? UUID()
            let model = cookedLogs.map[uuid] ?? insert(CookedLog(date: stored.date), uuid: uuid, into: context, map: &cookedLogs.map)
            model.date = stored.date
            model.dishName = stored.dishName
            model.servings = stored.servings
            model.photoData = stored.photoData
            model.dish = stored.dishUUID.flatMap { dishes.map[$0] }
            model.entry = stored.entryUUID.flatMap { entries.map[$0] }
            model.household = household
        }
        deleteMissing(cookedLogs, keeping: backup.cookedLogs.compactMap(\.uuid), context: context)

        // MARK: Shopping list

        var shoppingItems = partition(household.shoppingItems ?? [], by: \.uuid)
        for stored in backup.shoppingItems {
            let uuid = stored.uuid ?? UUID()
            let model = shoppingItems.map[uuid] ?? insert(
                ShoppingListItem(name: stored.name, category: IngredientCategory(rawValue: stored.categoryRaw) ?? .other, isManual: stored.isManual),
                uuid: uuid, into: context, map: &shoppingItems.map
            )
            model.name = stored.name
            model.normalizedName = stored.normalizedName
            model.categoryRaw = stored.categoryRaw
            model.customAisleName = stored.customAisleName
            model.canonicalValue = stored.canonicalValue
            model.canonicalDimensionRaw = stored.canonicalDimensionRaw
            model.displayText = stored.displayText
            model.displayUnit = stored.displayUnit
            model.isChecked = stored.isChecked
            model.isManual = stored.isManual
            model.isApproximate = stored.isApproximate
            model.sortIndex = stored.sortIndex
            model.rangeStart = stored.rangeStart
            model.rangeEnd = stored.rangeEnd
            model.sourceDishNames = stored.sourceDishNames
            model.dateCreated = stored.dateCreated
            model.ingredient = stored.ingredientKey.flatMap { ingredients[$0] }
            model.household = household
        }
        deleteMissing(shoppingItems, keeping: backup.shoppingItems.compactMap(\.uuid), context: context)

        // MARK: Week templates

        var templates = partition(household.weekTemplates ?? [], by: \.uuid)
        for stored in backup.weekTemplates {
            let model = templates.map[stored.uuid] ?? insert(WeekTemplate(name: stored.name), uuid: stored.uuid, into: context, map: &templates.map)
            model.name = stored.name
            model.createdByName = stored.createdByName
            model.dateCreated = stored.dateCreated
            model.household = household
            // Entries carry no independent identity — replace the whole set,
            // but only when it actually changed (see the dish ingredients
            // comment above for why that guard matters).
            let currentEntries = model.sortedEntries.map {
                MealPlanBackup.PortableWeekTemplateEntry(weekday: $0.weekday, mealKey: $0.mealSlotRaw, dishUUID: $0.dish?.uuid, servingsOverride: $0.servingsOverride, sortIndex: $0.sortIndex)
            }
            if currentEntries != stored.entries {
                for existingEntry in model.entries ?? [] { context.delete(existingEntry) }
                for storedEntry in stored.entries {
                    let entry = WeekTemplateEntry(weekday: storedEntry.weekday, mealKey: storedEntry.mealKey, dish: storedEntry.dishUUID.flatMap { dishes.map[$0] })
                    entry.servingsOverride = storedEntry.servingsOverride
                    entry.sortIndex = storedEntry.sortIndex
                    entry.template = model
                    context.insert(entry)
                }
            }
        }
        deleteMissing(templates, keeping: backup.weekTemplates.map(\.uuid), context: context)

        try context.save()
        return household
    }

    @MainActor
    private static func apply(
        _ stored: MealPlanBackup.PortableDish,
        to dish: Dish,
        household: Household,
        ingredients: [String: Ingredient],
        context: ModelContext
    ) {
        dish.name = stored.name
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

        // Images and ingredient lines carry no independent identity of their
        // own (a dish's ingredient list is edited as a whole in the UI), so
        // an actual change replaces both sets wholesale. Skipping the replace
        // when nothing changed matters: `apply` runs on every sync, for every
        // dish in the household, and rebuilding untouched children each time
        // would needlessly re-upload them through SwiftData's own private
        // CloudKit mirror.
        let currentImages = (dish.sortedImages).map { MealPlanBackup.PortableImage(data: $0.data, sortIndex: $0.sortIndex, isPrimary: $0.isPrimary, dateAdded: $0.dateAdded) }
        if currentImages != stored.images {
            for existingImage in dish.images ?? [] { context.delete(existingImage) }
            for storedImage in stored.images {
                let image = DishImage(data: storedImage.data, sortIndex: storedImage.sortIndex, isPrimary: storedImage.isPrimary)
                image.dateAdded = storedImage.dateAdded
                image.dish = dish
                context.insert(image)
            }
        }

        let currentLines = dish.sortedIngredients.map { line in
            MealPlanBackup.PortableDishIngredient(
                ingredientKey: line.ingredient?.normalizedName,
                canonicalValue: line.canonicalValue,
                canonicalDimensionRaw: line.canonicalDimensionRaw,
                displayUnit: line.displayUnit,
                isApproximate: line.isApproximate,
                note: line.note,
                rawText: line.rawText,
                sortIndex: line.sortIndex
            )
        }
        if currentLines != stored.ingredients {
            for existingLine in dish.ingredients ?? [] { context.delete(existingLine) }
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
        }
    }

    // MARK: - Merging two independently-edited snapshots

    /// Combines two backups taken since the last successful sync, when both
    /// the local store and the shared copy changed. There is no per-row
    /// modification date on these models (unlike `SharedBudgetPlanSnapshot`
    /// in Family Budget), so the merge is: a row present on only one side is
    /// kept; a row present on both sides, edited differently, is resolved by
    /// taking whichever whole backup is newer. That makes a genuine two-way
    /// conflict on the very same row coarse (last-editor-wins for that row),
    /// but non-conflicting concurrent edits — the overwhelmingly common case
    /// of two people editing different dishes — merge cleanly.
    static func merging(_ base: MealPlanBackup, with other: MealPlanBackup, at mergeDate: Date = .now) -> MealPlanBackup {
        let baseIsNewer = base.exportedAt >= other.exportedAt
        var merged = baseIsNewer ? base : other
        merged.exportedAt = mergeDate
        merged.mealTypes = union(base.mealTypes, other.mealTypes, baseIsNewer: baseIsNewer, id: \.uuid)
        merged.ingredients = union(base.ingredients, other.ingredients, baseIsNewer: baseIsNewer, id: \.normalizedName)
        merged.dishes = union(base.dishes, other.dishes, baseIsNewer: baseIsNewer, id: \.uuid)
        merged.entries = union(base.entries, other.entries, baseIsNewer: baseIsNewer, id: \.uuid)
        merged.routines = union(base.routines, other.routines, baseIsNewer: baseIsNewer, id: \.uuid)
        merged.cookedLogs = union(base.cookedLogs, other.cookedLogs, baseIsNewer: baseIsNewer, id: { $0.uuid?.uuidString ?? "\($0.date.timeIntervalSince1970)-\($0.dishUUID?.uuidString ?? "")" })
        merged.shoppingItems = union(base.shoppingItems, other.shoppingItems, baseIsNewer: baseIsNewer, id: { $0.uuid?.uuidString ?? $0.normalizedName })
        merged.weekTemplates = union(base.weekTemplates, other.weekTemplates, baseIsNewer: baseIsNewer, id: \.uuid)
        return merged
    }

    /// Unions two arrays by `id`. A row present on only one side is kept as-is;
    /// a row present on both sides takes whichever side's `exportedAt` is
    /// newer, so the same-row-edited-on-both-sides case is last-editor-wins
    /// while everything else merges without loss.
    private static func union<Value, ID: Hashable>(
        _ base: [Value],
        _ other: [Value],
        baseIsNewer: Bool,
        id: (Value) -> ID
    ) -> [Value] {
        var byID: [ID: Value] = [:]
        for value in (baseIsNewer ? other : base) { byID[id(value)] = value }
        for value in (baseIsNewer ? base : other) { byID[id(value)] = value }
        return Array(byID.values)
    }

    // MARK: - Bookkeeping helpers

    private static func partition<Model: AnyObject>(_ models: [Model], by uuid: (Model) -> UUID) -> (map: [UUID: Model], duplicates: [Model]) {
        var map: [UUID: Model] = [:]
        var duplicates: [Model] = []
        for model in models {
            let key = uuid(model)
            if map[key] == nil { map[key] = model } else { duplicates.append(model) }
        }
        return (map, duplicates)
    }

    @MainActor
    private static func insert<Model: PersistentModel>(_ model: Model, uuid: UUID, into context: ModelContext, map: inout [UUID: Model]) -> Model {
        context.insert(model)
        setUUID(uuid, on: model)
        map[uuid] = model
        return model
    }

    @MainActor
    private static func setUUID<Model: PersistentModel>(_ uuid: UUID, on model: Model) {
        switch model {
        case let m as MealType: m.uuid = uuid
        case let m as Dish: m.uuid = uuid
        case let m as MealPlanEntry: m.uuid = uuid
        case let m as MealRoutine: m.uuid = uuid
        case let m as CookedLog: m.uuid = uuid
        case let m as ShoppingListItem: m.uuid = uuid
        case let m as WeekTemplate: m.uuid = uuid
        default: break
        }
    }

    @MainActor
    private static func deleteMissing<Model: PersistentModel>(_ partitioned: (map: [UUID: Model], duplicates: [Model]), keeping ids: [UUID], context: ModelContext) {
        let keep = Set(ids)
        for (uuid, model) in partitioned.map where !keep.contains(uuid) { context.delete(model) }
        for duplicate in partitioned.duplicates { context.delete(duplicate) }
    }
}
