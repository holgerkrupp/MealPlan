import SwiftUI
import SwiftData

@MainActor
struct DishGridCell: View {
    let dish: Dish
    /// Set when the cell stands in for a whole variant group: the name and
    /// count come from the group, the artwork from its leading dish.
    var variantGroupName: String? = nil
    var variantCount: Int = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                DishThumbnail(
                    dish: dish,
                    cornerRadius: cardCornerRadius,
                    width: proxy.size.width,
                    height: proxy.size.height
                )

                VStack(alignment: .leading, spacing: 7) {
                    dishName

                    HStack(spacing: 6) {
                        dishMetadata
                        stalenessChip
                    }
                }
                .padding(10)

                HStack(spacing: 6) {
                    if variantCount > 1 {
                        variantBadge
                    }
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

    private var variantBadge: some View {
        Label("\(variantCount)", systemImage: "square.on.square")
            .font(.caption2.weight(.bold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.indigo)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .glassEffect(.regular.tint(.indigo.opacity(0.18)), in: Capsule())
    }

    private var displayName: String {
        if let variantGroupName, !variantGroupName.isEmpty { return variantGroupName }
        return dish.name.isEmpty ? String(localized: "Untitled dish") : dish.name
    }

    private var dishName: some View {
        Text(displayName)
            .font(.headline)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
    }

    @ViewBuilder
    private var dishMetadata: some View {
        if variantGroupName != nil {
            Text(String(localized: "\(variantCount) variants"))
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: Capsule())
        } else {
            HStack(spacing: 6) {
                if dish.rating > 0 {
                    Text(String(repeating: "★", count: dish.rating))
                        .foregroundStyle(.yellow)
                }
                ForEach(Array(dish.dietaryTags).sorted(by: { $0.rawValue < $1.rawValue }).prefix(3)) { tag in
                    Image(systemName: tag.symbolName)
                }
                if let minutes = dish.totalTimeMinutes {
                    Label("\(minutes) min", systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())
        }
    }

    @ViewBuilder
    private var stalenessChip: some View {
        if variantGroupName != nil {
            EmptyView()
        } else if dish.usageCount == 0 && dish.lastUsedDate == nil {
            chip(String(localized: "Never cooked"), system: "sparkles", tint: .blue)
        } else if let days = dish.daysSinceLastCooked(), days >= 30 {
            chip(String(localized: "\(days) days ago"), system: "clock.badge.exclamationmark", tint: .orange)
        } else if let days = dish.daysSinceLastCooked() {
            chip(String(localized: "Cooked \(days) d ago"), system: "checkmark.circle", tint: .green)
        }
    }

    private func chip(_ text: String, system: String, tint: Color) -> some View {
        Label(text, systemImage: system)
            .font(.caption2)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(tint)
            .glassEffect(.regular.tint(tint.opacity(0.18)), in: Capsule())
    }

    private func statusIcon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(9)
            .glassEffect(.regular.tint(tint.opacity(0.18)), in: Circle())
    }
}

#Preview {
    DishGridCell(dish: PreviewData.household.dishes?.first ?? Dish(name: "Test"))
        .frame(width: 200)
        .padding()
        .modelContainer(PreviewData.container)
}
