import Testing
import Foundation
@testable import MealPlan

struct RecipeSchemaParserTests {

    let parser = RecipeSchemaParser()
    let url = URL(string: "https://www.chefkoch.de/rezepte/123/Test.html")!

    @Test func extractsPlainJSONLDRecipe() {
        let html = """
        <html><head>
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"Recipe","name":"Kürbissuppe",
         "recipeYield":"4 Portionen",
         "prepTime":"PT15M","cookTime":"PT30M",
         "recipeIngredient":["500 g Kürbis","1 Zwiebel","200 ml Sahne"],
         "recipeInstructions":"Kürbis würfeln. Alles köcheln. Pürieren.",
         "image":"https://img.example/kuerbis.jpg"}
        </script></head><body></body></html>
        """
        let recipe = parser.parseJSONLD(html: html, sourceURL: url)
        #expect(recipe?.name == "Kürbissuppe")
        #expect(recipe?.servings == 4)
        #expect(recipe?.prepTimeMinutes == 15)
        #expect(recipe?.cookTimeMinutes == 30)
        #expect(recipe?.ingredientLines.count == 3)
        #expect(recipe?.imageURLString == "https://img.example/kuerbis.jpg")
        #expect(recipe?.needsReview == false)
    }

    @Test func findsRecipeInsideGraph() {
        let html = """
        <script type="application/ld+json">
        {"@context":"https://schema.org","@graph":[
          {"@type":"WebPage","name":"ignore"},
          {"@type":["Recipe","NewsArticle"],"name":"Pfannkuchen",
           "recipeIngredient":["250 g Mehl","3 Eier"],
           "recipeInstructions":[{"@type":"HowToStep","text":"Verrühren."},{"@type":"HowToStep","text":"Ausbacken."}]}
        ]}
        </script>
        """
        let recipe = parser.parseJSONLD(html: html, sourceURL: url)
        #expect(recipe?.name == "Pfannkuchen")
        #expect(recipe?.ingredientLines == ["250 g Mehl", "3 Eier"])
        #expect(recipe?.instructions?.contains("Verrühren") == true)
        #expect(recipe?.instructions?.contains("2.") == true)
    }

    @Test func imageObjectAndArrayShapes() {
        #expect(RecipeSchemaParser.imageURL(["https://a.jpg", "https://b.jpg"]) == "https://a.jpg")
        #expect(RecipeSchemaParser.imageURL(["url": "https://c.jpg"]) == "https://c.jpg")
        #expect(RecipeSchemaParser.imageURL(["@list": ["https://d.jpg"]]) == "https://d.jpg")
    }

    @Test func iso8601Durations() {
        #expect(RecipeSchemaParser.minutes("PT30M") == 30)
        #expect(RecipeSchemaParser.minutes("PT1H15M") == 75)
        #expect(RecipeSchemaParser.minutes("P0DT2H0M") == 120)
        #expect(RecipeSchemaParser.minutes("PT0S") == nil)
        #expect(RecipeSchemaParser.minutes(45 as NSNumber) == 45)
    }

    @Test func yieldParsing() {
        #expect(RecipeSchemaParser.servings("4 Portionen") == 4)
        #expect(RecipeSchemaParser.servings(6 as NSNumber) == 6)
        #expect(RecipeSchemaParser.servings(["2", "4"]) == 2)
    }

    @Test func microdataFallback() {
        let html = """
        <div itemscope itemtype="https://schema.org/Recipe">
          <h1 itemprop="name">Omelett</h1>
          <li itemprop="recipeIngredient">3 Eier</li>
          <li itemprop="recipeIngredient">Salz</li>
        </div>
        """
        let recipe = parser.parseMicrodata(html: html, sourceURL: url)
        #expect(recipe?.name == "Omelett")
        #expect(recipe?.ingredientLines.contains("3 Eier") == true)
        #expect(recipe?.needsReview == true)
    }

    @Test func heuristicUsesOgTitle() {
        let html = #"<html><head><meta property="og:title" content="Spaghetti Carbonara"><meta property="og:image" content="https://x/carb.jpg"></head></html>"#
        let recipe = parser.heuristic(html: html, sourceURL: url)
        #expect(recipe.name == "Spaghetti Carbonara")
        #expect(recipe.imageURLString == "https://x/carb.jpg")
        #expect(recipe.needsReview)
    }
}
