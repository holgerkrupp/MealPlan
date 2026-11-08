import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One possible stand-in for an ingredient, as suggested by the on-device model.
/// Only ever shown for review: nothing here writes to a recipe, and the
/// detail screen changes a line only when the cook explicitly applies one.
struct IngredientSubstitution: Equatable, Sendable, Identifiable {
    var name: String
    /// "Use about three quarters of the amount", or empty.
    var amountHint: String
    /// Why it works and what changes — taste, texture, diet.
    var note: String

    var id: String { name.lowercased() }

    /// The text added to the recipe line's note when applied: "or: oat milk (same amount)".
    var noteText: String {
        amountHint.isEmpty
            ? String(localized: "or: \(name)")
            : String(localized: "or: \(name) (\(amountHint))")
    }
}

/// Asks Apple Intelligence, on the device, what could replace one ingredient
/// of a recipe. Available only where `SystemLanguageModel` is; everywhere else
/// the action is simply not offered. Nothing leaves the device.
enum IngredientSubstitutionSuggester {

    static var isAvailable: Bool {
        #if canImport(FoundationModels) && !os(watchOS)
        SystemLanguageModel.default.isAvailable
        #else
        false
        #endif
    }

    static func suggestions(
        for ingredient: String,
        amount: String?,
        dishName: String,
        otherIngredients: [String]
    ) async -> [IngredientSubstitution]? {
        #if canImport(FoundationModels) && !os(watchOS)
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You suggest practical substitutes for one ingredient in a home-cooking recipe. \
            Suggest up to four common alternatives a home cook is likely to have or find, \
            with how much to use and a short note on what changes (taste, texture, dietary \
            needs). Answer in the same language as the ingredient name. Never suggest the \
            ingredient itself, and never suggest anything unsafe to eat. If there is no \
            sensible substitute, return an empty list.
            """)
        let prompt = """
            Recipe: \(dishName)
            Ingredient to replace: \(ingredient)
            Amount in the recipe: \(amount ?? "not given")
            Other ingredients: \(otherIngredients.prefix(20).joined(separator: ", "))
            """
        do {
            let response = try await session.respond(to: prompt, generating: GeneratedSubstitutions.self)
            return cleaned(
                response.content.substitutes.map {
                    IngredientSubstitution(name: $0.name, amountHint: $0.amountHint, note: $0.note)
                },
                replacing: ingredient
            )
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Model output tidied for display: trimmed, empty and repeated names
    /// dropped, the original ingredient itself left out, at most four.
    static func cleaned(_ raw: [IngredientSubstitution], replacing original: String) -> [IngredientSubstitution] {
        let originalKey = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen: Set<String> = []
        var result: [IngredientSubstitution] = []
        for item in raw {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !name.isEmpty, key != originalKey, seen.insert(key).inserted else { continue }
            result.append(IngredientSubstitution(
                name: name,
                amountHint: item.amountHint.trimmingCharacters(in: .whitespacesAndNewlines),
                note: item.note.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            if result.count == 4 { break }
        }
        return result
    }
}

#if canImport(FoundationModels) && !os(watchOS)
// Not `private`: the @Generable macro expansion can't see private types.
@Generable
struct GeneratedSubstitutions {
    @Guide(description: "Up to four substitutes, best first. Empty when nothing sensible replaces the ingredient.")
    var substitutes: [GeneratedSubstitute]
}

@Generable
struct GeneratedSubstitute {
    @Guide(description: "The substitute ingredient's name, short, without an amount.")
    var name: String
    @Guide(description: "How much to use compared with the original, e.g. 'same amount' or 'about half'. Empty if unsure.")
    var amountHint: String
    @Guide(description: "One short sentence on what changes when using it.")
    var note: String
}
#endif
