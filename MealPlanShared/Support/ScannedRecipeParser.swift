import Foundation

struct ScannedRecipeDraft: Equatable, Sendable {
    var name: String
    var ingredientLines: [String]
    var instructions: String

    /// The same draft, guaranteed not to have lost the text it came from: when
    /// neither ingredients nor a method could be told apart, the whole
    /// original text becomes the method so the cook can tidy it by hand.
    func preservingOriginal(_ text: String) -> ScannedRecipeDraft {
        guard ingredientLines.isEmpty,
              instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return self }
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, original != name else { return self }
        var copy = self
        copy.instructions = original
        return copy
    }
}

enum ScannedRecipeParser {
    private static let ingredientHeadings = [
        "ingredients", "ingredient", "zutaten", "zutatenliste", "you will need", "you'll need", "what you need"
    ]
    private static let methodHeadings = [
        "directions", "instructions", "method", "preparation", "steps", "zubereitung", "anleitung",
        "zubereitungsschritte"
    ]

    /// Conservative layout heuristic. The editable preview is the authority;
    /// this only saves the user from dividing well-labelled pages by hand.
    ///
    /// Nothing is dropped: lines between the title and the first heading (an
    /// intro, "Serves 4") lead the method rather than disappearing.
    static func parse(_ text: String) -> ScannedRecipeDraft {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return ScannedRecipeDraft(name: "", ingredientLines: [], instructions: "") }

        let ingredientIndex = lines.firstIndex { isHeading($0, in: ingredientHeadings, allowQualified: true) }
        let methodIndex = lines.firstIndex { isHeading($0, in: methodHeadings, allowQualified: false) }
        let firstHeading = [ingredientIndex, methodIndex].compactMap { $0 }.min() ?? lines.count
        let nameIndex = lines[..<firstHeading].firstIndex(where: { $0.count <= 100 }) ?? 0
        let name = lines[nameIndex]

        // Neither heading: a page from a recipe book (or a pasted note) rarely
        // prints one. Take the leading run of measurement-style lines under the
        // title as the ingredient list and leave the prose that follows as the
        // method.
        if ingredientIndex == nil, methodIndex == nil {
            let body = lines.enumerated().filter { $0.offset != nameIndex }.map(\.element)
            let split = body.prefix { looksLikeIngredient($0) }
            if split.count >= 2 {
                return ScannedRecipeDraft(
                    name: name,
                    ingredientLines: split.map(strippingBullet),
                    instructions: body.dropFirst(split.count).joined(separator: "\n")
                )
            }
            return ScannedRecipeDraft(name: name, ingredientLines: [], instructions: body.joined(separator: "\n"))
        }

        let preamble = lines[..<firstHeading].enumerated()
            .filter { $0.offset != nameIndex }
            .map(\.element)

        var ingredients: [String] = []
        if let start = ingredientIndex {
            let end = methodIndex.flatMap { $0 > start ? $0 : nil } ?? lines.count
            if start + 1 < end { ingredients = lines[(start + 1)..<end].map(strippingBullet) }
        }

        var method: [String] = []
        if let start = methodIndex {
            // A method printed before the ingredients stops where they begin.
            let end = ingredientIndex.flatMap { $0 > start ? $0 : nil } ?? lines.count
            if start + 1 < end { method = Array(lines[(start + 1)..<end]) }
        }

        return ScannedRecipeDraft(
            name: name,
            ingredientLines: ingredients,
            instructions: (preamble + method).joined(separator: "\n")
        )
    }

    /// Copied or shared text as a recipe ready for import. Uses only the
    /// layout heuristic (no model), so it is cheap enough for the Share
    /// Extension, and never loses the original text.
    static func importedRecipe(fromText text: String) -> ImportedRecipe {
        let draft = parse(text).preservingOriginal(text)
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var recipe = ImportedRecipe(name: name.isEmpty ? String(localized: "New dish") : name)
        recipe.ingredientLines = draft.ingredientLines
        recipe.instructions = draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        recipe.needsReview = true
        return recipe
    }

    private static func heading(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// "Ingredients", "Ingredients:", and — for ingredient headings only —
    /// short qualified forms such as "Zutaten für 4 Personen" or
    /// "Ingredients (serves 4)". Method headings must stand alone, so a step
    /// like "Method: mix well" is never swallowed as a heading.
    private static func isHeading(_ line: String, in headings: [String], allowQualified: Bool) -> Bool {
        let folded = heading(line)
        if headings.contains(folded) { return true }
        guard allowQualified, line.count <= 40 else { return false }
        return headings.contains { word in
            guard folded.hasPrefix(word), let next = folded.dropFirst(word.count).first else { return false }
            return next == " " || next == "(" || next == ":"
        }
    }

    private static let bulletScalars = CharacterSet(charactersIn: "•·▪◦‣∙*-–—▢□☐✓✔")

    /// "• 200 g flour" → "200 g flour". A hyphen only counts as a bullet when
    /// followed by a space, so "-5 °C" style text stays as it is.
    private static func strippingBullet(_ line: String) -> String {
        guard let first = line.unicodeScalars.first, bulletScalars.contains(first) else { return line }
        let rest = line.unicodeScalars.dropFirst()
        if first == "-", let next = rest.first, next != " " { return line }
        return String(String.UnicodeScalarView(rest)).trimmingCharacters(in: .whitespaces)
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
    /// period are almost always method steps, and so are numbered lines
    /// ("1. Preheat the oven").
    private static func looksLikeIngredient(_ raw: String) -> Bool {
        let line = strippingBullet(raw)
        let isBulleted = line != raw
        guard line.count <= 90 else { return false }
        if line.range(of: #"^\d+\s*[.)]\s"#, options: .regularExpression) != nil { return false }
        let folded = line.folding(options: .caseInsensitive, locale: .current)
        guard let first = folded.unicodeScalars.first else { return false }

        let fractionScalars = "¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞".unicodeScalars
        let startsWithQuantity = CharacterSet.decimalDigits.contains(first)
            || fractionScalars.contains(first)
        let firstWord = folded.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let leadsWithUnit = unitWords.contains(firstWord.trimmingCharacters(in: CharacterSet.letters.inverted))

        // A short bulleted line ("• salt and pepper") is a list entry even
        // without a quantity.
        guard startsWithQuantity || leadsWithUnit || (isBulleted && line.count <= 40) else { return false }
        // A measurement that runs into a sentence ("2 eggs, then beat them
        // well.") is a step, not a list entry.
        return !line.hasSuffix(".") || line.count <= 40
    }
}
