import Testing
import Foundation
@testable import MealPlan

/// Transient `MealType`s only — see the SwiftData note in the test plan: a
/// `ModelContainer` inside the app test host crashes it, so `ensure` itself is
/// out of reach and only its de-duplication rule is exercised here.
@MainActor
struct MealTypeDeduplicationTests {

    private func meal(_ key: String, _ name: String, order: Int, uuid: UUID) -> MealType {
        let meal = MealType(key: key, name: name, sortOrder: order)
        meal.uuid = uuid
        return meal
    }

    private let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!

    @Test func keepsOneMealPerKeyInDisplayOrder() {
        let meals = [
            meal("lunch", "Lunch", order: 0, uuid: low),
            meal("dinner", "Dinner", order: 1, uuid: low),
            meal("lunch", "Lunch", order: 0, uuid: high),
            meal("dinner", "Dinner", order: 1, uuid: high),
        ]

        let (keep, remove) = MealType.deduplicated(meals)

        #expect(keep.map(\.key) == ["lunch", "dinner"])
        #expect(remove.count == 2)
        #expect(keep.allSatisfy { $0.uuid == low })
    }

    @Test func winnerIsTheSmallestUUIDSoDevicesConverge() {
        let a = meal("lunch", "Lunch", order: 0, uuid: low)
        let b = meal("lunch", "Mittag", order: 0, uuid: high)

        #expect(MealType.deduplicated([a, b]).keep.map(\.name) == ["Lunch"])
        #expect(MealType.deduplicated([b, a]).keep.map(\.name) == ["Lunch"])
    }

    @Test func twoRowsSharingAUUIDStillCollapseToOne() {
        let meals = [
            meal("lunch", "Lunch", order: 0, uuid: low),
            meal("lunch", "Lunch", order: 0, uuid: low),
        ]

        let (keep, remove) = MealType.deduplicated(meals)

        #expect(keep.count == 1)
        #expect(remove.count == 1)
    }

    @Test func distinctKeysAreAllKept() {
        let meals = [
            meal("breakfast", "Breakfast", order: 0, uuid: low),
            meal("lunch", "Lunch", order: 1, uuid: high),
            meal("dinner", "Dinner", order: 2, uuid: low),
        ]

        let (keep, remove) = MealType.deduplicated(meals)

        #expect(keep.map(\.key) == ["breakfast", "lunch", "dinner"])
        #expect(remove.isEmpty)
    }
}
