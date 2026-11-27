import Foundation
import Testing
@testable import MealPlan

struct DiscoveryInspirationPolicyTests {
    private func article(
        _ id: String,
        title: String = "Pasta with tomatoes",
        summary: String? = nil,
        source: String = "discovery:a",
        daysAgo: Double = 0,
        image: Bool = true,
        read: Bool = false,
        archived: Bool = false,
        tags: [String] = []
    ) -> RecipeDiscoveryArticle {
        let categories = RecipeDiscoveryCategory.categories(title: title, summary: summary, providerTags: tags)
        return RecipeDiscoveryArticle(
            id: "\(source):\(id)",
            readStateID: id,
            title: title,
            articleURL: URL(string: "https://example.com/\(id)"),
            imageURL: image ? URL(string: "https://example.com/\(id).jpg") : nil,
            author: nil,
            summary: summary,
            publishedAt: nil,
            sourceID: source,
            sourceName: source,
            date: Date(timeIntervalSinceReferenceDate: 1_000_000 - daysAgo * 86_400),
            isArchived: archived,
            categories: categories,
            mayLookUpImage: false,
            isRead: read,
            inspirationThemes: RecipeInspirationTheme.themes(
                title: title, summary: summary, providerTags: tags, categories: categories
            )
        )
    }

    // MARK: Themes

    @Test func themesComeOnlyFromTheSourcesOwnWords() {
        func themes(_ title: String, tags: [String] = []) -> Set<RecipeInspirationTheme> {
            let categories = RecipeDiscoveryCategory.categories(title: title, summary: nil, providerTags: tags)
            return RecipeInspirationTheme.themes(title: title, summary: nil, providerTags: tags, categories: categories)
        }
        #expect(themes("Quick weeknight chicken curry").contains(.quickDinner))
        #expect(themes("Schnelle Nudelpfanne").contains(.quickDinner))
        // "breakfast" must not read as "fast", and a quick cake is no dinner.
        #expect(!themes("Breakfast burrito").contains(.quickDinner))
        #expect(!themes("Quick chocolate cake").contains(.quickDinner))
        // A bean stew with chicken is not vegetarian just because of the beans.
        #expect(!themes("Chicken and bean stew").contains(.vegetarian))
        #expect(themes("Linsensuppe", tags: ["Vegetarisch"]).contains(.vegetarian))
        #expect(themes("Vegan chili").contains(.vegetarian))
        #expect(themes("Sourdough bread").contains(.baking))
        #expect(themes("Roast chicken").isEmpty)
    }

    @Test func thinThemesAreHidden() {
        let articles = (0..<3).map { article("v\($0)", title: "Vegan bowl \($0)", source: "discovery:s\($0)") }
            + (0..<4).map { article("b\($0)", title: "Banana bread \($0)", source: "discovery:s\($0)") }
        let inspiration = DiscoveryInspirationPolicy.make(articles: articles)
        #expect(inspiration.themes.map(\.theme) == [.baking])
    }

    @Test func seasonalThemeNeedsEnoughArticlesAndKeepsFixedOrder() {
        let baking = (0..<4).map { article("b\($0)", title: "Apple pie \($0)", source: "discovery:s\($0)") }
        let seasonal = (0..<4).map { article("s\($0)", title: "Pumpkin soup \($0)") }
        let base = DiscoveryInspirationPolicy.make(articles: baking)
        #expect(base.withSeasonal(Array(seasonal.prefix(3))).themes.map(\.theme) == [.baking])
        #expect(base.withSeasonal(seasonal).themes.map(\.theme) == [.seasonal, .baking])
    }

    @Test func seasonalArticlesAreDeduplicatedAcrossMoments() {
        let moments = SeasonalRecipeCalendar.catalog.prefix(2)
        let shared = article("shared")
        let collections = moments.map { moment in
            SeasonalRecipeCollection(moment: moment, articles: [shared, article(moment.id)])
        }
        let merged = DiscoveryInspirationPolicy.seasonalArticles(Array(collections))
        #expect(merged.count == 3)
        #expect(merged.first?.id == shared.id)
    }

    // MARK: Ideas for this week

    @Test func weekIdeasCapEachSourceAndSkipReadArchivedAndForeign() {
        let articles = [
            article("a1", source: "discovery:a", daysAgo: 0),
            article("a2", source: "discovery:a", daysAgo: 1),
            article("b1", source: "discovery:b", daysAgo: 2),
            article("c1", source: "discovery:c", daysAgo: 3, read: true),
            article("d1", source: "discovery:d", daysAgo: 4, archived: true),
            article("e1", source: "discovery:foreign", daysAgo: 5),
            article("f1", source: "discovery:f", daysAgo: 6),
            article("g1", source: "discovery:g", daysAgo: 7),
        ]
        let week = DiscoveryInspirationPolicy.make(
            articles: articles,
            lowAffinitySourceIDs: ["discovery:foreign"]
        ).weekIdeas
        #expect(week.map(\.readStateID) == ["a1", "b1", "f1", "g1"])
    }

