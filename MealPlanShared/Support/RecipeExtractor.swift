import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns the raw text read off a scanned recipe page into a structured draft.
///
/// When Apple Intelligence is available it asks the on-device model to pull the
/// name, ingredients and steps apart — it copes with OCR line-break noise, page
/// headers and running text far better than a layout heuristic can. Everywhere
/// else (unsupported device, feature switched off, no capacity, or the model
/// declines) it falls back to `ScannedRecipeParser`. Nothing leaves the device
/// either way.
enum RecipeExtractor {
    enum Source: Sendable {
        case scannedPage
        case socialPost
    }

    static func extract(
        from text: String,
        source: Source = .scannedPage
    ) async -> ScannedRecipeDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ScannedRecipeDraft(name: "", ingredientLines: [], instructions: "")
        }
        #if canImport(FoundationModels)
        if let draft = await modelExtraction(from: trimmed, source: source) {
            return draft
        }
        #endif
        return ScannedRecipeParser.parse(trimmed)
    }

    #if canImport(FoundationModels)
    @Generable
    struct RecipeFields {
        @Guide(description: "The dish's name, in the page's own language. An empty string if the page has no clear title.")
        var name: String
        @Guide(description: "Each ingredient with its quantity, one entry per ingredient, kept in the page's own words and language. Empty when none are listed.")
        var ingredients: [String]
        @Guide(description: "The preparation steps in order, one entry per step, tidied of OCR noise but not reworded. Empty when none are given.")
        var steps: [String]
    }

    private static func promptInstructions(for source: Source) -> String {
        switch source {
        case .scannedPage:
            """
            You extract a single cooking recipe from text captured by OCR from a printed page.
            The text often has line-break noise, page numbers, book titles or other page \
            furniture mixed in — ignore anything that isn't part of the recipe. Keep the \
            recipe's original language and wording. Never invent an ingredient or a step that \
            isn't in the text; if a part is missing, leave it empty.
            """
        case .socialPost:
            """
            You extract a single cooking recipe from a social-media caption, video description, \
            or transcript. Ignore usernames, engagement prompts, sponsorships, hashtags, and \
            unrelated commentary. Keep the recipe's original language and wording. Never invent \
            an ingredient, quantity, or step that isn't in the text; if a part is missing, leave \
            it empty.
            """
        }
    }

    private static func modelExtraction(from text: String, source: Source) async -> ScannedRecipeDraft? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let session = LanguageModelSession(instructions: promptInstructions(for: source))
            let fields = try await session.respond(
                to: "Extract the recipe from this text:\n\n\(text)",
                generating: RecipeFields.self
            ).content

            let name = fields.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let ingredients = fields.ingredients
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let steps = fields.steps
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard !name.isEmpty || !ingredients.isEmpty || !steps.isEmpty else { return nil }
            return ScannedRecipeDraft(
                name: name,
                ingredientLines: ingredients,
                instructions: steps.joined(separator: "\n")
            )
        } catch {
            return nil
        }
    }
    #endif
}
