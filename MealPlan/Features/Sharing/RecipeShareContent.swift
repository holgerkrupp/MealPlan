import Foundation

/// A recipe as it leaves the app for someone who doesn't have it: every
/// amount already scaled and formatted, every label already localized.
///
/// Built once from a `Dish` by `make`, then read by the plain-text formatter
/// and the PDF alike — the same split printing uses, so the text and the page
/// can never disagree about an amount, and both are testable without a
/// model container.
struct RecipeShareContent: Equatable, Sendable {
    var title: String
    /// "4 servings" — what the amounts below are for.
    var servingsText: String
    var servings: Int = 1
    var metrics: [Metric]
    var tags: [String]
    var ingredients: [IngredientLine]
    var steps: [Step]
    /// "Per serving ≈ 640 kcal · P 31 g · C 70 g · F 22 g", present only when
    /// the estimate is one the app would show on screen.
    var nutritionText: String?
    /// The same figures one by one, for the nutrition share image.
    var nutrition: NutritionSummary?
    var sourceURL: URL?
    /// Set once `RecipeSourceLink` found the page gone. The site is still
    /// credited by name; only the dead address is left out.
    var sourceIsGone = false
    /// Downsampled photo for the PDF. Never part of the text.
    var imageData: Data?

    struct NutritionSummary: Equatable, Sendable {
        var energy: String
        var protein: String
        var carbs: String
        var fat: String
    }

    struct Metric: Equatable, Sendable {
        var label: String
        var value: String
    }

    struct IngredientLine: Equatable, Sendable {
        var amount: String?
        var name: String
        var note: String?

        /// "250 g flour, sifted" / "salt, to taste" / "eggs".
        var text: String {
            let head = [amount, name].compactMap { $0 }.joined(separator: " ")
            guard let note, !note.isEmpty else { return head }
            return "\(head), \(note)"
        }
    }

    struct Step: Equatable, Sendable {
        /// `nil` for a heading, and for the only step of a one-paragraph recipe.
        var number: Int?
        var text: String
        var isHeading: Bool = false
    }

    var sourceHost: String? {
        sourceURL?.host()?.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
    }

