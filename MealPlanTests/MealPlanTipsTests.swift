import Testing
import Foundation
@testable import MealPlan

/// A drop on the plan retires the tip that taught its gesture — and only
/// that one. Dragging a planned meal is the move tip's gesture; dragging a
/// dish in from the library is the sidebar's.
struct MealPlanTipsTests {

    @Test func draggingAPlannedMealCountsAsMovingIt() {
        let reference = DishReference(dishUUID: UUID(), name: "Chili", sourceEntryUUID: UUID())
        #expect(MealPlanTips.planDrop(for: reference) == .movedMeal)
    }

    @Test func draggingADishFromTheLibraryCountsAsPlanningIt() {
        let reference = DishReference(dishUUID: UUID(), name: "Chili")
        #expect(MealPlanTips.planDrop(for: reference) == .plannedDish)
    }
}
