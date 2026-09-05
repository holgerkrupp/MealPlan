import Testing
import Foundation
@testable import MealPlan

@MainActor
struct RecipeTranslationTests {

    // MARK: - Helpers

    private func makeDish() -> Dish {
        let dish = Dish(name: "Kartoffelsuppe")
        dish.recipeText = "Kartoffeln schälen.\n\nAlles 20 Minuten kochen."
        let lines: [(String, String?)] = [("Kartoffeln", "geschält"), ("Zwiebel", nil)]
        dish.ingredients = lines
            .enumerated()
            .map { index, pair in
                let line = DishIngredient(note: pair.1, rawText: pair.0, sortIndex: index)
                line.ingredient = Ingredient(name: pair.0)
                line.dish = dish
                return line
            }
        return dish
    }

    private func translation(of dish: Dish, into code: String = "en") -> RecipeTranslation {
        let lines = dish.sortedIngredients
        return RecipeTranslation(
            languageCode: code,
            name: "Potato soup",
            ingredients: [
                .init(id: lines[0].uuid, name: "Potatoes", note: "peeled"),
                .init(id: lines[1].uuid, name: "Onion", note: nil),
            ],
            directionsText: "Peel the potatoes.\n\nSimmer everything for 20 minutes."
        )
    }

    // MARK: - Language tags

    @Test func regionsAreTheSameLanguageButScriptsAreNot() {
        #expect(RecipeLanguage.matches("en-GB", "en-US"))
        #expect(RecipeLanguage.matches("de", "de-DE"))
        #expect(RecipeLanguage.matches("zh-Hans", "zh-Hans-CN"))
        #expect(!RecipeLanguage.matches("zh-Hans", "zh-Hant"))
        #expect(!RecipeLanguage.matches("de", "en"))
        #expect(!RecipeLanguage.matches(nil, "de"))
    }

    @Test func tagsAreTidiedIntoOneShape() {
        #expect(RecipeLanguage.canonical("PT_br") == "pt-BR")
        #expect(RecipeLanguage.canonical("zh-hans") == "zh-Hans")
        #expect(RecipeLanguage.base(of: "pt-BR") == "pt")
        #expect(RecipeLanguage.script(of: "zh-Hant-TW") == "Hant")
        #expect(RecipeLanguage.script(of: "de-DE") == nil)
    }

    @Test func thePickerAlwaysOffersTheReadersOwnLanguageFirst() {
        let offered = RecipeLanguage.offered(reader: "sw-KE")
        #expect(offered.first == "sw-KE")
        #expect(Set(offered).count == offered.count)
        // The reader's language replaces its own entry rather than doubling it.
        let german = RecipeLanguage.offered(reader: "de-DE")
        #expect(german.first == "de-DE")
        #expect(!german.dropFirst().contains { RecipeLanguage.matches($0, "de") })
    }

    // MARK: - Directions layout

