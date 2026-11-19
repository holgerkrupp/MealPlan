import Foundation
import SwiftData
import os

/// Runs the nonessential dish sweeps in a context owned by a background
/// model actor. Relationship traversal here must not compete with SwiftUI on
/// the main actor during launch.
@ModelActor
actor DishMaintenanceActor {
    private static let signposter = OSSignposter(
        subsystem: "de.holgerkrupp.mealplan",
        category: "dish maintenance"
    )

    func run(householdID: UUID, now: Date = .now) async {
        let interval = Self.signposter.beginInterval("startup dish maintenance")
        defer { Self.signposter.endInterval("startup dish maintenance", interval) }

        let glyphPredicate = #Predicate<Dish> {
            $0.glyphRaw == nil && $0.glyphIsAuto && $0.household?.uuid == householdID
        }
        guard let dishes = try? modelContext.fetch(FetchDescriptor<Dish>(predicate: glyphPredicate)) else {
            return
        }

        // Keep transactions modest for large libraries. The fetch is a value
        // of actor-owned models; all ingredient and tag traversal stays here.
        for start in stride(from: 0, to: dishes.count, by: 100) {
            if Task.isCancelled { break }
            for dish in dishes[start..<min(start + 100, dishes.count)] {
                dish.refreshAutoGlyph()
            }
            try? modelContext.save()
            await Task.yield()
        }

        guard !Task.isCancelled else { return }
        let emptyNamePredicate = #Predicate<Dish> {
            $0.name.isEmpty && $0.household?.uuid == householdID
        }
        guard let candidates = try? modelContext.fetch(FetchDescriptor<Dish>(predicate: emptyNamePredicate)) else {
            return
        }
        let doomed = BlankDishMaintenance.abandoned(in: candidates, now: now)
        for start in stride(from: 0, to: doomed.count, by: 100) {
            if Task.isCancelled { break }
            let end = min(start + 100, doomed.count)
            for dish in doomed[start..<end] {
                modelContext.delete(dish)
            }
            try? modelContext.save()
            await Task.yield()
        }
    }
}
