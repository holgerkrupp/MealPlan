import Foundation

// MARK: - Reading a dish in one language or the other

extension Dish {

    /// True once a translation has been saved onto this recipe. Reads the
    /// language tag alone, deliberately: it is written and cleared together
    /// with the translated text, and asking the ingredient lines would fault
    /// the whole relationship in from a list.
    var hasSavedTranslation: Bool {
        !(translationLanguageCode ?? "").isEmpty
    }

    /// Whether the saved translation is the one this device should open with.
    ///
    /// A household can read in two languages: the member who saved a German
    /// translation gets it by default, while the one whose device is English
    /// still opens the recipe as it was written — and can switch over by hand.
    var prefersTranslation: Bool {
        hasSavedTranslation && RecipeLanguage.matches(translationLanguageCode, RecipeLanguage.readerCode)
    }

    /// The dish's name, translated when asked for and available.
    func displayName(translated: Bool) -> String {
        guard translated, let name = translatedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return self.name }
        return name
    }

    /// The directions, translated when asked for and available.
    func displayRecipeText(translated: Bool) -> String? {
        guard translated, let text = translatedRecipeText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return recipeText }
        return text
    }

    // MARK: - Translating

    /// Everything about this recipe that is worth translating, with the
    /// ingredient lines keyed by their own identifiers so a translation that
    /// arrives after an edit still lands on the right rows.
    var translationRequest: RecipeTranslationRequest {
        RecipeTranslationRequest(
            name: name,
            ingredients: sortedIngredients.compactMap { line in
                let text = (line.ingredient?.name ?? line.rawText ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let note = line.note?.trimmingCharacters(in: .whitespacesAndNewlines)
                return RecipeTranslationRequest.IngredientLine(
                    id: line.uuid,
                    name: text,
                    note: (note?.isEmpty ?? true) ? nil : note
                )
            },
            directions: RecipeDirectionsLayout(recipeText),
            // Whatever was recognised when the translation sheet opened. Not
            // detected here: this is read while a view body is being built.
            sourceLanguageCode: recipeLanguageCode
        )
    }

    /// Whether there is anything here to translate at all. Cheap enough to ask
    /// from a view body, unlike building the whole request.
    var hasTranslatableText: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(recipeText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(ingredients ?? []).isEmpty
    }

    /// The language this recipe reads as, from its directions if it has any
    /// and its name otherwise. Not stored by itself: `rememberRecipeLanguage`
    /// writes it down once a translation has been made from it.
    var detectedRecipeLanguageCode: String? {
        let directions = (recipeText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return RecipeLanguage.detect(directions.isEmpty ? name : directions)
    }

    /// Notes down what language the recipe itself is in, so the translation
    /// sheet can say "German → English" without sniffing the text again.
    func rememberRecipeLanguage() {
        if recipeLanguageCode == nil { recipeLanguageCode = detectedRecipeLanguageCode }
    }

    /// Saves a translation beside the recipe. The recipe's own wording, its
    /// ingredient catalogue entries and its amounts are all left alone.
    func apply(_ translation: RecipeTranslation) {
        rememberRecipeLanguage()
        translationLanguageCode = RecipeLanguage.canonical(translation.languageCode)
        let name = translation.name.trimmingCharacters(in: .whitespacesAndNewlines)
        translatedName = name.isEmpty ? nil : name
        let directions = translation.directionsText?.trimmingCharacters(in: .whitespacesAndNewlines)
        translatedRecipeText = (directions?.isEmpty ?? true) ? nil : directions
        for line in sortedIngredients {
            line.apply(translation.line(line.uuid))
            line.modifiedAt = .now
        }
        modifiedAt = .now
    }

    /// A fingerprint of everything a translation is made from. The editor
    /// takes one before and after an edit: a recipe whose words changed no
    /// longer has a translation that matches it.
    var translationSourceSignature: String {
        ([name, recipeText ?? ""] + sortedIngredients.map {
            "\($0.ingredient?.name ?? $0.rawText ?? "")|\($0.note ?? "")"
        }).joined(separator: "\u{1}")
    }

    /// Drops the saved translation and leaves the recipe as it was written.
    func clearTranslation() {
        guard hasSavedTranslation else { return }
        translationLanguageCode = nil
        translatedName = nil
        translatedRecipeText = nil
        for line in sortedIngredients where line.translatedName != nil || line.translatedNote != nil {
            line.translatedName = nil
            line.translatedNote = nil
            line.modifiedAt = .now
        }
        modifiedAt = .now
    }
}

extension DishIngredient {

    /// What to call this line, translated when asked for and available.
    func displayName(translated: Bool) -> String? {
        if translated, let name = translatedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return ingredient?.name ?? rawText
    }

    /// This line's note ("finely chopped"), translated when asked for.
    func displayNote(translated: Bool) -> String? {
        if translated, let translated = translatedNote?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translated.isEmpty {
            return translated
        }
        return note
    }

    /// Writes this line's translation, or clears it when the model had nothing
    /// for it — a half-translated ingredient list reads worse than an honest
    /// original line among translated ones.
    func apply(_ translation: RecipeTranslation.IngredientLine?) {
        guard let translation else {
            translatedName = nil
            translatedNote = nil
            return
        }
        let name = translation.name.trimmingCharacters(in: .whitespacesAndNewlines)
        translatedName = name.isEmpty ? nil : name
        let note = translation.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        translatedNote = (note?.isEmpty ?? true) ? nil : note
    }
}
