import Foundation
import Testing
@testable import MealPlan

struct SeasonalRecipeDiscoveryTests {
    private var halloween: SeasonalRecipeMoment {
        SeasonalRecipeCalendar.catalog.first { $0.id == "halloween" }!
    }

    private var germanMarket: RecipeDiscoveryMarketContext {
        RecipeDiscoveryMarketContext(locale: Locale(identifier: "en-DE"))
    }

    private func seed(
        _ id: String,
        title: String,
        sourceID: String = "discovery:chefkoch",
        summary: String? = nil,
        tags: [String] = [],
        body: String? = nil,
        subscribed: Bool = false
    ) -> RecipeDiscoveryArticleSeed {
        RecipeDiscoveryArticleSeed(
            stableID: id,
            title: title,
            articleURL: URL(string: "https://recipes.example/\(sourceID.replacingOccurrences(of: ":", with: "-"))/\(id)"),
            imageURL: nil,
            author: nil,
            summary: summary,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceID: sourceID,
            sourceName: sourceID,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            isArchived: false,
            providerTags: tags,
            body: body,
            mayLookUpImage: false,
            isSubscribed: subscribed
        )
    }

    @Test func germanProviderTagMatchesEvenWithGenericTitle() {
        let article = seed("soup", title: "Suppe", tags: ["Kürbis"])
        let compoundTitle = seed("compound", title: "Kürbissuppe", tags: ["recipe"])
        let match = SeasonalRecipeRanking.rank(
            seeds: [article], for: halloween, context: germanMarket
        ).first?.match
        let compoundMatch = SeasonalRecipeRanking.rank(
            seeds: [compoundTitle], for: halloween, context: germanMarket
        ).first?.match

        #expect(match?.score == 30)
        #expect(match?.matchedSignals == [.providerTag])
        #expect(match?.matchedKeywords.contains("kürbis") == true)
        #expect(compoundMatch?.matchedSignals == [.title])
    }

    @Test func englishAndGermanRecipesMatchButRegionalOneRanksFirst() {
        let german = seed("german", title: "Kürbis soup", sourceID: "discovery:chefkoch")
        let english = seed("english", title: "Pumpkin soup", sourceID: "discovery:serious-eats")
        let ranked = SeasonalRecipeRanking.rank(
            seeds: [english, german], for: halloween, context: germanMarket
        )

        #expect(ranked.count == 2)
        #expect(ranked[0].seed.id == german.id)
        #expect(ranked[1].seed.id == english.id)
        #expect(ranked[0].match.score == ranked[1].match.score)
    }

