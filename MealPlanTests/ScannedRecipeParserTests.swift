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

    // MARK: - Pasted text

    @Test func keepsTheIntroAndStripsBullets() {
        let draft = ScannedRecipeParser.parse("""
        Lemon Pasta
        A quick weeknight dinner. Serves 2.
        Ingredients (serves 2)
        • 200 g spaghetti
        - 1 lemon
        Method
        1. Boil the pasta.
        2. Toss with lemon.
        """)
        #expect(draft.name == "Lemon Pasta")
        #expect(draft.ingredientLines == ["200 g spaghetti", "1 lemon"])
        #expect(draft.instructions == "A quick weeknight dinner. Serves 2.\n1. Boil the pasta.\n2. Toss with lemon.")
    }

    @Test func methodBeforeIngredientsDoesNotSwallowThem() {
        let draft = ScannedRecipeParser.parse("""
        Salad
        Zubereitung
        Alles mischen.
        Zutaten für 2 Personen
        1 Gurke
        2 Tomaten
        """)
        #expect(draft.ingredientLines == ["1 Gurke", "2 Tomaten"])
        #expect(draft.instructions == "Alles mischen.")
    }

    @Test func numberedStepsAreNotMistakenForIngredients() {
        let draft = ScannedRecipeParser.parse("""
        Toast
        • 2 slices bread
        • butter
        1. Toast the bread.
        2. Spread the butter.
        """)
        #expect(draft.ingredientLines == ["2 slices bread", "butter"])
        #expect(draft.instructions == "1. Toast the bread.\n2. Spread the butter.")
    }

    @Test func sharedTextKeepsEverythingWhenNothingCanBeSplit() {
        let recipe = ScannedRecipeParser.importedRecipe(fromText: "Grandma's stew\nBrown the beef.\nSimmer for hours.")
        #expect(recipe.name == "Grandma's stew")
        #expect(recipe.ingredientLines.isEmpty)
        #expect(recipe.instructions == "Brown the beef.\nSimmer for hours.")
        #expect(recipe.needsReview)
    }

    @Test func preservingOriginalRestoresAnEmptyDraft() {
        let text = "Some note about a recipe\nwith two lines"
        let empty = ScannedRecipeDraft(name: "Recipe", ingredientLines: [], instructions: "")
        #expect(empty.preservingOriginal(text).instructions == text)

        let filled = ScannedRecipeDraft(name: "Recipe", ingredientLines: ["1 egg"], instructions: "")
        #expect(filled.preservingOriginal(text) == filled)
    }
}
