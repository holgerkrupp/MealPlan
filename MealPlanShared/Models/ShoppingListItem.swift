import Foundation
import SwiftData

/// One line on the shopping list. Generated lines are rebuilt from the plan
/// each time the list is regenerated; manual lines are kept untouched.
@Model
final class ShoppingListItem {
    var name: String = ""
    var normalizedName: String = ""
    var categoryRaw: String = IngredientCategory.other.rawValue
    var customAisleName: String?
    /// Aggregated amount in canonical units, when known.
    var canonicalValue: Double?
    var canonicalDimensionRaw: String?
    /// Ready-to-read amount, e.g. "500 g" or "3 ×".
    var displayText: String?
    var isChecked: Bool = false
    var isManual: Bool = false
    var isApproximate: Bool = false
    var sortIndex: Int = 0
    /// The date range the generated list was built for.
    var rangeStart: Date?
    var rangeEnd: Date?
    /// Dishes that contributed to this line (for "why is this here?").
    var sourceDishNames: [String] = []
    var dateCreated: Date = Date.now

    var ingredient: Ingredient?
    var household: Household?

    init(
        name: String = "",
        category: IngredientCategory = .other,
        isManual: Bool = false
    ) {
        self.name = name
        self.normalizedName = Ingredient.normalize(name)
        self.categoryRaw = category.rawValue
        self.isManual = isManual
        self.dateCreated = .now
    }

    var category: IngredientCategory {
        get { IngredientCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var dimension: QuantityDimension? {
        get { canonicalDimensionRaw.flatMap(QuantityDimension.init(rawValue:)) }
        set { canonicalDimensionRaw = newValue?.rawValue }
    }

    var aisleName: String {
        let custom = customAisleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? category.localizedName : custom
    }
}