    @Test func noSeasonalKeywordDoesNotProduceAMatch() {
        let article = seed("ordinary", title: "Simple tomato pasta", tags: ["dinner"])
        #expect(SeasonalRecipeRanking.rank(
            seeds: [article], for: halloween, context: germanMarket
        ).isEmpty)
    }

    @Test func subscribedForeignSourceRemainsEligibleWithoutForeignPenalty() {
        let local = seed("local", title: "Kürbis soup", sourceID: "discovery:chefkoch")
        let subscribed = seed(
            "chosen", title: "Pumpkin soup", sourceID: "feed:my-subscription", subscribed: true
        )
        let ranked = SeasonalRecipeRanking.rank(
            seeds: [subscribed, local], for: halloween, context: germanMarket
        )
        let chosen = ranked.first { $0.seed.id == subscribed.id }

        #expect(chosen != nil)
        #expect(chosen?.marketPriority == 0)
    }

    @Test func perSourceCapAndSourceInterleavingPreserveProviderDiversity() {
        let seeds = [
            seed("a1", title: "Kürbis soup one", sourceID: "discovery:chefkoch"),
            seed("a2", title: "Kürbis soup two", sourceID: "discovery:chefkoch"),
            seed("a3", title: "Kürbis soup three", sourceID: "discovery:chefkoch"),
            seed("b1", title: "Kürbis soup one", sourceID: "discovery:lecker"),
            seed("b2", title: "Kürbis soup two", sourceID: "discovery:lecker"),
            seed("b3", title: "Kürbis soup three", sourceID: "discovery:lecker"),
        ]
        let ranked = SeasonalRecipeRanking.rank(
            seeds: seeds,
            for: halloween,
            context: germanMarket,
            limit: 6,
            perSourceLimit: 1
        )

        #expect(ranked.count == 2)
        #expect(Set(ranked.map(\.seed.sourceID)) == ["discovery:chefkoch", "discovery:lecker"])
    }

    @Test func manyForeignSourcesCannotDominateAndOrderingIsDeterministic() {
        let localSources = ["chefkoch", "lecker", "kuechengotter"]
        let localSeeds = localSources.flatMap { source in
            (0..<4).map { index in
                seed("\(source)-\(index)", title: "Kürbis soup", sourceID: "discovery:\(source)")
            }
        }
        let foreignSources = (0..<16).map { index in
            RecipeDiscoverySource(
                id: "us-\(index)",
                name: "US Recipe Source \(index)",
                siteURL: URL(string: "https://us-\(index).example")!,
                contentURL: URL(string: "https://us-\(index).example/recipes")!,
                format: .feed,
                preferredRegionCodes: ["US"],
                languageCodes: ["en"]
            )
        }
        let foreignSeeds = foreignSources.enumerated().map { index, source in
            seed("us-\(index)", title: "Pumpkin soup", sourceID: "discovery:\(source.id)")
        }
        let inputs = localSeeds + foreignSeeds
        let first = SeasonalRecipeRanking.rank(
            seeds: inputs,
            for: halloween,
            context: germanMarket,
            additionalSources: foreignSources,
            limit: 8
        )
        let second = SeasonalRecipeRanking.rank(
            seeds: Array(inputs.reversed()),
            for: halloween,
            context: germanMarket,
            additionalSources: foreignSources,
            limit: 8
        )

        #expect(first.count == 8)
        #expect(first.filter { $0.marketPriority == 2 }.count <= 2)
        #expect(first.filter { $0.marketPriority == 0 }.count >= 6)
        #expect(first.map(\.seed.id) == second.map(\.seed.id))
    }

    @Test func canonicalURLDeduplicationKeepsNormalDiscoverSeedFirst() {
        let normal = seed("normal", title: "Kürbis", sourceID: "discovery:chefkoch")
        let targeted = RecipeDiscoveryArticleSeed(
            stableID: "targeted",
            title: "Halloween Kürbis",
            articleURL: URL(string: "https://RECIPES.example/discovery-chefkoch/normal?utm_source=seasonal#share"),
            imageURL: nil,
            author: nil,
            summary: nil,
            publishedAt: nil,
            sourceID: "discovery:chefkoch",
            sourceName: "Chefkoch",
            date: .distantPast,
            isArchived: false,
            providerTags: [],
            body: nil,
            mayLookUpImage: true,
            isSubscribed: false
        )
        let merged = SeasonalRecipeURL.appendingUnique(existing: [normal], targeted: [targeted])

        #expect(merged.count == 1)
        #expect(merged.first?.id == normal.id)
        #expect(SeasonalRecipeURL.canonicalURLKey(normal.articleURL!) ==
                SeasonalRecipeURL.canonicalURLKey(targeted.articleURL!))
    }

    @Test func collectionCarriesReadStateForNormalDiscoveryCards() {
        let article = seed("read", title: "Kürbis soup")
        let collection = SeasonalRecipeRanking.collection(
            for: halloween,
            seeds: [article],
            context: germanMarket,
            readIDs: [article.readStateID]
        )

        #expect(collection.moment.id == halloween.id)
        #expect(collection.articles.count == 1)
        #expect(collection.articles[0].isRead)
    }

    @Test func failedOptionalProviderLeavesNormalSeasonalCandidatesAvailable() async {
        let normal = seed("normal", title: "Kürbis soup")
        let loaded = await SeasonalRecipeCollectionLoader.load(
            moment: halloween,
            context: germanMarket,
            providers: [FailingSeasonalCollectionProvider()]
        )
        let merged = SeasonalRecipeCollectionLoader.merging(normalSeeds: [normal], targetedLoad: loaded)

        #expect(loaded.seeds.isEmpty)
        #expect(loaded.failedProviderIDs == ["failing-seasonal"])
        #expect(merged.map(\.id) == [normal.id])
        #expect(SeasonalRecipeRanking.rank(seeds: merged, for: halloween, context: germanMarket).count == 1)
    }

    @Test func targetedProviderResultsAreBoundedPerMoment() async {
        let articles = (0..<20).map { index in
            ParsedFeedArticle(
                id: "candidate-\(index)",
                title: "Pumpkin soup \(index)",
                url: URL(string: "https://seasonal.example/\(index)")!,
                author: nil,
                summary: nil,
                body: nil,
                publishedAt: nil,
                imageURL: nil,
                categories: []
            )
        }
        let loaded = await SeasonalRecipeCollectionLoader.load(
            moment: halloween,
            context: germanMarket,
            providers: [StaticSeasonalCollectionProvider(articles: articles)]
        )

        #expect(loaded.seeds.count == SeasonalRecipeCollectionLoader.maximumArticlesPerProvider)
        #expect(loaded.sources.map(\.id) == ["static-seasonal"])
    }

    @Test func targetedProviderCountIsCapped() async {
        let tracker = SeasonalProviderCallTracker()
        let providers = (0..<10).map { index in
            TrackingSeasonalCollectionProvider(id: "provider-\(index)", tracker: tracker)
        }
        let loaded = await SeasonalRecipeCollectionLoader.load(
            moment: halloween,
            context: germanMarket,
            providers: providers
        )
        let counts = await tracker.snapshot()

        #expect(loaded.sources.count == SeasonalRecipeCollectionLoader.maximumProviders)
        #expect(counts.calls == SeasonalRecipeCollectionLoader.maximumProviders)
    }

    @Test func targetedProviderConcurrencyStaysWithinBound() async {
        let tracker = SeasonalProviderCallTracker()
        let providers = (0..<5).map { index in
            TrackingSeasonalCollectionProvider(id: "concurrent-\(index)", tracker: tracker)
        }
        _ = await SeasonalRecipeCollectionLoader.load(
            moment: halloween,
            context: germanMarket,
            providers: providers
        )
        let counts = await tracker.snapshot()

        #expect(counts.calls == providers.count)
        #expect(counts.maximumConcurrent == SeasonalRecipeCollectionLoader.maximumConcurrentProviders)
        #expect(counts.maximumConcurrent <= SeasonalRecipeCollectionLoader.maximumConcurrentProviders)
    }
}

