import SwiftUI
import SwiftData

/// The nutrition block on a recipe: what one serving is estimated to contain,
/// how heavy that makes the dish, and — just as important — how much of the
/// recipe the figure was actually built from.
///
/// Everything here is hedged on purpose. The heading says "estimated", every
/// number carries the app's `≈`, and a recipe we can't cover well enough
/// refuses to show a total at all rather than quietly showing a low one. See
/// `NutritionEstimate.isTrustworthy`.
@MainActor
struct NutritionSummaryView: View {
    let dish: Dish
    /// The head-count the detail screen is currently showing amounts for, so
    /// the block can also say what the whole pot comes to.
    var targetServings: Int

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @State private var editingIngredient: Ingredient?

    private var estimate: NutritionEstimate { NutritionEstimator.perServing(for: dish) }
    private var unit: EnergyUnit { appState.energyUnit }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if estimate.isTrustworthy {
                perServing
                macros
                if targetServings != 1 {
                    Text("For \(targetServings) servings: \(NutritionFormatting.energy(estimate.facts.scaled(by: Double(targetServings)), unit: unit))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                notEnoughData
            }

            footnotes
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editingIngredient) { ingredient in
            NavigationStack { IngredientNutritionEditor(ingredient: ingredient) }
                .dismissesOnOutsideClick()
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(String(localized: "Nutrition")).font(.headline)
            Text(String(localized: "Estimate"))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "These values are estimates"))
            Spacer()
        }
    }

    private var perServing: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(NutritionFormatting.energy(estimate.facts, unit: unit))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(String(localized: "per serving"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            NutritionBandBadge(band: .band(forKcalPerServing: estimate.facts.energyKcal))
        }
    }

    private var macros: some View {
        HStack(spacing: 18) {
            macro(String(localized: "Protein"), estimate.facts.proteinGrams)
            macro(String(localized: "Carbs"), estimate.facts.carbGrams)
            macro(String(localized: "Fat"), estimate.facts.fatGrams)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func macro(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(NutritionFormatting.grams(value))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
        }
    }

    /// Shown instead of a total when too much of the recipe is unaccounted
    /// for. A missing ingredient can only ever subtract, so a thin estimate is
    /// not a rough number — it is a number that is wrong in one direction.
    private var notEnoughData: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dish.sortedIngredients.isEmpty {
                Text("Add ingredients with amounts and MealPlan can estimate this dish.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not enough is known about the ingredients to estimate this dish.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let missing = NutritionFormatting.missingList(for: estimate) {
                    Text(missing).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if estimate.isTrustworthy, let note = NutritionFormatting.coverageNote(for: estimate) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if estimate.isTrustworthy, let missing = NutritionFormatting.missingList(for: estimate) {
                Text(missing).font(.caption).foregroundStyle(.secondary)
            }

            Text("Worked out from the ingredient list using average reference values. Real portions vary — treat it as a rough guide, not a nutrition label.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if !appState.isGuest, !unknownIngredients.isEmpty {
                Menu {
                    ForEach(unknownIngredients) { ingredient in
                        Button(ingredient.name) { editingIngredient = ingredient }
                    }
                } label: {
                    Label(String(localized: "Add missing values"), systemImage: "plus.circle")
                        .font(.caption)
                }
                .padding(.top, 2)
            }
        }
        .padding(.top, 2)
    }

    /// Catalogue entries behind the lines nothing recognised — the ones a cook
    /// can fix by typing what's on the package.
    private var unknownIngredients: [Ingredient] {
        var seen: Set<String> = []
        var result: [Ingredient] = []
        for line in dish.sortedIngredients {
            guard case .unknown = NutritionEstimator.outcome(for: line),
                  let ingredient = line.ingredient,
                  seen.insert(ingredient.normalizedName).inserted
            else { continue }
            result.append(ingredient)
        }
        return result
    }
}

/// "Light" / "Middling" / "Hearty" — the planner's shorthand for how a serving
/// sits next to the rest of the week.
struct NutritionBandBadge: View {
    let band: NutritionBand
    var compact = false

    private var tint: Color {
        switch band {
        case .light: .green
        case .moderate: .orange
        case .hearty: .red
        }
    }

    var body: some View {
        Group {
            if compact {
                Image(systemName: band.symbolName)
            } else {
                Label(band.localizedName, systemImage: band.symbolName)
            }
        }
            .font(compact ? .caption2 : .caption.weight(.medium))
            .padding(.horizontal, compact ? 5 : 9)
            .padding(.vertical, compact ? 2 : 4)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel(band.localizedName)
    }
}

#Preview("Nutrition summary") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            NutritionSummaryView(dish: PreviewData.richDish, targetServings: 4)
            Divider()
            NutritionSummaryView(dish: PreviewData.dish, targetServings: 2)
        }
        .padding()
    }
    .environment(AppState.preview)
    .modelContainer(PreviewData.container)
}

#Preview("Bands") {
    HStack {
        ForEach(NutritionBand.allCases, id: \.self) { NutritionBandBadge(band: $0) }
    }
    .padding()
}
