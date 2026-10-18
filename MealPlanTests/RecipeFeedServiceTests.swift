import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
struct RecipeFeedServiceTests {
    @Test func unchangedArticleKeepsItsFetchTimestamp() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let articleURL = URL(string: "https://example.com/recipes/soup")!
        let feed = RecipeFeed(title: "Recipes", siteURL: URL(string: "https://example.com")!, feedURL: URL(string: "https://example.com/feed")!)
        let article = ParsedFeedArticle(id: articleURL.absoluteString, title: "Soup", url: articleURL, summary: "Warm soup", publishedAt: Date(timeIntervalSince1970: 100))
        context.insert(feed)

        try RecipeFeedService.merge(.init(title: "Recipes", homeURL: nil, articles: [article]), into: feed, context: context)
        let item = try #require(feed.items?.first)
        let originalFetch = Date(timeIntervalSince1970: 200)
        item.fetchedAt = originalFetch

        try RecipeFeedService.merge(.init(title: "Recipes", homeURL: nil, articles: [article]), into: feed, context: context)
        #expect(item.fetchedAt == originalFetch)

        let changed = ParsedFeedArticle(id: article.id, title: "Better soup", url: articleURL, summary: article.summary, publishedAt: article.publishedAt)
        try RecipeFeedService.merge(.init(title: "Recipes", homeURL: nil, articles: [changed]), into: feed, context: context)
        #expect(item.fetchedAt != originalFetch)
    }

    @Test func mergeRepairsStoredDuplicatesAndIgnoresRepeatedFeedEntries() async throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-recipe-feed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let schema = SharedStore.makeSchema()
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeDirectory.appending(path: "test.sqlite"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let feedURL = URL(string: "https://example.com/feed")!
        let articleURL = URL(string: "https://example.com/recipes/soup")!
        let feed = RecipeFeed(title: "Recipes", siteURL: URL(string: "https://example.com")!, feedURL: feedURL)
        let older = RecipeFeedItem(stableID: articleURL.absoluteString, title: "Old soup", url: articleURL)
        let newer = RecipeFeedItem(stableID: articleURL.absoluteString, title: "Newer soup", url: articleURL)
        older.fetchedAt = Date(timeIntervalSince1970: 1)
        newer.fetchedAt = Date(timeIntervalSince1970: 2)
        context.insert(feed)
        try context.save()

        older.feed = feed
        context.insert(older)
        try context.save()

        newer.feed = feed
        context.insert(newer)
        try context.save()

        let repeatedArticle = ParsedFeedArticle(
            id: articleURL.absoluteString,
            title: "Tomato soup recipe",
            url: articleURL,
            summary: "A simple soup recipe",
            publishedAt: Date(timeIntervalSince1970: 1)
        )
        let updatedArticle = ParsedFeedArticle(
            id: articleURL.absoluteString,
            title: "Updated tomato soup recipe",
            url: articleURL,
            summary: "A newer soup recipe",
            publishedAt: Date(timeIntervalSince1970: 2)
        )
        let parsed = ParsedRecipeFeed(
            title: "Recipes",
            homeURL: URL(string: "https://example.com"),
            articles: [updatedArticle, repeatedArticle]
        )

        try RecipeFeedService.merge(parsed, into: feed, context: context)
        try context.save()

        let items = try context.fetch(FetchDescriptor<RecipeFeedItem>())
        #expect(items.count == 1)
        #expect(items.first === newer)
        #expect(items.first?.title == "Updated tomato soup recipe")
    }

    @Test func equalFetchTimesChooseTheSamePersistedDuplicateRegardlessOfFetchOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-recipe-feed-tie-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let schema = SharedStore.makeSchema()
        let configuration = ModelConfiguration(schema: schema, url: directory.appending(path: "test.sqlite"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let url = URL(string: "https://example.com/recipes/soup")!
        let feed = RecipeFeed(title: "Recipes", siteURL: URL(string: "https://example.com")!, feedURL: URL(string: "https://example.com/feed")!)
        let first = RecipeFeedItem(stableID: url.absoluteString, title: "First", url: url)
        let second = RecipeFeedItem(stableID: url.absoluteString, title: "Second", url: url)
        first.uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        second.uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let timestamp = Date(timeIntervalSince1970: 42)
        first.fetchedAt = timestamp
        second.fetchedAt = timestamp
        context.insert(feed)
        first.feed = feed
        second.feed = feed
        context.insert(first)
        context.insert(second)
        try context.save()

        let parsed = ParsedRecipeFeed(title: "Recipes", homeURL: nil, articles: [])
        try RecipeFeedService.merge(parsed, into: feed, context: context)
        try context.save()

        let items = try context.fetch(FetchDescriptor<RecipeFeedItem>())
        #expect(items.count == 1)
        #expect(items.first?.uuid == first.uuid)
        #expect(items.first?.feed === feed)
    }

    @Test func failedRefreshCommitRollsBackFeedAndArchiveMutations() throws {
        let schema = SharedStore.makeSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        context.undoManager = UndoManager()
        let feed = RecipeFeed(title: "Previous title", siteURL: URL(string: "https://example.com")!, feedURL: URL(string: "https://example.com/feed")!)
        let item = RecipeFeedItem(stableID: "article-1", title: "Saved recipe", url: URL(string: "https://example.com/recipe")!)
        item.feed = feed
        context.insert(feed)
        context.insert(item)
        try context.save()
        context.undoManager?.removeAllActions()

        do {
            try nonUndoableStoreTransaction(in: context) {
                feed.title = "Uncommitted title"
                item.archivedAt = .now
                throw RecipeFeedTestError.injectedSaveFailure
            }
        } catch RecipeFeedTestError.injectedSaveFailure {
            // A failed local commit must not leave a half-applied refresh.
        }

        #expect(feed.title == "Previous title")
        #expect(item.archivedAt == nil)
        #expect(context.undoManager?.canUndo == false)
        let reopenedFeed = try #require(context.fetch(FetchDescriptor<RecipeFeed>()).first { $0.uuid == feed.uuid })
        let reopenedItem = try #require(context.fetch(FetchDescriptor<RecipeFeedItem>()).first { $0.uuid == item.uuid })
        #expect(reopenedFeed.title == "Previous title")
        #expect(reopenedItem.archivedAt == nil)
    }
}

private enum RecipeFeedTestError: Error {
    case injectedSaveFailure
}
