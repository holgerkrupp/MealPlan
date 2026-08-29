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
}
