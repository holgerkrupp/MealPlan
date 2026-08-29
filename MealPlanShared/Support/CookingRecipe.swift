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
}
