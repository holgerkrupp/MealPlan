import Foundation

/// The inputs needed to build Discover recipes' value-only stream. SwiftData
/// objects are reduced to this type before any work is handed to a task.
struct RecipeDiscoveryArticleSeed: Sendable {
    let stableID: String
    let title: String
    let articleURL: URL?
    let imageURL: URL?
    let author: String?
    let summary: String?
    let publishedAt: Date?
    let sourceID: String
    let sourceName: String
    let date: Date
    let isArchived: Bool
    let providerTags: [String]
    let body: String?
    let mayLookUpImage: Bool
    let isSubscribed: Bool

    var id: String { "\(sourceID):\(stableID)" }
    var readStateID: String { isSubscribed ? stableID : id }
}

struct RecipeDiscoveryArticle: Identifiable, Hashable, Sendable {
    let id: String
    let readStateID: String
    let title: String
    let articleURL: URL?
    let imageURL: URL?
    let author: String?
    let summary: String?
    let publishedAt: Date?
    let sourceID: String
    let sourceName: String
    let date: Date
    let isArchived: Bool
    let categories: Set<RecipeDiscoveryCategory>
    let mayLookUpImage: Bool
    let isRead: Bool

    func withReadState(_ isRead: Bool) -> Self {
        Self(
            id: id,
            readStateID: readStateID,
            title: title,
            articleURL: articleURL,
            imageURL: imageURL,
            author: author,
            summary: summary,
            publishedAt: publishedAt,
            sourceID: sourceID,
            sourceName: sourceName,
            date: date,
            isArchived: isArchived,
            categories: categories,
            mayLookUpImage: mayLookUpImage,
            isRead: isRead
        )
    }

    func withImageURL(_ imageURL: URL?) -> Self {
        Self(
            id: id,
            readStateID: readStateID,
            title: title,
            articleURL: articleURL,
            imageURL: imageURL,
            author: author,
            summary: summary,
            publishedAt: publishedAt,
            sourceID: sourceID,
            sourceName: sourceName,
            date: date,
            isArchived: isArchived,
            categories: categories,
            mayLookUpImage: false,
            isRead: isRead
        )
    }
}

struct RecipeDiscoveryQuery: Equatable, Sendable {
    var search = ""
    var scope: RecipeArticleScope = .current
    var sourceID: String?
    var category: RecipeDiscoveryCategory?
    var sort: RecipeArticleSort = .mixed

    var isFiltering: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || scope != .current
            || sourceID != nil
            || category != nil
    }
}

/// A complete, value-only Discover state. The view reads this during layout;
/// classification, deduplication and sorting happen only when this snapshot
/// is built or a query/read state changes.
struct RecipeDiscoverySnapshot: Sendable {
    static let empty = Self(
        allArticles: [], categoryCandidates: [], availableCategories: [],
        visibleArticles: [], query: RecipeDiscoveryQuery()
    )

    let allArticles: [RecipeDiscoveryArticle]
    let categoryCandidates: [RecipeDiscoveryArticle]
    let availableCategories: [RecipeDiscoveryCategory]
    let visibleArticles: [RecipeDiscoveryArticle]
    let query: RecipeDiscoveryQuery

    static func build(
        seeds: [RecipeDiscoveryArticleSeed],
        sourceOrder: [String],
        query: RecipeDiscoveryQuery,
        readIDs: Set<String>
    ) -> Self {
        let normalized = normalize(seeds: seeds, readIDs: readIDs)
        return make(normalized, sourceOrder: sourceOrder, query: query)
    }

    func applying(query: RecipeDiscoveryQuery) -> Self {
        Self.make(allArticles, sourceOrder: sourceOrder, query: query)
    }

    func applying(readIDs: Set<String>) -> Self {
        let updated = allArticles.map { $0.withReadState(readIDs.contains($0.readStateID)) }
        return Self.make(updated, sourceOrder: sourceOrder, query: query)
    }

    func applying(imageURL: URL?, to articleID: String) -> Self {
        let updated = allArticles.map { article in
            article.id == articleID ? article.withImageURL(imageURL) : article
        }
        return Self(
            allArticles: updated,
            categoryCandidates: categoryCandidates.map { $0.id == articleID ? $0.withImageURL(imageURL) : $0 },
            availableCategories: availableCategories,
            visibleArticles: visibleArticles.map { $0.id == articleID ? $0.withImageURL(imageURL) : $0 },
            query: query,
            sourceOrder: sourceOrder
        )
    }

