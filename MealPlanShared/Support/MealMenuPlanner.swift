import Foundation
import SwiftData

/// Domain operations for reusable menus. All mutations are local SwiftData
/// writes, so menus remain useful offline and are picked up by the existing
/// household sync on its next opportunity.
@MainActor
enum MealMenuPlanner {
    struct Preview: Equatable, Sendable {
        var targetDate: Date
        var targetMealKey: String?
        var itemsToAdd: Int
        var duplicateItems: Int
        var itemsToReplace: Int
        var missingDishNames: [String]

        var isEmpty: Bool { itemsToAdd == 0 && itemsToReplace == 0 }
    }

    struct ApplicationResult {
        var insertedEntryIDs: [UUID]
        var replacedEntries: [MealMenuEntryUndoSnapshot]
        var skippedDuplicateCount: Int
        var missingDishNames: [String]

        var changedCount: Int { insertedEntryIDs.count + replacedEntries.count }
    }

    @discardableResult
    static func makeFromPlannedDate(
        _ date: Date,
        name: String,
        household: Household?,
        createdBy: String,
        context: ModelContext
    ) throws -> MealMenu? {
        guard HouseholdMutationAuthorization.canMutate(household: household) else { return nil }
        let day = date.startOfDay
        let householdID = household?.uuid
        let planned = try context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date == day && $0.household?.uuid == householdID && $0.skipped == false },
            sortBy: [SortDescriptor(\MealPlanEntry.mealSlotRaw), SortDescriptor(\MealPlanEntry.sortIndex)]
        ))
        let dishes = planned.compactMap { entry -> (Dish, String, Int?)? in
            guard let dish = entry.dish else { return nil }
            return (dish, entry.mealKey, entry.servingsOverride)
        }
        guard !dishes.isEmpty else { return nil }
        let menu = MealMenu(name: name)
        menu.createdByName = createdBy
        menu.household = household
        context.insert(menu)
        for (index, (dish, key, servings)) in dishes.enumerated() {
            let entry = MealMenuEntry(dish: dish, mealKey: key, servingsOverride: servings, sortIndex: index)
            entry.menu = menu
            context.insert(entry)
        }
        try context.save()
        return menu
    }

    static func preview(
        _ menu: MealMenu,
        on date: Date,
        mealKey: String?,
        replaceExisting: Bool,
        household: Household?,
        context: ModelContext
    ) -> Preview {
        let targetDate = date.startOfDay
        let items = menu.sortedEntries
        let existing = entries(on: targetDate, household: household, context: context)
        let missing = items.filter { $0.dish == nil }.map { $0.dishName }
        let destinations = items.compactMap { item -> (UUID, String)? in
            guard let dish = item.dish else { return nil }
            return (dish.uuid, item.mealKey ?? mealKey ?? MealType.extraKey)
        }

        var duplicates = 0
        var replacements = 0
        var additions = 0
        for (dishID, destination) in destinations {
            let matches = existing.filter { $0.mealKey == destination && $0.dish?.uuid == dishID && !$0.skipped }
            if matches.isEmpty {
                additions += 1
            } else {
                duplicates += 1
            }
        }
        if replaceExisting {
            let destinationKeys = Set(destinations.map(\.1))
            replacements = existing.filter { destinationKeys.contains($0.mealKey) && !$0.skipped }.count
            additions = destinations.count
            duplicates = 0
        }
        return Preview(
            targetDate: targetDate,
            targetMealKey: mealKey,
            itemsToAdd: additions,
            duplicateItems: duplicates,
            itemsToReplace: replacements,
            missingDishNames: missing
        )
    }

    static func apply(
        _ menu: MealMenu,
        on date: Date,
        mealKey: String?,
        replaceExisting: Bool,
        household: Household?,
        memberName: String,
        context: ModelContext
    ) throws -> ApplicationResult {
        guard HouseholdMutationAuthorization.canMutate(household: household ?? menu.household) else {
            return ApplicationResult(insertedEntryIDs: [], replacedEntries: [], skippedDuplicateCount: 0, missingDishNames: [])
        }

        let targetDate = date.startOfDay
        let items = menu.sortedEntries
        let existing = entries(on: targetDate, household: household, context: context)
        let destinations = items.compactMap { item -> (MealMenuEntry, Dish, String)? in
            guard let dish = item.dish else { return nil }
            return (item, dish, item.mealKey ?? mealKey ?? MealType.extraKey)
        }
        let destinationKeys = Set(destinations.map(\.2))
        var replacedSnapshots: [MealMenuEntryUndoSnapshot] = []
        if replaceExisting {
            for entry in existing where destinationKeys.contains(entry.mealKey) && !entry.skipped {
                replacedSnapshots.append(MealMenuEntryUndoSnapshot(entry))
                context.delete(entry)
            }
        }

        var insertedIDs: [UUID] = []
        var duplicateCount = 0
        for (item, dish, destination) in destinations {
            if !replaceExisting,
               existing.contains(where: { $0.mealKey == destination && $0.dish?.uuid == dish.uuid && !$0.skipped }) {
                duplicateCount += 1
                continue
            }
            let entry = MealPlanEntry(date: targetDate, mealKey: destination, dish: dish)
            entry.household = household ?? menu.household
            entry.servingsOverride = item.servingsOverride
            entry.plannedByName = memberName
            entry.sortIndex = nextSortIndex(for: targetDate, mealKey: destination, household: household ?? menu.household, context: context)
            context.insert(entry)
            insertedIDs.append(entry.uuid)
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        SharedStore.reloadWidgets()
        return ApplicationResult(
            insertedEntryIDs: insertedIDs,
            replacedEntries: replacedSnapshots,
            skippedDuplicateCount: duplicateCount,
            missingDishNames: items.filter { $0.dish == nil }.map { $0.dishName }
        )
    }

    static func undo(_ result: ApplicationResult, in context: ModelContext) throws {
        let entries = try context.fetch(FetchDescriptor<MealPlanEntry>())
        for id in result.insertedEntryIDs {
            if let entry = entries.first(where: { $0.uuid == id }) { context.delete(entry) }
        }
        for snapshot in result.replacedEntries {
            try snapshot.restore(in: context)
        }
        try context.save()
        SharedStore.reloadWidgets()
    }

    private static func entries(on date: Date, household: Household?, context: ModelContext) -> [MealPlanEntry] {
        let day = date.startOfDay
        let householdID = household?.uuid
        return (try? context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date == day && $0.household?.uuid == householdID },
            sortBy: [SortDescriptor(\MealPlanEntry.sortIndex)]
        ))) ?? []
    }

    private static func nextSortIndex(for date: Date, mealKey: String, household: Household?, context: ModelContext) -> Int {
        let householdID = household?.uuid
        let existing = (try? context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date == date && $0.mealSlotRaw == mealKey && $0.household?.uuid == householdID }
        ))) ?? []
        return (existing.map(\.sortIndex).max() ?? -1) + 1
    }
}

