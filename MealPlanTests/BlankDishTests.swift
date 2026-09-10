import Testing
import Foundation
import SwiftData
@testable import MealPlan

@MainActor
struct BlankDishTests {
    @Test func untouchedDraftIsBlank() {
        #expect(Dish(name: "").isBlankDraft)
        #expect(Dish(name: "   ").isBlankDraft)
    }

    @Test func anythingTheCookEnteredKeepsTheDish() {
        #expect(!Dish(name: "Soup").isBlankDraft)

        let withRecipe = Dish(name: "")
        withRecipe.recipeText = "Boil water"
        #expect(!withRecipe.isBlankDraft)

        let withLink = Dish(name: "")
        withLink.sourceURL = URL(string: "https://example.com/recipe")
        #expect(!withLink.isBlankDraft)

        let withTag = Dish(name: "")
        withTag.tagNames = ["Weeknight"]
        #expect(!withTag.isBlankDraft)

        let withPhoto = Dish(name: "")
        let image = DishImage(data: Data([1]), sortIndex: 0, isPrimary: true)
        image.dish = withPhoto
        withPhoto.images = [image]
        #expect(!withPhoto.isBlankDraft)

        let withIngredient = Dish(name: "")
        let line = DishIngredient(rawText: "1 onion")
        line.dish = withIngredient
        withIngredient.ingredients = [line]
        #expect(!withIngredient.isBlankDraft)
    }

    @Test func libraryFilterHidesBlankDrafts() {
        let draft = Dish(name: "")
        let real = Dish(name: "Soup")
        #expect(DishFilter().apply(to: [draft, real]) == [real])
    }

    @Test func maintenanceTakesOnlyLongUntouchedBlanks() {
        let now = Date.now
        let old = now.addingTimeInterval(-3600)

        let abandoned = Dish(name: "")
        abandoned.dateCreated = old
        abandoned.modifiedAt = old
        // Still on screen in an open editor, so not fair game yet.
        let beingEdited = Dish(name: "")
        let named = Dish(name: "Soup")
        named.dateCreated = old
        named.modifiedAt = old
        let unnamedButFilled = Dish(name: "")
        unnamedButFilled.dateCreated = old
        unnamedButFilled.modifiedAt = old
        unnamedButFilled.recipeText = "Boil water"

        let doomed = BlankDishMaintenance.abandoned(
            in: [abandoned, beingEdited, named, unnamedButFilled], now: now
        )
        #expect(doomed.count == 1)
        #expect(doomed.first === abandoned)
    }
}
