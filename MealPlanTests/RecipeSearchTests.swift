import Testing
import Foundation
@testable import MealPlan

struct RecipeSearchTests {

    @Test func defaultsToEcosia() {
        #expect(SearchEngine.fallback == .ecosia)
        #expect(SearchEngine.resolved(from: "") == .ecosia)
        #expect(SearchEngine.resolved(from: "not-an-engine") == .ecosia)
        #expect(SearchEngine.resolved(from: "duckDuckGo") == .duckDuckGo)
    }

    @Test func buildsASearchURLPerEngine() throws {
        let ecosia = try #require(SearchEngine.ecosia.searchURL(for: "Pizza"))
        #expect(ecosia.absoluteString == "https://www.ecosia.org/search?q=Pizza")

        let ddg = try #require(SearchEngine.duckDuckGo.searchURL(for: "Pizza"))
        #expect(ddg.host() == "duckduckgo.com")

        // Every engine must produce a usable https URL.
        for engine in SearchEngine.allCases {
            let url = try #require(engine.searchURL(for: "Pizza"))
            #expect(url.scheme == "https")
        }
    }

    @Test func escapesCharactersThatWouldCorruptTheQuery() throws {
        // "&" and "+" survive `urlQueryAllowed`, and would truncate or corrupt
        // the search term once concatenated into the URL.
        let url = try #require(SearchEngine.ecosia.searchURL(for: "Salt & Pepper + Öl"))
        #expect(url.absoluteString.contains("%26"))
        #expect(url.absoluteString.contains("%2B"))
        #expect(url.absoluteString.contains("&q=") == false)

        // The escaped form still decodes back to what was typed.
        let value = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value)
        #expect(value == "Salt & Pepper + Öl")
    }

    @Test func emptyQueryProducesNoURL() {
        #expect(SearchEngine.ecosia.searchURL(for: "") == nil)
        #expect(SearchEngine.ecosia.searchURL(for: "   ") == nil)
    }

    @Test func queryPairsTheDishNameWithTheWordRecipe() {
        let query = RecipeSearch.query(for: "Spaghetti Bolognese")
        #expect(query.hasPrefix("Spaghetti Bolognese "))
        #expect(query.count > "Spaghetti Bolognese ".count)
        // A nameless dish still searches for something.
        #expect(RecipeSearch.query(for: "   ").isEmpty == false)
    }

    @Test func searchURLForADishIsBuiltFromItsName() throws {
        let url = try #require(RecipeSearch.url(for: "Lasagne", engine: .ecosia))
        #expect(url.absoluteString.contains("Lasagne"))
    }
}

/// Discover's free-text web search (#176): what is sent, what may be
/// imported, and how a found page meets the library and the plan.
struct RecipeWebSearchTests {

    private let recipeWord = String(localized: "recipe")

