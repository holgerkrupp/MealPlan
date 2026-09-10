import Testing
import Foundation
import CoreGraphics
@testable import MealPlan

/// The share images' planning, with fixed heights standing in for rendering.
@MainActor
struct RecipeShareImageTests {

    private typealias Line = RecipeShareContent.IngredientLine
    private typealias Step = RecipeShareContent.Step

    private func content(ingredients: Int, steps: Int, nutrition: Bool = true) -> RecipeShareContent {
        RecipeShareContent(
            title: "Pancakes",
            servingsText: "4 servings",
            servings: 4,
            metrics: [],
            tags: [],
            ingredients: (0..<ingredients).map { Line(amount: "\($0) g", name: "item \($0)") },
            steps: (0..<steps).map { Step(number: $0 + 1, text: "Step \($0 + 1)") },
            nutritionText: nutrition ? "Per serving ≈ 500 kcal" : nil,
            nutrition: nutrition ? .init(energy: "≈ 500 kcal", protein: "20 g", carbs: "60 g", fat: "15 g") : nil
        )
    }

    /// 40 pt a line, 100 pt a step, 500 pt of everything else.
    private func fakeMeasure(_ request: RecipeImagePlanner.Measure) -> CGFloat {
        switch request {
        case .ingredient(_, _, let fit, _): 40 * fit
        case .steps(let steps, _, let fit, _): 100 * fit * CGFloat(steps.count)
        case .chrome: 500
        }
    }

    private let portrait = RecipeImageMetrics(aspect: .portrait)

    @Test func separateImagesComeInRecipeOrder() {
        let pages = RecipeImagePlanner.plan(
            content: content(ingredients: 5, steps: 3),
            layout: .separate,
            metrics: portrait,
            measure: fakeMeasure
        )
        #expect(pages.map(\.kind) == [.ingredients, .directions, .nutrition])
        #expect(pages.allSatisfy { $0.count == 1 && $0.fit == 1 })
    }

    @Test func noTrustworthyNutritionMeansNoNutritionImage() {
        let pages = RecipeImagePlanner.plan(
            content: content(ingredients: 5, steps: 3, nutrition: false),
            layout: .separate,
            metrics: portrait,
            measure: fakeMeasure
        )
        #expect(!pages.contains { $0.kind == .nutrition })
    }

    @Test func aLongMethodCarriesOnWithoutLosingAStep() {
        let recipe = content(ingredients: 3, steps: 20)
        let pages = RecipeImagePlanner.plan(content: recipe, layout: .separate, metrics: portrait, measure: fakeMeasure)
        let method = pages.filter { $0.kind == .directions }
        #expect(method.count > 1)
        #expect(method.map(\.index) == Array(0..<method.count))
        #expect(method.allSatisfy { $0.count == method.count })
        #expect(method.flatMap { $0.stepColumns.joined().joined() } == recipe.steps)
    }

    @Test func aListThatAlmostFitsIsSetSmallerRatherThanSplit() {
        // 850 pt holds 16 lines a column at full size — three columns for 34 —
        // but 17 at 90 %, which is exactly two.
        let pages = RecipeImagePlanner.plan(
            content: content(ingredients: 34, steps: 1),
            layout: .separate,
            metrics: portrait,
            measure: fakeMeasure
        )
        let ingredients = pages.filter { $0.kind == .ingredients }
        #expect(ingredients.count == 1)
        #expect(ingredients.first?.fit ?? 1 < 1)
        #expect(ingredients.first?.ingredientColumns.joined().count == 34)
    }

    @Test func allInOneShowsWhatFitsAndCountsTheRest() {
        let recipe = content(ingredients: 40, steps: 30)
        let pages = RecipeImagePlanner.plan(content: recipe, layout: .combined, metrics: portrait, measure: fakeMeasure)
        #expect(pages.count == 1)
        let page = pages[0]
        #expect(page.kind == .combined)
        #expect(page.hiddenIngredients > 0 && page.hiddenSteps > 0)
        #expect(page.ingredientColumns.joined().count + page.hiddenIngredients == 40)
        #expect(page.stepColumns.joined().joined().count + page.hiddenSteps == 30)
    }

    @Test func aShortRecipeFitsAllInOneWhole() {
        let page = RecipeImagePlanner.plan(
            content: content(ingredients: 4, steps: 2),
            layout: .combined,
            metrics: portrait,
            measure: fakeMeasure
        )[0]
        #expect(page.hiddenIngredients == 0 && page.hiddenSteps == 0)
        #expect(page.fit == 1)
    }

    @Test func aHeadingTravelsWithTheStepAfterIt() {
        let steps = [
            Step(number: 1, text: "Mix"),
            Step(number: nil, text: "For the sauce", isHeading: true),
            Step(number: 2, text: "Simmer"),
        ]
        #expect(RecipeImagePlanner.stepGroups(steps) == [[steps[0]], [steps[1], steps[2]]])
    }

    @Test func aListThatFitsOneColumnIsSharedEvenlyAcrossTwo() {
        // Twelve lines take 634 pt — one column's worth — but portrait plans
        // two columns for more than nine, so they are split six and six.
        let page = RecipeImagePlanner.plan(
            content: content(ingredients: 12, steps: 1),
            layout: .separate,
            metrics: portrait,
            measure: fakeMeasure
        )[0]
        #expect(page.columns == 2)
        #expect(page.ingredientColumns.map(\.count) == [6, 6])
    }

    @Test func balancingSplitsByHeightNotByCount() {
        #expect(RecipeImagePlanner.balance([40, 40, 40, 40], spacing: 10, columns: 2) == [[0, 1], [2, 3]])
        // One tall item on its own balances three short ones.
        #expect(RecipeImagePlanner.balance([150, 40, 40, 40], spacing: 10, columns: 2) == [[0], [1, 2, 3]])
        #expect(RecipeImagePlanner.balance([40], spacing: 10, columns: 2) == [[0]])
    }

    @Test func packingFillsColumnsInOrder() {
        #expect(RecipeImagePlanner.pack([40, 40, 40, 40], spacing: 10, capacity: 100) == [[0, 1], [2, 3]])
        // Too tall for any column: it gets one of its own.
        #expect(RecipeImagePlanner.pack([40, 300, 40], spacing: 10, capacity: 100) == [[0], [1], [2]])
        #expect(RecipeImagePlanner.fitCount([40, 40, 40], spacing: 10, capacity: 95) == 2)
    }

    @Test func everySizeIsTheMealShareSize() {
        #expect(RecipeImageMetrics(aspect: .portrait).size == CGSize(width: 1080, height: 1350))
        #expect(RecipeImageMetrics(aspect: .square).size == CGSize(width: 1080, height: 1080))
        #expect(RecipeImageMetrics(aspect: .landscape).size == CGSize(width: 1600, height: 900))
    }
}
