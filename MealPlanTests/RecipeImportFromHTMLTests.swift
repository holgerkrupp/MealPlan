import Testing
import Foundation
@testable import MealPlan

/// Covers the path the in-app recipe finder uses: parse HTML the browser
/// already has on screen, rather than re-fetching the URL.
///
/// The fixtures deliberately carry no image tags, so nothing here touches the
/// network.
struct RecipeImportFromHTMLTests {

    private let source = URL(string: "https://example.com/rezepte/bolognese")!

    private let jsonLD = """
    <html><head>
    <script type="application/ld+json">
    {
      "@context": "https://schema.org",
      "@type": "Recipe",
      "name": "Spaghetti Bolognese",
      "recipeYield": "4",
      "prepTime": "PT15M",
      "cookTime": "PT45M",
      "recipeIngredient": ["500 g Hackfleisch", "1 Zwiebel", "400 g gehackte Tomaten"],
      "recipeInstructions": "Zwiebel anbraten. Hackfleisch dazu. Tomaten dazu und köcheln."
    }
    </script>
    </head><body></body></html>
    """

    @Test func parsesStructuredDataFromSuppliedHTML() async throws {
        let recipe = try await RecipeSchemaParser().importRecipe(fromHTML: jsonLD, sourceURL: source)

        #expect(recipe.name == "Spaghetti Bolognese")
        #expect(recipe.sourceURL == source)
        #expect(recipe.ingredientLines.count == 3)
        #expect(recipe.ingredientLines.contains("1 Zwiebel"))
        #expect(recipe.instructions?.contains("Zwiebel anbraten") == true)
        #expect(recipe.servings == 4)
        #expect(recipe.prepTimeMinutes == 15)
        #expect(recipe.cookTimeMinutes == 45)
    }

    @Test func fallsBackToTheHeuristicForAPageWithNoMarkup() async throws {
        let html = "<html><head><title>Omas Lasagne</title></head><body><p>Hi</p></body></html>"
        let recipe = try await RecipeSchemaParser().importRecipe(fromHTML: html, sourceURL: source)

        // Nothing structured to find, so the title carries the name and the
        // result is flagged for the cook to check.
        #expect(recipe.name.contains("Lasagne"))
        #expect(recipe.needsReview)
        #expect(recipe.ingredientLines.isEmpty)
    }

    @Test func aPageWithNothingUsableYieldsNoRecipeContent() async throws {
        let html = "<html><body>404</body></html>"
        let recipe = try await RecipeSchemaParser().importRecipe(fromHTML: html, sourceURL: source)

        // This is what the finder checks before offering to save: no
        // ingredients and no instructions means "no recipe on this page".
        #expect(recipe.ingredientLines.isEmpty)
        #expect((recipe.instructions ?? "").isEmpty)
    }

    @Test func ingredientLinesSurviveGermanQuantityParsing() {
        // The lines the import hands to the dish are parsed downstream; check
        // the pairing works end to end for a typical German line.
        let parsed = GermanUnitParser.parse("500 g Hackfleisch")
        #expect(parsed.name == "Hackfleisch")
        #expect(parsed.quantity?.value == 500)
    }

    @Test func semanticFallbackReadsEnglishRecipeSections() async throws {
        let html = """
        <article class="recipe-card">
          <h1>Weeknight Pasta</h1>
          <h2>Ingredients</h2>
          <ul><li>250 g pasta</li><li>Salt to taste</li></ul>
          <h2>Instructions</h2>
          <ol><li>Boil the pasta.</li><li>Season and serve.</li></ol>
        </article>
        """

        let recipe = try await RecipeSchemaParser().importRecipe(fromHTML: html, sourceURL: source)

        #expect(recipe.name == "Weeknight Pasta")
        #expect(recipe.ingredientLines == ["250 g pasta", "Salt to taste"])
        #expect(recipe.instructions?.contains("1. Boil the pasta.") == true)
        #expect(recipe.instructions?.contains("2. Season and serve.") == true)
        #expect(recipe.fieldEvidence["ingredients"]?.source == .semanticHTML)
        #expect(recipe.fieldEvidence["instructions"]?.source == .semanticHTML)
    }

