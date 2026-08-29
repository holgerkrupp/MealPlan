import Foundation
import SwiftData

/// A shopping-relevant ingredient, shared across all dishes in a household.
/// Matched and de-duplicated on `normalizedName`.
@Model
final class Ingredient {
    var name: String = ""
    /// Lowercased / trimmed form used for matching and aggregation.
    var normalizedName: String = ""
    var categoryRaw: String = IngredientCategory.other.rawValue

    @Relationship(deleteRule: .nullify, inverse: \DishIngredient.ingredient)
    var dishIngredients: [DishIngredient]? = []

    @Relationship(deleteRule: .nullify, inverse: \ShoppingListItem.ingredient)
    var shoppingItems: [ShoppingListItem]? = []

    var household: Household?

    init(name: String = "", category: IngredientCategory = .other) {
        self.name = name
        self.normalizedName = Ingredient.normalize(name)
        self.categoryRaw = category.rawValue
    }

    var category: IngredientCategory {
        get { IngredientCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .init(identifier: "de"))
    }
}
