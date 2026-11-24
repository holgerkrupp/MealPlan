import Foundation

/// Rough densities (grams per millilitre) for common ingredients, used only
/// when a volume measure has to be shown as a weight or vice versa. These
/// vary a lot in practice, so any conversion that uses them is flagged
/// approximate.
enum DensityTable {
    /// grams per millilitre
    static let densities: [(names: [String], value: Double)] = [
        (["olivenöl", "olive oil"], 0.92),
        (["puderzucker", "icing sugar", "powdered sugar"], 0.56),
        (["haferflocken", "oats", "porridge oats"], 0.35),
        (["wasser", "water"], 1.0),
        (["milch", "milk"], 1.03),
        (["sahne", "cream"], 1.0),
        (["öl", "oel", "oil"], 0.92),
        (["butter"], 0.96),
        (["mehl", "flour"], 0.53),
        (["zucker", "sugar"], 0.85),
        (["salz", "salt"], 1.2),
        (["reis", "rice"], 0.85),
        (["honig", "honey"], 1.42),
    ]

    /// Density for an ingredient name, defaulting to water if unknown.
    static func gramsPerMillilitre(for ingredientName: String?) -> (value: Double, known: Bool) {
        guard let ingredientName else { return (1.0, false) }
        let key = Ingredient.normalize(ingredientName)
        for entry in densities {
            if entry.names.contains(where: { key.contains(Ingredient.normalize($0)) }) {
                return (entry.value, true)
            }
        }
        return (1.0, false)
    }
}
