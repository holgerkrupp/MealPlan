import SwiftUI

/// Everything a feed article needs to be shown, whether it is already stored in
/// a subscribed feed or has only just been fetched to preview a site the user
/// has not subscribed to. Keeping this a plain value is what lets the card and
/// the reader serve both cases without knowing about SwiftData.
struct RecipeArticleContent: Identifiable, Hashable, Sendable {
    /// The feed's own stable id, which is also the key read state is kept under.
    let id: String
    var title: String
    var articleURL: URL?
    var imageURL: URL?
    var author: String?
    var summary: String?
    var publishedAt: Date?
    /// False once the article's own page has already been searched for a photo,
    /// so a page that has none is not fetched again on every scroll.
    var mayLookUpImage: Bool = true

    /// Read state lives in the iCloud key-value store, which is main-actor
    /// bound, so this is asked for on the main actor by the views that draw it.
    @MainActor
    var isRead: Bool { RecipeFeedReadState.isRead(id) }
}

extension RecipeArticleContent {
    /// An article belonging to a subscribed feed.
    @MainActor
    init(_ item: RecipeFeedItem) {
        id = item.stableID
        title = item.title
        articleURL = item.url
        imageURL = item.imageURL
        author = item.author
        summary = item.summary
        publishedAt = item.publishedAt
        mayLookUpImage = item.imageLookupAt == nil
    }

    /// An article from a feed that has only been fetched to look at.
    init(_ article: ParsedFeedArticle) {
        id = article.id
        title = article.title
        articleURL = article.url
        imageURL = article.imageURL
        author = article.author
        summary = article.summary
        publishedAt = article.publishedAt
    }
}

/// An article drawn as a dish card: same proportions, same corner radius, same
/// name capsule over the photo. A feed with no artwork falls back to the
/// newspaper glyph rather than an empty tile.
@MainActor
struct RecipeArticleCard: View {
    let article: RecipeArticleContent
    /// Handed the picture found on the article's own page, or `nil` when the
    /// page was read and had none. Not called when the page was unreachable.
    /// A subscribed feed writes the answer to its item; a preview lets it go.
    var onImageResolved: ((URL?) -> Void)? = nil

    @State private var resolvedImageURL: URL?

    private var imageURL: URL? { article.imageURL ?? resolvedImageURL }
    private var cardCornerRadius: CGFloat { 24 }
    private var cardAspectRatio: CGFloat { 0.82 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                RemoteRecipeImage(
                    url: imageURL,
                    tint: DishGlyph.tint(forName: article.title),
                    cornerRadius: cardCornerRadius,
                    width: proxy.size.width,
                    height: proxy.size.height
                )

                title
                    .padding(10)

                if !article.isRead {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 12, height: 12)
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
        .aspectRatio(cardAspectRatio, contentMode: .fit)
        .clipShape(cellShape)
        .contentShape(previewShapeKinds, cellShape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(article.title)
        .accessibilityValue(article.isRead ? "" : String(localized: "Unread"))
        // Only cards that actually get drawn go looking, and each article is
        // looked up once.
        .task(id: article.id) { await lookUpImage() }
    }

    private func lookUpImage() async {
        guard article.imageURL == nil, article.mayLookUpImage, resolvedImageURL == nil,
              let link = article.articleURL else { return }
        switch await RecipeFeedImageResolver.shared.lookUpImage(forArticleAt: link) {
        case .found(let url):
            resolvedImageURL = url
            onImageResolved?(url)
        case .none:
            onImageResolved?(nil)
        case .unreachable:
            return
        }
    }

    private var title: some View {
        Text(article.title)
            .font(.headline)
            .multilineTextAlignment(.leading)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var cellShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    // .contextMenuPreview is iOS-only, so macOS gets the drag preview alone.
    private var previewShapeKinds: ContentShapeKinds {
        #if os(macOS)
        return [.dragPreview]
        #else
        return [.dragPreview, .contextMenuPreview]
        #endif
    }
}

/// The grid the discovery screen and the subscribe preview both lay their
/// articles out in.
@MainActor
struct RecipeArticleGrid<Destination: View>: View {
    let articles: [RecipeArticleContent]
    var onImageResolved: ((RecipeArticleContent, URL?) -> Void)? = nil
    @ViewBuilder var destination: (RecipeArticleContent) -> Destination

    /// The same measurements the dish library uses, so an article card and a
    /// dish card line up when both are on screen on the same iPad.
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(articles) { article in
                NavigationLink {
                    destination(article)
                } label: {
                    RecipeArticleCard(article: article) { url in
                        onImageResolved?(article, url)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
