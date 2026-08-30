import Foundation
import SwiftData

/// Shared helpers for creating and moving planned meals, so every entry gets
/// consistent attribution and ordering.
///
/// The core API works in terms of a `mealKey` string (see `MealType.key`);
/// the `MealSlot` overloads are kept for the widget, App Intents and the
/// Share Extension's fixed vocabulary.
enum MealPlanner {

    @MainActor
    @discardableResult
    static func plan(
        dish: Dish,
        on date: Date,
        mealKey: String,
        servings: Int? = nil,
        note: String? = nil,
        household: Household?,
        memberName: String,
        context: ModelContext
    ) -> MealPlanEntry {
        let entry = MealPlanEntry(date: date, mealKey: mealKey, dish: dish)
        entry.household = household
        entry.servingsOverride = (servings != nil && servings != dish.servings) ? servings : nil
        entry.note = note
        entry.plannedByName = memberName
        entry.sortIndex = nextSortIndex(for: date, mealKey: mealKey, context: context)
        context.insert(entry)
        try? context.save()
        SharedStore.reloadWidgets()
        return entry
    }

    @MainActor
    @discardableResult
    static func plan(
        dish: Dish,
        on date: Date,
        slot: MealSlot,
        servings: Int? = nil,
        note: String? = nil,
        household: Household?,
        memberName: String,
        context: ModelContext
    ) -> MealPlanEntry {
        plan(dish: dish, on: date, mealKey: slot.rawValue, servings: servings, note: note,
             household: household, memberName: memberName, context: context)
    }

    /// Plan a meal the family eats out. The place is optional: "we're eating
    /// out" is a valid plan on its own, and can get a restaurant later.
    @MainActor
    @discardableResult
    static func planEatingOut(
        on date: Date,
        mealKey: String,
        placeName: String? = nil,
        placeAddress: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        note: String? = nil,
        household: Household?,
        memberName: String,
        context: ModelContext
    ) -> MealPlanEntry {
        let entry = MealPlanEntry(date: date, mealKey: mealKey, dish: nil)
        entry.household = household
        entry.isEatingOut = true
        entry.placeName = placeName
        entry.placeAddress = placeAddress
        entry.placeLatitude = latitude
        entry.placeLongitude = longitude
        entry.note = note
        entry.plannedByName = memberName
        entry.sortIndex = nextSortIndex(for: date, mealKey: mealKey, context: context)
        context.insert(entry)
        try? context.save()
        SharedStore.reloadWidgets()
        return entry
    }

    @MainActor
    static func move(_ entry: MealPlanEntry, to date: Date, mealKey: String, memberName: String, context: ModelContext) {
        entry.date = date.startOfDay
        entry.mealKey = mealKey
        entry.sortIndex = nextSortIndex(for: date, mealKey: mealKey, context: context)
        entry.lastEditedByName = memberName
        entry.lastEditedDate = .now
        try? context.save()
        SharedStore.reloadWidgets()
    }

    @MainActor
    static func move(_ entry: MealPlanEntry, to date: Date, slot: MealSlot, memberName: String, context: ModelContext) {
        move(entry, to: date, mealKey: slot.rawValue, memberName: memberName, context: context)
    }

    /// Copy an entry to the same weekday `weeksAhead` weeks later.
    @MainActor
    @discardableResult
    static func repeatEntry(_ entry: MealPlanEntry, weeksAhead: Int, memberName: String, context: ModelContext) -> MealPlanEntry? {
        guard let dish = entry.dish else {
            guard entry.isEatingOut else { return nil }
            return planEatingOut(
                on: entry.date.adding(weeks: weeksAhead), mealKey: entry.mealKey,
                placeName: entry.placeName, placeAddress: entry.placeAddress,
                latitude: entry.placeLatitude, longitude: entry.placeLongitude,
                note: entry.note, household: entry.household,
                memberName: memberName, context: context
            )
        }
        return plan(
            dish: dish,
            on: entry.date.adding(weeks: weeksAhead),
            mealKey: entry.mealKey,
            servings: entry.servingsOverride,
            note: entry.note,
            household: entry.household,
            memberName: memberName,
            context: context
        )
    }

    /// Copy every planned meal from one day onto another day.
    @MainActor
    static func copyDay(from source: Date, to target: Date, household: Household?, memberName: String, context: ModelContext) {
        let day = source.startOfDay
        let entries = (try? context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date == day && $0.skipped == false }
        ))) ?? []
        for entry in entries.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            if let dish = entry.dish {
                plan(dish: dish, on: target, mealKey: entry.mealKey, servings: entry.servingsOverride,
                     note: entry.note, household: household ?? entry.household, memberName: memberName, context: context)
            } else if entry.isEatingOut {
                planEatingOut(
                    on: target, mealKey: entry.mealKey,
                    placeName: entry.placeName, placeAddress: entry.placeAddress,
                    latitude: entry.placeLatitude, longitude: entry.placeLongitude,
                    note: entry.note, household: household ?? entry.household,
                    memberName: memberName, context: context
                )
            }
        }
    }

    @MainActor
    static func nextSortIndex(for date: Date, mealKey: String, context: ModelContext) -> Int {
        let day = date.startOfDay
        let existing = (try? context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date == day && $0.mealSlotRaw == mealKey }
        ))) ?? []
        return (existing.map(\.sortIndex).max() ?? -1) + 1
    }

    @MainActor
    static func nextSortIndex(for date: Date, slot: MealSlot, context: ModelContext) -> Int {
        nextSortIndex(for: date, mealKey: slot.rawValue, context: context)
    }
}
