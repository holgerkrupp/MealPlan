import Foundation
import Testing
@testable import MealPlan

struct SeasonalRecipeShelfTests {
    private func article(_ id: String) -> RecipeDiscoveryArticle {
        RecipeDiscoveryArticle(
            id: id,
            readStateID: id,
            title: "Seasonal recipe \(id)",
            articleURL: URL(string: "https://example.com/\(id)"),
            imageURL: nil,
            author: nil,
            summary: nil,
            publishedAt: nil,
            sourceID: "discovery:example",
            sourceName: "Example recipes",
            date: .distantPast,
            isArchived: false,
            categories: [],
            mayLookUpImage: true,
            isRead: false
        )
    }

    private func collection(_ id: String, articleCount: Int) -> SeasonalRecipeCollection {
        let moment = SeasonalRecipeCalendar.catalog.first { $0.id == id }!
        return SeasonalRecipeCollection(
            moment: moment,
            articles: (0..<articleCount).map { article("\(id)-\($0)") }
        )
    }

    @Test func noMomentsAndThinResultsAreHidden() {
        #expect(SeasonalRecipeShelfPolicy.overviewCollections([]).isEmpty)
        #expect(SeasonalRecipeShelfPolicy.overviewCollections([
            collection("halloween", articleCount: 0),
            collection("autumn-harvest", articleCount: 2),
        ]).isEmpty)
    }

    @Test func overlappingMomentsKeepCalendarOrderAndCapAtTwo() {
        let input = [
            collection("halloween", articleCount: 3),
            collection("autumn-harvest", articleCount: 0),
            collection("winter-holiday-baking", articleCount: 4),
            collection("new-year", articleCount: 5),
        ]

        let visible = SeasonalRecipeShelfPolicy.overviewCollections(input)
        #expect(visible.map(\.id) == ["halloween", "winter-holiday-baking"])
    }

    @Test func seeAllRouteRetainsTheSelectedMomentIDAndLocalizedMetadata() {
        let halloween = collection("halloween", articleCount: 3)
        let route = SeasonalRecipeShelfPolicy.route(for: halloween)

        #expect(route.momentID == "halloween")
        #expect(route.title == halloween.moment.localizedTitle)
        #expect(route.symbolName == (halloween.moment.symbolName ?? "leaf"))
        #expect(route.articles.map(\.id) == halloween.articles.map(\.id))
    }
}