    @Test func weekIdeasRelaxTheSourceCapForFewSourcesAndPutAPhotoFirst() {
        let articles = [
            article("a1", source: "discovery:a", daysAgo: 0, image: false),
            article("a2", source: "discovery:a", daysAgo: 1),
            article("b1", source: "discovery:b", daysAgo: 2),
            article("b2", source: "discovery:b", daysAgo: 3),
        ]
        let week = DiscoveryInspirationPolicy.make(articles: articles).weekIdeas
        #expect(week.first?.imageURL != nil)
        #expect(week.count == 4)
    }

    @Test func weekIdeasAreHiddenWhenThereIsTooLittle() {
        let articles = [article("a1"), article("a2")]
        #expect(DiscoveryInspirationPolicy.make(articles: articles).weekIdeas.isEmpty)
    }

    @Test func weekIdeasSkipDrinksAndWhatIsAlreadyInSeason() {
        let articles = [
            article("drink", title: "Iced tea", source: "discovery:a"),
            article("season", source: "discovery:b"),
            article("c1", source: "discovery:c"),
            article("d1", source: "discovery:d"),
            article("e1", source: "discovery:e"),
        ]
        let week = DiscoveryInspirationPolicy.make(
            articles: articles,
            excludingIDs: ["discovery:b:season"]
        ).weekIdeas
        #expect(week.map(\.readStateID) == ["c1", "d1", "e1"])
    }

    // MARK: New from your sites

    @Test func sitesShelfIsUnreadSubscribedOnlyAndNeverRepeatsAWeekIdea() {
        let articles = [
            article("f1", source: "feed:1", daysAgo: 0),
            article("f2", source: "feed:1", daysAgo: 1),
            article("f3", source: "feed:1", daysAgo: 2),
            article("f4", source: "feed:1", daysAgo: 3, read: true),
            article("p1", source: "discovery:a", daysAgo: 4),
            article("p2", source: "discovery:b", daysAgo: 5),
        ]
        let inspiration = DiscoveryInspirationPolicy.make(articles: articles)
        // f1 is the week's single pick from feed:1, so the sites shelf starts at f2.
        #expect(inspiration.weekIdeas.map(\.readStateID) == ["f1", "p1", "p2"])
        #expect(inspiration.fromYourSites.map(\.readStateID) == ["f2", "f3"])
        #expect(inspiration.allFromYourSites.map(\.readStateID) == ["f1", "f2", "f3"])
        #expect(Set(inspiration.weekIdeas.map(\.id)).isDisjoint(with: inspiration.fromYourSites.map(\.id)))
    }

    @Test func noSubscriptionsMeansNoSitesShelf() {
        let articles = (0..<5).map { article("p\($0)", source: "discovery:s\($0)") }
        let inspiration = DiscoveryInspirationPolicy.make(articles: articles)
        #expect(inspiration.fromYourSites.isEmpty)
        #expect(inspiration.allFromYourSites.isEmpty)
        #expect(inspiration.weekIdeas.count == 5)
    }

    // MARK: Determinism and read state

    @Test func sameInputInAnyOrderGivesTheSameShelves() {
        let articles = (0..<12).map {
            article("x\($0)", title: $0.isMultiple(of: 2) ? "Vegan curry \($0)" : "Quick pasta \($0)",
                    source: "discovery:s\($0 % 4)", daysAgo: Double($0 % 3))
        }
        let one = DiscoveryInspirationPolicy.make(articles: articles)
        let two = DiscoveryInspirationPolicy.make(articles: articles.reversed())
        #expect(one.weekIdeas.map(\.id) == two.weekIdeas.map(\.id))
        #expect(one.themes.map { $0.articles.map(\.id) } == two.themes.map { $0.articles.map(\.id) })
    }

    @Test func markingReadUpdatesEveryShelf() {
        let articles = (0..<5).map { article("p\($0)", title: "Vegan stew \($0)", source: "discovery:s\($0)") }
        let inspiration = DiscoveryInspirationPolicy.make(articles: articles).applying(readID: "p0")
        #expect(inspiration.weekIdeas.first { $0.readStateID == "p0" }?.isRead == true)
        #expect(inspiration.themes.first?.articles.first { $0.readStateID == "p0" }?.isRead == true)
    }
}
