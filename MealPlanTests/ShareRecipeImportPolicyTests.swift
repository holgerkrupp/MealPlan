import Foundation
import Testing
@testable import MealPlan

struct ShareRecipeImportPolicyTests {
    private let articleURL = URL(string: "https://cookingitaly.de/recipe-items/pizza-margherita-alla-napoletana/")!

    private func recipe(hasContent: Bool = true) -> ImportedRecipe {
        var value = ImportedRecipe(name: "Pizza", sourceURL: articleURL)
        if hasContent {
            value.ingredientLines = ["500 g flour"]
            value.instructions = "Bake."
        }
        return value
    }

    @Test func articleMisclassifiedAsFeedStillUsesRecipeFirst() {
        let candidate = RecipeSiteCandidate(
            title: "Cooking Italy",
            siteURL: URL(string: "https://cookingitaly.de/")!,
            contentURL: articleURL,
            feedURL: URL(string: "https://cookingitaly.de/feed.xml")
        )
        let kind = SharedRecipeURLKind.recipeSite(candidate)

        #expect(ShareRecipeImportPolicy.accepts(recipe(), classification: kind))
    }

    @Test func collectionFeaturedRecipeDoesNotBecomeARecipe() {
        let candidate = RecipeSiteCandidate(
            title: "Cooking Italy",
            siteURL: URL(string: "https://cookingitaly.de/")!,
            contentURL: URL(string: "https://cookingitaly.de/recipes/")!,
            feedURL: URL(string: "https://cookingitaly.de/feed.xml")
        )
        let kind = SharedRecipeURLKind.recipeSite(candidate)

        #expect(!ShareRecipeImportPolicy.accepts(recipe(), classification: kind))
    }

    @Test func genuineFeedAndTitleOnlyExtractionStayOutOfSaveForm() {
        let feed = DiscoveredFeed(
            title: "Recipes",
            siteURL: URL(string: "https://example.com/")!,
            feedURL: URL(string: "https://example.com/feed.xml")!
        )
        #expect(!ShareRecipeImportPolicy.accepts(recipe(), classification: .feed(feed)))
        #expect(!ShareRecipeImportPolicy.accepts(recipe(hasContent: false), classification: .unsupported(articleURL)))
    }
}
