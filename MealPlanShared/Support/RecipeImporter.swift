import Foundation

/// The source of one field in an imported recipe. Keeping this separate from
/// `needsReview` lets the importer fill a missing structured field without
/// making the whole recipe look like a heuristic result.
enum RecipeExtractionSource: String, Sendable, Equatable {
    case jsonLD
    case microdata
    case embeddedJSON
    case siteMarkup
    case semanticHTML
    case heuristic
}

struct RecipeFieldEvidence: Sendable, Equatable {
    var source: RecipeExtractionSource
    /// A short, human-readable locator such as "h2 Ingredients" or
    /// "recipe-ingredients li". It is deliberately not the page contents.
    var locator: String?
    var confidence: Double
}

/// Result of trying to turn a URL or file into a dish.
struct ImportedRecipe: Sendable {
    var name: String
    var sourceURL: URL?
    /// An optional custom-scheme or universal link that opens the recipe in
    /// its source app. Kept separate from the browser-friendly source URL.
    var deepLinkURL: URL?
    var imageData: Data?
    var imageURLString: String?
    var ingredientLines: [String] = []
    var instructions: String?
    var servings: Int?
    var prepTimeMinutes: Int?
    var cookTimeMinutes: Int?
    var categories: [String] = []
    var isFavorite: Bool = false
    var rating: Int = 0
    var collectionNames: [String] = []
    /// Free-form tags carried over from the source (schema.org keywords,
    /// Paprika categories, a MealPlan archive). Merged with the tags the app
    /// derives itself in `DishBuilder`.
    var tagNames: [String] = []
    var mealTypeTags: Set<MealTypeTag> = []
    var dietaryTags: Set<DietaryTag> = []
    var season: Season?
    var glyph: DishGlyph?
    /// Present for MealPlan's own portable format. Other importers continue
    /// to provide raw ingredient lines and use the locale-aware parser.
    var structuredIngredients: [ImportedIngredient]?
    var additionalImageData: [Data] = []
    /// Identifier of the app the recipe came from, e.g. "Paprika".
    var importedSourceApp: String?
    /// The source app's own stable identifier for the recipe (Paprika's
    /// `uid`). Used by the duplicate check, which trusts it over the name.
    var sourceIdentifier: String?
    /// Variant grouping carried by MealPlan's own archive format, so a backup
    /// restores the groups it was exported with.
    var variantGroupID: UUID?
    var variantGroupName: String?
    /// What the source said one serving contains, when it said anything.
    /// schema.org recipes carry a `NutritionInformation` block often enough to
    /// be worth reading, and a figure the recipe's own author published beats
    /// anything MealPlan can add up from an ingredient list.
    var nutritionPerServing: NutritionFacts?
    /// True when the data came from HTML guesswork rather than structured markup.
    var needsReview: Bool = true
    /// Evidence for fields populated by an extraction layer. This is kept on
    /// the transport value so validation and future preview UI can explain
    /// where a field came from without changing the Dish model.
    var fieldEvidence: [String: RecipeFieldEvidence] = [:]

    init(name: String, sourceURL: URL? = nil) {
        self.name = name
        self.sourceURL = sourceURL
    }
}

/// The result of extracting a recipe, before it is allowed to touch SwiftData.
/// Keeping this separate from `ImportedRecipe` means parsers can be improved or
/// combined without making an incomplete parse look like a successful import.
struct RecipeExtractionResult: Identifiable, Sendable {
    let id: UUID
    var recipe: ImportedRecipe
    let outcome: RecipeExtractionOutcome
    let overallQuality: Double
    let fieldQuality: [RecipeExtractionField: Double]
    let provenance: [RecipeExtractionField: RecipeExtractionProvenance]
    let warnings: [String]
    let evidence: [String]

    var quality: Double { overallQuality }
    var isUsable: Bool { outcome != .failed }

    init(
        recipe: ImportedRecipe,
        provenance: [RecipeExtractionField: RecipeExtractionProvenance] = [:],
        evidence: [String] = [],
        id: UUID = UUID()
    ) {
        let assessment = Self.assess(recipe, provenance: provenance, evidence: evidence)
        self.id = id
        self.recipe = assessment.recipe
        self.outcome = assessment.outcome
        self.overallQuality = assessment.overallQuality
        self.fieldQuality = assessment.fieldQuality
        self.provenance = assessment.provenance
        self.warnings = assessment.warnings
        self.evidence = assessment.evidence
    }

