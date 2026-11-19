import Foundation
import Testing
@testable import MealPlan

@MainActor
struct ServingScalerTests {
    @Test
    func scalesPieceBasedRecipeFromItsOriginalYield() {
        let butter = DishIngredient(canonicalValue: 125, dimension: .mass, displayUnit: "g")
        let flour = DishIngredient(canonicalValue: 225, dimension: .mass, displayUnit: "g")
        let halfBatch = ServingScaler(baseServings: 12, targetServings: 6, system: .metric, roundsAmounts: false)
        let doubleBatch = ServingScaler(baseServings: 12, targetServings: 24, system: .metric, roundsAmounts: false)

        #expect(halfBatch.factor == 0.5)
        #expect(doubleBatch.factor == 2)
        #expect(butter.quantity?.scaled(by: halfBatch.factor).value == 62.5)
        #expect(butter.quantity?.scaled(by: doubleBatch.factor).value == 250)
        #expect(flour.quantity?.scaled(by: halfBatch.factor).value == 112.5)
        #expect(flour.quantity?.scaled(by: doubleBatch.factor).value == 450)
    }

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

    @Test
    func exactPreferenceKeepsFractionalEggCounts() {
        let eggs = Ingredient(name: "Eggs")
        let line = DishIngredient(canonicalValue: 3, dimension: .count)
        line.ingredient = eggs
        let scaler = ServingScaler(
            baseServings: 4,
            targetServings: 5,
            system: .metric,
            roundsAmounts: false,
            locale: Locale(identifier: "en_US")
        )

        #expect(scaler.amountText(for: line) == "3.75 ×")
    }
}
