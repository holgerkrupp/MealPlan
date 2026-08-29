import Foundation
import Testing
@testable import MealPlan

@MainActor
struct ServingScalerTests {
    @Test
    func scaledEggsRoundToPracticalWholeCounts() {
        let eggs = Ingredient(name: "Eggs")
        let line = DishIngredient(
            canonicalValue: 3,
            dimension: .count
        )
        line.ingredient = eggs

        let scaledUp = ServingScaler(
            baseServings: 4,
            targetServings: 5,
            system: .metric,
            locale: Locale(identifier: "en_US")
        )
        let scaledDown = ServingScaler(
            baseServings: 4,
            targetServings: 3,
            system: .metric,
            locale: Locale(identifier: "en_US")
        )

        #expect(scaledUp.amountText(for: line) == "≈ 4 ×")
        #expect(scaledDown.amountText(for: line) == "≈ 2 ×")
    }
}
