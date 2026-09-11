import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
struct RecipeFeedServiceTests {
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
            summary: "A simple soup recipe"
        )
        let parsed = ParsedRecipeFeed(
            title: "Recipes",
            homeURL: URL(string: "https://example.com"),
            articles: [repeatedArticle, repeatedArticle]
        )

        try await RecipeFeedService.merge(parsed, into: feed, context: context)
        try context.save()

        let items = try context.fetch(FetchDescriptor<RecipeFeedItem>())
        #expect(items.count == 1)
        #expect(items.first === newer)
        #expect(items.first?.title == "Tomato soup recipe")
    }
}
