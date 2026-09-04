import Foundation

/// Turns an estimate into the strings the app shows.
///
/// Every one of them carries the `≈` the rest of the app already uses for an
/// approximated amount (see `ServingScaler.amountText(for:)`), so a nutrition
/// figure reads the same way a converted quantity does: close, not exact.
/// Nothing here ever returns a bare number.
enum NutritionFormatting {

    /// "≈ 640 kcal". Energy is rounded to something a kitchen can act on —
    /// 10 kcal below a thousand, 50 above — because the underlying estimate is
    /// nowhere near precise enough to justify a digit in the ones column.
    static func energy(
        _ facts: NutritionFacts,
        unit: EnergyUnit,
        approximate: Bool = true,
        locale: Locale = .current
    ) -> String {
        let value = facts.energy(in: unit)
        let step: Double = value < 1_000 ? 10 : 50
        let rounded = (value / step).rounded() * step
        let text = "\(number(rounded, fractionDigits: 0, locale: locale)) \(unit.symbol)"
        return approximate ? "≈ \(text)" : text
    }

    /// "31 g" for a macronutrient. One decimal below 10 g, whole grams above.
    static func grams(_ value: Double, locale: Locale = .current) -> String {
        let digits = value < 10 ? 1 : 0
        return "\(number(value, fractionDigits: digits, locale: locale)) g"
    }

    /// The one-line caption under a total: what it was built from and what is
    /// missing. Returns `nil` when there is nothing worth qualifying.
    static func coverageNote(for estimate: NutritionEstimate) -> String? {
        switch estimate.origin {
        case .none:
            return nil
        case .statedByRecipe:
            return String(localized: "Stated by the recipe.")
        case .computed, .mixed:
            break
        }

        var parts: [String] = []
        if estimate.unknownLines > 0 {
            parts.append(String(
                localized: "From \(estimate.countedLines) of \(estimate.measuredLines) ingredients."
            ))
        }
        if estimate.dishesWithoutEstimate > 0 {
            parts.append(String(
                localized: "\(estimate.dishesWithoutEstimate) planned meals have no ingredients yet."
            ))
        }
        if estimate.unmeasuredLines > 0 {
            parts.append(String(
                localized: "\(estimate.unmeasuredLines) ingredients have no amount and were left out."
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The ingredients an estimate had to skip, as a readable list — at most a
    /// few, so a long tail doesn't take over the screen.
    static func missingList(for estimate: NutritionEstimate, limit: Int = 4) -> String? {
        guard !estimate.missingNames.isEmpty else { return nil }
        let shown = estimate.missingNames.prefix(limit)
        let joined = ListFormatter.localizedString(byJoining: Array(shown))
        let hidden = estimate.missingNames.count - shown.count
        guard hidden > 0 else {
            return String(localized: "No values for \(joined).")
        }
        return String(localized: "No values for \(joined) and \(hidden) more.")
    }

    private static func number(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value.rounded()))"
    }
}
