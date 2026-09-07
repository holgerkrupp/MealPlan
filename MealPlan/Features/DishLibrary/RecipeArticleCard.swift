import SwiftData
import SwiftUI

/// An article drawn as a dish card: same proportions, same corner radius, same
/// name capsule over the photo. A feed with no artwork falls back to the
/// newspaper glyph rather than an empty tile.
@MainActor
struct RecipeArticleCard: View {
    let item: RecipeFeedItem

    @Environment(\.modelContext) private var context

    private var isRead: Bool { RecipeFeedReadState.isRead(item.stableID) }

    /// True while this card has no picture and has not yet been to the
    /// article's own page to look for one.
    private var needsImageLookup: Bool {
        item.imageURL == nil && item.imageLookupAt == nil && item.url != nil
    }
    private var cardCornerRadius: CGFloat { 24 }
    private var cardAspectRatio: CGFloat { 0.82 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                RemoteRecipeImage(
                    url: item.imageURL,
                    tint: DishGlyph.tint(forName: item.title),
                    cornerRadius: cardCornerRadius,
                    width: proxy.size.width,
                    height: proxy.size.height
                )

                title
                    .padding(10)

                if !isRead {
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
        .accessibilityLabel(item.title)
        .accessibilityValue(isRead ? "" : String(localized: "Unread"))
        // Only cards that actually get drawn go looking, and each article is
        // looked up once. Writing the result back re-renders this card with
        // the photo in place.
        .task(id: item.stableID) { await lookUpImage() }
    }

    private func lookUpImage() async {
        guard needsImageLookup, let link = item.url else { return }
        switch await RecipeFeedImageResolver.shared.lookUpImage(forArticleAt: link) {
        case .found(let url):
            item.imageURLString = url.absoluteString
            item.imageLookupAt = .now
        case .none:
            item.imageLookupAt = .now
        case .unreachable:
            return
        }
        try? context.save()
    }

    private var title: some View {
        Text(item.title)
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
