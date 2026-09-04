import Foundation

/// Adds a recipe up.
///
/// The whole calculation is per **serving**, not per pot. A day's figure is
/// then the sum of the per-serving figures of everything planned on it, which
/// is what one person eats that day — independent of how many people are being
/// cooked for, so it stays comparable between a Tuesday for two and a Sunday
/// for eight. That is the number the planner needs to answer "was yesterday
/// heavy?".
///
/// Pure and free of `ModelContext`, so it can be tested against transient
/// `@Model` objects (see the note in the build memo about SwiftData tests).
enum NutritionEstimator {

    // MARK: - One recipe line

    /// What one ingredient line of a recipe contributes, at the amount the
    /// recipe writes — before any serving scaling.
    enum LineOutcome: Equatable, Sendable {
        /// Counted, with how much conversion it took to get there.
        case counted(NutritionFacts, NutritionConfidence)
        /// The line has no amount at all ("Salz nach Geschmack"). Almost
        /// always negligible, and never held against coverage.
        case unmeasured
        /// There is an amount, but nothing knows what the ingredient is.
        case unknown
    }

    static func outcome(for line: DishIngredient) -> LineOutcome {
        guard let quantity = line.quantity else { return .unmeasured }

        let name = line.ingredient?.name ?? line.rawText
        guard let reference = referenceFacts(for: line) else { return .unknown }

        // Everything below answers one question: how many multiples of the
        // reference amount does this line contain?
        switch reference.reference {
        case .perPiece:
            guard let pieces = pieces(of: quantity, name: name, unit: line.displayUnit) else {
                return .unknown
            }
            let confidence: NutritionConfidence = quantity.dimension == .count ? .weighed : .converted
            return .counted(reference.facts.scaled(by: pieces.value), max(confidence, pieces.confidence))

        case .per100Grams:
            guard let grams = grams(of: quantity, name: name, unit: line.displayUnit) else {
                return .unknown
            }
            return .counted(
                reference.facts.scaled(by: grams.value / 100),
                combined(grams.confidence, line)
            )

        case .per100Millilitres:
            guard let millilitres = millilitres(of: quantity, name: name, unit: line.displayUnit) else {
                return .unknown
            }
            return .counted(
                reference.facts.scaled(by: millilitres.value / 100),
                combined(millilitres.confidence, line)
            )
        }
    }

    /// A line the cook already flagged as approximate ("1 EL", "1 Prise") can
    /// never come out better than approximate.
    private static func combined(_ confidence: NutritionConfidence, _ line: DishIngredient) -> NutritionConfidence {
        line.isApproximate ? max(confidence, .converted) : confidence
    }

    /// The per-unit values to use for a line: the household's own entry for
    /// the ingredient if it has one, otherwise MealPlan's bundled table.
    private static func referenceFacts(
        for line: DishIngredient
    ) -> (facts: NutritionFacts, reference: NutritionReference)? {
        if let ingredient = line.ingredient, let own = ingredient.nutritionFacts {
            return (own, ingredient.nutritionReference)
        }
        // The catalogue name first, then the raw imported line — "200 g
        // Basmatireis" still finds rice even before anyone tidies it up.
        for candidate in [line.ingredient?.name, line.rawText].compactMap({ $0 }) {
            if let facts = NutritionTable.facts(for: candidate) {
                return (facts, .per100Grams)
            }
        }
        return nil
    }

    // MARK: - Amount conversions

    private struct Amount { var value: Double; var confidence: NutritionConfidence }

    private static func grams(of quantity: Quantity, name: String?, unit: String?) -> Amount? {
        switch quantity.dimension {
        case .mass:
            return Amount(value: quantity.value, confidence: .weighed)
        case .volume:
            let converted = UnitConversion.weight(fromVolume: quantity.value, ingredientName: name)
            return Amount(value: converted.grams, confidence: .converted)
        case .count:
            guard let perPiece = PieceWeightTable.grams(forIngredient: name, unitLabel: unit) else {
                return nil
            }
            return Amount(value: quantity.value * perPiece, confidence: .converted)
        }
    }

