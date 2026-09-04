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

// MARK: - Drag and drop

extension MealPlanner {

    /// Where a dragged meal came from, when it was already on the plan.
    struct DropOrigin: Equatable, Sendable {
        var date: Date
        var mealKey: String
    }

    /// What a drop onto the plan should do. Decided separately from carrying
    /// it out so the rules can be tested without a `ModelContext`.
    enum DropPlan: Equatable, Sendable {
        /// Move the meal that was dragged onto this day and meal.
        case move(date: Date, mealKey: String)
        /// Plan the dish that was dragged onto this day and meal.
        case add(date: Date, mealKey: String)
        /// Dropped back where it started — accept it, but change nothing.
        case unchanged
        /// Nowhere to put it: a day-level drop on a household with no meals.
        case rejected
    }

    /// Resolve a drop onto `date`.
    ///
    /// `mealKey` is the meal that was dropped on, or nil for a drop on a day as
    /// a whole (the week strip, a day's header). A day-level drop keeps an
    /// already-planned meal in the meal it was in, so dragging Tuesday's dinner
    /// onto Friday stays dinner; a dish coming from the library has no meal of
    /// its own and falls back to `defaultMealKey`.
    ///
    /// Pure, so it can be tested without a `ModelContext`.
    static func dropPlan(
        from origin: DropOrigin?,
        onto date: Date,
        mealKey: String?,
        defaultMealKey: String? = nil
    ) -> DropPlan {
        let day = date.startOfDay
        if let origin {
            let target = mealKey ?? origin.mealKey
            if origin.date.isSameDay(as: day) && origin.mealKey == target { return .unchanged }
            return .move(date: day, mealKey: target)
        }
        guard let target = mealKey ?? defaultMealKey else { return .rejected }
        return .add(date: day, mealKey: target)
    }

    /// Apply a dropped `DishReference` to one day, and one meal when the drop
    /// landed on a meal card. Returns false when nothing in the payload
    /// resolved, so the drop is refused and the drag animates back.
    @MainActor
    @discardableResult
    static func drop(
        _ reference: DishReference,
        onto date: Date,
        mealKey: String?,
        household: Household?,
        memberName: String,
        context: ModelContext
    ) -> Bool {
        // A meal dragged off the plan is identified by its entry; the dish it
        // points at may well be planned on other days too.
        let entry = reference.sourceEntryUUID.flatMap { self.entry(uuid: $0, context: context) }
        let origin = entry.map { DropOrigin(date: $0.date, mealKey: $0.mealKey) }
        let dish: Dish? = origin == nil ? self.dish(uuid: reference.dishUUID, context: context) : nil
        guard origin != nil || dish != nil else { return false }

        let fallback: String? = mealKey == nil ? defaultMealKey(context: context) : nil
        switch dropPlan(from: origin, onto: date, mealKey: mealKey, defaultMealKey: fallback) {
        case .move(let day, let key):
            guard let entry else { return false }
            move(entry, to: day, mealKey: key, memberName: memberName, context: context)
            return true
        case .add(let day, let key):
            guard let dish else { return false }
            plan(dish: dish, on: day, mealKey: key,
                 household: household, memberName: memberName, context: context)
            return true
        case .unchanged:
            return true
        case .rejected:
            return false
        }
    }

    @MainActor
    static func entry(uuid: UUID, context: ModelContext) -> MealPlanEntry? {
        try? context.fetch(FetchDescriptor<MealPlanEntry>(predicate: #Predicate { $0.uuid == uuid })).first
    }

    @MainActor
    static func dish(uuid: UUID, context: ModelContext) -> Dish? {
        try? context.fetch(FetchDescriptor<Dish>(predicate: #Predicate { $0.uuid == uuid })).first
    }

    /// The meal a day-level drop falls back to: the household's first one.
    @MainActor
    private static func defaultMealKey(context: ModelContext) -> String? {
        var descriptor = FetchDescriptor<MealType>(
            sortBy: [SortDescriptor(\MealType.sortOrder), SortDescriptor(\MealType.name)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.key
    }
}
