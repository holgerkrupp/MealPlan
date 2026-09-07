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
}
