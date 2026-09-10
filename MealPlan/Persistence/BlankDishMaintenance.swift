import Foundation
import SwiftData

/// Clears out dishes that hold nothing at all — no name, no recipe, no
/// ingredients, no photo, never planned.
///
/// The editor inserts a new dish before the first keystroke, so a draft the
/// user walked away from used to survive as an "Untitled dish" in the
/// library. The editor now takes its own draft with it when it closes; this
/// sweep is for the ones already in the store, and for the cases no view can
/// clean up after itself — a crash, or a window the system closed for us.
///
/// Deliberately timid: only a dish that is empty in every respect is removed,
/// and only once it has been sitting still for a while, so a record whose
/// ingredients or photos are still arriving from CloudKit is never mistaken
/// for an empty one.
enum BlankDishMaintenance {

    /// How long a dish must have been untouched before it counts as
    /// abandoned rather than in progress.
    static let grace: TimeInterval = 10 * 60

    @MainActor
    @discardableResult
    static func run(context: ModelContext, now: Date = .now) -> Int {
        let predicate = #Predicate<Dish> { $0.name.isEmpty }
        guard let candidates = try? context.fetch(FetchDescriptor<Dish>(predicate: predicate)),
              !candidates.isEmpty else { return 0 }
        let doomed = abandoned(in: candidates, now: now)
        guard !doomed.isEmpty else { return 0 }
        for dish in doomed {
            context.delete(dish)
        }
        try? context.save()
        return doomed.count
    }

    /// The selection rule on its own, so it can be tested without a store.
    static func abandoned(in dishes: [Dish], now: Date = .now) -> [Dish] {
        let cutoff = now.addingTimeInterval(-grace)
        return dishes.filter { dish in
            dish.isBlankDraft && dish.modifiedAt < cutoff && dish.dateCreated < cutoff
        }
    }
}
