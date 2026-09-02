import Testing
import Foundation
@testable import MealPlan

@MainActor
struct DishSearchTests {

    // MARK: - Fuzzy matching

    @Test func literalMatchesOutrankEverythingElse() {
        #expect("Lasagne".fuzzyScore(query: "Lasagne") == 1)
        #expect("Lasagne".fuzzyScore(query: "Lasa") == 0.95)
        #expect("Vegetarian lasagne".fuzzyScore(query: "lasagne") == 0.85)
        // Accents and case are noise.
        #expect("Käsespätzle".fuzzyScore(query: "kasespatzle") == 1)
    }

    @Test func toleratesTypos() {
        // Swapped letters, a missing one, and an extra one.
        #expect("Lasagne".fuzzyScore(query: "lasgane") > 0)
        #expect("Zucchini soup".fuzzyScore(query: "zuchini") > 0)
        #expect("Bolognese".fuzzyScore(query: "bolognesse") > 0)
        // A typo in a half-typed word still reaches the dish.
        #expect("Lasagne".fuzzyScore(query: "lasgan") > 0)
    }

    @Test func staysQuietForWordsThatSimplyDontMatch() {
        #expect("Lasagne".fuzzyScore(query: "pizza") == 0)
        #expect("Soup".fuzzyScore(query: "cake") == 0)
        // Too short to tell a typo from a different word.
        #expect("Rice".fuzzyScore(query: "ice") > 0) // substring, not a typo
        #expect("Rice".fuzzyScore(query: "elk") == 0)
    }

    @Test func findsAWordFromTheMiddleOfALongImportedName() {
        // The reported case: a part-typed word, inside a compound name, in the
        // middle of a title an importer produced.
        let dish = Dish(name: "Bratnudeln mit Teriyaki-Hühnchen")
        #expect(dish.name.fuzzyScore(query: "Teriya") > 0)
        #expect(DishSearch.rank([dish], query: "Teriya").count == 1)
        #expect(DishSearch.rank([dish], query: "Hühnchen").count == 1)
        #expect(DishSearch.rank([dish], query: "huhnchen").count == 1)
    }

    @Test func matchesWordsInAnyOrder() {
        #expect("Red onion soup".fuzzyScore(query: "onion red") > 0)
        #expect("Red onion soup".fuzzyScore(query: "soup onion") > 0)
        // But every word typed still has to land somewhere.
        #expect("Red onion soup".fuzzyScore(query: "onion pizza") == 0)
    }

    @Test func stillMatchesLettersTypedAcrossWordBoundaries() {
        #expect("Spaghetti Bolognese".fuzzyScore(query: "spagbol") > 0)
    }

    @Test func rankingPutsTheCloserNameFirst() {
        let scores = ["Lasagne", "Vegetarian lasagne", "Lasagne al forno"]
            .map { $0.fuzzyScore(query: "lasagne") }
        #expect(scores[0] > scores[1])
        #expect(scores[2] > scores[1])
    }

    // MARK: - Ranking dishes

    @Test func nameMatchesOutrankIngredientMatches() {
        let soup = Dish(name: "Onion soup")
        let steak = dish(named: "Steak", ingredients: ["Onion", "Butter"])

        let results = DishSearch.rank([steak, soup], query: "onion")
        #expect(results.map(\.dish.name) == ["Onion soup", "Steak"])
        // A name match needs no explanation; an ingredient match does.
        #expect(results[0].reason == nil)
        #expect(results[1].reason?.contains("Onion") == true)
    }

    @Test func findsDishesByAMisspelledIngredient() {
        let bake = dish(named: "Summer bake", ingredients: ["Zucchini", "Feta"])
        let results = DishSearch.rank([bake], query: "zuchini")
        #expect(results.count == 1)
        #expect(results[0].reason?.contains("Zucchini") == true)
    }

    @Test func explainsTagAndRecipeMatches() {
        let curry = Dish(name: "Chickpea curry")
        curry.tagNames = ["Vegan"]
        curry.recipeText = "Toast the cumin seeds before adding the tomatoes."

        let byTag = DishSearch.rank([curry], query: "vegan")
        #expect(byTag.first?.reason == "Vegan")

        let byMethod = DishSearch.rank([curry], query: "cumin seeds")
        #expect(byMethod.count == 1)
        #expect(byMethod.first?.reason?.isEmpty == false)
    }

    @Test func leavesOutDishesThatMatchNothing() {
        let soup = dish(named: "Onion soup", ingredients: ["Onion"])
        #expect(DishSearch.rank([soup], query: "chocolate").isEmpty)
    }

    @Test func anEmptyQueryKeepsTheOrderItWasGiven() {
        let dishes = [Dish(name: "B"), Dish(name: "A")]
        let results = DishSearch.rank(dishes, query: "  ", limit: 5)
        #expect(results.map(\.dish.name) == ["B", "A"])
        #expect(results.allSatisfy { $0.reason == nil })
    }

    @Test func honoursTheResultLimit() {
        let dishes = (1...20).map { Dish(name: "Soup \($0)") }
        #expect(DishSearch.rank(dishes, query: "soup", limit: 4).count == 4)
    }

    // MARK: - Deciding whether to create a new dish

    @Test func exactMatchIgnoresCaseAccentsAndPadding() {
        let dishes = [Dish(name: "Käsespätzle")]
        #expect(DishSearch.hasExactMatch(dishes, name: "  kasespatzle "))
        #expect(DishSearch.exactMatch(dishes, name: "KÄSESPÄTZLE")?.name == "Käsespätzle")
        // A near miss is a new dish, not the old one.
        #expect(DishSearch.exactMatch(dishes, name: "Käsespätzle mit Zwiebeln") == nil)
        #expect(DishSearch.exactMatch(dishes, name: "   ") == nil)
    }

    // MARK: - Helpers

    private func dish(named name: String, ingredients: [String]) -> Dish {
        let dish = Dish(name: name)
        dish.ingredients = ingredients.enumerated().map { index, ingredientName in
            let line = DishIngredient(sortIndex: index)
            line.ingredient = Ingredient(name: ingredientName)
            line.dish = dish
            return line
        }
        return dish
    }
}
