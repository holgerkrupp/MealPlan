import Foundation
import SwiftData

/// A household shopping list. The generated list is the durable home for
/// groceries derived from the meal plan; named lists are independent and are
/// never touched by a plan rebuild.
@Model
final class ShoppingList {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    var name: String = ""
    var isGenerated: Bool = false
    var sortIndex: Int = 0
    var dateCreated: Date = Date.now
    @Relationship(deleteRule: .cascade, inverse: \ShoppingListItem.list)
    var items: [ShoppingListItem]? = []

    var household: Household?

    init(name: String, isGenerated: Bool = false, uuid: UUID = UUID(), sortIndex: Int = 0) {
        self.uuid = uuid
        self.name = name
        self.isGenerated = isGenerated
        self.sortIndex = sortIndex
        self.dateCreated = .now
    }

    /// A household's plan-derived list must have the same identity on every
    /// device before CloudKit has exchanged the first new-list record.
    static func generatedID(for householdID: UUID) -> UUID { householdID }

    static let generatedName = String(localized: "Plan groceries")
}

/// One line on the shopping list. Generated lines are rebuilt from the plan
/// each time the list is regenerated; manual lines are kept untouched.
@Model
final class ShoppingListItem {
    /// Stable identity across devices, so sharing sync can recognise "the same
    /// line" instead of duplicating it on every merge. Added after launch, so
    /// every property carries a default for the lightweight migration.
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    var contentModifiedAt: Date = Date.now
    var checkStateModifiedAt: Date = Date.now
    var name: String = ""
    var normalizedName: String = ""
    var categoryRaw: String = IngredientCategory.other.rawValue
    var customAisleName: String?
    /// Aggregated amount in canonical units, when known.
    var canonicalValue: Double?
    var canonicalDimensionRaw: String?
    /// Amounts the merged line couldn't add to `canonicalValue` because they
    /// are measured in another dimension — a yoghurt one recipe asks for as
    /// "500 g" and another as "2 Becher". Encoded, so the model stays a plain
    /// array; read them through `additionalQuantities`.
    var additionalAmountsRaw: [String] = []
    /// How many of the merged recipe lines gave no measurable amount at all
    /// ("Salz nach Geschmack"). Kept so the amount can be written out again
    /// after a unit or rounding change.
    var unmeasuredCount: Int = 0
    /// Ready-to-read amount, e.g. "500 g" or "3 ×".
    var displayText: String?
    /// Original unit label, retained so changing display preferences can
    /// reformat the item without rebuilding it from its source recipe.
    var displayUnit: String?
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
    var list: ShoppingList?

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

    /// The merged amounts that aren't in `dimension`, in the order they were
    /// aggregated.
    var additionalQuantities: [Quantity] {
        get { additionalAmountsRaw.compactMap(Quantity.init(encoded:)) }
        set { additionalAmountsRaw = newValue.map(\.encoded) }
    }

    var aisleName: String {
        let custom = customAisleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? category.localizedName : custom
    }
}
