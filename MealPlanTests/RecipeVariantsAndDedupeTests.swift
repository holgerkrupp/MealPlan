import Testing
import Foundation
@testable import MealPlan

@MainActor
struct RecipeVariantsAndDedupeTests {

    // MARK: - Helpers

    private func dish(_ name: String, ingredients: [String] = [], source: String? = nil) -> Dish {
        let dish = Dish(name: name)
        dish.sourceURL = source.flatMap(URL.init(string:))
        dish.ingredients = ingredients.enumerated().map { index, raw in
            let line = DishIngredient(rawText: raw, sortIndex: index)
            line.ingredient = Ingredient(name: raw)
            line.dish = dish
            return line
        }
        return dish
    }

    private func recipe(_ name: String, ingredients: [String] = [], source: String? = nil, uid: String? = nil) -> ImportedRecipe {
        var recipe = ImportedRecipe(name: name, sourceURL: source.flatMap(URL.init(string:)))
        recipe.ingredientLines = ingredients
        recipe.sourceIdentifier = uid
        return recipe
    }

    // MARK: - Duplicates

    @Test func sameNameAndIngredientsIsADuplicate() {
        let existing = dish("Bolognese", ingredients: ["Hackfleisch", "Tomaten", "Zwiebel", "Karotte"])
        let incoming = recipe("bolognese", ingredients: ["Hackfleisch", "Tomaten", "Zwiebel", "Karotte"])
        #expect(RecipeDuplicateDetector.duplicate(of: incoming, in: [existing]) === existing)
    }

    @Test func theSourceAppIdentifierBeatsARename() {
        let existing = dish("Omas Bolognese")
        existing.importedSourceID = "00A16B01-4166-4883-BC78-F28F66E78CF6"
        let incoming = recipe("Bolognese Classico", uid: "00A16B01-4166-4883-BC78-F28F66E78CF6")
        #expect(RecipeDuplicateDetector.duplicate(of: incoming, in: [existing]) === existing)
    }

    @Test func servingCountsInTheURLDoNotHideADuplicate() {
        let existing = dish("Gnocchiauflauf", source: "https://www.chefkoch.de/rezepte/33231/Gnocchi.html?portionen=3")
        let incoming = recipe("Gnocchi-Auflauf", source: "https://www.chefkoch.de/rezepte/33231/Gnocchi.html?portionen=6")
        #expect(RecipeDuplicateDetector.duplicate(of: incoming, in: [existing]) === existing)
    }

    // MARK: - Variants

    /// The bug this whole feature exists for: a second Burger used to be
    /// dropped as a duplicate of the first.
    @Test func aDifferentRecipeUnderTheSameNameIsAVariantNotADuplicate() {
        let existing = dish("Burger", ingredients: ["Rinderhack", "Brioche", "Cheddar", "Zwiebel"])
        let incoming = recipe("Burger", ingredients: ["Halloumi", "Vollkornbrötchen", "Aubergine", "Rucola"])

        #expect(RecipeDuplicateDetector.duplicate(of: incoming, in: [existing]) == nil)
        #expect(RecipeDuplicateDetector.sameDish(as: incoming, in: [existing]) === existing)

        let plan = RecipeImportPlanner.plan([incoming], against: [existing])
        #expect(plan.count == 1)
        #expect(plan[0].include)
        guard case .variant(let match) = plan[0].outcome else {
            Issue.record("expected a variant, got \(plan[0].outcome)")
            return
        }
        #expect(match.uuid == existing.uuid)
    }

    @Test func aFileListingTheSameRecipeTwiceImportsItOnce() {
        let first = recipe("Chili", ingredients: ["Bohnen", "Hack", "Mais"], uid: "abc")
        let second = recipe("Chili", ingredients: ["Bohnen", "Hack", "Mais"], uid: "abc")
        let plan = RecipeImportPlanner.plan([first, second], against: [])
        #expect(plan[0].outcome == .new)
        #expect(plan[0].include)
        #expect(plan[1].outcome == .duplicateInFile("Chili"))
        #expect(plan[1].include == false)
    }

    @Test func twoUnrelatedRecipesBothCountAsNew() {
        let plan = RecipeImportPlanner.plan(
            [recipe("Linsensuppe", ingredients: ["Linsen"]), recipe("Pad Thai", ingredients: ["Reisnudeln"])],
            against: []
        )
        #expect(plan.allSatisfy { $0.outcome == .new && $0.include })
    }

    // MARK: - Grouping

    @Test func joiningCreatesAGroupNamedAfterTheSharedWords() {
        let smash = Dish(name: "Smash Burger")
        let halloumi = Dish(name: "Halloumi Burger")
        DishVariants.join(halloumi, with: smash)

        #expect(smash.variantGroupID != nil)
        #expect(smash.variantGroupID == halloumi.variantGroupID)
        #expect(smash.variantGroupName == "Burger")
        #expect(halloumi.variantGroupDisplayName == "Burger")
    }

    @Test func aThirdVariantJoinsTheExistingGroup() {
        let smash = Dish(name: "Smash Burger")
        let halloumi = Dish(name: "Halloumi Burger")
        let classic = Dish(name: "Classic Burger")
        DishVariants.join(halloumi, with: smash)
        DishVariants.join(classic, with: halloumi)

        let all = [smash, halloumi, classic]
        #expect(classic.variantGroupID == smash.variantGroupID)
        #expect(DishVariants.members(of: classic, in: all).count == 3)
        #expect(DishVariants.siblings(of: classic, in: all).count == 2)
        #expect(DishVariants.groups(in: all).count == 1)
    }

