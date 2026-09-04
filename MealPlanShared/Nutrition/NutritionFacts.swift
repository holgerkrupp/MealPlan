import Foundation

/// An amount of energy and macronutrients.
///
/// Everything in this file is an **estimate**. MealPlan never weighs anything:
/// it reads the amounts written in a recipe, looks each ingredient up in a
/// bundled reference table, and adds the results up. Densities, piece weights,
/// how much fat a pan actually keeps and whether rice is measured raw or
/// cooked all move the answer, so a dish's figure is comfortably ±20 % even
/// when every ingredient is known. That is enough to see that Saturday was
/// heavy and Sunday should be light; it is not a nutrition label, and the UI
/// says so wherever a number appears — see `NutritionEstimate.isTrustworthy`
/// and the "Estimate" labelling in `NutritionSummaryView`.
///
/// The four values are kept non-optional and default to zero: the bundled
/// table always carries all four, and an ingredient we know nothing about is
/// excluded from the total entirely (and counted in
/// `NutritionEstimate.missingNames`) rather than folded in as zeros.
struct NutritionFacts: Equatable, Sendable, Codable {
    var energyKcal: Double = 0
    var proteinGrams: Double = 0
    var carbGrams: Double = 0
    var fatGrams: Double = 0

    static let zero = NutritionFacts()

    init(
        energyKcal: Double = 0,
        proteinGrams: Double = 0,
        carbGrams: Double = 0,
        fatGrams: Double = 0
    ) {
        self.energyKcal = energyKcal
        self.proteinGrams = proteinGrams
        self.carbGrams = carbGrams
        self.fatGrams = fatGrams
    }

    /// Shorthand for the bundled table, which is written per 100 g:
    /// `.init(283, 14, 54, 13)`.
    init(_ energyKcal: Double, _ proteinGrams: Double, _ carbGrams: Double, _ fatGrams: Double) {
        self.init(
            energyKcal: energyKcal,
            proteinGrams: proteinGrams,
            carbGrams: carbGrams,
            fatGrams: fatGrams
        )
    }

    static func + (lhs: NutritionFacts, rhs: NutritionFacts) -> NutritionFacts {
        NutritionFacts(
            energyKcal: lhs.energyKcal + rhs.energyKcal,
            proteinGrams: lhs.proteinGrams + rhs.proteinGrams,
            carbGrams: lhs.carbGrams + rhs.carbGrams,
            fatGrams: lhs.fatGrams + rhs.fatGrams
        )
    }

    static func += (lhs: inout NutritionFacts, rhs: NutritionFacts) {
        lhs = lhs + rhs
    }

    func scaled(by factor: Double) -> NutritionFacts {
        guard factor.isFinite else { return .zero }
        return NutritionFacts(
            energyKcal: energyKcal * factor,
            proteinGrams: proteinGrams * factor,
            carbGrams: carbGrams * factor,
            fatGrams: fatGrams * factor
        )
    }

    /// The other half of every European nutrition label.
    var energyKilojoules: Double { energyKcal * 4.184 }

    func energy(in unit: EnergyUnit) -> Double {
        switch unit {
        case .kilocalories: energyKcal
        case .kilojoules: energyKilojoules
        }
    }
}

/// Which energy unit a household reads. Both are legally required on European
/// packaging, and which one people actually think in is a personal habit.
enum EnergyUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case kilocalories = "kcal"
    case kilojoules = "kJ"

    var id: String { rawValue }

    /// The symbol shown next to a number. Deliberately not localized — "kcal"
    /// and "kJ" are the same everywhere MealPlan ships.
    var symbol: String { rawValue }

    var localizedName: String {
        switch self {
        case .kilocalories: String(localized: "Kilocalories (kcal)")
        case .kilojoules: String(localized: "Kilojoules (kJ)")
        }
    }
}

/// What a stored per-ingredient value is measured against.
///
/// Packaging states values per 100 g for solids and per 100 ml for liquids,
/// and some things ("one egg") are only ever sold and cooked by the piece.
/// Storing which of the three the cook typed keeps us from silently treating
/// millilitres as grams.
enum NutritionReference: String, CaseIterable, Identifiable, Codable, Sendable {
    case per100Grams = "per100g"
    case per100Millilitres = "per100ml"
    case perPiece = "perPiece"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .per100Grams: String(localized: "per 100 g")
        case .per100Millilitres: String(localized: "per 100 ml")
        case .perPiece: String(localized: "per piece")
        }
    }
}

/// Where an ingredient's values came from, so the app can tell a figure it
/// guessed from one somebody checked.
enum NutritionSource: String, CaseIterable, Codable, Sendable {
    /// MealPlan's own reference table — a generic ingredient, not a product.
    case builtIn
    /// Typed by someone in the household, usually off a package.
    case user
    /// Carried in with the recipe (schema.org `NutritionInformation`).
    case imported

    var localizedName: String {
        switch self {
        case .builtIn: String(localized: "MealPlan reference values")
        case .user: String(localized: "Entered by hand")
        case .imported: String(localized: "From the recipe")
        }
    }
}

/// How much conversion stood between the recipe and the number.
enum NutritionConfidence: Int, Comparable, Sendable {
    /// A weight in the recipe against a value stored per weight. As good as
    /// this gets.
    case weighed = 0
    /// Needed a density ("1 EL oil") or a piece weight ("2 onions"), both of
    /// which are averages.
    case converted = 1

    static func < (lhs: NutritionConfidence, rhs: NutritionConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
