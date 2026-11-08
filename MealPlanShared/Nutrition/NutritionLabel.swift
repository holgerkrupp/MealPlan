import Foundation

/// A per-serving breakdown laid out the way a packaging label reads — energy,
/// fat (saturated), cholesterol, sodium, carbohydrate (fibre, sugar), protein —
/// built from whatever MealPlan actually knows about a dish.
///
/// It looks like a nutrition label, but it is never presented as one: every
/// label says where its numbers come from (`source`), a value nobody knows
/// stays `nil` and is shown as unknown rather than as zero, and an estimate
/// carries how many ingredients it was built from. The bundled reference
/// table and the household's own ingredient values only hold energy, protein,
/// carbohydrate and fat, so an estimated label leaves the other rows unknown
/// instead of adding up partial figures.
struct NutritionLabel: Equatable, Sendable {

    enum Source: Equatable, Sendable {
        /// Carried in with the recipe (schema.org `NutritionInformation`).
        case statedByRecipe
        /// Typed by someone in the household, usually off a package.
        case enteredByHand
        /// Added up by MealPlan from the ingredient list.
        case estimated
    }

    enum Nutrient: String, CaseIterable, Sendable {
        case energy, fat, saturatedFat, cholesterol, sodium, carbs, fiber, sugar, protein

        /// Shown indented under its parent, as on a package.
        var isSubRow: Bool { self == .saturatedFat || self == .fiber || self == .sugar }

        var isMilligrams: Bool { self == .cholesterol || self == .sodium }

        var localizedName: String {
            switch self {
            case .energy: String(localized: "Energy")
            case .fat: String(localized: "Fat")
            case .saturatedFat: String(localized: "Saturated fat")
            case .cholesterol: String(localized: "Cholesterol")
            case .sodium: String(localized: "Sodium")
            case .carbs: String(localized: "Carbohydrate")
            case .fiber: String(localized: "Fiber")
            case .sugar: String(localized: "Sugar")
            case .protein: String(localized: "Protein")
            }
        }
    }

    struct Row: Equatable, Sendable, Identifiable {
        var nutrient: Nutrient
        /// Grams, milligrams (`nutrient.isMilligrams`) or kcal. `nil` when
        /// nothing says what it is.
        var value: Double?
        var id: Nutrient { nutrient }
    }

    var source: Source
    /// In label order, energy first.
    var rows: [Row]
    /// Kept so the UI can say what an estimate was built from.
    var estimate: NutritionEstimate

    func value(of nutrient: Nutrient) -> Double? {
        rows.first { $0.nutrient == nutrient }?.value
    }

    /// Rows other than energy — the headline figure is shown on its own.
    var detailRows: [Row] { rows.filter { $0.nutrient != .energy } }

    /// The label for one serving of `dish`, or `nil` when there is nothing
    /// trustworthy to show (see `NutritionEstimate.isTrustworthy`).
    static func make(for dish: Dish, estimate: NutritionEstimate) -> NutritionLabel? {
        guard estimate.isTrustworthy else { return nil }

        if estimate.origin == .statedByRecipe, let energy = dish.statedEnergyKcalPerServing {
            let source: Source = dish.statedNutritionProvenanceRaw == RecipeNutritionProvenance.manuallyEntered.rawValue
                ? .enteredByHand
                : .statedByRecipe
            let values: [Nutrient: Double?] = [
                .energy: energy,
                .fat: dish.statedFatGramsPerServing,
                .saturatedFat: dish.statedSaturatedFatGramsPerServing,
                .cholesterol: dish.statedCholesterolMilligramsPerServing,
                .sodium: dish.statedSodiumMilligramsPerServing,
                .carbs: dish.statedCarbGramsPerServing,
                .fiber: dish.statedFiberGramsPerServing,
                .sugar: dish.statedSugarGramsPerServing,
                .protein: dish.statedProteinGramsPerServing,
            ]
            return NutritionLabel(
                source: source,
                rows: Nutrient.allCases.map { Row(nutrient: $0, value: values[$0] ?? nil) },
                estimate: estimate
            )
        }

        let facts = estimate.facts
        let known: [Nutrient: Double] = [
            .energy: facts.energyKcal,
            .fat: facts.fatGrams,
            .carbs: facts.carbGrams,
            .protein: facts.proteinGrams,
        ]
        return NutritionLabel(
            source: .estimated,
            rows: Nutrient.allCases.map { Row(nutrient: $0, value: known[$0]) },
            estimate: estimate
        )
    }

    // MARK: - Text

    /// The chip next to the heading.
    var sourceBadge: String {
        switch source {
        case .statedByRecipe: String(localized: "From recipe")
        case .enteredByHand: String(localized: "Entered by hand")
        case .estimated: String(localized: "Estimate")
        }
    }

    /// One line on what the numbers rest on — for an estimate, how much of
    /// the ingredient list made it in ("Estimated from 7 of 9 ingredients.").
    var sourceNote: String {
        switch source {
        case .statedByRecipe:
            return String(localized: "Values stated by the recipe’s source. MealPlan hasn’t checked them.")
        case .enteredByHand:
            return String(localized: "Values entered by someone in your household.")
        case .estimated:
            let counted = estimate.countedLines
            let measured = estimate.measuredLines
            return String(localized: "Estimated from \(counted) of \(measured) ingredients.")
        }
    }

    /// The text for one row's value: "≈ 12 g" for an estimate, "12 g" for a
    /// stated figure, "—" for an unknown one.
    func valueText(for row: Row, unit: EnergyUnit, locale: Locale = .current) -> String {
        guard let value = row.value else { return "—" }
        let approximate = source == .estimated
        switch row.nutrient {
        case .energy:
            return NutritionFormatting.energy(
                NutritionFacts(energyKcal: value), unit: unit, approximate: approximate, locale: locale
            )
        case .cholesterol, .sodium:
            let text = NutritionFormatting.milligrams(value, locale: locale)
            return approximate ? "≈ \(text)" : text
        default:
            let text = NutritionFormatting.grams(value, locale: locale)
            return approximate ? "≈ \(text)" : text
        }
    }
}
