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
        memberName: String = ""
    ) {
        let routines = (household.mealRoutines ?? []).filter(\.isActive)
        guard !routines.isEmpty else { return }
        for routine in routines {
            apply(routine, household: household, context: context, now: now, memberName: memberName)
        }
    }

    /// Plan one routine up to the horizon. Also used right after the user
    /// creates or edits a routine, so its meals show up immediately.
    @MainActor
    static func apply(
        _ routine: MealRoutine,
        household: Household?,
        context: ModelContext,
        now: Date = .now,
        memberName: String = ""
    ) {
        guard routine.isActive, let dish = routine.dish else { return }

        let today = now.startOfDay
        let horizon = today.adding(weeks: horizonWeeks)
        // Never backfill: start after whatever has already been planned, and
        // never before today.
        let from = max(today, routine.plannedThrough?.adding(days: 1).startOfDay ?? today)
        guard from <= horizon else { return }

        let days = routine.occurrences(from: from, through: horizon)
        for day in days where !isTaken(day: day, mealKey: routine.mealKey, context: context) {
            let entry = MealPlanner.plan(
                dish: dish,
                on: day,
                mealKey: routine.mealKey,
                household: household ?? routine.household,
                memberName: memberName,
                context: context
            )
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

    /// True when that meal on that day already holds something.
    @MainActor
    private static func isTaken(day: Date, mealKey: String, context: ModelContext) -> Bool {
        let start = day.startOfDay
        let predicate = #Predicate<MealPlanEntry> { $0.date == start && $0.mealSlotRaw == mealKey }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.isEmpty == false)
    }
}
