import Foundation

struct ScannedRecipeDraft: Equatable, Sendable {
    var name: String
    var ingredientLines: [String]
    var instructions: String
}

enum ScannedRecipeParser {
    private static let ingredientHeadings = ["ingredients", "ingredient", "zutaten", "zutatenliste"]
    private static let methodHeadings = ["directions", "instructions", "method", "preparation", "zubereitung", "anleitung"]

    /// Conservative layout heuristic. The editable preview is the authority;
    /// this only saves the user from dividing well-labelled pages by hand.
    static func parse(_ text: String) -> ScannedRecipeDraft {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return ScannedRecipeDraft(name: "", ingredientLines: [], instructions: "") }

        let ingredientIndex = lines.firstIndex { ingredientHeadings.contains(heading($0)) }
        let methodIndex = lines.firstIndex { methodHeadings.contains(heading($0)) }
        let firstHeading = [ingredientIndex, methodIndex].compactMap { $0 }.min() ?? lines.count
        let name = lines[..<firstHeading].first(where: { $0.count <= 100 }) ?? lines[0]

        let ingredients: [String]
        if let start = ingredientIndex {
            let end = methodIndex.flatMap { $0 > start ? $0 : nil } ?? lines.count
            ingredients = start + 1 < end ? Array(lines[(start + 1)..<end]) : []
        } else {
            ingredients = []
        }

        let instructions: [String]
        if let start = methodIndex, start + 1 < lines.count {
            instructions = Array(lines[(start + 1)...])
        } else if ingredientIndex == nil {
            instructions = Array(lines.dropFirst())
        } else {
            instructions = []
        }

        // A page from a recipe book rarely prints an "Ingredients" heading. When
        // neither heading was found, take the leading run of measurement-style
        // lines under the title as the ingredient list and leave the prose that
        // follows as the method.
        if ingredientIndex == nil, methodIndex == nil {
            let body = Array(lines.dropFirst())
            let split = body.prefix { looksLikeIngredient($0) }
            if split.count >= 2 {
                return ScannedRecipeDraft(
                    name: name,
                    ingredientLines: Array(split),
                    instructions: body.dropFirst(split.count).joined(separator: "\n")
                )
            }
        }

        return ScannedRecipeDraft(
            name: name,
            ingredientLines: ingredients,
            instructions: instructions.joined(separator: "\n")
        )
    }

    private static func heading(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private static let unitWords: Set<String> = [
        "g", "kg", "mg", "ml", "cl", "l", "el", "tl", "prise", "prisen", "pkg", "packung", "dose", "dosen",
        "bund", "stück", "stk", "scheibe", "scheiben", "zehe", "zehen", "tasse", "tassen", "glas",
        "tsp", "tbsp", "teaspoon", "teaspoons", "tablespoon", "tablespoons", "cup", "cups", "oz", "lb",
        "pound", "pounds", "ounce", "ounces", "clove", "cloves", "pinch", "can", "cans", "slice", "slices",
        "handful", "stick", "sticks", "sprig", "sprigs"
    ]

    /// A single ingredient line usually starts with a number or fraction, or
    /// leads with a measurement word, and is short. Full sentences ending in a
    /// period are almost always method steps.
    private static func looksLikeIngredient(_ line: String) -> Bool {
        guard line.count <= 90 else { return false }
        let folded = line.folding(options: .caseInsensitive, locale: .current)
        guard let first = folded.unicodeScalars.first else { return false }

        let fractionScalars = "¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞".unicodeScalars
        let startsWithQuantity = CharacterSet.decimalDigits.contains(first)
            || fractionScalars.contains(first)
        let firstWord = folded.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let leadsWithUnit = unitWords.contains(firstWord.trimmingCharacters(in: CharacterSet.letters.inverted))

        guard startsWithQuantity || leadsWithUnit else { return false }
        // A measurement that runs into a sentence ("2 eggs, then beat them
        // well.") is a step, not a list entry.
        return !line.hasSuffix(".") || line.count <= 40
    }
}
