import Foundation
import SwiftData

/// Fills the plan ahead from the household's `MealRoutine`s.
///
/// Two rules keep this unsurprising:
/// * nothing in the past or in a meal slot that already has something planned
///   is ever touched, so a routine never overwrites a decision;
/// * each routine remembers the day it has been planned through, so a meal the
///   family deleted for one week is not recreated on the next launch.
enum MealRoutineScheduler {

    /// How far ahead routines are planned.
    static let horizonWeeks = 8

    @MainActor
    static func apply(
        for household: Household,
        context: ModelContext,
        now: Date = .now,
        through latestPlanningDate: Date? = nil,
        memberName: String = ""
    ) {
        let routines = (household.mealRoutines ?? []).filter(\.isActive)
        guard !routines.isEmpty else { return }
        let today = now.startOfDay
        let horizon = latestPlanningDate.map { min(today.adding(weeks: horizonWeeks), $0.startOfDay) }
            ?? today.adding(weeks: horizonWeeks)
        let eligible = routines.compactMap { routine -> (MealRoutine, Dish, [Date])? in
            guard let dish = routine.dish else { return nil }
            let from = max(today, routine.plannedThrough?.adding(days: 1).startOfDay ?? today)
            guard from <= horizon else { return nil }
            return (routine, dish, routine.occurrences(from: from, through: horizon))
        }
        guard !eligible.isEmpty else { return }

        // One bounded read seeds occupancy for every routine. Keep it keyed by
        // day and meal so newly inserted routine entries reserve their slots too.
        let start = eligible.flatMap { $0.2 }.min() ?? today
        let end = eligible.flatMap { $0.2 }.max()?.adding(days: 1) ?? horizon.adding(days: 1)
        let householdID = household.uuid
        let predicate = #Predicate<MealPlanEntry> {
            $0.date >= start && $0.date < end && $0.household?.uuid == householdID
        }
        let existing = (try? context.fetch(FetchDescriptor<MealPlanEntry>(predicate: predicate))) ?? []
        var occupied = Set(existing.map { "\($0.date.startOfDay.timeIntervalSinceReferenceDate)|\($0.mealSlotRaw)" })
        for (routine, dish, days) in eligible {
            for day in days {
                let key = "\(day.startOfDay.timeIntervalSinceReferenceDate)|\(routine.mealKey)"
                guard occupied.insert(key).inserted else { continue }
                let entry = MealPlanner.plan(
                    dish: dish, on: day, mealKey: routine.mealKey,
                    household: household, memberName: memberName, context: context
                )
                entry.routineUUID = routine.uuid
            }
            routine.plannedThrough = horizon
        }
        try? context.save()
    }

    /// Plan one routine up to the horizon. Also used right after the user
    /// creates or edits a routine, so its meals show up immediately.
    @MainActor
    static func apply(
        _ routine: MealRoutine,
        household: Household?,
        context: ModelContext,
        now: Date = .now,
        through latestPlanningDate: Date? = nil,
        memberName: String = ""
    ) {
        guard routine.isActive else { return }
        // Route a single routine through the same batched scheduler. Temporarily
        // scoped to its own occurrence list by the scheduler's active-routine
        // filtering would otherwise include siblings; the single path uses one
        // bounded fetch and an in-memory occupied set.
        guard let dish = routine.dish else { return }
        let today = now.startOfDay
        let horizon = latestPlanningDate.map { min(today.adding(weeks: horizonWeeks), $0.startOfDay) }
            ?? today.adding(weeks: horizonWeeks)
        let from = max(today, routine.plannedThrough?.adding(days: 1).startOfDay ?? today)
        guard from <= horizon else { return }
        let days = routine.occurrences(from: from, through: horizon)
        guard let first = days.min(), let last = days.max() else {
            routine.plannedThrough = horizon
            try? context.save()
            return
        }
        let start = first.startOfDay
        let end = last.startOfDay.adding(days: 1)
        let householdID = (household ?? routine.household)?.uuid
        let predicate: Predicate<MealPlanEntry>
        if let householdID {
            predicate = #Predicate { $0.date >= start && $0.date < end && $0.household?.uuid == householdID }
        } else {
            predicate = #Predicate { $0.date >= start && $0.date < end }
        }
        let existing = (try? context.fetch(FetchDescriptor<MealPlanEntry>(predicate: predicate))) ?? []
        var occupied = Set(existing.map { "\($0.date.startOfDay.timeIntervalSinceReferenceDate)|\($0.mealSlotRaw)" })
        for day in days {
            let key = "\(day.startOfDay.timeIntervalSinceReferenceDate)|\(routine.mealKey)"
            guard occupied.insert(key).inserted else { continue }
            let entry = MealPlanner.plan(dish: dish, on: day, mealKey: routine.mealKey,
                household: household ?? routine.household, memberName: memberName, context: context)
            entry.routineUUID = routine.uuid
        }
        routine.plannedThrough = horizon
        try? context.save()
    }

    /// Remove the meals a routine has planned from `now` on, leaving history
    /// (and anything the family has already edited into place) alone.
    @MainActor
    static func removeFutureEntries(of routine: MealRoutine, context: ModelContext, now: Date = .now) {
        let today = now.startOfDay
        let id = routine.uuid
        let predicate = #Predicate<MealPlanEntry> { $0.routineUUID == id && $0.date >= today }
        let entries = (try? context.fetch(FetchDescriptor(predicate: predicate))) ?? []
        for entry in entries { context.delete(entry) }
        if !entries.isEmpty {
            try? context.save()
            SharedStore.reloadWidgets()
        }
    }

}
