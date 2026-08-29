import Testing
import Foundation
@testable import MealPlan

struct DishGlyphSuggesterTests {

    // MARK: - Naming

    @Test func matchesEnglishAndGermanDishNames() {
        #expect(DishGlyphSuggester.match(name: "Spaghetti Bolognese") == .emoji("🍝"))
        #expect(DishGlyphSuggester.match(name: "Pfannkuchen") == .emoji("🥞"))
        #expect(DishGlyphSuggester.match(name: "Chicken Curry") == .emoji("🍛"))
        #expect(DishGlyphSuggester.match(name: "Greek Salad") == .emoji("🥗"))
        #expect(DishGlyphSuggester.match(name: "Margherita Pizza") == .emoji("🍕"))
    }

    @Test func foldsCaseAndDiacritics() {
        #expect(DishGlyphSuggester.match(name: "KÜRBISSUPPE") == .emoji("🍲"))
        #expect(DishGlyphSuggester.match(name: "hähnchen") == .emoji("🍗"))
    }

    @Test func matchesInsideGermanCompounds() {
        // The dish word is glued to the front or back of a longer word.
        #expect(DishGlyphSuggester.match(name: "Nudelauflauf") == .emoji("🍝"))
        #expect(DishGlyphSuggester.match(name: "Kartoffelsuppe") == .emoji("🍲"))
        #expect(DishGlyphSuggester.match(name: "Lachsfilet mit Reis") == .emoji("🐟"))
    }

    @Test func ruleOrderDecidesWhenTwoKeywordsMatch() {
        // "Kürbissuppe" is a soup, not a pumpkin; "Kartoffelsalat" a salad,
        // not a potato. The whole-dish rules come first for exactly this.
        #expect(DishGlyphSuggester.match(name: "Kürbissuppe") == .emoji("🍲"))
        #expect(DishGlyphSuggester.match(name: "Kartoffelsalat") == .emoji("🥗"))
        #expect(DishGlyphSuggester.match(name: "Tomatensuppe") == .emoji("🍲"))
    }

    // MARK: - The short-keyword trap

    @Test func shortKeywordsDoNotMatchInsideWords() {
        // "Fleisch" and "Reis" both contain "eis" (ice cream); "Eierkuchen"
        // contains "kuchen" (cake). None of them should win on that.
        #expect(DishGlyphSuggester.match(name: "Fleisch") == .emoji("🥩"))
        #expect(DishGlyphSuggester.match(name: "Reis") == .emoji("🍚"))
        #expect(DishGlyphSuggester.match(name: "Eierkuchen") == .emoji("🥞"))
        #expect(DishGlyphSuggester.match(name: "Eis") == .emoji("🍦"))
    }

    @Test func twoCharacterKeywordsAreRejected() {
        #expect(DishGlyphSuggester.contains(" fleisch ", "ei") == false)
        #expect(DishGlyphSuggester.contains(" eis ", "eis"))
        #expect(DishGlyphSuggester.contains(" fleisch ", "eis") == false)
    }

    // MARK: - Tokenizing

    @Test func tokenizingStripsPunctuationAndPadsWords() {
        #expect(DishGlyphSuggester.tokenized("Spaghetti, Bolognese!") == " spaghetti bolognese ")
        #expect(DishGlyphSuggester.tokenized("   ") == "")
        #expect(DishGlyphSuggester.tokenized("") == "")
    }

    // MARK: - Fallbacks

    @Test func unmatchedNameFallsBackToIngredients() {
        let glyph = DishGlyphSuggester.suggestion(
            for: "Omas Sonntagsrezept",
            ingredientNames: ["Zwiebel", "Lachs", "Salz"]
        )
        #expect(glyph == .emoji("🐟"))
    }

    @Test func unmatchedNameAndIngredientsFallBackToMealType() {
        #expect(DishGlyphSuggester.suggestion(for: "Rezept", mealTypeTags: [.breakfast]) == .emoji("🥐"))
        #expect(DishGlyphSuggester.suggestion(for: "Rezept", mealTypeTags: [.snack]) == .emoji("🍎"))
        #expect(DishGlyphSuggester.suggestion(for: "Rezept", mealTypeTags: [.dinner]) == .emoji("🍽️"))
    }

    @Test func alwaysSuggestsSomething() {
        #expect(DishGlyphSuggester.suggestion(for: "") == .symbol("fork.knife"))
        #expect(DishGlyphSuggester.suggestion(for: "zzzz") == .symbol("fork.knife"))
    }

    // MARK: - Round-tripping through the model

    @Test func glyphRawRoundTrips() {
        #expect(DishGlyph(rawValue: DishGlyph.emoji("🍝").rawValue) == .emoji("🍝"))
        #expect(DishGlyph(rawValue: DishGlyph.symbol("carrot.fill").rawValue) == .symbol("carrot.fill"))
        #expect(DishGlyph(rawValue: "nonsense") == nil)
        #expect(DishGlyph(rawValue: "emoji:") == nil)
    }

    @Test func autoGlyphFollowsTheNameUntilTheUserChooses() {
        let dish = Dish(name: "Pizza Margherita")
        dish.refreshAutoGlyph()
        #expect(dish.glyph == .emoji("🍕"))

        // Renaming re-derives while the suggestion is still the app's.
        dish.name = "Gemüsesuppe"
        dish.refreshAutoGlyph()
        #expect(dish.glyph == .emoji("🍲"))

        // Once chosen by hand, nothing overwrites it.
        dish.setGlyphManually(.emoji("🥕"))
        dish.name = "Pizza Margherita"
        dish.refreshAutoGlyph()
        #expect(dish.glyph == .emoji("🥕"))
        #expect(dish.glyphIsAuto == false)
    }

    @Test func clearingIsAChoiceAndSticks() {
        let dish = Dish(name: "Pizza")
        dish.setGlyphManually(nil)
        dish.refreshAutoGlyph()
        #expect(dish.glyph == nil)
    }

    @Test func handingItBackReEnablesSuggestions() {
        let dish = Dish(name: "Pizza")
        dish.setGlyphManually(.emoji("🥕"))
        dish.glyphIsAuto = true
        dish.refreshAutoGlyph()
        #expect(dish.glyph == .emoji("🍕"))
    }

    @Test func emojiValidation() {
        #expect("🍝".isSingleEmoji)
        #expect("👨‍👩‍👧".isSingleEmoji)
        #expect("a".isSingleEmoji == false)
        #expect("🍝🍕".isSingleEmoji == false)
        #expect("".isSingleEmoji == false)
    }
}

struct PageImageExtractionTests {

    @Test func prefersOpenGraphThenTwitterThenLinkRel() {
        let html = """
        <html><head>
        <meta name="twitter:image" content="https://example.com/twitter.jpg">
        <meta property="og:image" content="https://example.com/og.jpg">
        <link rel="image_src" href="https://example.com/link.jpg">
        </head></html>
        """
        let found = RecipeSchemaParser.pageImageURLs(in: html)
        #expect(found.first == "https://example.com/og.jpg")
        #expect(found.contains("https://example.com/twitter.jpg"))
        #expect(found.contains("https://example.com/link.jpg"))
    }

    @Test func findsTwitterImageWhenOpenGraphIsMissing() {
        let html = #"<meta name="twitter:image:src" content="https://example.com/t.png">"#
        #expect(RecipeSchemaParser.pageImageURLs(in: html) == ["https://example.com/t.png"])
    }

    @Test func returnsNothingForAPageWithNoImages() {
        #expect(RecipeSchemaParser.pageImageURLs(in: "<html><body>Hi</body></html>").isEmpty)
    }
}