private extension MealMenuEntry {
    var dishName: String { dish?.name ?? String(localized: "Missing dish") }
}

/// Shared, value-only undo data for menu application. This intentionally
/// mirrors the calendar's undo information without depending on an
/// app-target type, because menu application is also compiled into the
/// shared/watch extensions.
struct MealMenuEntryUndoSnapshot {
    struct CookedLogSnapshot {
        let uuid: UUID
        let modifiedAt: Date
        let date: Date
        let dishName: String?
        let servings: Int?
        let photoData: Data?
    }

    let uuid: UUID
    let modifiedAt: Date
    let placementModifiedAt: Date
    let contentModifiedAt: Date
    let date: Date
    let mealSlotRaw: String
    let servingsOverride: Int?
    let note: String?
    let sortIndex: Int
    let reactionRaw: String?
    let skipped: Bool
    let prepReminder: Bool
    let plannedByName: String?
    let lastEditedByName: String?
    let lastEditedDate: Date?
    let participatingMemberUUIDs: [String]
    let isEatingOut: Bool
    let placeName: String?
    let placeAddress: String?
    let placeLatitude: Double?
    let placeLongitude: Double?
    let routineUUID: UUID?
    let extraItemsText: String?
    let dishUUID: UUID?
    let householdUUID: UUID?
    let cookedLog: CookedLogSnapshot?

