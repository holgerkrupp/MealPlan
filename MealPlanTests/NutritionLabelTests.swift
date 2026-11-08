import Testing
import Foundation
import SwiftData
@testable import MealPlan

/// Transient model objects only — no `ModelContext`, per the rest of the suite.
@MainActor
@Suite(.serialized)
struct NutritionLabelTests {

    private func dish(servings: Int = 2) -> Dish {
        let d = Dish(name: "Testgericht")
        d.servings = servings
        return d
    }

    private func line(_ dish: Dish, _ name: String, _ grams: Double?) {
        let item = DishIngredient(
            canonicalValue: grams,
            dimension: grams == nil ? nil : .mass,
            sortIndex: dish.ingredients?.count ?? 0
        )
        item.ingredient = Ingredient(name: name)
        var existing = dish.ingredients ?? []
        existing.append(item)
        dish.ingredients = existing
        item.dish = dish
    }

    private func label(_ dish: Dish) -> NutritionLabel? {
        NutritionLabel.make(for: dish, estimate: NutritionEstimator.perServing(for: dish))
    }

    @Test func listsTheNutrientsInPackageOrder() throws {
        let d = dish()
        d.setStatedNutritionPerServing(NutritionFacts(energyKcal: 500))
        let rows = try #require(label(d)).rows.map(\.nutrient)
        #expect(rows == [.energy, .fat, .saturatedFat, .cholesterol, .sodium, .carbs, .fiber, .sugar, .protein])
    }

    @Test func importedValuesAreLabelledAsTheRecipesOwnAndUnknownsStayUnknown() throws {
        let d = dish()
        d.statedEnergyKcalPerServing = 620
        d.statedFatGramsPerServing = 21
        d.statedSodiumMilligramsPerServing = 480
        d.statedNutritionProvenanceRaw = RecipeNutritionProvenance.imported.rawValue

        let label = try #require(label(d))
        #expect(label.source == .statedByRecipe)
        #expect(label.value(of: .fat) == 21)
        #expect(label.value(of: .sodium) == 480)
        // Not stated means not known — never a zero.
        #expect(label.value(of: .sugar) == nil)
        let sugar = try #require(label.rows.first { $0.nutrient == .sugar })
        #expect(label.valueText(for: sugar, unit: .kilocalories) == "—")
        // A stated figure is shown as stated, without the estimate's ≈.
        let fat = try #require(label.rows.first { $0.nutrient == .fat })
        #expect(!label.valueText(for: fat, unit: .kilocalories).contains("≈"))
        let sodium = try #require(label.rows.first { $0.nutrient == .sodium })
        #expect(label.valueText(for: sodium, unit: .kilocalories, locale: Locale(identifier: "en_US")) == "480 mg")
    }

    @Test func legacyStatedValuesWithoutProvenanceReadAsFromTheRecipe() throws {
        let d = dish()
        d.statedEnergyKcalPerServing = 300
        d.statedNutritionProvenanceRaw = nil
        #expect(try #require(label(d)).source == .statedByRecipe)
    }

    @Test func handEnteredValuesAreLabelledAsSuch() throws {
        let d = dish()
        d.setStatedNutritionPerServing(NutritionFacts(energyKcal: 410), provenance: .manuallyEntered)
        let label = try #require(label(d))
        #expect(label.source == .enteredByHand)
        #expect(label.sourceBadge != NutritionLabel(source: .statedByRecipe, rows: [], estimate: .unavailable).sourceBadge)
    }

    @Test func anEstimateSaysHowManyIngredientsItWasBuiltFrom() throws {
        let d = dish(servings: 1)
        line(d, "Mehl", 100)
        line(d, "Zucker", 50)
        line(d, "Butter", 50)
        line(d, "Haferflocken", 50)
        line(d, "Zauberpulver", 10)
        line(d, "Salz", nil)

        let label = try #require(label(d))
        #expect(label.source == .estimated)
        #expect(label.estimate.countedLines == 4)
        #expect(label.estimate.measuredLines == 5)
        #expect(label.sourceNote.contains("4"))
        #expect(label.sourceNote.contains("5"))
    }

    @Test func anEstimateOnlyClaimsTheFourValuesItCanAddUp() throws {
        let d = dish(servings: 1)
        line(d, "Mehl", 100)

        let label = try #require(label(d))
        #expect(label.value(of: .energy) != nil)
        #expect(label.value(of: .fat) != nil)
        #expect(label.value(of: .carbs) != nil)
        #expect(label.value(of: .protein) != nil)
        for nutrient in [NutritionLabel.Nutrient.saturatedFat, .cholesterol, .sodium, .fiber, .sugar] {
            #expect(label.value(of: nutrient) == nil)
        }
        let carbs = try #require(label.rows.first { $0.nutrient == .carbs })
        #expect(label.valueText(for: carbs, unit: .kilocalories).hasPrefix("≈"))
    }

    @Test func showsNoLabelForAThinEstimate() {
        let d = dish(servings: 1)
        line(d, "Mehl", 100)
        line(d, "Zauberpulver", 10)
        line(d, "Feenstaub", 10)
        #expect(label(d) == nil)
    }

    @Test func substitutionSuggestionsAreTidiedForReview() {
        let raw = [
            IngredientSubstitution(name: "  Hafermilch ", amountHint: " same amount ", note: ""),
            IngredientSubstitution(name: "Milch", amountHint: "", note: "the original"),
            IngredientSubstitution(name: "hafermilch", amountHint: "", note: "duplicate"),
            IngredientSubstitution(name: "", amountHint: "", note: "empty"),
            IngredientSubstitution(name: "Sojamilch", amountHint: "", note: ""),
            IngredientSubstitution(name: "Mandelmilch", amountHint: "", note: ""),
            IngredientSubstitution(name: "Reismilch", amountHint: "", note: ""),
            IngredientSubstitution(name: "Kokosmilch", amountHint: "", note: ""),
        ]
        let cleaned = IngredientSubstitutionSuggester.cleaned(raw, replacing: "Milch")
        #expect(cleaned.map(\.name) == ["Hafermilch", "Sojamilch", "Mandelmilch", "Reismilch"])
        #expect(cleaned[0].amountHint == "same amount")
        #expect(cleaned[0].noteText.contains("Hafermilch"))
        #expect(cleaned[0].noteText.contains("same amount"))
    }
}