    private let sourceOrder: [String]

    private init(
        allArticles: [RecipeDiscoveryArticle],
        categoryCandidates: [RecipeDiscoveryArticle],
        availableCategories: [RecipeDiscoveryCategory],
        visibleArticles: [RecipeDiscoveryArticle],
        query: RecipeDiscoveryQuery,
        sourceOrder: [String] = []
    ) {
        self.allArticles = allArticles
        self.categoryCandidates = categoryCandidates
        self.availableCategories = availableCategories
        self.visibleArticles = visibleArticles
        self.query = query
        self.sourceOrder = sourceOrder
    }

    private static func normalize(
        seeds: [RecipeDiscoveryArticleSeed],
        readIDs: Set<String>
    ) -> [RecipeDiscoveryArticle] {
        var seenURLs = Set<String>()
        return seeds.compactMap { seed in
            let urlKey = seed.articleURL?.absoluteString ?? seed.id
            guard seenURLs.insert(urlKey).inserted else { return nil }
            guard seed.isSubscribed || RecipeArticleClassifier.isLikelyRecipe(
                title: seed.title,
                summary: seed.summary,
                url: seed.articleURL,
                providerTags: seed.providerTags,
                body: seed.body
            ) else { return nil }
            return RecipeDiscoveryArticle(
                id: seed.id,
                readStateID: seed.readStateID,
                title: seed.title,
                articleURL: seed.articleURL,
                imageURL: seed.imageURL,
                author: seed.author,
                summary: seed.summary,
                publishedAt: seed.publishedAt,
                sourceID: seed.sourceID,
                sourceName: seed.sourceName,
                date: seed.date,
                isArchived: seed.isArchived,
                categories: RecipeDiscoveryCategory.categories(
                    title: seed.title,
                    summary: seed.summary,
                    providerTags: seed.providerTags
                ),
                mayLookUpImage: seed.mayLookUpImage,
                isRead: readIDs.contains(seed.readStateID)
            )
        }
    }

    private static func make(
        _ allArticles: [RecipeDiscoveryArticle],
        sourceOrder: [String],
        query: RecipeDiscoveryQuery
    ) -> Self {
        let candidates = allArticles.filter { article in
            (query.sourceID == nil || article.sourceID == query.sourceID)
                && RecipeArticleFilter.matches(
                    .init(
                        title: article.title,
                        summary: article.summary,
                        author: article.author,
                        feedTitle: article.sourceName,
                        date: article.date,
                        isArchived: article.isArchived,
                        isRead: article.isRead
                    ),
                    scope: query.scope,
                    search: query.search
                )
        }

        var categoryMembership = Set<RecipeDiscoveryCategory>()
        for article in candidates { categoryMembership.formUnion(article.categories) }
        let available = RecipeDiscoveryCategory.allCases.filter { categoryMembership.contains($0) }
        let matching = query.category.map { category in
            candidates.filter { $0.categories.contains(category) }
        } ?? candidates

        let visible: [RecipeDiscoveryArticle]
        if query.sort == .mixed {
            // Group in one pass. The previous sourceOptions.map/filter approach
            // scanned all matching articles once per source.
            var groups: [String: [RecipeDiscoveryArticle]] = [:]
            for article in matching { groups[article.sourceID, default: []].append(article) }
            let orderedIDs = sourceOrder + groups.keys.filter { !sourceOrder.contains($0) }
            let groupsInOrder = orderedIDs.compactMap { sourceID in
                groups[sourceID]?.sorted { lhs, rhs in
                    RecipeArticleFilter.areInOrder(candidate(lhs), candidate(rhs), sort: .newest)
                }
            }
            visible = Array(RecipeArticleFilter.interleave(groupsInOrder).prefix(query.isFiltering ? 80 : 40))
        } else {
            visible = Array(matching.sorted {
                RecipeArticleFilter.areInOrder(candidate($0), candidate($1), sort: query.sort)
            }.prefix(query.isFiltering ? 80 : 40))
        }

        return Self(
            allArticles: allArticles,
            categoryCandidates: candidates,
            availableCategories: available,
            visibleArticles: visible,
            query: query,
            sourceOrder: sourceOrder
        )
    }

    private static func candidate(_ article: RecipeDiscoveryArticle) -> RecipeArticleFilter.Candidate {
        .init(
            title: article.title,
            summary: article.summary,
            author: article.author,
            feedTitle: article.sourceName,
            date: article.date,
            isArchived: article.isArchived,
            isRead: article.isRead
        )
    }
}
