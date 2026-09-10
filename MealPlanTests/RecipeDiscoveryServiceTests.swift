import Foundation
import Testing
@testable import MealPlan

struct RecipeDiscoveryServiceTests {
    @Test func catalogContainsTheRequestedPublicSources() {
        #expect(Set(RecipeDiscoveryService.sources.map(\.siteURL.host)) == [
            "www.themealdb.com",
            "openstove.org",
            "publicdomainrecipes.com",
        ])
    }

    @Test func parsesOpenStoveCards() {
        let html = """
        <a class="card" href="/recipes/australian-damper">
          <img src="https://images.example/damper.avif" alt="Damper">
          <h3>Australian damper</h3>
          <p>Bush bread that&#39;s simple to make.</p>
          <span>Australian</span><span>Bread</span>
        </a>
        <a href="/recipes/saved"><h3>Saved recipes</h3></a>
        """

        let articles = RecipeDiscoveryHTMLParser.openStoveArticles(
            in: Data(html.utf8),
            baseURL: URL(string: "https://openstove.org")!
        )

        #expect(articles.count == 1)
        #expect(articles[0].title == "Australian damper")
        #expect(articles[0].summary == "Bush bread that's simple to make.")
        #expect(articles[0].url.absoluteString == "https://openstove.org/recipes/australian-damper")
        #expect(articles[0].imageURL?.absoluteString == "https://images.example/damper.avif")
        #expect(articles[0].categories == ["Australian", "Bread"])
    }

    @Test func parsesPublicDomainRecipeTags() {
        let html = """
        <li data-tags="[dessert cookies sweet]">
          <a href="https://publicdomainrecipes.com/cookies/">Chocolate Cookies</a>
        </li>
        <li><a href="/about/">About</a></li>
        """

        let articles = RecipeDiscoveryHTMLParser.publicDomainArticles(
            in: Data(html.utf8),
            baseURL: URL(string: "https://publicdomainrecipes.com")!
        )

        #expect(articles.count == 1)
        #expect(articles[0].title == "Chocolate Cookies")
        #expect(articles[0].url.absoluteString == "https://publicdomainrecipes.com/cookies/")
        #expect(articles[0].categories == ["dessert", "cookies", "sweet"])
    }

    @Test func parsesAndDeduplicatesMealDBCards() {
        let html = """
        <a href='/meal/52772-teriyaki-chicken-recipe'><img src='https://images.example/chicken.jpg'/>Teriyaki Chicken</a>
        <a href='/meal/52772-teriyaki-chicken-recipe'>Teriyaki Chicken</a>
        <a href='/ingredient/1-chicken'>Chicken</a>
        """

        let articles = RecipeDiscoveryHTMLParser.mealDBArticles(
            in: Data(html.utf8),
            baseURL: URL(string: "https://www.themealdb.com")!
        )

        #expect(articles.count == 1)
        #expect(articles[0].title == "Teriyaki Chicken")
        #expect(articles[0].url.absoluteString == "https://www.themealdb.com/meal/52772-teriyaki-chicken-recipe")
        #expect(articles[0].imageURL?.absoluteString == "https://images.example/chicken.jpg")
    }
}