    init(_ entry: MealPlanEntry) {
        uuid = entry.uuid
        modifiedAt = entry.modifiedAt
        placementModifiedAt = entry.placementModifiedAt
        contentModifiedAt = entry.contentModifiedAt
        date = entry.date
        mealSlotRaw = entry.mealSlotRaw
        servingsOverride = entry.servingsOverride
        note = entry.note
        sortIndex = entry.sortIndex
        reactionRaw = entry.reactionRaw
        skipped = entry.skipped
        prepReminder = entry.prepReminder
        plannedByName = entry.plannedByName
        lastEditedByName = entry.lastEditedByName
        lastEditedDate = entry.lastEditedDate
        participatingMemberUUIDs = entry.participatingMemberUUIDs
        isEatingOut = entry.isEatingOut
        placeName = entry.placeName
        placeAddress = entry.placeAddress
        placeLatitude = entry.placeLatitude
        placeLongitude = entry.placeLongitude
        routineUUID = entry.routineUUID
        extraItemsText = entry.extraItemsText
        dishUUID = entry.dish?.uuid
        householdUUID = entry.household?.uuid
        cookedLog = entry.cookedLog.map {
            CookedLogSnapshot(
                uuid: $0.uuid,
                modifiedAt: $0.modifiedAt,
                date: $0.date,
                dishName: $0.dishName,
                servings: $0.servings,
                photoData: $0.photoData
            )
        }
    }

    @MainActor
    func restore(in context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<MealPlanEntry>())
        guard !existing.contains(where: { $0.uuid == uuid }) else { return }
        let households = try context.fetch(FetchDescriptor<Household>())
        let household = households.first { $0.uuid == householdUUID }
        let dishes = try context.fetch(FetchDescriptor<Dish>())
        let dish = dishes.first { $0.uuid == dishUUID }

        let entry = MealPlanEntry(date: date, mealKey: mealSlotRaw, dish: dish)
        entry.uuid = uuid
        entry.modifiedAt = modifiedAt
        entry.placementModifiedAt = placementModifiedAt
        entry.contentModifiedAt = contentModifiedAt
        entry.servingsOverride = servingsOverride
        entry.note = note
        entry.sortIndex = sortIndex
        entry.reactionRaw = reactionRaw
        entry.skipped = skipped
        entry.prepReminder = prepReminder
        entry.plannedByName = plannedByName
        entry.lastEditedByName = lastEditedByName
        entry.lastEditedDate = lastEditedDate
        entry.participatingMemberUUIDs = participatingMemberUUIDs
        entry.isEatingOut = isEatingOut
        entry.placeName = placeName
        entry.placeAddress = placeAddress
        entry.placeLatitude = placeLatitude
        entry.placeLongitude = placeLongitude
        entry.routineUUID = routineUUID
        entry.extraItemsText = extraItemsText
        entry.household = household
        context.insert(entry)

        if let cookedLog {
            let log = CookedLog(date: cookedLog.date, dish: dish, servings: cookedLog.servings)
            log.uuid = cookedLog.uuid
            log.modifiedAt = cookedLog.modifiedAt
            log.dishName = cookedLog.dishName
            log.photoData = cookedLog.photoData
            log.entry = entry
            log.household = household
            context.insert(log)
        }
    }
}
