import Foundation

/// Turns canonical quantities (g / ml / pieces) into human-readable strings
/// in the household's preferred unit system, and handles oven-temperature
/// conversion.
enum UnitConversion {

    // MARK: - Quantity display

    /// A formatted amount plus whether the value is an approximation.
    struct Display: Equatable, Sendable {
        var text: String
        var isApproximate: Bool
    }

    static func string(
        for quantity: Quantity,
        system: UnitSystem,
        preferredUnit: String? = nil,
        approximate: Bool = false,
        ingredientName: String? = nil,
        roundsAmounts: Bool = true,
        locale: Locale = .current
    ) -> Display {
        switch quantity.dimension {
        case .count:
            let practical = roundsAmounts
                ? practicalCount(
                    quantity.value,
                    ingredientName: ingredientName,
                    preferredUnit: preferredUnit
                )
                : (value: quantity.value, wasAdjusted: false)
            let n = roundsAmounts
                ? formatRounded(practical.value, step: countStep(
                    for: quantity.value,
                    ingredientName: ingredientName,
                    preferredUnit: preferredUnit
                ), locale: locale)
                : formatExact(practical.value, locale: locale)
            let rounded = approximate || practical.wasAdjusted
            if let preferredUnit, !preferredUnit.isEmpty, preferredUnit != "Stück" {
                return Display(text: "\(n) \(preferredUnit)", isApproximate: rounded)
            }
            return Display(text: "\(n) ×", isApproximate: rounded)

        case .mass:
            switch system {
            case .metric:
                if quantity.value >= 1000 {
                    return measurementDisplay(
                        value: quantity.value / 1000, unit: "kg", practicalStep: 0.05,
                        approximate: approximate, roundsAmounts: roundsAmounts, locale: locale
                    )
                }
                let step = quantity.value < 10 ? 0.1 : quantity.value < 100 ? 1.0 : 5.0
                return measurementDisplay(
                    value: quantity.value, unit: "g", practicalStep: step,
                    approximate: approximate, roundsAmounts: roundsAmounts, locale: locale
                )
            case .imperial:
                let oz = quantity.value / 28.3495
                if oz >= 32 {
                    return measurementDisplay(
                        value: oz / 16, unit: "lb", practicalStep: 0.25,
                        approximate: approximate, roundsAmounts: roundsAmounts, locale: locale
                    )
                }
                return measurementDisplay(
                    value: oz, unit: "oz", practicalStep: oz < 1 ? 0.1 : 0.25,
                    approximate: approximate, roundsAmounts: roundsAmounts, locale: locale
                )
            }

        case .volume:
            switch system {
            case .metric:
                if quantity.value >= 1000 {
                    return measurementDisplay(
                        value: quantity.value / 1000, unit: "l", practicalStep: 0.05,
                        approximate: approximate, roundsAmounts: roundsAmounts, locale: locale
                    )
                }
                let step = quantity.value < 10 ? 0.5 : quantity.value < 100 ? 5.0 : 10.0
                return measurementDisplay(
                    value: quantity.value, unit: "ml", practicalStep: step,
                    approximate: approximate, roundsAmounts: roundsAmounts, locale: locale
                )
            case .imperial:
                let cups = quantity.value / 236.588
                if cups >= 0.25 {
                    return measurementDisplay(
                        value: cups, unit: "cups", practicalStep: 0.25,
                        approximate: approximate, roundsAmounts: roundsAmounts, locale: locale
                    )
                }
                let tablespoons = quantity.value / 14.7868
                if tablespoons >= 1 {
                    return measurementDisplay(
                        value: tablespoons, unit: "tbsp", practicalStep: 0.25,
                        approximate: approximate, roundsAmounts: roundsAmounts, locale: locale
                    )
                }
                let teaspoons = quantity.value / 4.92892
                return measurementDisplay(
                    value: teaspoons, unit: "tsp", practicalStep: 0.25,
                    approximate: approximate, roundsAmounts: roundsAmounts, locale: locale
                )
            }
        }
    }

    // MARK: - Volume ⇄ weight (always approximate)

    /// Convert a volume to an approximate weight for a named ingredient.
    static func weight(fromVolume ml: Double, ingredientName: String?) -> (grams: Double, known: Bool) {
        let d = DensityTable.gramsPerMillilitre(for: ingredientName)
        return (ml * d.value, d.known)
    }

    static func volume(fromWeight grams: Double, ingredientName: String?) -> (millilitres: Double, known: Bool) {
        let d = DensityTable.gramsPerMillilitre(for: ingredientName)
        return (grams / d.value, d.known)
    }

    // MARK: - Temperature

    static func celsiusToFahrenheit(_ c: Double) -> Double { c * 9 / 5 + 32 }
    static func fahrenheitToCelsius(_ f: Double) -> Double { (f - 32) * 5 / 9 }