    /// Merges field-level candidates, preferring the candidate with the
    /// strongest evidence for each field. This keeps provenance when a page's
    /// title comes from JSON-LD but its visible steps come from semantic HTML.
    static func merging(_ candidates: [RecipeExtractionResult]) -> RecipeExtractionResult? {
        guard let first = candidates.first else { return nil }
        var merged = first.recipe
        var selectedQuality = first.fieldQuality
        var selectedProvenance = first.provenance

        for candidate in candidates.dropFirst() {
            func shouldTake(_ field: RecipeExtractionField) -> Bool {
                candidate.fieldQuality[field, default: 0] > selectedQuality[field, default: 0]
            }

            if shouldTake(.title) { merged.name = candidate.recipe.name }
            if shouldTake(.ingredients) {
                merged.ingredientLines = candidate.recipe.ingredientLines
                merged.structuredIngredients = candidate.recipe.structuredIngredients
            }
            if shouldTake(.instructions) { merged.instructions = candidate.recipe.instructions }
            if shouldTake(.servings) { merged.servings = candidate.recipe.servings }
            if shouldTake(.prepTime) { merged.prepTimeMinutes = candidate.recipe.prepTimeMinutes }
            if shouldTake(.cookTime) { merged.cookTimeMinutes = candidate.recipe.cookTimeMinutes }
            if shouldTake(.image) {
                merged.imageData = candidate.recipe.imageData
                merged.imageURLString = candidate.recipe.imageURLString
            }

            for field in RecipeExtractionField.allCases where shouldTake(field) {
                selectedQuality[field] = candidate.fieldQuality[field, default: 0]
                selectedProvenance[field] = candidate.provenance[field]
            }
            if merged.sourceURL == nil { merged.sourceURL = candidate.recipe.sourceURL }
        }

        return RecipeExtractionResult(
            recipe: merged,
            provenance: selectedProvenance,
            evidence: candidates.flatMap(\.evidence),
            id: first.id
        )
    }

    private struct Assessment {
        var recipe: ImportedRecipe
        var outcome: RecipeExtractionOutcome
        var overallQuality: Double
        var fieldQuality: [RecipeExtractionField: Double]
        var provenance: [RecipeExtractionField: RecipeExtractionProvenance]
        var warnings: [String]
        var evidence: [String]
    }

    private static func assess(
        _ input: ImportedRecipe,
        provenance: [RecipeExtractionField: RecipeExtractionProvenance],
        evidence: [String]
    ) -> Assessment {
        var recipe = input
        let title = meaningfulTitle(input.name)
        let ingredients = input.ingredientLines.filter(isMeaningfulIngredient)
        let instructions = meaningfulInstructions(input.instructions)
        recipe.name = title ?? input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.ingredientLines = ingredients
        recipe.instructions = instructions

        var warnings: [String] = []
        if title == nil { warnings.append("The recipe title is missing or looks like a page heading.") }
        if ingredients.isEmpty { warnings.append("No plausible ingredients were found.") }
        if instructions == nil { warnings.append("No usable preparation steps were found.") }
        if input.ingredientLines.count > 120 {
            warnings.append("The ingredient section is unusually large and may include page boilerplate.")
        }
        if (input.instructions?.count ?? 0) > 20_000 {
            warnings.append("The instruction section is unusually large and may include page boilerplate.")
        }

        let ingredientScore: Double = ingredients.isEmpty
            ? 0
            : min(1, 0.35 + Double(min(ingredients.count, 10)) * 0.065)
        let instructionScore: Double = instructions.map { text in
            min(1, max(0.35, Double(text.count) / 220.0))
        } ?? 0
        let titleScore: Double = title == nil ? 0 : 1
        let servingsScore: Double = input.servings.flatMap { $0 > 0 ? 0.8 : nil } ?? 0
        let timingScore: Double = input.prepTimeMinutes != nil || input.cookTimeMinutes != nil ? 0.7 : 0
        let imageScore: Double = input.imageData != nil || input.imageURLString != nil ? 0.7 : 0
        let coreScore = 0.2 * titleScore + 0.35 * ingredientScore + 0.35 * instructionScore
        let supportingScore = 0.05 * servingsScore + 0.025 * timingScore + 0.025 * imageScore
        let overall = min(1.0, coreScore + supportingScore)

        let outcome: RecipeExtractionOutcome
        if ingredients.isEmpty && instructions == nil {
            outcome = .failed
        } else if title == nil || ingredients.isEmpty || instructions == nil {
            outcome = .partial
        } else {
            outcome = .good
        }
        recipe.needsReview = recipe.needsReview || outcome != .good

        var fieldQuality = [RecipeExtractionField: Double]()
        fieldQuality[.title] = titleScore
        fieldQuality[.ingredients] = ingredientScore
        fieldQuality[.instructions] = instructionScore
        fieldQuality[.servings] = servingsScore
        fieldQuality[.prepTime] = input.prepTimeMinutes == nil ? 0 : 0.7
        fieldQuality[.cookTime] = input.cookTimeMinutes == nil ? 0 : 0.7
        fieldQuality[.image] = imageScore

        var inferredProvenance = provenance
        let defaultProvenance: RecipeExtractionProvenance = .semanticHTML
        for field in RecipeExtractionField.allCases where inferredProvenance[field] == nil {
            if fieldQuality[field, default: 0] > 0 { inferredProvenance[field] = defaultProvenance }
        }

        var allEvidence = evidence
        allEvidence.append("title=" + (titleScore > 0 ? "meaningful" : "missing"))
        allEvidence.append("ingredients=\(ingredients.count) plausible line(s)")
        allEvidence.append("instructions=" + (instructions == nil ? "missing" : "usable"))
        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        return Assessment(
            recipe: recipe,
            outcome: outcome,
            overallQuality: overall,
            fieldQuality: fieldQuality,
            provenance: inferredProvenance,
            warnings: unique(warnings),
            evidence: unique(allEvidence)
        )
    }

