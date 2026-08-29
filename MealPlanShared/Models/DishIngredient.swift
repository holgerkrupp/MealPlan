import Foundation
import SwiftData

/// Join between a `Dish` and an `Ingredient`, carrying the amount needed for
/// the dish's default yield. Quantities are stored in canonical units
/// (grams / millilitres / pieces); `displayUnit` remembers how the cook
/// originally entered it.
@Model
final class DishIngredient {
    /// Amount in the canonical unit for `dimension`. `nil` for things like
    /// "a pinch" or "to taste".
    var canonicalValue: Double?
    var canonicalDimensionRaw: String?
    /// The unit label the user typed, e.g. "EL", "Prise", "g".
    var displayUnit: String?
    /// Volume↔weight conversions and spoon measures are approximate.
    var isApproximate: Bool = false
    /// Free-text note such as "gehackt" or "nach Geschmack".
    var note: String?
    /// The original line the user / importer entered, kept for review.
    var rawText: String?
    var sortIndex: Int = 0

    var dish: Dish?
    var ingredient: Ingredient?

    init(
        canonicalValue: Double? = nil,
        dimension: QuantityDimension? = nil,
        displayUnit: String? = nil,
        isApproximate: Bool = false,
        note: String? = nil,
        rawText: String? = nil,
        sortIndex: Int = 0
    ) {
        self.canonicalValue = canonicalValue
        self.canonicalDimensionRaw = dimension?.rawValue
        self.displayUnit = displayUnit
        self.isApproximate = isApproximate
        self.note = note
        self.rawText = rawText
        self.sortIndex = sortIndex
    }

    var dimension: QuantityDimension? {
        get { canonicalDimensionRaw.flatMap(QuantityDimension.init(rawValue:)) }
        set { canonicalDimensionRaw = newValue?.rawValue }
    }

    var quantity: Quantity? {
        guard let canonicalValue, let dimension else { return nil }
        return Quantity(value: canonicalValue, dimension: dimension)
    }
}
