import Testing
import Foundation
import SwiftData
@testable import MealPlan

/// Transient model objects only — no `ModelContext`, per the rest of the suite.
@MainActor
@Suite(.serialized)
struct NutritionEstimatorTests {

    // MARK: - Fixtures

    private func dish(_ name: String, servings: Int = 4) -> Dish {
        let d = Dish(name: name)
        d.servings = servings
        return d
    }

    @discardableResult
    private func line(
        _ dish: Dish,
        _ ingredientName: String,
        _ value: Double?,
        _ dimension: QuantityDimension?,
        unit: String? = nil,
        approximate: Bool = false
    ) -> DishIngredient {
        let ingredient = Ingredient(name: ingredientName)
        let item = DishIngredient(
            canonicalValue: value,
            dimension: dimension,
            displayUnit: unit,
            isApproximate: approximate,
            sortIndex: dish.ingredients?.count ?? 0
        )
        item.ingredient = ingredient
        var existing = dish.ingredients ?? []
        existing.append(item)
        dish.ingredients = existing
        item.dish = dish
        return item
    }

    private func kcal(_ outcome: NutritionEstimator.LineOutcome) -> Double? {
        guard case let .counted(facts, _) = outcome else { return nil }
        return facts.energyKcal
    }

    // MARK: - The reference table

    @Test func findsAnIngredientByItsExactName() throws {
        let flour = try #require(NutritionTable.facts(for: "Mehl"))
        #expect(flour.energyKcal == 364)
        #expect(NutritionTable.facts(for: "flour")?.energyKcal == 364)
    }

    @Test func findsAnIngredientInsideALongerName() {
        // A word of the name, and a compound built on one.
        #expect(NutritionTable.facts(for: "Gehackte Tomaten")?.energyKcal == 18)
        #expect(NutritionTable.facts(for: "Bio-Olivenöl extra vergine")?.energyKcal == 884)
    }

    @Test func prefersTheMoreSpecificIngredient() {
        // "Hähnchenbrust" contains "Hähnchen"; the leaner, longer alias wins.
        #expect(NutritionTable.facts(for: "Hähnchenbrust")?.energyKcal == 165)
        #expect(NutritionTable.facts(for: "Hähnchen")?.energyKcal == 215)
    }

    /// The whole reason short aliases are whole-word only: "Reis" contains
    /// "ei", and rice at 143 kcal instead of 360 would be silently wrong in
    /// every risotto in the library.
    @Test func aShortAliasNeverMatchesInsideAnotherWord() {
        #expect(NutritionTable.facts(for: "Reis")?.energyKcal == 360)
        #expect(NutritionTable.facts(for: "Ei")?.energyKcal == 143)
    }

    @Test func admitsWhenItDoesNotKnowSomething() {
        #expect(NutritionTable.facts(for: "Yuzu-Kosho") == nil)
        #expect(NutritionTable.facts(for: "") == nil)
    }

    // MARK: - Piece weights

    @Test func aCloveIsNotABulb() {
        #expect(PieceWeightTable.grams(forIngredient: "Knoblauch", unitLabel: "Zehe") == 3)
        #expect(PieceWeightTable.grams(forIngredient: "Knoblauch", unitLabel: "Knolle") == 50)
    }

    @Test func aSliceDependsOnWhatIsBeingSliced() {
        #expect(PieceWeightTable.grams(forIngredient: "Brot", unitLabel: "Scheibe") == 40)
        #expect(PieceWeightTable.grams(forIngredient: "Schinken", unitLabel: "Scheibe") == 15)
        // Something sliced that no rule names still gets a sensible default.
        #expect(PieceWeightTable.grams(forIngredient: "Kassler", unitLabel: "Scheibe") == 30)
    }

    @Test func aGenericPieceUnitDefersToTheIngredient() {
        // "2 Stück Zwiebeln" must weigh an onion, not a generic piece.
        #expect(PieceWeightTable.grams(forIngredient: "Zwiebel", unitLabel: "Stück") == 110)
        #expect(PieceWeightTable.grams(forIngredient: "Zwiebeln") == 110)
    }

