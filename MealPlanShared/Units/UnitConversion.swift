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
        locale: Locale = .current
    ) -> Display {
        switch quantity.dimension {
        case .count:
            let n = format(quantity.value, locale: locale)
            if let preferredUnit, !preferredUnit.isEmpty, preferredUnit != "Stück" {
                return Display(text: "\(n) \(preferredUnit)", isApproximate: approximate)
            }
            return Display(text: "\(n) ×", isApproximate: approximate)

        case .mass:
            switch system {
            case .metric:
                if quantity.value >= 1000 {
                    return Display(text: "\(format(quantity.value / 1000, locale: locale)) kg", isApproximate: approximate)
                }
                return Display(text: "\(format(quantity.value, locale: locale)) g", isApproximate: approximate)
            case .imperial:
                let oz = quantity.value / 28.3495
                if oz >= 16 {
                    return Display(text: "\(format(oz / 16, locale: locale)) lb", isApproximate: true)
                }
                return Display(text: "\(format(oz, locale: locale)) oz", isApproximate: true)
            }

        case .volume:
            switch system {
            case .metric:
                if quantity.value >= 1000 {
                    return Display(text: "\(format(quantity.value / 1000, locale: locale)) l", isApproximate: approximate)
                }
                return Display(text: "\(format(quantity.value, locale: locale)) ml", isApproximate: approximate)
            case .imperial:
                let cups = quantity.value / 236.588
                if cups >= 0.25 {
                    return Display(text: "\(format(cups, locale: locale)) cups", isApproximate: true)
                }
                let tbsp = quantity.value / 14.787
                return Display(text: "\(format(tbsp, locale: locale)) tbsp", isApproximate: true)
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
    static func ovenTemperature(celsius: Double, system: UnitSystem) -> String {
        switch system {
        case .metric:
            return "\(Int((celsius / 10).rounded()) * 10) °C"
        case .imperial:
            let f = celsiusToFahrenheit(celsius)
            return "\(Int((f / 25).rounded()) * 25) °F"
        }
    }

    // MARK: - Formatting

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