    private static func millilitres(of quantity: Quantity, name: String?, unit: String?) -> Amount? {
        switch quantity.dimension {
        case .volume:
            return Amount(value: quantity.value, confidence: .weighed)
        case .mass:
            let converted = UnitConversion.volume(fromWeight: quantity.value, ingredientName: name)
            return Amount(value: converted.millilitres, confidence: .converted)
        case .count:
            guard let grams = grams(of: quantity, name: name, unit: unit) else { return nil }
            let converted = UnitConversion.volume(fromWeight: grams.value, ingredientName: name)
            return Amount(value: converted.millilitres, confidence: .converted)
        }
    }

    private static func pieces(of quantity: Quantity, name: String?, unit: String?) -> Amount? {
        switch quantity.dimension {
        case .count:
            return Amount(value: quantity.value, confidence: .weighed)
        case .mass, .volume:
            guard let perPiece = PieceWeightTable.grams(forIngredient: name, unitLabel: unit),
                  perPiece > 0,
                  let grams = grams(of: quantity, name: name, unit: unit)
            else { return nil }
            return Amount(value: grams.value / perPiece, confidence: .converted)
        }
    }

    // MARK: - One dish

    /// What one serving of `dish` is estimated to contain.
    ///
    /// A recipe that came with its own figures is taken at its word — those
    /// beat anything added up from an ingredient list.
    static func perServing(for dish: Dish) -> NutritionEstimate {
        if let stated = dish.statedNutritionPerServing {
            return NutritionEstimate(
                facts: stated,
                countedLines: 0,
                unknownLines: 0,
                unmeasuredLines: 0,
                convertedLines: 0,
                missingNames: [],
                origin: .statedByRecipe
            )
        }

        let lines = dish.sortedIngredients
        guard !lines.isEmpty else { return .unavailable }

        var total = NutritionFacts.zero
        var counted = 0
        var unknown = 0
        var unmeasured = 0
        var converted = 0
        var missing: [String] = []

        for line in lines {
            switch outcome(for: line) {
            case let .counted(facts, confidence):
                total += facts
                counted += 1
                if confidence == .converted { converted += 1 }
            case .unmeasured:
                unmeasured += 1
            case .unknown:
                unknown += 1
                let name = line.ingredient?.name ?? line.rawText ?? ""
                if !name.isEmpty, !missing.contains(name) { missing.append(name) }
            }
        }

        let yield = max(1, dish.servings)
        return NutritionEstimate(
            facts: total.scaled(by: 1 / Double(yield)),
            countedLines: counted,
            unknownLines: unknown,
            unmeasuredLines: unmeasured,
            convertedLines: converted,
            missingNames: missing,
            origin: .computed
        )
    }

    // MARK: - A day, or any set of planned meals

    /// What one person is estimated to eat across `entries` — one serving of
    /// each dish planned, skipped meals and meals eaten out left out.
    ///
    /// Head-count deliberately plays no part: doubling the pot doesn't change
    /// what a person eats, and a day whose figure moved because guests came
    /// would be useless for "eat lighter tomorrow".
    static func perPerson(for entries: [MealPlanEntry]) -> NutritionEstimate {
        var combined = NutritionEstimate.unavailable
        var any = false

        for entry in entries where !entry.skipped {
            guard let dish = entry.dish else { continue }
            let estimate = perServing(for: dish)
            guard estimate.origin != .none else {
                // A planned dish with no ingredients at all still means the
                // day's total is incomplete, and saying so is the point.
                combined.dishesWithoutEstimate += 1
                any = true
                continue
            }
            combined.merge(estimate)
            any = true
        }

        guard any else { return .unavailable }
        return combined
    }
}