    @Test func staysQuietAboutThingsItCannotWeigh() {
        #expect(PieceWeightTable.grams(forIngredient: "Yuzu") == nil)
    }

    // MARK: - One line

    @Test func weighsAMassLineDirectly() {
        let d = dish("Test")
        let item = line(d, "Mehl", 200, .mass)
        // 200 g of flour at 364 kcal per 100 g.
        #expect(kcal(NutritionEstimator.outcome(for: item)) == 728)
        if case let .counted(_, confidence) = NutritionEstimator.outcome(for: item) {
            #expect(confidence == .weighed)
        }
    }

    @Test func convertsAVolumeThroughItsDensity() throws {
        let d = dish("Test")
        // "1 EL Olivenöl" reaches us as 15 ml, approximate.
        let item = line(d, "Olivenöl", 15, .volume, unit: "EL", approximate: true)
        let outcome = NutritionEstimator.outcome(for: item)
        let value = try #require(kcal(outcome))
        // 15 ml × 0.92 g/ml = 13.8 g at 884 kcal per 100 g.
        #expect(abs(value - 122) < 1)
        if case let .counted(_, confidence) = outcome {
            #expect(confidence == .converted)
        }
    }

    @Test func convertsACountThroughItsPieceWeight() throws {
        let d = dish("Test")
        let item = line(d, "Ei", 2, .count)
        let value = try #require(kcal(NutritionEstimator.outcome(for: item)))
        // 2 × 58 g at 143 kcal per 100 g.
        #expect(abs(value - 165.9) < 0.5)
    }

    @Test func aLineWithNoAmountIsLeftOutRatherThanCountedAsNothing() {
        let d = dish("Test")
        let item = line(d, "Salz", nil, nil)
        #expect(NutritionEstimator.outcome(for: item) == .unmeasured)
    }

    @Test func anUnknownIngredientIsReportedNotAssumedToBeZero() {
        let d = dish("Test")
        let item = line(d, "Yuzu-Kosho", 20, .mass)
        #expect(NutritionEstimator.outcome(for: item) == .unknown)
    }

    @Test func theHouseholdsOwnValuesBeatTheReferenceTable() throws {
        let d = dish("Test")
        let item = line(d, "Mehl", 100, .mass)
        item.ingredient?.setNutrition(NutritionFacts(energyKcal: 500, proteinGrams: 1, carbGrams: 2, fatGrams: 3))
        #expect(kcal(NutritionEstimator.outcome(for: item)) == 500)
    }

    @Test func readsValuesStatedPerPiece() throws {
        let d = dish("Test")
        let item = line(d, "Proteinriegel", 3, .count)
        item.ingredient?.setNutrition(NutritionFacts(energyKcal: 210), reference: .perPiece)
        #expect(kcal(NutritionEstimator.outcome(for: item)) == 630)
    }

    // MARK: - One dish

    @Test func dividesTheWholeRecipeByItsYield() throws {
        let d = dish("Pfannkuchen", servings: 4)
        line(d, "Mehl", 200, .mass)       // 728 kcal
        line(d, "Milch", 500, .volume)    // ~515 ml→g at 64 kcal/100 g
        line(d, "Ei", 3, .count)          // ~249 kcal

        let estimate = NutritionEstimator.perServing(for: d)
        #expect(estimate.origin == .computed)
        #expect(estimate.countedLines == 3)
        #expect(estimate.isTrustworthy)
        // Roughly 1 300 kcal over four servings.
        #expect(estimate.facts.energyKcal > 280)
        #expect(estimate.facts.energyKcal < 360)
    }

