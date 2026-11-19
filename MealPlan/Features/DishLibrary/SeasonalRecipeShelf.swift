import SwiftUI

struct SeasonalRecipeMomentRoute: Identifiable, Hashable {
    let momentID: String
    let title: String
    let symbolName: String
    let articles: [RecipeDiscoveryArticle]

    var id: String { momentID }
}

enum SeasonalRecipeShelfPolicy {
    static let minimumArticles = 3
    static let maximumMoments = 2

    /// Preserve the calendar's stable moment order while hiding thin results
    /// and limiting how far the normal Discover grid is pushed down.
    static func overviewCollections(_ collections: [SeasonalRecipeCollection]) -> [SeasonalRecipeCollection] {
        Array(collections.filter { $0.articles.count >= minimumArticles }.prefix(maximumMoments))
    }

    static func route(for collection: SeasonalRecipeCollection) -> SeasonalRecipeMomentRoute {
        SeasonalRecipeMomentRoute(
            momentID: collection.moment.id,
            title: collection.moment.localizedTitle,
            symbolName: collection.moment.symbolName ?? "leaf",
            articles: collection.articles
        )
    }
}

/// A compact, value-only preview of one active seasonal recipe collection.
/// The moment title and symbol come from calendar metadata; this view has no
/// event-specific presentation rules.
@MainActor
struct SeasonalRecipeShelf: View {
    let title: String
    let symbolName: String
    let articles: [RecipeDiscoveryArticle]
    let readIDs: Set<String>
    let onSeeAll: () -> Void
    let onRead: (RecipeArticleContent) -> Void
    let onImageResolved: (RecipeArticleContent, URL?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(title, systemImage: symbolName)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 8)

                Button(action: onSeeAll) {
                    Text(String(localized: "Show all"))
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Show all seasonal recipes"))
            }
            .padding(.horizontal, MacLayout.gutter)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(articles) { article in
                        let content = RecipeArticleContent(
                            article.withReadState(article.isRead || readIDs.contains(article.readStateID))
                        )
                        NavigationLink {
                            RecipeArticleReaderView(
                                article: content,
                                onRead: { onRead(content) },
                                onImageResolved: { onImageResolved(content, $0) }
                            )
                        } label: {
                            RecipeArticleCard(article: content) { url in
                                onImageResolved(content, url)
                            }
                        }
                        .frame(width: 174)
                        .buttonStyle(.plain)
                        .accessibilityHint(String(localized: "Open seasonal recipe"))
                    }
                }
                .padding(.horizontal, MacLayout.gutter)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 8)
    }
}

/// The destination behind a seasonal shelf's “Show all” action. It uses the
/// same discovery card and reader as the normal grid without changing the
/// normal query, source filter, or selected category.
@MainActor
struct SeasonalRecipeMomentGrid: View {
    let title: String
    let symbolName: String
    let articles: [RecipeDiscoveryArticle]
    let readIDs: Set<String>
    let onRead: (RecipeArticleContent) -> Void
    let onImageResolved: (RecipeArticleContent, URL?) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Label(title, systemImage: symbolName)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)

                RecipeArticleGrid(
                    articles: articles.map { article in
                        RecipeArticleContent(
                            article.withReadState(article.isRead || readIDs.contains(article.readStateID))
                        )
                    },
                    onImageResolved: onImageResolved
                ) { article in
                    RecipeArticleReaderView(
                        article: article,
                        onRead: { onRead(article) },
                        onImageResolved: { onImageResolved(article, $0) }
                    )
                }
            }
            .padding(MacLayout.gutter)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

extension RecipeArticleContent {
    init(_ article: RecipeDiscoveryArticle) {
        self.init(
            id: article.id,
            readStateID: article.readStateID,
            title: article.title,
            articleURL: article.articleURL,
            imageURL: article.imageURL,
            author: article.author,
            summary: article.summary,
            publishedAt: article.publishedAt,
            sourceName: article.sourceName,
            mayLookUpImage: article.mayLookUpImage,
            isRead: article.isRead
        )
    }
}