    private static let headings: Set<String> = [
        "ingredient", "ingredients", "zutaten", "zutatenliste", "direction", "directions",
        "instruction", "instructions", "method", "preparation", "zubereitung", "anleitung"
    ]

    private static let boilerplate: [String] = [
        "privacy policy", "terms of use", "sign up", "subscribe", "cookie settings",
        "accept cookies", "jump to recipe", "print recipe", "advertisement"
    ]

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters)
    }

    private static func meaningfulTitle(_ value: String) -> String? {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 180 else { return nil }
        let normalized = folded(title)
        guard !headings.contains(normalized), normalized != "recipe", normalized != "imported recipe",
              !boilerplate.contains(where: { normalized == $0 }) else { return nil }
        return title
    }

    private static func isMeaningfulIngredient(_ value: String) -> Bool {
        let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.count <= 240 else { return false }
        let normalized = folded(line)
        guard !headings.contains(normalized), !boilerplate.contains(where: { normalized.contains($0) }) else { return false }
        return line.rangeOfCharacter(from: .letters) != nil
    }

    private static func meaningfulInstructions(_ value: String?) -> String? {
        guard let value else { return nil }
        let lines = value.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let useful = lines.filter { line in
            let normalized = folded(line)
            return !headings.contains(normalized)
                && !boilerplate.contains(where: { normalized == $0 })
                && line.rangeOfCharacter(from: .letters) != nil
        }
        guard !useful.isEmpty else { return nil }
        let text = useful.joined(separator: "\n\n")
        guard text.count >= 8, text.count <= 20_000 else { return nil }
        return text
    }
}

enum RecipeExtractionOutcome: String, Equatable, Sendable {
    case good
    case partial
    case failed
}

enum RecipeExtractionField: String, CaseIterable, Hashable, Sendable {
    case title
    case ingredients
    case instructions
    case servings
    case prepTime
    case cookTime
    case image
}

enum RecipeExtractionProvenance: String, Equatable, Sendable {
    case jsonLD
    case microdata
    case embeddedJSON
    case semanticHTML
    case appleIntelligence
    case userEdited
}

struct ImportedIngredient: Sendable {
    var name: String
    var category: IngredientCategory
    var customAisleName: String? = nil
    var isPantryStaple: Bool
    var canonicalValue: Double?
    var dimension: QuantityDimension?
    var displayUnit: String?
    var isApproximate: Bool
    var note: String?
    var rawText: String?
    /// Values the exporting household had entered for this ingredient, so a
    /// shared recipe arrives knowing what its ingredients contain instead of
    /// falling back to generic reference figures.
    var nutrition: NutritionFacts? = nil
    var nutritionReference: NutritionReference = .per100Grams
}

enum RecipeImportError: LocalizedError {
    case notReachable
    case noRecipeFound
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .notReachable: String(localized: "Couldn’t reach that page.")
        case .noRecipeFound: String(localized: "No recipe found on that page.")
        case .unreadableFile: String(localized: "That file couldn’t be read.")
        }
    }
}

/// Turns a recipe URL into an `ImportedRecipe`.
protocol RecipeImporter: Sendable {
    func importRecipe(from url: URL) async throws -> ImportedRecipe
}

/// Records only the URL + site name. Kept as a fallback / for tests.
struct StubRecipeImporter: RecipeImporter {
    func importRecipe(from url: URL) async throws -> ImportedRecipe {
        let name = url.host()?
            .replacingOccurrences(of: "www.", with: "")
            ?? String(localized: "Imported recipe")
        var recipe = ImportedRecipe(name: name.capitalized, sourceURL: url)
        recipe.needsReview = true
        return recipe
    }
}