    @Test func refusesToShowATotalItCannotStandBehind() {
        let d = dish("Mystery", servings: 2)
        line(d, "Mehl", 100, .mass)
        line(d, "Yuzu-Kosho", 50, .mass)
        line(d, "Sansho", 50, .mass)
        line(d, "Shiso", 50, .mass)

        let estimate = NutritionEstimator.perServing(for: d)
        #expect(estimate.coverage == 0.25)
        #expect(!estimate.isTrustworthy)
        #expect(estimate.missingNames.count == 3)
    }

    @Test func seasoningWithoutAnAmountDoesNotCountAgainstCoverage() {
        let d = dish("Nudeln", servings: 2)
        line(d, "Nudeln", 250, .mass)
        line(d, "Salz", nil, nil)
        line(d, "Pfeffer", nil, nil)

        let estimate = NutritionEstimator.perServing(for: d)
        #expect(estimate.coverage == 1)
        #expect(estimate.unmeasuredLines == 2)
        #expect(estimate.isTrustworthy)
    }

    @Test func aRecipeThatStatesItsOwnFiguresIsTakenAtItsWord() {
        let d = dish("Importiert", servings: 4)
        line(d, "Mehl", 200, .mass)
        d.setStatedNutritionPerServing(NutritionFacts(energyKcal: 540, proteinGrams: 20, carbGrams: 60, fatGrams: 22))

        let estimate = NutritionEstimator.perServing(for: d)
        #expect(estimate.origin == .statedByRecipe)
        #expect(estimate.facts.energyKcal == 540)
        #expect(estimate.isTrustworthy)
    }

    @Test func aDishWithNoIngredientsHasNoEstimate() {
        #expect(NutritionEstimator.perServing(for: dish("Nur ein Name")).origin == .none)
    }

    // MARK: - A day

    @Test func addsUpWhatOnePersonEatsInADay() {
        let breakfast = dish("Haferbrei", servings: 2)
        line(breakfast, "Haferflocken", 100, .mass)   // 375 kcal → 187.5 a head
        let dinner = dish("Nudeln", servings: 2)
        line(dinner, "Nudeln", 250, .mass)            // 927.5 kcal → 463.75 a head

        let day = Date.now
        let estimate = NutritionEstimator.perPerson(for: [
            MealPlanEntry(date: day, slot: .breakfast, dish: breakfast),
            MealPlanEntry(date: day, slot: .dinner, dish: dinner),
        ])
        #expect(abs(estimate.facts.energyKcal - 651.25) < 1)
    }