    @Test func directionsKeepTheirParagraphShape() {
        let layout = RecipeDirectionsLayout("Chop onions.\n\nSimmer 20 min.\nServe.")
        #expect(layout.translatableLines == ["Chop onions.", "Simmer 20 min.", "Serve."])
        #expect(layout.rebuilt(with: ["Zwiebeln schneiden.", "20 Min. köcheln.", "Servieren."])
            == "Zwiebeln schneiden.\n\n20 Min. köcheln.\nServieren.")
    }

    @Test func aMismatchedLineCountKeepsTheOriginal() {
        let layout = RecipeDirectionsLayout("One.\nTwo.")
        #expect(layout.rebuilt(with: ["Eins."]) == "One.\nTwo.")
        #expect(RecipeDirectionsLayout(nil).rebuilt(with: []) == nil)
        #expect(RecipeDirectionsLayout("").translatableLines.isEmpty)
    }

    @Test func aBlankTranslationLeavesTheLineAsItWas() {
        let layout = RecipeDirectionsLayout("Chop onions.\nServe.")
        #expect(layout.rebuilt(with: ["  ", "Servieren."]) == "Chop onions.\nServieren.")
    }

    // MARK: - Batching

    @Test func batchesAreCappedByLinesAndByLength() {
        let short = Array(repeating: "salt", count: 20)
        let byLines = RecipeTranslationBatcher.batches(of: short, maximumLines: 8, maximumCharacters: 900)
        #expect(byLines == [0..<8, 8..<16, 16..<20])

        let long = Array(repeating: String(repeating: "a", count: 400), count: 4)
        let byLength = RecipeTranslationBatcher.batches(of: long, maximumLines: 8, maximumCharacters: 900)
        #expect(byLength == [0..<2, 2..<4])
    }

    @Test func aSingleOverlongLineStillGetsItsOwnBatch() {
        let texts = ["short", String(repeating: "b", count: 2_000), "short"]
        let batches = RecipeTranslationBatcher.batches(of: texts, maximumLines: 8, maximumCharacters: 900)
        #expect(batches == [0..<1, 1..<2, 2..<3])
        #expect(RecipeTranslationBatcher.batches(of: []).isEmpty)
    }

    // MARK: - What gets translated

    @Test func theRequestCarriesNameIngredientsAndSteps() {
        let dish = makeDish()
        let request = dish.translationRequest
        #expect(request.name == "Kartoffelsuppe")
        #expect(request.ingredients.map(\.name) == ["Kartoffeln", "Zwiebel"])
        #expect(request.ingredients.first?.note == "geschält")
        #expect(request.directions.translatableLines == ["Kartoffeln schälen.", "Alles 20 Minuten kochen."])
        #expect(!request.isEmpty)
    }

    @Test func anEmptyRecipeHasNothingToTranslate() {
        let empty = Dish(name: "  ")
        #expect(empty.translationRequest.isEmpty)
    }

    // MARK: - Saving beside the original

    @Test func savingATranslationLeavesTheRecipeItselfAlone() {
        let dish = makeDish()
        dish.apply(translation(of: dish))

        #expect(dish.name == "Kartoffelsuppe")
        #expect(dish.recipeText == "Kartoffeln schälen.\n\nAlles 20 Minuten kochen.")
        #expect(dish.sortedIngredients.first?.ingredient?.name == "Kartoffeln")

        #expect(dish.hasSavedTranslation)
        #expect(dish.translationLanguageCode == "en")
        #expect(dish.displayName(translated: true) == "Potato soup")
        #expect(dish.displayName(translated: false) == "Kartoffelsuppe")
        #expect(dish.sortedIngredients.first?.displayName(translated: true) == "Potatoes")
        #expect(dish.sortedIngredients.first?.displayNote(translated: true) == "peeled")
        #expect(dish.sortedIngredients.last?.displayName(translated: false) == "Zwiebel")
        #expect(dish.displayRecipeText(translated: true)?.contains("Simmer everything") == true)
    }

    @Test func anUntranslatedLineFallsBackToItsOwnWording() {
        let dish = makeDish()
        var partial = translation(of: dish)
        partial.ingredients.removeLast()
        dish.apply(partial)

        #expect(dish.sortedIngredients.last?.translatedName == nil)
        #expect(dish.sortedIngredients.last?.displayName(translated: true) == "Zwiebel")
    }

    @Test func removingATranslationLeavesNothingBehind() {
        let dish = makeDish()
        dish.apply(translation(of: dish))
        dish.clearTranslation()

        #expect(!dish.hasSavedTranslation)
        #expect(dish.translationLanguageCode == nil)
        #expect(dish.translatedRecipeText == nil)
        #expect(dish.sortedIngredients.allSatisfy { $0.translatedName == nil && $0.translatedNote == nil })
        #expect(dish.displayName(translated: true) == "Kartoffelsuppe")
    }

    @Test func aTranslationIsOnlyTheDefaultInTheLanguageThisDeviceReads() {
        let dish = makeDish()
        dish.apply(translation(of: dish, into: RecipeLanguage.readerCode))
        #expect(dish.prefersTranslation)

        let otherCode = RecipeLanguage.matches(RecipeLanguage.readerCode, "ja") ? "de" : "ja"
        dish.apply(translation(of: dish, into: otherCode))
        #expect(dish.hasSavedTranslation)
        #expect(!dish.prefersTranslation)
    }

    @Test func editingTheRecipeChangesItsTranslationFingerprint() {
        let dish = makeDish()
        let before = dish.translationSourceSignature
        dish.recipeText = (dish.recipeText ?? "") + "\nAbschmecken."
        #expect(dish.translationSourceSignature != before)

        let afterEdit = dish.translationSourceSignature
        dish.sortedIngredients.first?.note = "gewürfelt"
        #expect(dish.translationSourceSignature != afterEdit)
    }
}
