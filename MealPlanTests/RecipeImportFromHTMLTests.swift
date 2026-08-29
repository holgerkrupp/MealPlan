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
}
