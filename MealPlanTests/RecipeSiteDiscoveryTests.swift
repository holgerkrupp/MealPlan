import Foundation
import Testing
@testable import MealPlan

struct RecipeSiteDiscoveryTests {
    @Test func individualRecipePageIsRecipe() {
        let html = """
        <script type="application/ld+json">{"@type":"Recipe","name":"Soup","recipeIngredient":["1 onion"],"recipeInstructions":"Cook it"}</script>
        """
        let kind = RecipeSiteDiscoveryService.classifyHTML(Data(html.utf8), sourceURL: URL(string: "https://example.com/recipes/soup")!)
        guard case .recipe(let candidate) = kind else { Issue.record("Expected recipe, got \(kind)"); return }
        #expect(candidate.title == "Soup")
    }

    @Test func homepageWithFeedIsRecipeSite() {
        let html = """
        <title>Kitchen</title><link rel="canonical" href="https://example.com/">
        <link rel="alternate" type="application/rss+xml" title="Recipes" href="/feed.xml">
        <a href="/recipes/soup">Soup</a><a href="/recipes/cake">Cake</a>
        """
        let kind = RecipeSiteDiscoveryService.classifyHTML(Data(html.utf8), sourceURL: URL(string: "https://example.com/")!)
        guard case .recipeSite(let candidate) = kind else { Issue.record("Expected site, got \(kind)"); return }
        #expect(candidate.feedURL?.absoluteString == "https://example.com/feed.xml")
        #expect(candidate.siteURL.absoluteString == "https://example.com/")
    }

    @Test func categoryPageWithoutFeedIsRecipeSite() {
        let html = #"<div itemtype="https://schema.org/ItemList"><a href="/recipes/soup">Soup</a><a href="/recipes/cake">Cake</a></div>"#
        let kind = RecipeSiteDiscoveryService.classifyHTML(Data(html.utf8), sourceURL: URL(string: "https://example.com/category/weeknight")!)
        guard case .recipeSite(let candidate) = kind else { Issue.record("Expected site, got \(kind)"); return }
        #expect(candidate.sourceKind == .websiteDiscovery)
        #expect(candidate.feedURL == nil)
    }

    @Test func feedContentIsFeed() {
        let url = URL(string: "https://example.com/feed.xml")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/rss+xml"])!
        let kind = RecipeSiteDiscoveryService.classifyHTML(Data("<rss/>".utf8), response: response, sourceURL: url)
        guard case .feed(let feed) = kind else { Issue.record("Expected feed, got \(kind)"); return }
        #expect(feed.feedURL == url)
    }

    @Test func itemListAndRecipePreferSite() {
        let html = #"<script type="application/ld+json">{"@type":"Recipe","name":"Featured","recipeIngredient":["flour"]}</script><div itemtype="https://schema.org/ItemList"><a href="/recipes/a">A</a><a href="/recipes/b">B</a></div>"#
        let kind = RecipeSiteDiscoveryService.classifyHTML(Data(html.utf8), sourceURL: URL(string: "https://example.com/")!)
        guard case .recipeSite = kind else { Issue.record("ItemList must win over Recipe snippet"); return }
    }

    @Test func chefkochIndividualAndDiscoveryURLsDiffer() async {
        let provider = ChefkochDiscoveryProvider()
        let discovery = try? await provider.subscriptionCandidates(for: URL(string: "https://www.chefkoch.de/rezepte/was-koche-ich-heute/")!)
        #expect(discovery?.contains(where: { $0.providerID == "chefkoch" }) == true)
        let recipe = try? await provider.subscriptionCandidates(for: URL(string: "https://www.chefkoch.de/rezepte/12345/suppe.html")!)
        #expect(recipe?.isEmpty == true)
    }

    @Test func canonicalizationNormalizesHostAndRootPath() {
        let url = RecipeSiteDiscoveryService.canonicalize(URL(string: "HTTPS://Example.COM")!)
        #expect(url.absoluteString == "https://example.com/")
    }
}
