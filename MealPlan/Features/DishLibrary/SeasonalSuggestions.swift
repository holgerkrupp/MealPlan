import SwiftUI
import SwiftData

/// Horizontal strip of dishes that fit the current season — either tagged
/// with the season or containing a seasonal ingredient.
@MainActor
struct SeasonalSuggestionsStrip: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @State private var planning: Dish?

    private var season: Season { Season.current() }

    private var suggestions: [Dish] {
        allDishes.filter { dish in
            if dish.season == season { return true }
            return dish.sortedIngredients.contains { line in
                guard let name = line.ingredient?.name else { return false }
                return SeasonalProduce.seasons(forIngredientNamed: name).contains(season)
            }
        }
        .sorted { ($0.lastUsedDate ?? .distantPast) < ($1.lastUsedDate ?? .distantPast) }
        .prefix(10)
        .map { $0 }
    }

    var body: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "In season now"), systemImage: "leaf")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(suggestions) { dish in
                            Button {
                                planning = dish
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    DishThumbnail(dish: dish, size: 96, cornerRadius: 12)
                                    Text(dish.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(width: 96, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.top, 8)
            .sheet(item: $planning) { dish in
                NavigationStack { PlanDishSheet(dish: dish, defaultDate: appState.selectedDate) }
                    .presentationDetents([.medium])
            }
        }
    }
}

#Preview {
    SeasonalSuggestionsStrip()
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
