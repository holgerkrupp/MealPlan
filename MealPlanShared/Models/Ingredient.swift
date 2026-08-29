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
    /// Optional household-specific store aisle, e.g. "Turkish market".
    var customAisleName: String?
    /// Pantry staples are normally on hand and are omitted when rebuilding a
    /// generated shopping list. They can still be added manually.
    var isPantryStaple: Bool = false

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

    var aisleName: String {
        let custom = customAisleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? category.localizedName : custom
    }

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .init(identifier: "de"))
    }
}
