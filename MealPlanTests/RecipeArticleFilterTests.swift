import Foundation
import Testing
@testable import MealPlan

struct RecipeArticleFilterTests {
    private func candidate(
        _ title: String,
        summary: String? = nil,
        author: String? = nil,
        feed: String = "Kitchen",
        date: Date = .now,
        archived: Bool = false,
        read: Bool = false
    ) -> RecipeArticleFilter.Candidate {
        .init(title: title, summary: summary, author: author, feedTitle: feed,
              date: date, isArchived: archived, isRead: read)
    }

    // MARK: - Discovery categories

    @Test func categorizesUsingTitlesAndSummaries() {
        let soup = RecipeDiscoveryCategory.categories(
            title: "Slow-roasted tomato soup",
            summary: "A warming vegetarian dinner",
            providerTags: []
        )

        #expect(soup.contains(.soups))
        #expect(soup.contains(.vegetarian))
        #expect(soup.contains(.mainDishes))
    }

    @Test func categorizesUsingProviderTags() {
        let cake = RecipeDiscoveryCategory.categories(
            title: "Grandma's favorite",
            summary: nil,
            providerTags: ["baking", "dessert", "sweet"]
        )

        #expect(cake.contains(.baking))
        #expect(cake.contains(.desserts))
    }

    @Test func oneRecipeCanAppearInSeveralCategories() {
        let pizza = RecipeDiscoveryCategory.categories(
            title: "Vegetarian pizza",
            summary: nil,
            providerTags: []
        )

        #expect(pizza.contains(.vegetarian))
        #expect(pizza.contains(.baking))
        #expect(pizza.contains(.mainDishes))
    }

    @Test func hidesTheNonRecipePostFromTheScreenshot() {
        let visible = RecipeArticleClassifier.isLikelyRecipe(
            title: "Mein Glycin-Erfahrungsbericht – so überraschend hat es auf Haut, Haare & mehr gewirkt",
            summary: "Bessere Haut, starke Nägel und glänzende Haare.",
            url: URL(string: "https://www.kochtrotz.de/glycin-mein-erfahrungsbericht-haut-haare-naegel/"),
            providerTags: ["Blog", "Magazin", "Erfahrungsbericht", "Glycin"]
        )

        #expect(!visible)
    }

    @Test func hidesExplicitAdvertisementsEvenWhenTheyMentionFood() {
        #expect(!RecipeArticleClassifier.isLikelyRecipe(
            title: "Anzeige: Unser neuer Pizzaofen im Test",
            summary: "Pizza und Brot zu Hause backen",
            url: URL(string: "https://example.com/pizzaofen")
        ))
    }

    @Test func keepsRecipesFromMetadataAndStructuredFeeds() {
        #expect(RecipeArticleClassifier.isLikelyRecipe(
            title: "Orientalischer Couscous-Salat",
            summary: "In 15 Minuten fertig",
            url: URL(string: "https://example.com/food/couscous")
        ))
        #expect(RecipeArticleClassifier.isLikelyRecipe(
            title: "Omas Liebling",
            summary: nil,
            url: URL(string: "https://example.com/post/42"),
            providerTags: ["Rezepte"]
        ))
        #expect(RecipeArticleClassifier.isLikelyRecipe(
            title: "Sunday special",
            summary: nil,
            url: URL(string: "https://example.com/post/43"),
            body: #"<script type="application/ld+json">{"@type":"Recipe"}</script>"#
        ))
    }

    // MARK: - Scope

    @Test func recentHidesArchivedPosts() {
        #expect(RecipeArticleFilter.matches(candidate("Soup"), scope: .current, search: ""))
        #expect(!RecipeArticleFilter.matches(candidate("Soup", archived: true), scope: .current, search: ""))
    }

    @Test func everythingIncludesTheArchive() {
        #expect(RecipeArticleFilter.matches(candidate("Soup", archived: true), scope: .archive, search: ""))
    }

    @Test func unreadHidesReadAndArchivedPosts() {
        #expect(RecipeArticleFilter.matches(candidate("Soup"), scope: .unread, search: ""))
        #expect(!RecipeArticleFilter.matches(candidate("Soup", read: true), scope: .unread, search: ""))
        #expect(!RecipeArticleFilter.matches(candidate("Soup", archived: true), scope: .unread, search: ""))
    }

    // MARK: - Search

    @Test func everyWordHasToAppearSomewhere() {
        let item = candidate("Slow-roasted tomato soup", summary: "With fennel and basil")
        #expect(RecipeArticleFilter.matches(item, scope: .current, search: "tomato soup"))
        // Order does not matter, and the words may come from different fields.
        #expect(RecipeArticleFilter.matches(item, scope: .current, search: "soup tomato"))
        #expect(RecipeArticleFilter.matches(item, scope: .current, search: "tomato fennel"))
        #expect(!RecipeArticleFilter.matches(item, scope: .current, search: "tomato chicken"))
    }

    @Test func searchesTheAuthorAndTheSiteToo() {
        let item = candidate("Soup", author: "Deb Perelman", feed: "Smitten Kitchen")
        #expect(RecipeArticleFilter.matches(item, scope: .current, search: "perelman"))
        #expect(RecipeArticleFilter.matches(item, scope: .current, search: "smitten"))
    }

    @Test func searchIgnoresCaseAndSurroundingSpace() {
        let item = candidate("Tomato Soup")
        #expect(RecipeArticleFilter.matches(item, scope: .current, search: "  TOMATO  "))
    }

    @Test func anEmptySearchKeepsEverythingInScope() {
        #expect(RecipeArticleFilter.matches(candidate("Soup"), scope: .current, search: "   "))
    }

    @Test func searchStillObeysTheScope() {
        let archived = candidate("Tomato soup", archived: true)
        #expect(!RecipeArticleFilter.matches(archived, scope: .current, search: "tomato"))
        #expect(RecipeArticleFilter.matches(archived, scope: .archive, search: "tomato"))
    }

    // MARK: - Sort

    @Test func sortsByDateInBothDirections() {
        let old = candidate("A", date: Date(timeIntervalSince1970: 1_000))
        let new = candidate("B", date: Date(timeIntervalSince1970: 2_000))
        #expect(RecipeArticleFilter.areInOrder(new, old, sort: .newest))
        #expect(!RecipeArticleFilter.areInOrder(old, new, sort: .newest))
        #expect(RecipeArticleFilter.areInOrder(old, new, sort: .oldest))
    }

    @Test func sortsByTitleIgnoringCase() {
        #expect(RecipeArticleFilter.areInOrder(candidate("apple"), candidate("Banana"), sort: .title))
        #expect(!RecipeArticleFilter.areInOrder(candidate("Banana"), candidate("apple"), sort: .title))
    }

    @Test func interleavesSourcesWithoutDroppingShorterGroups() {
        let result = RecipeArticleFilter.interleave([
            ["a1", "a2", "a3"],
            ["b1"],
            ["c1", "c2"],
        ])

        #expect(result == ["a1", "b1", "c1", "a2", "c2", "a3"])
    }
}