    /// Oven temperature string in the preferred system, rounded to a sensible step.
    static func ovenTemperature(
        celsius: Double,
        system: UnitSystem,
        roundsAmounts: Bool = true,
        locale: Locale = .current
    ) -> String {
        if !roundsAmounts {
            let value = system == .metric ? celsius : celsiusToFahrenheit(celsius)
            let unit = system == .metric ? "°C" : "°F"
            return "\(formatExact(value, locale: locale)) \(unit)"
        }
        switch system {
        case .metric:
            return "\(Int((celsius / 10).rounded()) * 10) °C"
        case .imperial:
            let f = celsiusToFahrenheit(celsius)
            return "\(Int((f / 25).rounded()) * 25) °F"
        }
    }

    // MARK: - Formatting

    /// Counts need different display rules from weights. A mathematically
    /// exact scaled amount such as 2.75 eggs is not actionable in a kitchen.
    /// Eggs (including yolks/whites) always become whole units. Other small
    /// countables retain useful halves—half a lemon is reasonable—then switch
    /// to whole units once the quantity is large.
    static func practicalCount(
        _ value: Double,
        ingredientName: String?,
        preferredUnit: String? = nil
    ) -> (value: Double, wasAdjusted: Bool) {
        guard value.isFinite else { return (0, true) }
        guard value > 0 else { return (0, value != 0) }

        let step = countStep(
            for: value,
            ingredientName: ingredientName,
            preferredUnit: preferredUnit
        )

        // A positive ingredient should not disappear when scaling a recipe
        // down. Use one whole egg, or half of another countable item.
        let minimum = step
        let result = max(minimum, (value / step).rounded() * step)
        return (result, abs(result - value) > 0.000_001)
    }

    private static func countStep(
        for value: Double,
        ingredientName: String?,
        preferredUnit: String?
    ) -> Double {
        requiresWholeCount(ingredientName: ingredientName, preferredUnit: preferredUnit)
            ? 1
            : value < 10 ? 0.5 : 1
    }

    private static func requiresWholeCount(ingredientName: String?, preferredUnit: String?) -> Bool {
        let raw = [ingredientName, preferredUnit].compactMap { $0 }.joined(separator: " ")
        let folded = raw.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let tokens = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let wholeTokens: Set<String> = [
            "ei", "eier", "egg", "eggs", "eigelb", "eigelbe", "eiweiss",
            "yolk", "yolks"
        ]
        return !wholeTokens.isDisjoint(with: tokens)
    }

    private static func measurementDisplay(
        value: Double,
        unit: String,
        practicalStep: Double,
        approximate: Bool,
        roundsAmounts: Bool,
        locale: Locale
    ) -> Display {
        guard roundsAmounts else {
            return Display(
                text: "\(formatExact(value, locale: locale)) \(unit)",
                isApproximate: approximate
            )
        }

        let practical = practicalMeasurement(value, step: practicalStep)
        return Display(
            text: "\(formatRounded(practical.value, step: practicalStep, locale: locale)) \(unit)",
            isApproximate: approximate || practical.wasAdjusted
        )
    }

    private static func practicalMeasurement(
        _ value: Double,
        step: Double
    ) -> (value: Double, wasAdjusted: Bool) {
        guard value.isFinite else { return (0, true) }
        guard value > 0 else { return (0, value != 0) }
        let result = max(step, (value / step).rounded() * step)
        return (result, abs(result - value) > 0.000_001)
    }

    private static func formatRounded(_ value: Double, step: Double, locale: Locale) -> String {
        let fractionDigits: Int
        if step >= 1 {
            fractionDigits = 0
        } else if (step * 10).rounded() == step * 10 {
            fractionDigits = 1
        } else if (step * 100).rounded() == step * 100 {
            fractionDigits = 2
        } else {
            fractionDigits = 3
        }
        return numberString(value, maximumFractionDigits: fractionDigits, locale: locale)
    }

    private static func formatExact(_ value: Double, locale: Locale) -> String {
        numberString(value, maximumFractionDigits: 4, locale: locale)
    }

    private static func numberString(
        _ value: Double,
        maximumFractionDigits: Int,
        locale: Locale
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.minimumFractionDigits = 0
        return formatter.string(from: value as NSNumber) ?? "\(value)"
    }

    static func format(_ value: Double, locale: Locale) -> String {
        let rounded: Double
        if value < 1 {
            rounded = (value * 100).rounded() / 100
        } else if value < 10 {
            rounded = (value * 10).rounded() / 10
        } else {
            rounded = value.rounded()
        }
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        return f.string(from: rounded as NSNumber) ?? "\(rounded)"
    }
}
