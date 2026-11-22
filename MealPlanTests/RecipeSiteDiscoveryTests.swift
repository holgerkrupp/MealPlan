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

    @Test func individualRecipeWithFeedAndRelatedLinksWins() {
        let html = """
        <html><head>
          <title>Neapolitanische Pizza</title>
          <link rel="alternate" type="application/rss+xml" title="Recipes" href="/feed.xml">
          <script type="application/ld+json">
          {"@type":"Recipe","name":"Neapolitanische Pizza",
           "recipeIngredient":["500 g flour","350 ml water"],
           "recipeInstructions":"Mix, proof and bake."}
          </script>
        </head><body>
          <article><h1>Neapolitanische Pizza</h1>
            <a href="/recipes/pasta">Pasta</a>
            <a href="/recipes/salad">Salad</a>
          </article>
        </body></html>
        """

        let kind = RecipeSiteDiscoveryService.classifyHTML(
            Data(html.utf8),
            sourceURL: URL(string: "https://bigmeatlove.de/neapolitanische-pizza.html")!
        )

        guard case .recipe(let candidate) = kind else {
            Issue.record("A recipe page must win over its site feed, got \(kind)")
            return
        }
        #expect(candidate.title == "Neapolitanische Pizza")
        #expect(candidate.subscriptionCandidate?.feedURL?.absoluteString == "https://bigmeatlove.de/feed.xml")
        #expect(candidate.subscriptionCandidate?.siteURL.absoluteString == "https://bigmeatlove.de/")
    }

    @Test func collectionWithFeaturedRecipeSnippetRemainsSiteDiscovery() {
        let html = """
        <html><head>
          <title>Pizza Rezepte</title>
          <script type="application/ld+json">
          {"@type":"Recipe","name":"Featured Pizza","recipeIngredient":["flour"],"recipeInstructions":"Bake."}
          </script>
        </head><body>
          <section itemtype="https://schema.org/ItemList">
            <a href="/recipe-items/pizza">Featured Pizza</a>
            <a href="/recipe-items/focaccia">Focaccia</a>
          </section>
        </body></html>
        """

        let kind = RecipeSiteDiscoveryService.classifyHTML(
            Data(html.utf8),
            sourceURL: URL(string: "https://cookingitaly.de/recipes/")!
        )
        guard case .recipeSite(let candidate) = kind else {
            Issue.record("A collection page must not import its featured Recipe snippet, got \(kind)")
            return
        }
        #expect(candidate.sourceKind == .websiteDiscovery)
        #expect(candidate.feedURL == nil)
    }

    @Test func recipeWithoutJSONLDUsesMicrodata() {
        let html = """
        <html><head>
          <link rel="alternate" type="application/atom+xml" href="/atom.xml">
        </head><body>
          <article itemscope itemtype="https://schema.org/Recipe">
            <h1 itemprop="name">Pizza Margherita alla Napoletana</h1>
            <ul><li itemprop="recipeIngredient">500 g flour</li><li itemprop="recipeIngredient">400 ml water</li></ul>
            <p itemprop="recipeInstructions">Stretch the dough and bake.</p>
          </article>
        </body></html>
        """

        let kind = RecipeSiteDiscoveryService.classifyHTML(
            Data(html.utf8),
            sourceURL: URL(string: "https://cookingitaly.de/recipe-items/pizza-margherita-alla-napoletana/")!
        )
        guard case .recipe(let candidate) = kind else {
            Issue.record("Microdata recipe should remain importable, got \(kind)")
            return
        }
        #expect(candidate.title == "Pizza Margherita alla Napoletana")
        #expect(candidate.subscriptionCandidate?.feedURL?.absoluteString == "https://cookingitaly.de/atom.xml")
    }

    @Test func semanticRecipeWithoutStructuredMarkupRemainsImportable() {
        let html = """
        <html><head><title>Weeknight pizza</title></head><body>
          <main>
            <div class="recipe-ingredients"><ul><li>500 g flour</li><li>350 ml water</li></ul></div>
            <div class="recipe-instructions"><p>Mix the dough and bake it hot.</p></div>
          </main>
        </body></html>
        """
        let kind = RecipeSiteDiscoveryService.classifyHTML(
            Data(html.utf8),
            sourceURL: URL(string: "https://example.com/weeknight-pizza")!
        )
        guard case .recipe(let candidate) = kind else {
            Issue.record("Semantic recipe markup should remain importable, got \(kind)")
            return
        }
        #expect(candidate.title == "Weeknight pizza")
    }

    @Test func unsupportedArticleRemainsExplicitlyImportable() {
        let html = """
        <html><head><title>Pizza ohne strukturierte Daten</title></head>
        <body><article><h1>Pizza ohne strukturierte Daten</h1>
          <h2>Zutaten</h2><ul><li>Mehl</li></ul>
          <h2>Zubereitung</h2><p>Backen.</p>
        </article></body></html>
        """
        let kind = RecipeSiteDiscoveryService.classifyHTML(
            Data(html.utf8),
            sourceURL: URL(string: "https://example.com/pizza-ohne-schema")!
        )
        switch kind {
        case .recipe, .ambiguous, .unsupported:
            break
        case .recipeSite, .feed:
            Issue.record("An article without strong structure must not be trapped in a site-only flow, got \(kind)")
        }
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