    /// The figure has to mean the same thing on a Tuesday for two and a Sunday
    /// for eight, or it is useless for "make tomorrow lighter".
    @Test func headCountDoesNotChangeWhatOnePersonEats() {
        let d = dish("Nudeln", servings: 2)
        line(d, "Nudeln", 250, .mass)

        let forTwo = MealPlanEntry(date: .now, slot: .dinner, dish: d)
        let forEight = MealPlanEntry(date: .now, slot: .dinner, dish: d)
        forEight.servingsOverride = 8

        #expect(
            NutritionEstimator.perPerson(for: [forTwo]).facts
                == NutritionEstimator.perPerson(for: [forEight]).facts
        )
    }

    @Test func leavesOutMealsThatWereSkipped() {
        let d = dish("Nudeln", servings: 2)
        line(d, "Nudeln", 250, .mass)
        let entry = MealPlanEntry(date: .now, slot: .dinner, dish: d)
        entry.skipped = true
        #expect(NutritionEstimator.perPerson(for: [entry]).origin == .none)
    }

    @Test func aPlannedDishWithNoRecipeMakesTheDayUntrustworthy() {
        let known = dish("Nudeln", servings: 2)
        line(known, "Nudeln", 250, .mass)

        let estimate = NutritionEstimator.perPerson(for: [
            MealPlanEntry(date: .now, slot: .dinner, dish: known),
            MealPlanEntry(date: .now, slot: .lunch, dish: dish("Reste")),
        ])
        #expect(estimate.dishesWithoutEstimate == 1)
        #expect(!estimate.isTrustworthy)
    }

    // MARK: - The week

    private func estimate(_ kcal: Double) -> NutritionEstimate {
        NutritionEstimate(
            facts: NutritionFacts(energyKcal: kcal),
            countedLines: 3,
            origin: .computed
        )
    }

    @Test func marksTheDaysThatStandOutFromTheirWeek() throws {
        let days = (0..<5).map { Date.now.adding(days: $0) }
        let summary = WeekNutritionSummary(estimatesByDayID: [
            days[0].dayID: estimate(2_000),
            days[1].dayID: estimate(2_000),
            days[2].dayID: estimate(2_000),
            days[3].dayID: estimate(3_000),   // +50 %
            days[4].dayID: estimate(1_200),   // −40 %
        ])
        #expect(summary.standing(on: days[0]) == .typical)
        #expect(summary.standing(on: days[3]) == .heavier)
        #expect(summary.standing(on: days[4]) == .lighter)
    }

    @Test func saysNothingAboutAWeekWithTooLittleInIt() {
        let days = (0..<2).map { Date.now.adding(days: $0) }
        let summary = WeekNutritionSummary(estimatesByDayID: [
            days[0].dayID: estimate(2_000),
            days[1].dayID: estimate(3_500),
        ])
        #expect(summary.standing(on: days[0]) == nil)
        #expect(summary.estimate(on: days[0])?.facts.energyKcal == 2_000)
    }

    @Test func smallDifferencesAreNotWorthPointingOut() {
        let days = (0..<3).map { Date.now.adding(days: $0) }
        let summary = WeekNutritionSummary(estimatesByDayID: [
            days[0].dayID: estimate(2_000),
            days[1].dayID: estimate(2_100),
            days[2].dayID: estimate(2_200),
        ])
        #expect(summary.standing(on: days[2]) == .typical)
    }

    // MARK: - Presentation

    @Test func everyFigureIsMarkedAsAnEstimate() {
        let facts = NutritionFacts(energyKcal: 643)
        #expect(NutritionFormatting.energy(facts, unit: .kilocalories).hasPrefix("≈"))
        // Rounded to something a kitchen can act on, not to the calorie.
        #expect(NutritionFormatting.energy(facts, unit: .kilocalories).contains("640"))
    }

    @Test func convertsToKilojoulesOnRequest() {
        let text = NutritionFormatting.energy(
            NutritionFacts(energyKcal: 1_000), unit: .kilojoules, locale: Locale(identifier: "en_US")
        )
        #expect(text.contains("kJ"))
        #expect(text.contains("4,200"))   // 4 184 kJ, rounded to 50
    }

    @Test func bandsAServingByHowHeavyItIs() {
        #expect(NutritionBand.band(forKcalPerServing: 320) == .light)
        #expect(NutritionBand.band(forKcalPerServing: 600) == .moderate)
        #expect(NutritionBand.band(forKcalPerServing: 980) == .hearty)
    }

    // MARK: - Import

    @Test func readsSchemaOrgNutrition() throws {
        let facts = try #require(RecipeSchemaParser.nutrition([
            "@type": "NutritionInformation",
            "calories": "540 calories",
            "proteinContent": "31 g",
            "carbohydrateContent": "60g",
            "fatContent": "22",
        ]))
        #expect(facts.energyKcal == 540)
        #expect(facts.proteinGrams == 31)
        #expect(facts.carbGrams == 60)
        #expect(facts.fatGrams == 22)
    }

    @Test func convertsKilojoulesFromARecipe() throws {
        let facts = try #require(RecipeSchemaParser.nutrition(["calories": "2200 kJ"]))
        #expect(abs(facts.energyKcal - 525.8) < 0.5)
    }

    @Test func dropsANutritionBlockWithNoEnergyInIt() {
        #expect(RecipeSchemaParser.nutrition(["proteinContent": "31 g"]) == nil)
        #expect(RecipeSchemaParser.nutrition(["calories": "0"]) == nil)
        #expect(RecipeSchemaParser.nutrition("540 kcal") == nil)
    }
}
