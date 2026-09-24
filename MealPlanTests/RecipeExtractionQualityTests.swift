import Testing

@testable import MealPlan

struct RecipeExtractionQualityTests {
    @Test func headingOnlyIngredientAndInstructionValuesFail() {
        var recipe = ImportedRecipe(name: "A recipe")
        recipe.ingredientLines = ["Ingredients"]
        recipe.instructions = "Directions"

        let result = RecipeExtractionResult(recipe: recipe)

        #expect(result.outcome == .failed)
        #expect(result.recipe.ingredientLines.isEmpty)
        #expect(result.recipe.instructions == nil)
        #expect(result.warnings.contains("No plausible ingredients were found."))
        #expect(result.warnings.contains("No usable preparation steps were found."))
    }

    @Test func ingredientsWithoutInstructionsArePartial() {
        var recipe = ImportedRecipe(name: "Roasted vegetables")
        recipe.ingredientLines = (1...10).map { "\($0) cup chopped vegetables" }

        let result = RecipeExtractionResult(recipe: recipe)

        #expect(result.outcome == .partial)
        #expect(result.recipe.ingredientLines.count == 10)
        #expect(result.recipe.instructions == nil)
    }

    @Test func instructionsWithoutIngredientsArePartial() {
        var recipe = ImportedRecipe(name: "Roasted vegetables")
        recipe.instructions = "Toss the vegetables with oil and roast until tender."

        let result = RecipeExtractionResult(recipe: recipe)

        #expect(result.outcome == .partial)
        #expect(result.recipe.ingredientLines.isEmpty)
        #expect(result.recipe.instructions != nil)
    }

    @Test func completeRecipeIsGood() {
        var recipe = ImportedRecipe(name: "Roasted vegetables")
        recipe.ingredientLines = ["2 carrots", "1 onion", "2 tbsp olive oil"]
        recipe.instructions = "Toss everything with oil. Roast at 200°C for 25 minutes."
        recipe.servings = 2

        let result = RecipeExtractionResult(
            recipe: recipe,
            provenance: [
                .title: .jsonLD,
                .ingredients: .jsonLD,
                .instructions: .semanticHTML,
            ]
        )

        #expect(result.outcome == .good)
        #expect(result.quality > 0.5)
        #expect(result.provenance[.ingredients] == .jsonLD)
        #expect(result.provenance[.instructions] == .semanticHTML)
    }

    @Test func mergingCandidatesKeepsTheBestFieldProvenance() {
        var structured = ImportedRecipe(name: "Structured soup")
        structured.ingredientLines = ["2 carrots"]
        structured.instructions = "Directions"
        let structuredResult = RecipeExtractionResult(
            recipe: structured,
            provenance: [.title: .jsonLD, .ingredients: .jsonLD]
        )

        var visible = ImportedRecipe(name: "Structured soup")
        visible.instructions = "Simmer the carrots until tender."
        let visibleResult = RecipeExtractionResult(
            recipe: visible,
            provenance: [.title: .semanticHTML, .instructions: .semanticHTML]
        )

        let merged = RecipeExtractionResult.merging([structuredResult, visibleResult])

        #expect(merged?.outcome == .good)
        #expect(merged?.recipe.ingredientLines == ["2 carrots"])
        #expect(merged?.recipe.instructions == "Simmer the carrots until tender.")
        #expect(merged?.provenance[.ingredients] == .jsonLD)
        #expect(merged?.provenance[.instructions] == .semanticHTML)
    }
}
