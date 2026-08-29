import Foundation

/// Scales a dish's ingredient amounts from its default yield to a target
/// head-count, and formats them for display.
struct ServingScaler {
    var baseServings: Int
    var targetServings: Int
    var system: UnitSystem
    var locale: Locale = .current

    var factor: Double {
        guard baseServings > 0 else { return 1 }
        return Double(targetServings) / Double(baseServings)
    }

    /// A ready-to-show amount string for one ingredient line, e.g. "≈ 375 g".
    func amountText(for line: DishIngredient) -> String? {
        guard let quantity = line.quantity else {
            return line.note?.isEmpty == false ? line.note : nil
        }
        let scaled = quantity.scaled(by: factor)
        let display = UnitConversion.string(
            for: scaled,
            system: system,
            preferredUnit: line.displayUnit,
            approximate: line.isApproximate,
            ingredientName: line.ingredient?.name,
            locale: locale
        )
        return (display.isApproximate ? "≈ " : "") + display.text
    }
}
