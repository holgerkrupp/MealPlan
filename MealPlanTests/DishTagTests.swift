import Testing
import Foundation
@testable import MealPlan

// MARK: - Vocabulary and normalization

@MainActor
struct DishTagTests {

    @Test func cleaningTrimsHashesWhitespaceAndTooShortInput() {
        #expect(DishTag.clean("  #Short   prepwork ") == "Short prepwork")
        #expect(DishTag.clean("") == "")
        #expect(DishTag.clean("a") == "")
        #expect(DishTag.clean(String(repeating: "x", count: 80)).count == DishTag.maxLength)
    }

    @Test func tagsCompareCaseAndDiacriticInsensitively() {
        #expect(DishTag.areSame("Vegan", "vegan"))
        #expect(DishTag.areSame("Gemüse", "gemuse"))
        #expect(!DishTag.areSame("Vegan", "Vegetarian"))
        #expect(!DishTag.areSame("", ""))
    }

    @Test func mergingKeepsTheFirstSpellingAndDropsDuplicates() {
        #expect(DishTag.merge(["Vegan", "vegan", "VEGAN"]) == ["Vegan"])
        #expect(DishTag.merge(["Pork"], adding: ["pork", "Quick"]) == ["Pork", "Quick"])
        #expect(DishTag.merge(["Beef", "Apple"]) == ["Apple", "Beef"])
    }

    @Test func removingIgnoresSpelling() {
        #expect(DishTag.removing("VEGAN", from: ["Vegan", "Pork"]) == ["Pork"])
    }

    @Test func vocabularyPrefersTheMostUsedSpelling() {
        let a = Dish(name: "A"); a.tagNames = ["vegan"]
        let b = Dish(name: "B"); b.tagNames = ["vegan", "Pork"]
        let c = Dish(name: "C"); c.tagNames = ["Vegan"]
        #expect(DishTag.vocabulary(from: [a, b, c]) == ["Pork", "vegan"])
    }

    @Test func mostUsedRanksByHowManyDishesCarryTheTag() {
        let a = Dish(name: "A"); a.tagNames = ["Vegan", "Soup"]
        let b = Dish(name: "B"); b.tagNames = ["Vegan", "Pork"]
        let c = Dish(name: "C"); c.tagNames = ["vegan"]
        // Vegan is on three dishes; Pork and Soup tie on one and go A–Z.
        #expect(DishTag.mostUsed(from: [a, b, c]) == ["Vegan", "Pork", "Soup"])
        #expect(DishTag.mostUsed(from: [a, b, c], limit: 1) == ["Vegan"])
        #expect(DishTag.usage(from: [a, b, c]).first?.count == 3)
    }

    @Test func aTagRepeatedOnOneDishCountsOnce() {
        let dish = Dish(name: "A"); dish.tagNames = ["Vegan", "vegan"]
        #expect(DishTag.usage(from: [dish]).first?.count == 1)
    }

    @Test func dishTagHelpersAreSpellingInsensitive() {
        let dish = Dish(name: "Chili")
        dish.addTag("Spicy")
        dish.addTag("spicy")
        #expect(dish.tagNames == ["Spicy"])
        #expect(dish.hasTag("SPICY"))
        dish.removeTag("spicy")
        #expect(dish.tagNames.isEmpty)
    }

    // MARK: - Autocomplete

    @Test func completionsRankPrefixMatchesFirst() {
        let vocabulary = ["Vegan", "Vegetarian", "Prepwork", "Short prepwork", "Pork"]
        #expect(DishTag.completions(for: "veg", in: vocabulary) == ["Vegan", "Vegetarian"])
        // "Prepwork" starts with what was typed; "Short prepwork" only
        // contains it, so it follows.
        #expect(DishTag.completions(for: "prep", in: vocabulary) == ["Prepwork", "Short prepwork"])
    }

    @Test func completionsSkipWhatTheDishAlreadyHas() {
        let vocabulary = ["Vegan", "Vegetarian"]
        #expect(DishTag.completions(for: "veg", in: vocabulary, excluding: ["vegan"]) == ["Vegetarian"])
    }

    @Test func typingSomethingNewIsOfferedAsACreation() {
        #expect(DishTag.isNew("Taco night", in: ["Vegan"]))
        #expect(!DishTag.isNew("vegan", in: ["Vegan"]))
        #expect(!DishTag.isNew("  ", in: []))
    }

    @Test func canonicalReusesTheHouseholdSpelling() {
        #expect(DishTag.canonical("VEGAN", in: ["Vegan"]) == "Vegan")
        #expect(DishTag.canonical("Grill", in: ["Vegan"]) == "Grill")
    }
}

// MARK: - Automatic suggestions

struct DishTagSuggesterTests {

