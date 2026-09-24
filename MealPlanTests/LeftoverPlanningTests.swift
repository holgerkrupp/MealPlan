import Foundation
import Testing
@testable import MealPlan

@MainActor
@Suite(.serialized)
struct LeftoverPlanningTests {
    private func packages(
        _ quantity: Quantity,
        id: String = "tomatoes-400",
        name: String = "Tomaten, gehackt"
    ) -> [PackageSizeDefinition] {
        [PackageSizeDefinition(id: id, ingredientName: name, countryCode: "DE", quantity: quantity, containerType: .can)]
    }

    private func dish(_ name: String, servings: Int = 2, ingredient: String, quantity: Quantity) -> Dish {
        let dish = Dish(name: name)
        dish.servings = servings
        let ingredientModel = Ingredient(name: ingredient)
        let line = DishIngredient(canonicalValue: quantity.value, dimension: quantity.dimension)
        line.ingredient = ingredientModel
        line.dish = dish
        dish.ingredients = [line]
        return dish
    }

    @Test func threeHundredGramsInFourHundredGramPackageLeavesOneHundred() throws {
        let result = try #require(LeftoverCalculator.remainder(for: .grams(300), packageSizes: packages(.grams(400))))
        #expect(result.purchased == .grams(400))
        #expect(result.remainder == .grams(100))
        #expect(result.packageCount == 1)
    }

    @Test func sixHundredFiftyGramsUsesTwoFourHundredGramPackages() throws {
        let result = try #require(LeftoverCalculator.remainder(for: .grams(650), packageSizes: packages(.grams(400))))
        #expect(result.purchased == .grams(800))
        #expect(result.remainder == .grams(150))
        #expect(result.packageCount == 2)
    }

    @Test func multipleSizesChooseTheLeastWastefulCombination() throws {
        let sizes = packages(.grams(200), id: "tomatoes-200") + packages(.grams(400), id: "tomatoes-400")
        let result = try #require(LeftoverCalculator.remainder(for: .grams(650), packageSizes: sizes))
        #expect(result.purchased == .grams(800))
        #expect(result.packageCount == 2)
    }

    @Test func exactPackageUsageProducesNoLeftover() {
        #expect(LeftoverCalculator.remainder(for: .grams(400), packageSizes: packages(.grams(400))) == nil)
    }

    @Test func incompatibleDimensionsNeverMatch() {
        #expect(LeftoverCalculator.remainder(for: .grams(300), packageSizes: packages(.millilitres(400), name: "Kokosmilch")) == nil)
    }

    @Test func userProfileReplacesBundledRegionalProfile() throws {
        let user = IngredientPackageSize(
            ingredientKey: IngredientMatching.key(for: "Tomaten, gehackt"), ingredientName: "Tomaten, gehackt",
            countryCode: "DE", quantity: .grams(500), containerType: .jar, provenance: .user
        )
        user.overridesProfile = true
        let effective = IngredientPackageCatalogue.effectiveSizes(
            for: IngredientMatching.key(for: "Tomaten, gehackt"), countryCode: "DE",
            bundled: packages(.grams(400)), userOverrides: [user]
        )
        #expect(effective.map(\.quantity) == [.grams(500)])
    }

    @Test func disabledBundledSizeIsIgnored() {
        let user = IngredientPackageSize(
            ingredientKey: IngredientMatching.key(for: "Tomaten, gehackt"), ingredientName: "Tomaten, gehackt",
            countryCode: "DE", quantity: .grams(400), containerType: .can, provenance: .user
        )
        user.stableBundledID = "tomatoes-400"
        user.overridesBundledID = "tomatoes-400"
        user.isEnabled = false
        #expect(IngredientPackageCatalogue.effectiveSizes(
            for: IngredientMatching.key(for: "Tomaten, gehackt"), countryCode: "DE",
            bundled: packages(.grams(400)), userOverrides: [user]
        ).isEmpty)
    }

    @Test func aliasesUseTheSameCanonicalIngredientIdentity() {
        let source = dish("Pasta", ingredient: "gehackt Tomaten", quantity: .grams(300))
        let entry = MealPlanEntry(date: .now, slot: .dinner, dish: source)
        let leftovers = LeftoverCalculator.calculate(
            entries: [entry], countryCode: "DE", bundled: packages(.grams(400))
        )
        #expect(leftovers.first?.ingredientKey == IngredientMatching.key(for: "Tomaten, gehackt"))
    }

    @Test func servingScalingChangesTheRemainder() throws {
        let source = dish("Pasta", servings: 2, ingredient: "Tomaten, gehackt", quantity: .grams(300))
        let entry = MealPlanEntry(date: .now, slot: .dinner, dish: source)
        entry.servingsOverride = 4
        let leftover = try #require(LeftoverCalculator.calculate(
            entries: [entry], countryCode: "DE", bundled: packages(.grams(400))
        ).first)
        #expect(leftover.required == .grams(600))
        #expect(leftover.remainder == .grams(200))
    }

    @Test func rankingPrefersMoreLeftoverUseWithoutNewPackageWaste() {
        let leftover = PredictedLeftover(
            ingredientKey: IngredientMatching.key(for: "Tomaten, gehackt"), ingredientName: "Tomaten, gehackt",
            required: .grams(300), purchased: .grams(400), remainder: .grams(100), packageSize: .grams(400),
            packageCount: 1, sourceDishNames: ["Tuesday pasta"], sourceDates: [.now]
        )
        let good = dish("Tomato toast", ingredient: "Tomaten, gehackt", quantity: .grams(100))
        let bad = dish("Tomato pasta", ingredient: "Tomaten, gehackt", quantity: .grams(100))
        let pastaLine = DishIngredient(canonicalValue: 1, dimension: .count)
        let pasta = Ingredient(name: "Nudeln")
        pastaLine.ingredient = pasta
        pastaLine.dish = bad
        bad.ingredients?.append(pastaLine)
        let sizes = packages(.grams(400)) + [PackageSizeDefinition(
            id: "pasta-500", ingredientName: "Nudeln", countryCode: "DE", quantity: .grams(500), containerType: .bag
        )]
        let suggestions = LeftoverDishSuggester.suggestions(
            for: [leftover], dishes: [bad, good], servings: 2, countryCode: "DE", bundled: sizes
        )
        #expect(suggestions.first?.dish === good)
        #expect(suggestions.first?.reasons.first?.contains("likely left over") == true)
    }
}
