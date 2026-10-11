import SwiftUI
import SwiftData

/// Horizontal strip of dishes that fit the current season — either tagged
/// with the season or containing a seasonal ingredient.
@MainActor
struct SeasonalSuggestionsStrip: View {
    @Environment(AppState.self) private var appState
    let dishes: [Dish]

    @State private var planning: Dish?
    @State private var suggestions: [Dish] = []

    private var season: Season { Season.current() }

    private struct Revision: Hashable {
        var count: Int
        var latestModification: Date?
    }

    private var revision: Revision {
        Revision(count: dishes.count, latestModification: dishes.lazy.map(\.modifiedAt).max())
    }

    var body: some View {
        Group {
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(String(localized: "In season now"), systemImage: "leaf")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, MacLayout.gutter)

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
                                            // A fixed caption box: two lines that
                                            // shrink to fit, so a long name shows
                                            // in full without making the strip
                                            // taller than its neighbours.
                                            .lineLimit(2)
                                            .minimumScaleFactor(0.7)
                                            .frame(width: 96, height: 28, alignment: .topLeading)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, MacLayout.gutter)
                    }
                }
                .padding(.top, 8)
                .detailPresentation(item: $planning, route: { .planRecipe($0.uuid) }) { dish in
                    NavigationStack { PlanDishSheet(dish: dish, defaultDate: appState.selectedDate) }
                        .presentationDetents([.medium])
                        .dismissesOnOutsideClick()
                }
            }
        }
        .task(id: revision) {
            await refreshSuggestions()
        }
    }

    /// Ingredient relationships are SwiftData faults. Scanning every recipe
    /// while SwiftUI is constructing the tab made Plan → Dishes wait for the
    /// complete library. Explicit season labels are cheap and immediate; the
    /// ingredient fallback runs after the first frame, yields regularly, and
    /// examines a useful bounded set of the least-recently-cooked recipes.
    private func refreshSuggestions() async {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        let currentSeason = season
        var selected = dishes
            .filter { $0.season == currentSeason }
            .sorted(by: suggestionOrder)
        if selected.count >= 10 {
            suggestions = Array(selected.prefix(10))
            return
        }

        let candidates = dishes
            .filter { $0.season != currentSeason }
            .sorted(by: suggestionOrder)
            .prefix(120)

        for (offset, dish) in candidates.enumerated() {
            if dish.sortedIngredients.contains(where: { line in
                guard let name = line.ingredient?.name else { return false }
                return SeasonalProduce.seasons(forIngredientNamed: name).contains(currentSeason)
            }) {
                selected.append(dish)
                if selected.count == 10 { break }
            }

            if offset.isMultiple(of: 8) {
                await Task.yield()
                guard !Task.isCancelled else { return }
            }
        }

        suggestions = Array(selected.sorted(by: suggestionOrder).prefix(10))
    }

    private func suggestionOrder(_ lhs: Dish, _ rhs: Dish) -> Bool {
        let left = lhs.lastUsedDate ?? .distantPast
        let right = rhs.lastUsedDate ?? .distantPast
        if left != right { return left < right }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

#Preview {
    SeasonalSuggestionsStrip(dishes: PreviewData.household.dishes ?? [])
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
