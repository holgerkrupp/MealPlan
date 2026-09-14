import Foundation

struct CookingStep: Identifiable, Equatable, Sendable {
    var id: Int
    var text: String
    var timers: [RecipeTimerSuggestion]
}

struct RecipeTimerSuggestion: Identifiable, Equatable, Sendable {
    var id: String { "\(rangeLocation)-\(duration)" }
    var label: String
    var duration: TimeInterval
    var rangeLocation: Int
}

/// Ingredient indexes assigned to the first recipe step that mentions them.
/// A nil `stepID` holds ingredients that the plain-text directions do not
/// mention clearly enough to place without guessing.
struct CookingIngredientGroup: Identifiable, Equatable, Sendable {
    var stepID: Int?
    var ingredientIndexes: [Int]

    var id: String { stepID.map { "step-\($0)" } ?? "other" }
}

enum CookingRecipe {
    /// Turns the deliberately portable plain-text directions field into
    /// focused cooking steps. Blank lines and explicit line breaks both make
    /// useful step boundaries for imported and hand-written recipes.
    static func steps(from text: String?) -> [CookingStep] {
        guard let text else { return [] }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.enumerated().map { index, raw in
            let cleaned = raw.replacingOccurrences(
                of: #"^\s*(?:step\s+)?\d+[\.:\)]\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            return CookingStep(id: index, text: cleaned, timers: timers(in: cleaned))
        }
    }

    static func timers(in text: String) -> [RecipeTimerSuggestion] {
        let pattern = #"(?i)(\d+(?:[\.,]\d+)?)\s*(hours?|hrs?|hr|h|stunden?|std|minutes?|mins?|min|minuten?|seconds?|secs?|sec|s|sekunden?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }
            let numberText = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: ".")
            guard let value = Double(numberText), value > 0 else { return nil }
            let unit = ns.substring(with: match.range(at: 2)).lowercased()
            let multiplier: Double
            if unit.hasPrefix("h") || unit.hasPrefix("std") || unit.hasPrefix("stund") {
                multiplier = 3600
            } else if unit.hasPrefix("s") && !unit.hasPrefix("st") || unit.hasPrefix("sek") {
                multiplier = 1
            } else {
                multiplier = 60
            }
            return RecipeTimerSuggestion(
                label: ns.substring(with: match.range),
                duration: value * multiplier,
                rangeLocation: match.range.location
            )
        }
    }

    /// Groups each ingredient with the first step that names it. Matching is
    /// token-based instead of substring-based, so "oil" never matches "boil".
    /// A small plural stem covers common imported English and German recipes;
    /// anything ambiguous remains visible in the unassigned group.
    static func ingredientGroups(
        ingredientNames: [String],
        steps: [CookingStep]
    ) -> [CookingIngredientGroup] {
        guard !ingredientNames.isEmpty else { return [] }

        let stepTokens = steps.map { matchTokens(in: $0.text) }
        var indexesByStep: [Int: [Int]] = [:]
        var unassigned: [Int] = []

        for (ingredientIndex, name) in ingredientNames.enumerated() {
            let ingredientTokens = matchTokens(in: name)
            let matchedStep = stepTokens.firstIndex { tokens in
                ingredientTokens.contains { ingredientToken in
                    tokens.contains { stepToken in tokensMatch(ingredientToken, stepToken) }
                }
            }

            if let matchedStep {
                indexesByStep[steps[matchedStep].id, default: []].append(ingredientIndex)
            } else {
                unassigned.append(ingredientIndex)
            }
        }

        var groups = steps.compactMap { step -> CookingIngredientGroup? in
            guard let indexes = indexesByStep[step.id], !indexes.isEmpty else { return nil }
            return CookingIngredientGroup(stepID: step.id, ingredientIndexes: indexes)
        }
        if !unassigned.isEmpty {
            groups.append(CookingIngredientGroup(stepID: nil, ingredientIndexes: unassigned))
        }
        return groups
    }

    private static func matchTokens(in text: String) -> Set<String> {
        let folded = text
            .lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        return Set(folded.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !ingredientStopWords.contains($0) })
    }

    private static func tokensMatch(_ ingredient: String, _ step: String) -> Bool {
        if ingredient == step { return true }
        return !tokenStems(for: ingredient).isDisjoint(with: tokenStems(for: step))
    }

    private static func tokenStems(for token: String) -> Set<String> {
        var stems: Set<String> = [token]
        guard token.count >= 5 else { return stems }
        for suffix in ["ern", "en", "es", "er", "n", "s"] where token.hasSuffix(suffix) {
            let stem = String(token.dropLast(suffix.count))
            if stem.count >= 4 { stems.insert(stem) }
        }
        return stems
    }

    private static let ingredientStopWords: Set<String> = [
        "and", "der", "die", "for", "fresh", "large", "mit", "oder",
        "small", "the", "und", "with",
    ]
}