    @Test func namesTheMeatInADish() {
        #expect(DishTagSuggester.suggestions(for: "Schweinebraten").contains("Pork"))
        #expect(DishTagSuggester.suggestions(for: "Chicken Curry").contains("Poultry"))
        #expect(DishTagSuggester.suggestions(for: "Lachsfilet").contains("Fish"))
        #expect(DishTagSuggester.suggestions(for: "Spaghetti Bolognese", ingredientNames: ["Hackfleisch", "Tomaten", "Zwiebel"])
            .contains("Beef"))
    }

    @Test func tagsTheStyleOfTheDish() {
        #expect(DishTagSuggester.suggestions(for: "Kürbissuppe").contains("Soup"))
        #expect(DishTagSuggester.suggestions(for: "Nudelauflauf").contains("Pasta"))
        #expect(DishTagSuggester.suggestions(for: "Apfelkuchen").contains("Baking"))
    }

    @Test func vegetarianAndVeganComeFromTheIngredients() {
        let vegan = DishTagSuggester.suggestions(
            for: "Linseneintopf",
            ingredientNames: ["Linsen", "Karotten", "Zwiebel", "Gemüsebrühe"]
        )
        #expect(vegan.contains("Vegan"))
        #expect(vegan.contains("Vegetarian"))

        let vegetarian = DishTagSuggester.suggestions(
            for: "Käsespätzle",
            ingredientNames: ["Spätzle", "Bergkäse", "Zwiebel", "Butter"]
        )
        #expect(vegetarian.contains("Vegetarian"))
        #expect(!vegetarian.contains("Vegan"))
    }

    @Test func aSingleEggIsEnoughToRuleOutVegan() {
        // "Ei" is two letters, so it only counts as a whole word — but it has
        // to count, or half of German baking would come out vegan.
        let tags = DishTagSuggester.suggestions(
            for: "Pfannkuchen", ingredientNames: ["Mehl", "1 Ei", "Milch", "Zucker"]
        )
        #expect(tags.contains("Vegetarian"))
        #expect(!tags.contains("Vegan"))
    }

    @Test func meatKeepsBothDietTagsAway() {
        let tags = DishTagSuggester.suggestions(
            for: "Gulasch", ingredientNames: ["Rindfleisch", "Zwiebeln", "Paprika", "Tomatenmark"]
        )
        #expect(!tags.contains("Vegetarian"))
        #expect(!tags.contains("Vegan"))
        #expect(tags.contains("Beef"))
    }

    @Test func aBareNameIsNotAssumedVegetarian() {
        // Nothing says there's meat in it because nothing says anything.
        #expect(!DishTagSuggester.suggestions(for: "Omas Rezept").contains("Vegetarian"))
        #expect(DishTagSuggester.suggestions(for: "Omas Rezept").isEmpty)
    }

    @Test func aClaimInTheTitleIsTakenAtFaceValue() {
        #expect(DishTagSuggester.suggestions(for: "Veganes Chili").contains("Vegan"))
        #expect(DishTagSuggester.suggestions(for: "Vegetarian Lasagne").contains("Vegetarian"))
    }

    @Test func timeBecomesAnEffortTag() {
        #expect(DishTagSuggester.suggestions(for: "Rührei", totalMinutes: 10).contains("Short prepwork"))
        #expect(DishTagSuggester.suggestions(for: "Schmorbraten", totalMinutes: 180).contains("Takes a while"))
        #expect(!DishTagSuggester.suggestions(for: "Rührei", totalMinutes: 60).contains("Short prepwork"))
    }

    @Test func suggestionsReuseTheHouseholdsOwnWords() {
        let tags = DishTagSuggester.suggestions(
            for: "Schweinebraten", existingVocabulary: ["Schweinefleisch", "Grillen"]
        )
        #expect(tags.contains("Schweinefleisch"))
        #expect(!tags.contains("Pork"))
    }

    @Test func suggestionsStayAHandful() {
        let tags = DishTagSuggester.suggestions(
            for: "Scharfe vegane Nudelsuppe mit Auflauf vom Grill",
            ingredientNames: ["Nudeln", "Chili", "Gemüsebrühe", "Tomaten"],
            totalMinutes: 20
        )
        #expect(tags.count <= 6)
        #expect(Set(tags).count == tags.count)
    }
}

// MARK: - Filtering

@MainActor
struct DishTagFilterTests {

    private func dish(_ name: String, tags: [String]) -> Dish {
        let dish = Dish(name: name)
        dish.tagNames = tags
        return dish
    }

    @Test func filteringByTagIgnoresSpelling() {
        let vegan = dish("Linseneintopf", tags: ["Vegan", "Soup"])
        let pork = dish("Schweinebraten", tags: ["Pork"])

        var filter = DishFilter()
        filter.tags = ["vegan"]
        #expect(filter.apply(to: [vegan, pork]) == [vegan])
    }

    @Test func severalTagsNarrowTheList() {
        let quickVegan = dish("Salat", tags: ["Vegan", "Short prepwork"])
        let slowVegan = dish("Eintopf", tags: ["Vegan"])

        var filter = DishFilter()
        filter.tags = ["Vegan", "Short prepwork"]
        #expect(filter.apply(to: [quickVegan, slowVegan]) == [quickVegan])
    }

    @Test func togglingATagAddsThenRemovesIt() {
        var filter = DishFilter()
        #expect(!filter.isActive)
        filter.toggle(tag: "Vegan")
        #expect(filter.isSelected(tag: "vegan"))
        #expect(filter.isActive)
        filter.toggle(tag: "VEGAN")
        #expect(filter.tags.isEmpty)
        #expect(!filter.isActive)
    }

    @Test func tagsAreSearchable() {
        let dish = dish("Omas Rezept", tags: ["Short prepwork"])
        var filter = DishFilter()
        filter.searchText = "prepwork"
        #expect(filter.apply(to: [dish]) == [dish])
    }
}
