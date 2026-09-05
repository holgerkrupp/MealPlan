import SwiftUI
import SwiftData

@MainActor
struct DishGridCell: View {
    let dish: Dish
    /// Set when the cell stands in for a whole variant group: this supplies
    /// the group name while the artwork comes from its leading dish.
    var variantGroupName: String? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                DishThumbnail(
                    dish: dish,
                    cornerRadius: cardCornerRadius,
                    width: proxy.size.width,
                    height: proxy.size.height
                )

                dishName
                    .padding(10)

                HStack(spacing: 6) {
                    if dish.needsReview, variantGroupName == nil {
                        statusIcon("exclamationmark.triangle.fill", tint: .orange)
                    }
                    if dish.isFavorite, variantGroupName == nil {
                        statusIcon("heart.fill", tint: .pink)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .aspectRatio(cardAspectRatio, contentMode: .fit)
        .clipShape(cellShape)
        // Without this the lift/drag preview falls back to the rectangular
        // bounds, so a long press draws sharp white corners around the card.
        .contentShape(previewShapeKinds, cellShape)
    }

    // .contextMenuPreview is iOS-only, so macOS gets the drag preview alone.
    private var previewShapeKinds: ContentShapeKinds {
        #if os(macOS)
        return [.dragPreview]
        #else
        return [.dragPreview, .contextMenuPreview]
        #endif
    }

    private var cellShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    private var cardCornerRadius: CGFloat { 24 }
    private var cardAspectRatio: CGFloat { 0.82 }

    private var displayName: String {
        if let variantGroupName, !variantGroupName.isEmpty { return variantGroupName }
        return dish.name.isEmpty ? String(localized: "Untitled dish") : dish.name
    }

    private var dishName: some View {
        Text(displayName)
            .font(.headline)
            .lineLimit(2)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.56), in: Capsule())
    }

    private func statusIcon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(9)
            .background(tint.opacity(0.84), in: Circle())
    }
}

#Preview {
    DishGridCell(dish: PreviewData.household.dishes?.first ?? Dish(name: "Test"))
        .frame(width: 200)
        .padding()
        .modelContainer(PreviewData.container)
}
