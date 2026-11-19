import Foundation

/// Optional enrichment capability for existing public recipe providers.
/// Implementations should fetch only stable public collection/index metadata,
/// use the provider's existing timeout/cache behavior, and never open each
/// recipe page merely to classify it.
protocol SeasonalRecipeCollectionProviding: RecipeDiscoveryProvider {
    var seasonalSource: RecipeDiscoverySource { get }

    func seasonalCandidates(
        for moment: SeasonalRecipeMoment,
        context: RecipeDiscoveryMarketContext
    ) async throws -> [ParsedFeedArticle]
}

extension RecipeSiteDiscoveryService {
    static var seasonalProviders: [any SeasonalRecipeCollectionProviding] {
        providers.compactMap { $0 as? any SeasonalRecipeCollectionProviding }
    }
}

struct SeasonalRecipeProviderLoad: Sendable {
    let seeds: [RecipeDiscoveryArticleSeed]
    let sources: [RecipeDiscoverySource]
    let failedProviderIDs: [String]

    static let empty = Self(seeds: [], sources: [], failedProviderIDs: [])
}

enum SeasonalRecipeCollectionLoader {
    static let maximumConcurrentProviders = 2
    static let maximumProviders = 6
    static let maximumArticlesPerProvider = 12

    /// Provider failures are isolated. Callers can combine the returned seeds
    /// with the regular Discover seeds and keep building the shelf when this
    /// optional enrichment returns nothing.
    static func load(
        moment: SeasonalRecipeMoment,
        context: RecipeDiscoveryMarketContext,
        providers: [any SeasonalRecipeCollectionProviding] = RecipeSiteDiscoveryService.seasonalProviders
    ) async -> SeasonalRecipeProviderLoad {
        enum Outcome: Sendable {
            case success(Int, RecipeDiscoverySource, [ParsedFeedArticle])
            case failure(Int, String)
        }

        let boundedProviders = Array(providers.prefix(maximumProviders))
        guard !boundedProviders.isEmpty else { return .empty }
        var outcomes: [Outcome] = []

        for start in stride(from: 0, to: boundedProviders.count, by: maximumConcurrentProviders) {
            let end = min(start + maximumConcurrentProviders, boundedProviders.count)
            let batch = await withTaskGroup(of: Outcome.self) { group in
                for index in start..<end {
                    let provider = boundedProviders[index]
                    group.addTask {
                        do {
                            let articles = try await provider.seasonalCandidates(for: moment, context: context)
                            return .success(index, provider.seasonalSource, Array(articles.prefix(maximumArticlesPerProvider)))
                        } catch {
                            return .failure(index, provider.seasonalSource.id)
                        }
                    }
                }

                var collected: [Outcome] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            outcomes.append(contentsOf: batch)
        }

        let ordered = outcomes.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case (.success(let left, _, _), .success(let right, _, _)): left < right
            case (.failure(let left, _), .failure(let right, _)): left < right
            case (.success(let left, _, _), .failure(let right, _)): left < right
            case (.failure(let left, _), .success(let right, _, _)): left < right
            }
        }

        var seeds: [RecipeDiscoveryArticleSeed] = []
        var sources: [RecipeDiscoverySource] = []
        var failures: [String] = []
        for outcome in ordered {
            switch outcome {
            case .success(_, let source, let articles):
                sources.append(source)
                seeds.append(contentsOf: articles.map { article in
                    RecipeDiscoveryArticleSeed(
                        stableID: article.id,
                        title: article.title,
                        articleURL: article.url,
                        imageURL: article.imageURL,
                        author: article.author,
                        summary: article.summary,
                        publishedAt: article.publishedAt,
                        sourceID: "discovery:\(source.id)",
                        sourceName: source.name,
                        date: article.publishedAt ?? .distantPast,
                        isArchived: false,
                        providerTags: article.categories,
                        body: article.body,
                        mayLookUpImage: true,
                        isSubscribed: false
                    )
                })
            case .failure(_, let id):
                failures.append(id)
            }
        }

        return SeasonalRecipeProviderLoad(
            seeds: SeasonalRecipeURL.unique(seeds),
            sources: sources,
            failedProviderIDs: failures
        )
    }

    static func merging(
        normalSeeds: [RecipeDiscoveryArticleSeed],
        targetedLoad: SeasonalRecipeProviderLoad
    ) -> [RecipeDiscoveryArticleSeed] {
        SeasonalRecipeURL.appendingUnique(existing: normalSeeds, targeted: targetedLoad.seeds)
    }
}
