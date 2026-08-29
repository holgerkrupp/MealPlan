import SwiftUI
import SwiftData

@MainActor
struct DishGridCell: View {
    let dish: Dish

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                DishThumbnail(dish: dish, size: cellImageSize, cornerRadius: 16)
                    .frame(maxWidth: .infinity)

                if dish.needsReview {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.orange, in: Circle())
                        .padding(6)
                }
                if dish.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.pink, in: Circle())
                        .padding(6)
                        .offset(x: dish.needsReview ? -34 : 0)
                }
            }

            Text(dish.name.isEmpty ? String(localized: "Untitled dish") : dish.name)
                .font(.headline)
                .lineLimit(2)
                .foregroundStyle(.primary)

            HStack(spacing: 6) {
                if dish.rating > 0 {
                    Text(String(repeating: "★", count: dish.rating))
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                ForEach(Array(dish.dietaryTags).sorted(by: { $0.rawValue < $1.rawValue }).prefix(3)) { tag in
                    Image(systemName: tag.symbolName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let minutes = dish.totalTimeMinutes {
                    Label("\(minutes) min", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }

            stalenessChip
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var cellImageSize: CGFloat { 150 }

    @ViewBuilder
    private var stalenessChip: some View {
        if dish.usageCount == 0 && dish.lastUsedDate == nil {
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

#Preview {
    DishGridCell(dish: PreviewData.household.dishes?.first ?? Dish(name: "Test"))
        .frame(width: 200)
        .padding()
        .modelContainer(PreviewData.container)
}
