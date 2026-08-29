import Foundation
import SwiftData

/// Turns planned meals whose day has passed into cooked-history, so the
/// "haven't cooked this in a while" tracking reflects reality without the
/// cook having to confirm every meal.
enum CookedLogMaintenance {

    @MainActor
    static func run(for household: Household, context: ModelContext, now: Date = .now) {
        let cutoff = now.startOfDay
        let predicate = #Predicate<MealPlanEntry> { entry in
            entry.date < cutoff
                && entry.skipped == false
                && entry.cookedLog == nil
        }
        guard let due = try? context.fetch(FetchDescriptor(predicate: predicate)) else { return }

        for entry in due {
            let log = CookedLog(date: entry.date, dish: entry.dish, servings: entry.effectiveServings)
            log.entry = entry
            log.household = household
            context.insert(log)

            if let dish = entry.dish {
                if (dish.lastUsedDate ?? .distantPast) < entry.date {
                    dish.lastUsedDate = entry.date
                }
                dish.usageCount += 1
            }
        }
        if !due.isEmpty { try? context.save() }
    }
}