/// The result of an estimate, and how much of it to believe.
///
/// Coverage is the whole reason this is a struct rather than a `NutritionFacts`:
/// a total built from four of a recipe's eleven ingredients is not a small
/// number, it is a wrong one, and the UI has to be able to tell the difference.
struct NutritionEstimate: Equatable, Sendable {
    /// Per serving for a dish, per person for a day.
    var facts: NutritionFacts = .zero
    /// Measured lines we found values for.
    var countedLines = 0
    /// Measured lines nothing recognised.
    var unknownLines = 0
    /// Lines with no amount at all ("a pinch of salt"). Not held against
    /// coverage — they are almost always seasoning.
    var unmeasuredLines = 0
    /// Counted lines that needed a density or a piece weight.
    var convertedLines = 0
    /// What we couldn't work out, for the "so you know what's missing" line.
    var missingNames: [String] = []
    /// Planned dishes with no ingredient list at all, when this covers a day.
    var dishesWithoutEstimate = 0
    var origin: Origin = .none

    enum Origin: Equatable, Sendable {
        /// Nothing to go on.
        case none
        /// Added up from the ingredient list.
        case computed
        /// The recipe stated its own figures.
        case statedByRecipe
        /// A day built from a mix of the two.
        case mixed
    }

    static let unavailable = NutritionEstimate()

    /// Measured lines, whether or not we recognised them.
    var measuredLines: Int { countedLines + unknownLines }

    /// How much of the recipe made it into the number, 0...1.
    ///
    /// Only lines with an amount can be covered, so a recipe that is nothing
    /// but "salt to taste" counts as fully covered — there is genuinely
    /// nothing missing from it, even though there is also nothing to add up.
    /// `isTrustworthy` is what stops that becoming a zero on screen.
    var coverage: Double {
        guard measuredLines > 0 else { return unmeasuredLines > 0 ? 1 : 0 }
        return Double(countedLines) / Double(measuredLines)
    }

    /// Whether this is worth putting in front of someone.
    ///
    /// Below three quarters, too much of the recipe is missing for the total
    /// to mean anything, and showing it anyway would understate the dish —
    /// always in the same direction, since a missing ingredient can only
    /// subtract. The UI shows "not enough information" instead, which at least
    /// invites a fix.
    var isTrustworthy: Bool {
        switch origin {
        case .none: false
        case .statedByRecipe: true
        case .computed, .mixed: countedLines > 0 && coverage >= 0.75 && dishesWithoutEstimate == 0
        }
    }

    /// Fold another dish's estimate into this one (a day, a week).
    mutating func merge(_ other: NutritionEstimate) {
        facts += other.facts
        countedLines += other.countedLines
        unknownLines += other.unknownLines
        unmeasuredLines += other.unmeasuredLines
        convertedLines += other.convertedLines
        dishesWithoutEstimate += other.dishesWithoutEstimate
        for name in other.missingNames where !missingNames.contains(name) {
            missingNames.append(name)
        }
        origin = switch (origin, other.origin) {
        case (.none, let new): new
        case (let existing, .none): existing
        case (let a, let b) where a == b: a
        default: .mixed
        }
    }
}

/// How heavy one serving is, in the only terms that matter while planning:
/// compared with the other meals of the week.
///
/// The thresholds are for a main meal and are deliberately coarse. They are a
/// planning aid — "yesterday was hearty, make tonight light" — not a
/// recommendation, a target or a budget, and MealPlan never sets a daily goal
/// or tells anyone what to eat.
enum NutritionBand: Sendable, CaseIterable {
    case light
    case moderate
    case hearty

    /// kcal per serving.
    static func band(forKcalPerServing kcal: Double) -> NutritionBand {
        switch kcal {
        case ..<450: .light
        case ..<750: .moderate
        default: .hearty
        }
    }

    var localizedName: String {
        switch self {
        case .light: String(localized: "Light")
        case .moderate: String(localized: "Middling")
        case .hearty: String(localized: "Hearty")
        }
    }

    var symbolName: String {
        switch self {
        case .light: "leaf"
        case .moderate: "circle.righthalf.filled"
        case .hearty: "flame"
        }
    }
}