    /// Whether the source is something a browser can open. A Paprika import can
    /// carry a bare name or a custom scheme, which is not worth sharing.
    var hasWebSource: Bool {
        guard let scheme = sourceURL?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

// MARK: - Building

extension RecipeShareContent {

    @MainActor
    static func make(
        dish: Dish,
        servings: Int,
        translated: Bool,
        system: UnitSystem,
        roundsAmounts: Bool,
        energyUnit: EnergyUnit?,
        includesImage: Bool = true,
        locale: Locale = .current
    ) -> RecipeShareContent {
        let servings = max(1, servings)
        let scaler = ServingScaler(
            baseServings: dish.servings,
            targetServings: servings,
            system: system,
            roundsAmounts: roundsAmounts,
            locale: locale
        )

        var metrics: [Metric] = []
        if let prep = dish.prepTimeMinutes, prep > 0 {
            metrics.append(Metric(label: String(localized: "Prep"), value: String(localized: "\(prep) min")))
        }
        if let cook = dish.cookTimeMinutes, cook > 0 {
            metrics.append(Metric(label: String(localized: "Cook"), value: String(localized: "\(cook) min")))
        }
        if dish.prepTimeMinutes ?? 0 > 0, dish.cookTimeMinutes ?? 0 > 0, let total = dish.totalTimeMinutes {
            metrics.append(Metric(label: String(localized: "Total"), value: String(localized: "\(total) min")))
        }

        let ingredients = dish.sortedIngredients.compactMap { line -> IngredientLine? in
            let name = (line.displayName(translated: translated) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let note = line.displayNote(translated: translated)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Without an amount, `ServingScaler` hands back the note in its
            // place ("a pinch"); that belongs after the name, not before it.
            let amount = line.quantity == nil ? nil : scaler.amountText(for: line)
            return IngredientLine(amount: amount, name: name, note: note?.isEmpty == false ? note : nil)
        }

        var nutritionText: String?
        var nutrition: NutritionSummary?
        if let energyUnit {
            let estimate = NutritionEstimator.perServing(for: dish)
            if estimate.isTrustworthy, estimate.facts.energyKcal > 0 {
                let facts = estimate.facts
                let energy = NutritionFormatting.energy(facts, unit: energyUnit, locale: locale)
                let protein = NutritionFormatting.grams(facts.proteinGrams, locale: locale)
                let carbs = NutritionFormatting.grams(facts.carbGrams, locale: locale)
                let fat = NutritionFormatting.grams(facts.fatGrams, locale: locale)
                nutritionText = String(localized: "Per serving \(energy) · P \(protein) · C \(carbs) · F \(fat)")
                nutrition = NutritionSummary(energy: energy, protein: protein, carbs: carbs, fat: fat)
            }
        }

        let title = dish.displayName(translated: translated).trimmingCharacters(in: .whitespacesAndNewlines)
        return RecipeShareContent(
            title: title.isEmpty ? String(localized: "Untitled dish") : title,
            servingsText: String(localized: "\(servings) servings"),
            servings: servings,
            metrics: metrics,
            tags: dish.sortedTagNames,
            ingredients: ingredients,
            steps: steps(from: dish.displayRecipeText(translated: translated)),
            nutritionText: nutritionText,
            nutrition: nutrition,
            sourceURL: dish.sourceURL,
            imageData: includesImage
                ? dish.primaryImageData.map { ImagePreparation.prepared(from: $0, maxDimension: 1_200, quality: 0.75) }
                : nil
        )
    }

    /// Splits the directions the way Cooking Mode does, then numbers them.
    ///
    /// A short line ending in a colon ("For the sauce:") is a heading, not a
    /// step, so it isn't numbered and doesn't use up a number. A recipe that is
    /// one paragraph gets no number at all — "1." in front of the only step
    /// reads like a list that lost the rest of itself.
    static func steps(from text: String?) -> [Step] {
        let raw = CookingRecipe.steps(from: text).map(\.text)
        let isHeading: (String) -> Bool = { line in
            line.hasSuffix(":") && line.count <= 60
        }
        let numberedCount = raw.filter { !isHeading($0) }.count
        var number = 0
        return raw.map { line in
            if isHeading(line) {
                return Step(number: nil, text: String(line.dropLast()), isHeading: true)
            }
            number += 1
            return Step(number: numberedCount > 1 ? number : nil, text: line)
        }
    }
}

// MARK: - Plain text

extension RecipeShareContent {

    /// The recipe as a message: readable in Messages, Mail or Notes, with
    /// nothing that needs rendering.
    var plainText: String {
        var blocks: [String] = []

        var header = [title]
        let facts = [servingsText] + metrics.map { "\($0.label) \($0.value)" }
        header.append(facts.joined(separator: " · "))
        blocks.append(header.joined(separator: "\n"))

        if !ingredients.isEmpty {
            let lines = ingredients.map { "• \($0.text)" }
            blocks.append(([String(localized: "Ingredients")] + lines).joined(separator: "\n"))
        }

        if !steps.isEmpty {
            let lines = steps.map { step -> String in
                if step.isHeading { return "\n\(step.text):" }
                if let number = step.number { return "\(number). \(step.text)" }
                return step.text
            }
            blocks.append(([String(localized: "Method")] + lines).joined(separator: "\n"))
        }

        if let nutritionText {
            blocks.append(nutritionText)
        }

        if hasWebSource, let sourceURL {
            if sourceIsGone, let host = sourceHost {
                blocks.append(String(localized: "Original recipe: \(host)"))
            } else {
                blocks.append(String(localized: "Recipe: \(sourceURL.absoluteString)"))
            }
        }

        return blocks.joined(separator: "\n\n")
    }
}
