import Foundation
import SwiftData

/// A shopping-relevant ingredient, shared across all dishes in a household.
/// Matched and de-duplicated on `normalizedName`.
@Model
final class Ingredient {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    var name: String = ""
    /// Lowercased / trimmed form used for matching and aggregation.
    var normalizedName: String = ""
    var categoryRaw: String = IngredientCategory.other.rawValue
    /// Optional household-specific store aisle, e.g. "Turkish market".
    var customAisleName: String?
    /// Pantry staples are normally on hand and are omitted when rebuilding a
    /// generated shopping list. They can still be added manually.
    var isPantryStaple: Bool = false

    // MARK: Nutrition
    //
    // Estimated values for this ingredient, shared across every dish that uses
    // it — the whole reason nutrition hangs off the catalogue and not off each
    // recipe line. All optional: an ingredient nobody has looked up falls back
    // to `NutritionTable`, and one neither knows is left out of the estimate
    // rather than counted as zero. See `NutritionEstimator`.

    var nutritionEnergyKcal: Double?
    var nutritionProteinGrams: Double?
    var nutritionCarbGrams: Double?
    var nutritionFatGrams: Double?
    /// What the four values above are measured against — 100 g, 100 ml or one
    /// piece. `nil` reads as per 100 g.
    var nutritionReferenceRaw: String?
    /// Who to believe: `NutritionSource`. `nil` reads as `.user`, since only a
    /// person or an import ever writes these fields.
    var nutritionSourceRaw: String?

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

    // MARK: - Nutrition

    var nutritionReference: NutritionReference {
        get { nutritionReferenceRaw.flatMap(NutritionReference.init(rawValue:)) ?? .per100Grams }
        set { nutritionReferenceRaw = newValue.rawValue }
    }

    var nutritionSource: NutritionSource {
        get { nutritionSourceRaw.flatMap(NutritionSource.init(rawValue:)) ?? .user }
        set { nutritionSourceRaw = newValue.rawValue }
    }

    /// The household's own values for this ingredient, if anyone has entered
    /// or imported any. Energy is what makes a row worth having: an entry with
    /// no calories in it says nothing the reference table doesn't.
    var nutritionFacts: NutritionFacts? {
        guard let nutritionEnergyKcal else { return nil }
        return NutritionFacts(
            energyKcal: nutritionEnergyKcal,
            proteinGrams: nutritionProteinGrams ?? 0,
            carbGrams: nutritionCarbGrams ?? 0,
            fatGrams: nutritionFatGrams ?? 0
        )
    }

    /// Replace (or clear) this ingredient's own values.
    func setNutrition(
        _ facts: NutritionFacts?,
        reference: NutritionReference = .per100Grams,
        source: NutritionSource = .user
    ) {
        guard let facts else {
            nutritionEnergyKcal = nil
            nutritionProteinGrams = nil
            nutritionCarbGrams = nil
            nutritionFatGrams = nil
            nutritionReferenceRaw = nil
            nutritionSourceRaw = nil
            return
        }
        nutritionEnergyKcal = facts.energyKcal
        nutritionProteinGrams = facts.proteinGrams
        nutritionCarbGrams = facts.carbGrams
        nutritionFatGrams = facts.fatGrams
        nutritionReference = reference
        nutritionSource = source
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