    /// A group of one is just a dish, so leaving dissolves the rest of it.
    @Test func leavingATwoMemberGroupDissolvesIt() {
        let smash = Dish(name: "Smash Burger")
        let halloumi = Dish(name: "Halloumi Burger")
        DishVariants.join(halloumi, with: smash)
        DishVariants.leaveGroup(halloumi, in: [smash, halloumi])

        #expect(halloumi.variantGroupID == nil)
        #expect(smash.variantGroupID == nil)
    }

    @Test func leavingALargerGroupLeavesTheRestIntact() {
        let dishes = [Dish(name: "A Burger"), Dish(name: "B Burger"), Dish(name: "C Burger")]
        DishVariants.join(dishes[1], with: dishes[0])
        DishVariants.join(dishes[2], with: dishes[0])
        DishVariants.leaveGroup(dishes[2], in: dishes)

        #expect(dishes[2].variantGroupID == nil)
        #expect(dishes[0].variantGroupID != nil)
        #expect(dishes[0].variantGroupID == dishes[1].variantGroupID)
    }

    /// Dropping a recipe on another makes a group of the two; dropping a third
    /// on that group adds it. This is what the library grid's drop target does.
    @Test func droppingOntoAGroupAddsToItRatherThanStartingAnother() {
        let smash = Dish(name: "Smash Burger")
        let halloumi = Dish(name: "Halloumi Burger")
        let classic = Dish(name: "Classic Burger")
        let all = [smash, halloumi, classic]

        DishVariants.join(halloumi, with: smash, in: all)
        let groupID = smash.variantGroupID
        // Onto the group's leading dish, as the grid's group cell does.
        DishVariants.join(classic, with: smash, in: all)

        #expect(smash.variantGroupID == groupID)
        #expect(DishVariants.groups(in: all).count == 1)
        #expect(DishVariants.members(of: smash, in: all).count == 3)
    }

    @Test func droppingSomethingAlreadyInTheGroupChangesNothing() {
        let smash = Dish(name: "Smash Burger")
        let halloumi = Dish(name: "Halloumi Burger")
        let all = [smash, halloumi]
        DishVariants.join(halloumi, with: smash, in: all)
        let groupID = smash.variantGroupID

        DishVariants.join(halloumi, with: smash, in: all)
        #expect(smash.variantGroupID == groupID)
        #expect(halloumi.variantGroupID == groupID)
    }

    /// Moving a recipe out of a pair leaves one behind, and a group of one is
    /// not a group.
    @Test func movingToAnotherGroupDissolvesAnAbandonedPair() {
        let burgers = [Dish(name: "Smash Burger"), Dish(name: "Halloumi Burger")]
        let pastas = [Dish(name: "Bolognese"), Dish(name: "Vegane Bolognese")]
        let all = burgers + pastas
        DishVariants.join(burgers[1], with: burgers[0], in: all)
        DishVariants.join(pastas[1], with: pastas[0], in: all)

        DishVariants.join(burgers[1], with: pastas[0], in: all)

        #expect(burgers[1].variantGroupID == pastas[0].variantGroupID)
        #expect(burgers[0].variantGroupID == nil)   // left alone, so no longer a group
        #expect(DishVariants.groups(in: all).count == 1)
        #expect(DishVariants.members(of: pastas[0], in: all).count == 3)
    }

    @Test func movingOutOfALargerGroupLeavesItStanding() {
        let burgers = [Dish(name: "A Burger"), Dish(name: "B Burger"), Dish(name: "C Burger")]
        let other = Dish(name: "Bolognese")
        let all = burgers + [other]
        DishVariants.join(burgers[1], with: burgers[0], in: all)
        DishVariants.join(burgers[2], with: burgers[0], in: all)

        DishVariants.join(burgers[2], with: other, in: all)

        #expect(burgers[0].variantGroupID != nil)
        #expect(burgers[0].variantGroupID == burgers[1].variantGroupID)
        #expect(burgers[2].variantGroupID == other.variantGroupID)
        #expect(DishVariants.groups(in: all).count == 2)
    }

    @Test func renamingAGroupRewritesEveryMember() {
        let dishes = [Dish(name: "Smash Burger"), Dish(name: "Halloumi Burger")]
        DishVariants.join(dishes[1], with: dishes[0])
        DishVariants.rename(groupOf: dishes[0], to: "  Burger  night ", in: dishes)
        #expect(dishes.allSatisfy { $0.variantGroupName == "Burger night" })
    }

    @Test func namesWithNothingInCommonFallBackToTheFirst() {
        #expect(DishVariants.sharedName("Chili con Carne", "Bolognese") == "Chili con Carne")
        #expect(DishVariants.sharedName("Spaghetti Bolognese", "Vegane Bolognese") == "Bolognese")
    }

    /// A group whose members were deleted down to one shouldn't be presented
    /// as a group in the library grid.
    @Test func aGroupWithOneRemainingMemberIsNotListed() {
        let lonely = Dish(name: "Burger")
        lonely.variantGroupID = UUID()
        lonely.variantGroupName = "Burger"
        #expect(DishVariants.groups(in: [lonely]).isEmpty)
        #expect(DishVariants.members(of: lonely, in: [lonely]) == [lonely])
    }
}
