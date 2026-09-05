import Foundation

/// The parts of a recipe worth translating, lifted off the model so the
/// translator itself never touches SwiftData and stays testable.
struct RecipeTranslationRequest: Sendable, Equatable {
    /// One line of the ingredient list. The identifier is the `DishIngredient`
    /// it came from, so the translation can be written back to the right line
    /// even after the list was re-sorted while the model was working.
    struct IngredientLine: Sendable, Equatable, Identifiable {
        var id: UUID
        var name: String
        var note: String?
    }

    var name: String
    var ingredients: [IngredientLine]
    var directions: RecipeDirectionsLayout
    /// The language the recipe appears to be written in, when it could be told.
    var sourceLanguageCode: String?

    var isEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ingredients.isEmpty
            && directions.translatableLines.isEmpty
    }
}

/// A finished translation, ready to be shown or saved onto the dish.
struct RecipeTranslation: Sendable, Equatable {
    struct IngredientLine: Sendable, Equatable, Identifiable {
        var id: UUID
        var name: String
        var note: String?
    }

    /// The language tag the cook asked for, e.g. "de" or "pt-BR".
    var languageCode: String
    var name: String
    var ingredients: [IngredientLine]
    /// The directions as one plain-text block, in the shape the original had.
    var directionsText: String?

    func line(_ id: UUID) -> IngredientLine? {
        ingredients.first { $0.id == id }
    }
}

/// The paragraph shape of a recipe's directions.
///
/// Directions are stored as one portable plain-text field, and both the recipe
/// view and cooking mode read its line breaks as step boundaries. Translating
/// the block as a whole would let the model re-flow it, so the lines are
/// translated one by one and slotted back where they were — blank lines and
/// step order survive the round trip untouched.
struct RecipeDirectionsLayout: Sendable, Equatable {
    /// Every line of the original, blank ones included.
    private(set) var lines: [String]
    /// Indexes into `lines` that actually carry text.
    private(set) var translatableIndexes: [Int]

    init(_ text: String?) {
        let normalized = (text ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        lines = normalized.isEmpty ? [] : normalized.components(separatedBy: .newlines)
        translatableIndexes = lines.indices.filter {
            !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The lines to hand the translator, in order.
    var translatableLines: [String] { translatableIndexes.map { lines[$0] } }

    /// The original text, unchanged.
    var text: String { lines.joined(separator: "\n") }

    /// The same block with each non-blank line replaced by its translation.
    /// A mismatched count means the model dropped or merged lines; the
    /// original is kept rather than a scrambled version of it.
    func rebuilt(with translations: [String]) -> String? {
        guard !lines.isEmpty else { return nil }
        guard translations.count == translatableIndexes.count else { return text }
        var rebuilt = lines
        for (slot, index) in translatableIndexes.enumerated() {
            let translated = translations[slot].trimmingCharacters(in: .whitespacesAndNewlines)
            if !translated.isEmpty { rebuilt[index] = translated }
        }
        return rebuilt.joined(separator: "\n")
    }
}
