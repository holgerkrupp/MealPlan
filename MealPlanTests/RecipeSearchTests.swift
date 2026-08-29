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
