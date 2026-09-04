import SwiftUI

/// The day's estimate, in the calendar's day header.
///
/// This is the point of the whole feature for the planner: seeing that
/// Saturday came to 2 600 kcal a head is what makes someone plan a salad for
/// Sunday. It stays small and grey — a plan is still a plan when nobody is
/// counting — and it disappears entirely when the week is too thin to say
/// anything honest.
@MainActor
struct DayNutritionBadge: View {
    let estimate: NutritionEstimate
    let standing: NutritionDayStanding?
    let unit: EnergyUnit

    var body: some View {
        if estimate.isTrustworthy, estimate.facts.energyKcal > 0 {
            HStack(spacing: 5) {
                Text(NutritionFormatting.energy(estimate.facts, unit: unit))
                    .monospacedDigit()
                if let standing {
                    Image(systemName: standing.symbolName)
                        .imageScale(.small)
                        .foregroundStyle(tint(standing))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .help(helpText)
        }
    }

    private func tint(_ standing: NutritionDayStanding) -> Color {
        switch standing {
        case .lighter: .green
        case .typical: .secondary
        case .heavier: .orange
        }
    }

    private var accessibilityLabel: String {
        let energy = NutritionFormatting.energy(estimate.facts, unit: unit)
        guard let standing else {
            return String(localized: "Estimated \(energy) per person")
        }
        return String(localized: "Estimated \(energy) per person. \(standing.localizedName)")
    }

    private var helpText: String {
        guard let standing else {
            return String(localized: "Estimated for one person across this day's meals.")
        }
        return standing.localizedName
    }
}

/// One planned meal's estimate, on its card in the calendar.
///
/// Deliberately just an energy figure and nothing else: a meal card is already
/// dense, and the per-dish detail is one tap away. Font and colour come from
/// the row it sits in, which is grey on a plain card and white on a photo.
@MainActor
struct MealNutritionCaption: View {
    let dish: Dish
    let unit: EnergyUnit

    var body: some View {
        let estimate = NutritionEstimator.perServing(for: dish)
        if estimate.isTrustworthy, estimate.facts.energyKcal > 0 {
            Text(NutritionFormatting.energy(estimate.facts, unit: unit))
                .monospacedDigit()
                .accessibilityLabel(String(
                    localized: "Estimated \(NutritionFormatting.energy(estimate.facts, unit: unit)) per serving"
                ))
        }
    }
}

#Preview("Day badge") {
    VStack(alignment: .leading, spacing: 10) {
        DayNutritionBadge(
            estimate: NutritionEstimate(
                facts: NutritionFacts(energyKcal: 2_480, proteinGrams: 90, carbGrams: 250, fatGrams: 95),
                countedLines: 12,
                origin: .computed
            ),
            standing: .heavier,
            unit: .kilocalories
        )
        DayNutritionBadge(
            estimate: NutritionEstimate(
                facts: NutritionFacts(energyKcal: 1_320, proteinGrams: 60, carbGrams: 140, fatGrams: 40),
                countedLines: 9,
                origin: .computed
            ),
            standing: .lighter,
            unit: .kilocalories
        )
    }
    .padding()
}