private struct FailingSeasonalCollectionProvider: SeasonalRecipeCollectionProviding {
    let id = "failing-seasonal"
    let seasonalSource = RecipeDiscoverySource(
        id: "failing-seasonal",
        name: "Failing seasonal source",
        siteURL: URL(string: "https://failing.example")!,
        contentURL: URL(string: "https://failing.example/recipes")!,
        format: .provider,
        marketScope: .international,
        languageCodes: ["en"]
    )

    func recognizes(_ url: URL) -> Bool { false }

    func subscriptionCandidates(for url: URL) async throws -> [RecipeSiteCandidate] { [] }

    func discoverArticles(from candidate: RecipeSiteCandidate) async throws -> [ParsedFeedArticle] { [] }

    func seasonalCandidates(
        for moment: SeasonalRecipeMoment,
        context: RecipeDiscoveryMarketContext
    ) async throws -> [ParsedFeedArticle] {
        throw Failure.expected
    }

    private enum Failure: Error { case expected }
}

private struct StaticSeasonalCollectionProvider: SeasonalRecipeCollectionProviding {
    let articles: [ParsedFeedArticle]
    let id = "static-seasonal"
    let seasonalSource = RecipeDiscoverySource(
        id: "static-seasonal",
        name: "Static seasonal source",
        siteURL: URL(string: "https://seasonal.example")!,
        contentURL: URL(string: "https://seasonal.example/recipes")!,
        format: .provider,
        marketScope: .international,
        languageCodes: ["en"]
    )

    func recognizes(_ url: URL) -> Bool { false }

    func subscriptionCandidates(for url: URL) async throws -> [RecipeSiteCandidate] { [] }

    func discoverArticles(from candidate: RecipeSiteCandidate) async throws -> [ParsedFeedArticle] { articles }

    func seasonalCandidates(
        for moment: SeasonalRecipeMoment,
        context: RecipeDiscoveryMarketContext
    ) async throws -> [ParsedFeedArticle] { articles }
}

private actor SeasonalProviderCallTracker {
    private var active = 0
    private var maximumConcurrent = 0
    private var calls = 0

    func started() {
        calls += 1
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
    }

    func finished() {
        active -= 1
    }

    func snapshot() -> (calls: Int, maximumConcurrent: Int) {
        (calls, maximumConcurrent)
    }
}

private struct TrackingSeasonalCollectionProvider: SeasonalRecipeCollectionProviding {
    let id: String
    let tracker: SeasonalProviderCallTracker

    var seasonalSource: RecipeDiscoverySource {
        RecipeDiscoverySource(
            id: id,
            name: id,
            siteURL: URL(string: "https://\(id).example")!,
            contentURL: URL(string: "https://\(id).example/recipes")!,
            format: .provider,
            marketScope: .international,
            languageCodes: ["en"]
        )
    }

    func recognizes(_ url: URL) -> Bool { false }

    func subscriptionCandidates(for url: URL) async throws -> [RecipeSiteCandidate] { [] }

    func discoverArticles(from candidate: RecipeSiteCandidate) async throws -> [ParsedFeedArticle] { [] }

    func seasonalCandidates(
        for moment: SeasonalRecipeMoment,
        context: RecipeDiscoveryMarketContext
    ) async throws -> [ParsedFeedArticle] {
        await tracker.started()
        do {
            try await Task.sleep(for: .milliseconds(30))
        } catch {
            await tracker.finished()
            throw error
        }
        await tracker.finished()
        return []
    }
}
