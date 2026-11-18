import SwiftUI
import SwiftData

/// Scalar-only data used while SwiftUI draws a library card. Constructing the
/// thumbnail from these values avoids reading a Dish or its lazy relationships
/// during card layout.
struct DishLibraryCardSnapshot: Equatable, Identifiable {
    var id: UUID
    var persistentID: PersistentIdentifier?
    var name: String
    var glyph: DishGlyph?
    var unsavedImageData: Data?
    var isFavorite: Bool
    var needsReview: Bool
    var modifiedAt: Date

    init(_ dish: Dish) {
        let persistentID = DishPhotoLoading.persistentID(for: dish)
        id = dish.uuid
        self.persistentID = persistentID
        unsavedImageData = persistentID == nil ? dish.primaryImage?.data : nil
        name = dish.name
        glyph = dish.glyph
        isFavorite = dish.isFavorite
        needsReview = dish.needsReview
        modifiedAt = dish.modifiedAt
    }

    var photoCacheKey: String {
        "dish-\(id)-\(modifiedAt.timeIntervalSinceReferenceDate)"
    }
}

@MainActor
struct DishGridCell: View {
    let snapshot: DishLibraryCardSnapshot
    /// Set when the cell stands in for a whole variant group: this supplies
    /// the group name while the artwork comes from its leading dish.
    var variantGroupName: String? = nil

    init(snapshot: DishLibraryCardSnapshot, variantGroupName: String? = nil) {
        self.snapshot = snapshot
        self.variantGroupName = variantGroupName
    }

    /// Other detail surfaces can still pass a model; the grid cell immediately
    /// reduces it to the same scalar snapshot used by the library.
    init(dish: Dish, variantGroupName: String? = nil) {
        self.init(snapshot: DishLibraryCardSnapshot(dish), variantGroupName: variantGroupName)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                thumbnail(size: proxy.size)

                dishName
                    .padding(10)

                HStack(spacing: 6) {
                    if snapshot.needsReview, variantGroupName == nil {
                        statusIcon("exclamationmark.triangle.fill", tint: .orange)
                    }
                    if snapshot.isFavorite, variantGroupName == nil {
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
        // The name sits on the photo and the review / favourite badges are
        // colour-coded corner glyphs — fold all of it into one spoken element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayName)
        .accessibilityValue(statusValue)
    }

    private var statusValue: String {
        guard variantGroupName == nil else { return "" }
        var parts: [String] = []
        if snapshot.isFavorite { parts.append(String(localized: "Favourite")) }
        if snapshot.needsReview { parts.append(String(localized: "Needs review")) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func thumbnail(size: CGSize) -> some View {
        let tint = DishGlyph.tint(forName: snapshot.name)
        if let persistentID = snapshot.persistentID {
            DishThumbnail(
                dishID: persistentID,
                dishUUID: snapshot.id,
                cacheKey: snapshot.photoCacheKey,
                glyph: snapshot.glyph,
                tint: tint,
                cornerRadius: cardCornerRadius,
                width: size.width,
                height: size.height
            )
        } else {
            DishThumbnail(
                data: snapshot.unsavedImageData,
                glyph: snapshot.glyph,
                tint: tint,
                cornerRadius: cardCornerRadius,
                width: size.width,
                height: size.height
            )
        }
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
        return snapshot.name.isEmpty ? String(localized: "Untitled dish") : snapshot.name
    }

    private var dishName: some View {
        Text(displayName)
            .font(.headline)
            // No line limit: a recipe's name is how the cook picks it out of
            // the grid, so the capsule grows up the card rather than ending in
            // an ellipsis that hides which of two similar dishes this is.
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Sits over an arbitrary photo — a heavier scrim keeps the name
            // readable on bright images (WCAG AA against white text). A capsule
            // would round itself into a circle as soon as the name wraps, so
            // the scrim is a rounded rectangle instead.
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    DishGridCell(snapshot: DishLibraryCardSnapshot(PreviewData.household.dishes?.first ?? Dish(name: "Test")))
        .frame(width: 200)
        .padding()
        .modelContainer(PreviewData.container)
}
