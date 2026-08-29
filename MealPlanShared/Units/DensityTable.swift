import Foundation

/// Rough densities (grams per millilitre) for common ingredients, used only
/// when a volume measure has to be shown as a weight or vice versa. These
/// vary a lot in practice, so any conversion that uses them is flagged
/// approximate.
enum DensityTable {
    /// grams per millilitre
    static let densities: [String: Double] = [
        "wasser": 1.0,
        "milch": 1.03,
        "sahne": 1.0,
        "öl": 0.92,
        "olivenöl": 0.92,
        "butter": 0.96,
        "mehl": 0.53,
        "zucker": 0.85,
        "puderzucker": 0.56,
        "salz": 1.2,
        "reis": 0.85,
        "honig": 1.42,
        "haferflocken": 0.35,
    ]

    /// Density for an ingredient name, defaulting to water if unknown.
    static func gramsPerMillilitre(for ingredientName: String?) -> (value: Double, known: Bool) {
        guard let key = ingredientName?.lowercased() else { return (1.0, false) }
        for (name, density) in densities where key.contains(name) {
            return (density, true)
        }
        return (1.0, false)
    }
}