    private func sentQuery(_ url: URL, engine: SearchEngine) -> String? {
        let name = engine == .startpage ? "query" : "q"
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    @Test func freeTextIsKeptAsTypedAndGainsTheWordRecipe() {
        #expect(RecipeSearch.query(forFreeText: "  neapolitanische Pizza ") == "neapolitanische Pizza \(recipeWord)")
        #expect(RecipeSearch.query(forFreeText: "") == nil)
        #expect(RecipeSearch.query(forFreeText: " \n ") == nil)
    }

    @Test func advancedSyntaxSurvives() {
        let typed = #""quick vegetarian curry" -coconut tofu+spinach & rice"#
        let query = RecipeSearch.query(forFreeText: typed)
        #expect(query == "\(typed) \(recipeWord)")
    }

    @Test func queriesThatAlreadyAskForRecipesAreNotPadded() {
        #expect(RecipeSearch.query(forFreeText: "Kürbissuppe Rezept") == "Kürbissuppe Rezept")
        #expect(RecipeSearch.query(forFreeText: "easy weeknight RECIPES") == "easy weeknight RECIPES")
        #expect(RecipeSearch.query(forFreeText: "Rezepte mit Pilzen") == "Rezepte mit Pilzen")
        #expect(RecipeSearch.query(forFreeText: "lasagne site:chefkoch.de") == "lasagne site:chefkoch.de")
    }

    @Test func everyEngineReceivesTheExactQuery() throws {
        let typed = #"Käsespätzle "mit Röstzwiebeln" -Speck & Salat + Öl #1 50%"#
        let expected = try #require(RecipeSearch.query(forFreeText: typed))
        for engine in SearchEngine.allCases {
            let url = try #require(RecipeSearch.url(forFreeText: typed, engine: engine))
            #expect(url.scheme == "https")
            #expect(sentQuery(url, engine: engine) == expected, "engine \(engine)")
            // A raw "+" would arrive as a space; a raw "#" would cut the query.
            #expect(!url.absoluteString.contains("+"))
            #expect(url.fragment == nil)
        }
        #expect(RecipeSearch.url(forFreeText: "   ", engine: .ecosia) == nil)
    }

    @Test func searchResultsPagesAreNotImportable() throws {
        let results = [
            "https://www.ecosia.org/search?q=pizza",
            "https://www.google.com/search?q=pizza",
            "https://www.google.de/search?q=pizza",
            "https://news.google.co.uk/",
            "https://duckduckgo.com/?q=pizza",
            "https://html.duckduckgo.com/html?q=pizza",
            "https://www.startpage.com/sp/search?query=pizza",
            "https://www.bing.com/search?q=pizza",
        ]
        for string in results {
            let url = try #require(URL(string: string))
            #expect(SearchEngine.isSearchResultsPage(url), "\(string)")
            #expect(SearchEngine.importableURL(url) == nil, "\(string)")
        }
    }

    @Test func realRecipePagesAnywhereAreImportable() throws {
        let pages = [
            "https://www.chefkoch.de/rezepte/123/pizza.html",
            "http://example.com/recipes/curry",
            "https://notbing.com/pizza",
            "https://googleplex-recipes.example/pizza",
        ]
        for string in pages {
            let url = try #require(URL(string: string))
            #expect(SearchEngine.importableURL(url) == url, "\(string)")
        }
        #expect(SearchEngine.importableURL(nil) == nil)
        #expect(SearchEngine.importableURL(URL(string: "about:blank")) == nil)
        #expect(SearchEngine.importableURL(URL(string: "file:///tmp/recipe.html")) == nil)
        #expect(SearchEngine.importableURL(URL(string: "data:text/html,hi")) == nil)
    }

    @Test func aFoundRecipeIsAttributedToTheVisitedPage() throws {
        let visited = try #require(URL(string: "https://example.com/curry?utm_source=x"))
        let unlinked = RecipeSearch.attributed(ImportedRecipe(name: "Curry"), to: visited)
        #expect(unlinked.sourceURL == visited)

        let blank = RecipeSearch.attributed(ImportedRecipe(name: "Curry", sourceURL: URL(string: "about:blank")), to: visited)
        #expect(blank.sourceURL == visited)

        let canonical = try #require(URL(string: "https://example.com/curry"))
        let linked = RecipeSearch.attributed(ImportedRecipe(name: "Curry", sourceURL: canonical), to: visited)
        #expect(linked.sourceURL == canonical)
    }

    @Test func linkOnlyRecipeIsNamedAndMarkedForReview() throws {
        let url = try #require(URL(string: "https://www.example.com/pizza"))
        let titled = RecipeSearch.linkOnlyRecipe(title: "  Pizza Napoletana ", url: url)
        #expect(titled.name == "Pizza Napoletana")
        #expect(titled.sourceURL == url)
        #expect(titled.needsReview)
        #expect(RecipeSearch.linkOnlyRecipe(title: "", url: url).name == "example.com")
    }

    /// Trying the same page twice must find the dish saved the first time,
    /// even when the second visit arrives with tracking parameters.
    @MainActor
    @Test func theSamePageTriedTwiceIsADuplicate() throws {
        let existing = Dish(name: "Pizza Napoletana")
        existing.sourceURL = URL(string: "https://example.com/pizza/")
        let visited = try #require(URL(string: "https://example.com/pizza?utm_campaign=search#recipe"))
        let again = RecipeSearch.attributed(ImportedRecipe(name: "Neapolitan pizza"), to: visited)

        let plan = RecipeImportPlanner.plan([again], against: [existing])
        #expect(plan.count == 1)
        #expect(plan[0].include == false)
        #expect(plan[0].outcome == .duplicate(DishReferenceInfo(uuid: existing.uuid, name: existing.name)))
    }

    @Test func planningContextIsADayAndAMeal() throws {
        let afternoon = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 15)))
        let context = RecipePlanningContext(date: afternoon, mealKey: "dinner")
        #expect(context.date == Calendar.current.startOfDay(for: afternoon))
        #expect(context == RecipePlanningContext(date: afternoon.addingTimeInterval(3600), mealKey: "dinner"))
        #expect(context != RecipePlanningContext(date: afternoon, mealKey: MealType.extraKey))
    }

    /// The Mac opens the search in its own window, so the route — context
    /// included — must survive state restoration.
    @Test func webSearchRouteRoundTrips() throws {
        let context = RecipePlanningContext(date: .now, mealKey: MealType.extraKey)
        for route in [
            DetailWindowRoute.searchWeb(query: "Pilz Risotto", planningContext: context),
            DetailWindowRoute.searchWeb(query: "curry", planningContext: nil),
        ] {
            let data = try JSONEncoder().encode(route)
            #expect(try JSONDecoder().decode(DetailWindowRoute.self, from: data) == route)
        }
    }
}
