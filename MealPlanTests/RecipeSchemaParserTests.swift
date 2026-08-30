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

    @Test func resolvesKptnCookSharePageToItsRecipePage() {
        let shortURL = URL(string: "https://share.kptncook.com/Dh4a/c1qxclti")!
        let landingPage = "var mac_redirect = 'https://mobile.kptncook.com/recipe/pinterest/Bratnudeln-mit-Teriyaki-H%C3%BChnchen/66de50bf';"

        #expect(
            RecipeSchemaParser.kptnCookDestination(in: landingPage, from: shortURL)?.absoluteString
                == "https://mobile.kptncook.com/recipe/pinterest/Bratnudeln-mit-Teriyaki-H%C3%BChnchen/66de50bf"
        )
    }

    @Test func parsesKptnCookRecipeContent() {
        let source = URL(string: "https://mobile.kptncook.com/recipe/pinterest/test/123")!
        let html = """
        <body itemscope itemtype="http://schema.org/Recipe">
          <img itemprop="image" src="https://images.kptncook.com/test.jpg">
          <div class="kptn-recipetitle">Bratnudeln mit Teriyaki-Hühnchen</div>
          <span itemprop="totalTime">PT30M</span>
          <span itemprop="recipeYield">Für 2 Portionen</span>
          <span itemprop="ingredients">250 g Hühnerbrustfilets</span>
          <span itemprop="ingredients">160 g Mie-Nudeln</span>
          <div class="row kptn-step-title"><div><span>1. </span>Alles parat?</div></div>
          <div class="row kptn-step-title"><div><span>2. </span>Backofen vorheizen.</div></div>
          <script>navigator.clipboard.writeText("https://mobile.kptncook.com/r/123?lang=de")</script>
        </body>
        """

        let recipe = parser.parseKptnCook(html: html, sourceURL: source)
        #expect(recipe?.name == "Bratnudeln mit Teriyaki-Hühnchen")
        #expect(recipe?.sourceURL == source)
        #expect(recipe?.ingredientLines == ["250 g Hühnerbrustfilets", "160 g Mie-Nudeln"])
        #expect(recipe?.instructions?.contains("Alles parat?") == true)
        #expect(recipe?.instructions?.contains("Backofen vorheizen.") == true)
        #expect(recipe?.servings == 2)
        #expect(recipe?.cookTimeMinutes == 30)
        #expect(recipe?.deepLinkURL?.absoluteString == "https://mobile.kptncook.com/r/123?lang=de")
        #expect(recipe?.importedSourceApp == "KptnCook")
        #expect(recipe?.needsReview == false)
    }

    @Test func parsesChefkochRenderedRecipeMarkup() {
        let html = """
        <html><head><title>Einfache Meat-Pie von KrimsKramsBlog</title></head><body>
          <div class="ds-quantity-control__label">Für <span class="ds-quantity-control__amount">2</span> Portionen</div>
          <div class="recipe-meta-property-group__value">20 Min.</div>
          <div class="recipe-meta-property-group__title">Arbeitszeit</div>
          <table class="ds-ingredients-table"><tbody>
            <tr class="ds-ingredients-table__tr"><td><div>500&nbsp;g</div></td><td><span>Hackfleisch</span></td></tr>
            <tr class="ds-ingredients-table__tr"><td><div>1</div></td><td><span>Zwiebel(n)</span></td></tr>
          </tbody></table>
          <span data-testid="recipe-instruction">Hackfleisch anbraten.</span>
          <span data-testid="recipe-instruction">Zwiebel dazugeben.</span>
        </body></html>
        """
        let recipe = parser.parseChefkoch(html: html, sourceURL: url)

        #expect(recipe?.name == "Einfache Meat-Pie von KrimsKramsBlog")
        #expect(recipe?.ingredientLines == ["500 g Hackfleisch", "1 Zwiebel(n)"])
        #expect(recipe?.instructions?.contains("1. Hackfleisch anbraten.") == true)
        #expect(recipe?.instructions?.contains("2. Zwiebel dazugeben.") == true)
        #expect(recipe?.servings == 2)
        #expect(recipe?.prepTimeMinutes == 20)
        #expect(recipe?.needsReview == false)
    }

    @Test func genericHTMLFallbackFindsIngredientAndInstructionLists() {
        let genericURL = URL(string: "https://recipes.example.test/chili")!
        let html = """
        <html><head><title>Weeknight Chili</title></head><body>
          <section class="recipe-ingredients"><ul>
            <li class="recipe-ingredient">400 g Bohnen</li>
            <li class="recipe-ingredient">1 Zwiebel</li>
          </ul></section>
          <section class="recipe-instructions"><ol>
            <li class="recipe-instruction">Zwiebel anbraten.</li>
            <li class="recipe-instruction">Bohnen dazugeben.</li>
          </ol></section>
        </body></html>
        """
        let recipe = parser.parseGenericHTML(html: html, sourceURL: genericURL)

        #expect(recipe?.name == "Weeknight Chili")
        #expect(recipe?.ingredientLines == ["400 g Bohnen", "1 Zwiebel"])
        #expect(recipe?.instructions?.contains("Zwiebel anbraten.") == true)
        #expect(recipe?.instructions?.contains("Bohnen dazugeben.") == true)
        #expect(recipe?.needsReview == true)
    }

    // MARK: - Tags

    @Test func keywordsAndCategoriesBecomeTags() {
        let tags = RecipeSchemaParser.tagList([
            "vegan, weeknight , 30 minutes",
            "Hauptgericht",
            ["Italian"],
            "https://schema.org/VegetarianDiet"
        ])
        #expect(tags == ["vegan", "weeknight", "30 minutes", "Hauptgericht", "Italian", "Vegetarian"])
    }

    @Test func tagListDropsNoiseAndStaysShort() {
        // Duplicates in any spelling, one-character scraps and essay-length
        // "keywords" are not tags.
        let tags = RecipeSchemaParser.tagList([
            "Vegan, vegan, v, \(String(repeating: "long ", count: 10))",
            "a, b, c, d, e, f, g, h"
        ])
        #expect(tags == ["Vegan"])
    }
}
