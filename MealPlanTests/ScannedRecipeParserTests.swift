import Testing
@testable import MealPlan

struct ScannedRecipeParserTests {
    @Test func emptyInputProducesAnEmptyDraft() async {
        let draft = await RecipeExtractor.extract(from: "  \n\t")

        #expect(draft == ScannedRecipeDraft(name: "", ingredientLines: [], instructions: ""))
    }

    @Test func parsesGermanHeadings() {
        let draft = ScannedRecipeParser.parse("""
        Kartoffelsuppe
        Zutaten
        500 g Kartoffeln
        1 Zwiebel
        Zubereitung
        Alles schneiden.
        20 min kochen.
        """)
        #expect(draft.name == "Kartoffelsuppe")
        #expect(draft.ingredientLines == ["500 g Kartoffeln", "1 Zwiebel"])
        #expect(draft.instructions == "Alles schneiden.\n20 min kochen.")
    }

    @Test func acceptsPunctuatedEnglishHeadings() {
        let draft = ScannedRecipeParser.parse("""
        Tomato soup
        Ingredients:
        400 g tomatoes
        1 onion
        Directions:
        Cook until soft.
        Blend until smooth.
        """)

        #expect(draft.name == "Tomato soup")
        #expect(draft.ingredientLines == ["400 g tomatoes", "1 onion"])
        #expect(draft.instructions == "Cook until soft.\nBlend until smooth.")
    }

    @Test func splitsHeadinglessPageByMeasurementLines() {
        let draft = ScannedRecipeParser.parse("""
        Pancakes
        200 g flour
        2 eggs
        300 ml milk
        1 pinch of salt
        Whisk everything into a smooth batter.
        Fry spoonfuls in a hot buttered pan until golden.
        """)
        #expect(draft.name == "Pancakes")
        #expect(draft.ingredientLines == ["200 g flour", "2 eggs", "300 ml milk", "1 pinch of salt"])
        #expect(draft.instructions == "Whisk everything into a smooth batter.\nFry spoonfuls in a hot buttered pan until golden.")
    }

    @Test func leavesProseAloneWhenNothingLooksLikeAList() {
        let draft = ScannedRecipeParser.parse("""
        Grandma's stew
        Brown the beef in a heavy pot.
        Add stock and simmer for two hours.
        """)
        #expect(draft.name == "Grandma's stew")
        #expect(draft.ingredientLines.isEmpty)
        #expect(draft.instructions == "Brown the beef in a heavy pot.\nAdd stock and simmer for two hours.")
    }
}