    @Test func semanticFallbackSupportsGermanSubsectionsAndParagraphSteps() async throws {
        let html = """
        <main class="recipe">
          <h1>Linsensuppe</h1>
          <h2>Zutaten</h2>
          <h3>Für die Sauce</h3>
          <ul><li>1 Zwiebel</li><li>Salz</li></ul>
          <h2>Zubereitung</h2>
          <div><p>Zwiebel würfeln.</p><p>Alles in einem Topf kochen.</p></div>
        </main>
        """

        let recipe = try await RecipeSchemaParser().importRecipe(fromHTML: html, sourceURL: source)

        #expect(recipe.ingredientLines == ["1 Zwiebel", "Salz"])
        #expect(recipe.ingredientLines.contains("Für die Sauce") == false)
        #expect(recipe.instructions?.contains("1. Zwiebel würfeln.") == true)
        #expect(recipe.instructions?.contains("2. Alles in einem Topf kochen.") == true)
    }

    @Test func semanticFallbackIgnoresNavigationAndEmptyHeadings() async throws {
        let html = """
        <body>
          <nav><a href="#ingredients">Ingredients</a></nav>
          <article><h2>Ingredients</h2><h2>Directions</h2></article>
          <footer><h2>Ingredients</h2><ul><li>Newsletter</li></ul></footer>
        </body>
        """

        let recipe = try await RecipeSchemaParser().importRecipe(fromHTML: html, sourceURL: source)

        #expect(recipe.ingredientLines.isEmpty)
        #expect((recipe.instructions ?? "").isEmpty)
    }

    @Test func semanticFallbackRejectsPageChromeAroundRecipeCard() async throws {
        let html = """
        <body>
          <aside class="related-recipes"><h2>Ingredients</h2><ul><li>Click here to subscribe</li></ul></aside>
          <article class="recipe-card">
            <h1>Chili</h1><h2>Ingredients</h2>
            <ul><li>400 g beans</li><li>1 onion</li></ul>
            <h2>Method</h2><p>Stir the beans and simmer.</p>
          </article>
          <section class="comments"><h2>Instructions</h2><p>Leave a comment.</p></section>
        </body>
        """

        let recipe = try await RecipeSchemaParser().importRecipe(fromHTML: html, sourceURL: source)

        #expect(recipe.ingredientLines == ["400 g beans", "1 onion"])
        #expect(recipe.instructions == "1. Stir the beans and simmer.")
    }

    @Test func semanticFallbackAugmentsPlaceholderStructuredFields() async throws {
        let html = """
        <html><head><script type="application/ld+json">
        {"@type":"Recipe","name":"Rendered Stew","recipeIngredient":["Ingredients"],"recipeInstructions":"Directions"}
        </script></head><body>
          <article class="recipe-card"><h2>Ingredients</h2><ul><li>2 carrots</li><li>1 onion</li></ul>
          <h2>Directions</h2><ol><li>Chop the vegetables.</li><li>Simmer until tender.</li></ol></article>
        </body></html>
        """

        let recipe = try await RecipeSchemaParser().importRecipe(fromHTML: html, sourceURL: source)

        #expect(recipe.ingredientLines == ["2 carrots", "1 onion"])
        #expect(recipe.instructions?.contains("Chop the vegetables.") == true)
        #expect(recipe.fieldEvidence["ingredients"]?.source == .semanticHTML)
        #expect(recipe.fieldEvidence["instructions"]?.source == .semanticHTML)
    }

    @Test func credibleStructuredFieldsOutrankVisibleHeuristics() async throws {
        let html = """
        <html><head><script type="application/ld+json">
        {"@type":"Recipe","name":"Structured Soup","recipeIngredient":["500 g pumpkin"],"recipeInstructions":"Blend the pumpkin."}
        </script></head><body>
          <article class="recipe-card"><h2>Ingredients</h2><ul><li>1 onion</li></ul>
          <h2>Instructions</h2><ol><li>Fry the onion.</li></ol></article>
        </body></html>
        """

        let recipe = try await RecipeSchemaParser().importRecipe(fromHTML: html, sourceURL: source)

        #expect(recipe.ingredientLines == ["500 g pumpkin"])
        #expect(recipe.instructions == "Blend the pumpkin.")
        #expect(recipe.fieldEvidence["ingredients"]?.source == .jsonLD)
        #expect(recipe.fieldEvidence["instructions"]?.source == .jsonLD)
    }
}
