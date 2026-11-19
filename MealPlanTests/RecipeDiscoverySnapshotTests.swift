import Foundation
import Testing
@testable import MealPlan

struct RecipeDiscoverySnapshotTests {
    private func seed(
        _ id: String,
        title: String = "Soup recipe",
        source: String = "discovery:a",
        date: TimeInterval,
        url: String? = nil,
        archived: Bool = false,
        subscribed: Bool = false
    ) -> RecipeDiscoveryArticleSeed {
        RecipeDiscoveryArticleSeed(
            stableID: id,
            title: title,
            articleURL: url.flatMap(URL.init(string:)) ?? URL(string: "https://example.com/\(id)"),
            imageURL: nil,
            author: nil,
            summary: nil,
            publishedAt: Date(timeIntervalSince1970: date),
            sourceID: source,
            sourceName: source,
            date: Date(timeIntervalSince1970: date),
            isArchived: archived,
            providerTags: ["recipe"],
            body: nil,
            mayLookUpImage: true,
            isSubscribed: subscribed
        )
    }

    @Test func mixedSourcesInterleaveInSourceOrder() {
        let snapshot = RecipeDiscoverySnapshot.build(
            seeds: [
                seed("a1", source: "discovery:a", date: 4),
                seed("a2", source: "discovery:a", date: 2),
                seed("b1", source: "discovery:b", date: 3),
            ],
            sourceOrder: ["discovery:a", "discovery:b"],
            query: .init(sort: .mixed),
            readIDs: []
        )

        #expect(snapshot.visibleArticles.map(\.id) == [
            "discovery:a:a1", "discovery:b:b1", "discovery:a:a2"
        ])
    }

    @Test func categoriesAndFiltersAreComputedFromOneSnapshot() {
        let snapshot = RecipeDiscoverySnapshot.build(
            seeds: [
                seed("soup", title: "Tomato soup", source: "feed:one", date: 3, subscribed: true),
                seed("cake", title: "Chocolate cake", source: "feed:one", date: 2, subscribed: true),
                seed("old", title: "Old soup", source: "feed:one", date: 1, archived: true, subscribed: true),
            ],
            sourceOrder: ["feed:one"],
            query: .init(search: "tomato", sourceID: "feed:one", category: .soups, sort: .newest),
            readIDs: []
        )

        #expect(snapshot.availableCategories.contains(.soups))
        #expect(snapshot.visibleArticles.map(\.title) == ["Tomato soup"])
        #expect(snapshot.categoryCandidates.count == 1)
    }

    @Test func duplicateURLsPreferTheFirstSeed() {
        let snapshot = RecipeDiscoverySnapshot.build(
            seeds: [
                seed("stored", title: "Stored soup", source: "feed:one", date: 2, url: "https://example.com/soup", subscribed: true),
                seed("public", title: "Public soup", source: "discovery:a", date: 3, url: "https://example.com/soup"),
            ],
            sourceOrder: ["feed:one", "discovery:a"],
            query: .init(),
            readIDs: []
        )

        #expect(snapshot.allArticles.count == 1)
        #expect(snapshot.allArticles.first?.title == "Stored soup")
    }

    @Test func limitsUnfilteredAndFilteredResults() {
        let seeds = (0..<90).map { index in
            seed("\(index)", title: "Soup \(index)", source: "discovery:a", date: Double(index))
        }
        let all = RecipeDiscoverySnapshot.build(
            seeds: seeds, sourceOrder: ["discovery:a"], query: .init(), readIDs: []
        )
        let filtered = RecipeDiscoverySnapshot.build(
            seeds: seeds, sourceOrder: ["discovery:a"],
            query: .init(search: "soup"), readIDs: []
        )

        #expect(all.visibleArticles.count == 40)
        #expect(filtered.visibleArticles.count == 80)
    }

    @Test func defaultMixedFeedCapsLowAffinitySourcesAtTenOfForty() {
        let local = (0..<40).map { seed("local-\($0)", source: "discovery:local", date: Double($0)) }
        let international = (0..<40).map { seed("global-\($0)", source: "discovery:global", date: Double($0)) }
        let foreignIDs = (0..<20).map { "discovery:foreign-\($0)" }
        let foreignIDSet = Set(foreignIDs)
        let foreign = foreignIDs.enumerated().map { index, sourceID in
            seed("foreign-\(index)", source: sourceID, date: Double(index))
        }
        let snapshot = RecipeDiscoverySnapshot.build(
            seeds: local + international + foreign,
            sourceOrder: ["discovery:local", "discovery:global"] + foreignIDs,
            query: .init(sort: .mixed),
            readIDs: [],
            lowAffinitySourceIDs: foreignIDSet
        )

        #expect(snapshot.visibleArticles.count == 40)
        #expect(snapshot.visibleArticles.filter { foreignIDSet.contains($0.sourceID) }.count == 10)
    }

    @Test func subscribedSourcesAreNotCountedAgainstForeignSourceCap() {
        let local = [seed("local", source: "discovery:local", date: 1)]
        let international = [seed("global", source: "discovery:global", date: 1)]
        let foreignIDs = (0..<20).map { "discovery:foreign-\($0)" }
        let foreignIDSet = Set(foreignIDs)
        let foreign = foreignIDs.enumerated().map { index, sourceID in
            seed("foreign-\(index)", source: sourceID, date: Double(index))
        }
        let subscriptions = (0..<15).map {
            seed("feed-\($0)", source: "feed:\($0)", date: Double($0), subscribed: true)
        }
        let snapshot = RecipeDiscoverySnapshot.build(
            seeds: local + international + foreign + subscriptions,
            sourceOrder: ["discovery:local", "discovery:global"] + foreignIDs + (0..<15).map { "feed:\($0)" },
            query: .init(sort: .mixed),
            readIDs: [],
            lowAffinitySourceIDs: foreignIDSet
        )

        #expect(snapshot.visibleArticles.filter { $0.sourceID.hasPrefix("feed:") }.count == 15)
        #expect(snapshot.visibleArticles.filter { foreignIDSet.contains($0.sourceID) }.count <= 10)
    }

    @Test func explicitlySelectedForeignSourceBypassesMarketCap() {
        let selectedSource = "discovery:foreign"
        let selected = (0..<20).map {
            seed("foreign-\($0)", source: selectedSource, date: Double($0))
        }
        let snapshot = RecipeDiscoverySnapshot.build(
            seeds: selected,
            sourceOrder: [selectedSource],
            query: .init(sourceID: selectedSource, sort: .mixed),
            readIDs: [],
            lowAffinitySourceIDs: [selectedSource]
        )

        #expect(snapshot.visibleArticles.count == 20)
    }
}
