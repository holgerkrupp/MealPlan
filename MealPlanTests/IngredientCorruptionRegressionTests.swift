import CloudKit
import Foundation
import SwiftData
import Testing
@testable import MealPlan

/// Independent fixtures for issue #173.
///
/// These tests deliberately inspect the persisted DishIngredient graph rather
/// than only the rendered recipe view. A repeated display row is meaningful
/// only if its storage UUID, owning dish, source text, canonical ingredient,
/// and quantity can be compared directly.
@MainActor
struct IngredientCorruptionRegressionTests {

    private struct LineState: Equatable, Sendable {
        let uuid: UUID
        let dishUUID: UUID?
        let ingredientUUID: UUID?
        let ingredientName: String?
        let rawText: String?
        let canonicalValue: Double?
        let dimension: QuantityDimension?
        let displayUnit: String?
        let note: String?
    }

    private let sourceURL = URL(string: "https://example.test/authentic-tex")!

    private var screenshotLikeRecipe: ImportedRecipe {
        var recipe = ImportedRecipe(name: "Authentic Tex", sourceURL: sourceURL)
        recipe.ingredientLines = [
            "7.5 ml garlic powder",
            "225 g ground beef",
            "10 ml Schweinenacken ohne Knochen",
            "1 piece Chili Con Carne",
            "0.5 piece bay leaf",
            "1 quart water",
        ]
        recipe.instructions = "Cook the ground beef."
        recipe.servings = 6
        recipe.needsReview = false
        return recipe
    }

    private func recipe(
        _ name: String,
        source: URL? = nil,
        ingredients: [String],
        instructions: String = "Mix and cook."
    ) -> ImportedRecipe {
        var value = ImportedRecipe(name: name, sourceURL: source)
        value.ingredientLines = ingredients
        value.instructions = instructions
        value.needsReview = false
        return value
    }

    private func lineStates(for dish: Dish) -> [LineState] {
        dish.sortedIngredients.map {
            LineState(
                uuid: $0.uuid,
                dishUUID: $0.dish?.uuid,
                ingredientUUID: $0.ingredient?.uuid,
                ingredientName: $0.ingredient?.name,
                rawText: $0.rawText,
                canonicalValue: $0.canonicalValue,
                dimension: $0.dimension,
                displayUnit: $0.displayUnit,
                note: $0.note
            )
        }
    }

    private func makeHousehold(in context: ModelContext) -> Household {
        let household = Household(name: "Issue 173 fixture")
        context.insert(household)
        return household
    }

    private func assertUniqueLineIDs(_ states: [LineState]) {
        #expect(Set(states.map(\.uuid)).count == states.count)
    }

    @Test func freshImportStoresOneLinePerSourceLineWithIndependentDimensions() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let household = makeHousehold(in: context)

        let result = RecipeImportCommitter.importAll(
            [screenshotLikeRecipe], household: household, createdByName: nil, context: context
        )
        #expect(result.imported == 1)
        let dish = try #require(result.dishes.first)
        let states = lineStates(for: dish)

        #expect(states.count == screenshotLikeRecipe.ingredientLines.count)
        #expect(states.map(\.rawText) == screenshotLikeRecipe.ingredientLines)
        #expect(states.map(\.dishUUID).allSatisfy { $0 == dish.uuid })
        #expect(states.map(\.ingredientUUID).allSatisfy { $0 != nil })
        #expect(states.map(\.ingredientName) == [
            "garlic powder", "ground beef", "Schweinenacken ohne Knochen",
            "Chili Con Carne", "bay leaf", "water",
        ])
        #expect(states.map(\.canonicalValue) == [7.5, 225, 10, 1, 0.5, 946.353])
        #expect(states.map(\.dimension) == [.volume, .mass, .volume, .count, .count, .volume])
        assertUniqueLineIDs(states)

        let directFetch = try context.fetch(FetchDescriptor<DishIngredient>())
        #expect(directFetch.count == states.count)
        #expect(Set(directFetch.map(\.uuid)) == Set(states.map(\.uuid)))
        #expect(directFetch.allSatisfy { $0.dish?.uuid == dish.uuid })
    }

    @Test func repeatedImportDoesNotCreateAnotherDishOrIngredientLines() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let household = makeHousehold(in: context)

        let first = RecipeImportCommitter.importAll(
            [screenshotLikeRecipe], household: household, createdByName: nil, context: context
        )
        let original = try #require(first.dishes.first)
        let originalStates = lineStates(for: original)

        let second = RecipeImportCommitter.importAll(
            [screenshotLikeRecipe], household: household, createdByName: nil, context: context
        )
        #expect(second.imported == 0)
        #expect(second.skipped == 1)
        #expect(try context.fetch(FetchDescriptor<Dish>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<DishIngredient>()).count == originalStates.count)
        #expect(lineStates(for: original) == originalStates)
        assertUniqueLineIDs(originalStates)
    }

    @Test func repeatedRefreshReplacesOnlyTheTargetRecipeAndNeverAppends() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let household = makeHousehold(in: context)
        let first = RecipeImportCommitter.importAll(
            [
                recipe("Recipe A", source: URL(string: "https://example.test/a"), ingredients: ["225 g ground beef", "1 onion"]),
                recipe("Recipe B", source: URL(string: "https://example.test/b"), ingredients: ["500 g potatoes", "1 onion"]),
            ], household: household, createdByName: nil, context: context
        )
        let dishA = try #require(first.dishes.first { $0.name == "Recipe A" })
        let dishB = try #require(first.dishes.first { $0.name == "Recipe B" })
        let dishBState = lineStates(for: dishB)
        let refreshed = recipe(
            "Recipe A refreshed",
            source: URL(string: "https://example.test/a"),
            ingredients: ["225 g ground beef", "1 onion"]
        )

        try DishBuilder.refresh(refreshed, to: dishA, context: context)
        try DishBuilder.refresh(refreshed, to: dishA, context: context)

        let stateA = lineStates(for: dishA)
        #expect(dishA.name == "Recipe A refreshed")
        #expect(stateA.count == 2)
        #expect(stateA.map(\.rawText) == refreshed.ingredientLines)
        #expect(stateA.map(\.dishUUID).allSatisfy { $0 == dishA.uuid })
        #expect(stateA.map(\.dimension) == [.mass, .count])
        assertUniqueLineIDs(stateA)
        #expect(lineStates(for: dishB) == dishBState)
        #expect(try context.fetch(FetchDescriptor<DishIngredient>()).count == 4)
        #expect(try context.fetch(FetchDescriptor<Dish>()).count == 2)
    }

    @Test func overlappingCanonicalIngredientsDoNotCrossRecipeOwnership() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let household = makeHousehold(in: context)
        let result = RecipeImportCommitter.importAll(
            [
                recipe("Soup", ingredients: ["1 onion", "2 g salt"]),
                recipe("Stew", ingredients: ["1 onion", "225 g ground beef", "2 g salt"]),
            ], household: household, createdByName: nil, context: context
        )
        let soup = try #require(result.dishes.first { $0.name == "Soup" })
        let stew = try #require(result.dishes.first { $0.name == "Stew" })
        let soupLines = soup.sortedIngredients
        let stewLines = stew.sortedIngredients

        #expect(soupLines.count == 2)
        #expect(stewLines.count == 3)
        #expect(Set(soupLines.map(\.uuid)).isDisjoint(with: Set(stewLines.map(\.uuid))))
        #expect(soupLines.allSatisfy { $0.dish?.uuid == soup.uuid })
        #expect(stewLines.allSatisfy { $0.dish?.uuid == stew.uuid })
        #expect(soupLines[0].ingredient?.uuid == stewLines[0].ingredient?.uuid)
        #expect(soupLines[1].ingredient?.uuid == stewLines[2].ingredient?.uuid)
        #expect(soupLines[1].canonicalValue == 2)
        #expect(soupLines[1].dimension == .mass)
        #expect(stewLines[1].canonicalValue == 225)
        #expect(stewLines[1].dimension == .mass)
    }

    @Test func structuredCandidateSelectionDoesNotMixTwoRecipeObjects() async throws {
        let html = """
        <html><head>
          <script type="application/ld+json">
          {"@type":"Recipe","name":"Related Chili","recipeIngredient":["10 ml Schweinenacken ohne Knochen"]}
          </script>
          <script type="application/ld+json">
          {"@type":"Recipe","name":"Authentic Tex","recipeYield":"6 servings",
           "recipeIngredient":["225 g ground beef","1 onion","1 quart water"],
           "recipeInstructions":"Cook the beef and simmer."}
          </script>
        </head><body><article><h1>Authentic Tex</h1></article></body></html>
        """

        let imported = try await RecipeSchemaParser(loadImage: false)
            .importRecipe(fromHTML: html, sourceURL: sourceURL)
        #expect(imported.name == "Authentic Tex")
        #expect(imported.ingredientLines == ["225 g ground beef", "1 onion", "1 quart water"])
        #expect(!imported.ingredientLines.contains("10 ml Schweinenacken ohne Knochen"))
    }

    @Test func microdataAliasPropertiesDoNotDuplicateOneDOMIngredient() {
        let html = """
        <article itemscope itemtype="https://schema.org/Recipe">
          <h1 itemprop="name">Alias Property Soup</h1>
          <li itemprop="recipeIngredient ingredients">1 tbsp olive oil</li>
          <li itemprop="recipeIngredient ingredients">225 g ground beef</li>
        </article>
        """

        let imported = RecipeSchemaParser().parseMicrodata(html: html, sourceURL: sourceURL)
        #expect(imported?.ingredientLines == ["1 tbsp olive oil", "225 g ground beef"])
    }

    @Test func archiveRestorePreservesRawTextQuantitiesAndCanonicalNames() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let household = makeHousehold(in: context)
        let sourceDish = Dish(name: "Archived stew")
        sourceDish.household = household
        let sourceLines = [
            ("225 g ground beef", "ground beef", 225.0, QuantityDimension.mass),
            ("1 quart water", "water", 946.353, QuantityDimension.volume),
        ]
        sourceDish.ingredients = sourceLines.enumerated().map { index, value in
            let ingredient = Ingredient(name: value.1)
            ingredient.household = household
            let line = DishIngredient(
                canonicalValue: value.2,
                dimension: value.3,
                displayUnit: index == 0 ? "g" : "quart",
                rawText: value.0,
                sortIndex: index
            )
            line.dish = sourceDish
            line.ingredient = ingredient
            context.insert(ingredient)
            context.insert(line)
            return line
        }
        household.dishes = [sourceDish]
        context.insert(sourceDish)
        try context.save()
        let originalIDs = Set(sourceDish.sortedIngredients.map(\.uuid))

        let archive = try MealPlanRecipeArchive.data(from: [sourceDish])
        let imported = try #require(MealPlanRecipeArchive.importedRecipes(from: archive).first)
        let restored = DishBuilder.makeDish(
            from: imported, household: household, createdByName: nil, context: context
        )
        let states = lineStates(for: restored)

        #expect(states.count == 2)
        #expect(states.map(\.rawText) == sourceLines.map(\.0))
        #expect(states.map(\.ingredientName) == sourceLines.map(\.1))
        #expect(states.map(\.canonicalValue) == sourceLines.map(\.2))
        #expect(states.map(\.dimension) == sourceLines.map(\.3))
        #expect(states.map(\.dishUUID).allSatisfy { $0 == restored.uuid })
        #expect(originalIDs.isDisjoint(with: Set(states.map(\.uuid))))
        assertUniqueLineIDs(states)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<DishIngredient>()).count == 4)
    }

    @Test func repeatedCloudKitDishIngredientApplyIsIdempotentOnDisk() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let household = makeHousehold(in: context)
        let dish = Dish(name: "Cloud replay")
        let ingredient = Ingredient(name: "ground beef")
        dish.household = household
        ingredient.household = household
        context.insert(dish)
        context.insert(ingredient)
        try context.save()

        let lineID = UUID()
        let payload = HouseholdRecordPayload.dishIngredient(.init(
            dishID: dish.uuid,
            ingredientID: ingredient.uuid,
            canonicalValue: 225,
            canonicalDimensionRaw: QuantityDimension.mass.rawValue,
            displayUnit: "g",
            isApproximate: false,
            note: nil,
            rawText: "225 g ground beef",
            sortIndex: 0
        ))
        let bytes = try HouseholdRecordCodec.encode(payload)
        let identity = HouseholdRecordIdentity(type: .dishIngredient, uuid: lineID)
        let replayDate = Date(timeIntervalSince1970: 1_234)

        try HouseholdRecordApplier.withBatchLookup(in: context, expectedRecordCount: 1) {
            for _ in 0..<3 {
                try HouseholdRecordApplier.apply(
                    payloadData: bytes,
                    identity: identity,
                    modifiedAt: replayDate,
                    assetData: nil,
                    household: household,
                    context: context
                )
            }
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<DishIngredient>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.uuid == lineID)
        #expect(fetched.first?.dish?.uuid == dish.uuid)
        #expect(fetched.first?.ingredient?.uuid == ingredient.uuid)
        #expect(fetched.first?.rawText == "225 g ground beef")
        #expect(fetched.first?.canonicalValue == 225)
        #expect(fetched.first?.dimension == .mass)
        #expect(dish.sortedIngredients.count == 1)
        #expect(dish.sortedIngredients.first?.uuid == lineID)
        #expect(Set(dish.sortedIngredients.map(\.uuid)) == Set(fetched.map(\.uuid)))
    }

    @Test func diskStoreReloadPreservesLineUUIDsAndInverseOwnership() throws {
        let setup = try makeTestModelContainer()
        var container: ModelContainer? = setup.container
        let directory = setup.directory
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try #require(container?.mainContext)
        let household = makeHousehold(in: context)
        let result = RecipeImportCommitter.importAll(
            [screenshotLikeRecipe], household: household, createdByName: nil, context: context
        )
        let dishID = try #require(result.dishes.first).uuid
        let expected = lineStates(for: try #require(result.dishes.first))
        let expectedIDs = Set(expected.map(\.uuid))
        try context.save()
        container = nil

        let schema = SharedStore.makeSchema()
        let configuration = ModelConfiguration(
            schema: schema,
            url: directory.appending(path: "test.sqlite"),
            cloudKitDatabase: .none
        )
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = reopened.mainContext
        let reopenedDish = try #require(
            reopenedContext.fetch(FetchDescriptor<Dish>()).first { $0.uuid == dishID }
        )
        let restored = lineStates(for: reopenedDish)
        #expect(restored == expected)
        #expect(Set(restored.map(\.uuid)) == expectedIDs)
        #expect(restored.allSatisfy { $0.dishUUID == dishID })
        #expect(try reopenedContext.fetch(FetchDescriptor<DishIngredient>()).count == expected.count)
    }

    @Test func repeatedInverseReferenceGroupingIsLossless() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let household = makeHousehold(in: context)
        let dish = Dish(name: "Repeated inverse")
        let ingredient = Ingredient(name: "ground beef")
        let line = DishIngredient(canonicalValue: 225, dimension: .mass, rawText: "225 g ground beef")
        dish.household = household
        ingredient.household = household
        line.dish = dish
        line.ingredient = ingredient
        dish.ingredients = [line]
        ingredient.dishIngredients = [line, line]
        household.dishes = [dish]
        household.ingredients = [ingredient]
        context.insert(dish)
        context.insert(ingredient)
        context.insert(line)

        let repeated = try #require(
            IngredientIntegrityAuditor.duplicateReferenceGroups([line, line]).first
        )
        #expect(repeated.count == 2)
        // SwiftData normalizes the persisted inverse to one reference, so a
        // disk reload cannot retain this malformed shape. The auditor's
        // grouping remains explicitly lossless if a damaged relationship is
        // handed to it before materialization.
        #expect((ingredient.dishIngredients ?? []).count == 1)
        #expect(line.dish?.uuid == dish.uuid)
        #expect(line.ingredient?.uuid == ingredient.uuid)
        try context.save()
    }

    @Test func auditDoesNotClassifyDistinctSameUUIDRowsAsLossless() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let household = makeHousehold(in: context)
        let dish = Dish(name: "Duplicate UUID")
        let ingredient = Ingredient(name: "ground beef")
        let first = DishIngredient(canonicalValue: 225, dimension: .mass, rawText: "225 g ground beef", sortIndex: 0)
        let second = DishIngredient(canonicalValue: 225, dimension: .mass, rawText: "225 g ground beef", sortIndex: 1)
        let sharedID = UUID()
        first.uuid = sharedID
        second.uuid = sharedID
        dish.household = household
        ingredient.household = household
        first.dish = dish
        second.dish = dish
        first.ingredient = ingredient
        second.ingredient = ingredient
        dish.ingredients = [first, second]
        household.dishes = [dish]
        household.ingredients = [ingredient]
        context.insert(dish)
        context.insert(ingredient)
        context.insert(first)
        context.insert(second)
        try context.save()

        let audit = IngredientIntegrityAuditor.audit(household: household, context: context)
        let finding = try #require(
            audit.recipeIngredientIssues.first { $0.kind == .duplicateDishIngredientUUID }
        )
        #expect(finding.classification == .cannotDetermine)
        #expect(!finding.isSafeToRepair)
        #expect(finding.relatedDishIngredientUUIDs.count == 2)
        #expect(dish.sortedIngredients.count == 2)
    }

    @Test func twoSequentialContextsDoNotMoveExistingLinesAcrossRecipes() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstContext = container.mainContext
        let household = makeHousehold(in: firstContext)
        let first = RecipeImportCommitter.importAll(
            [recipe("Context A", ingredients: ["225 g ground beef"])],
            household: household, createdByName: nil, context: firstContext
        )
        let dishA = try #require(first.dishes.first)
        try firstContext.save()

        let secondContext = ModelContext(container)
        let secondHousehold = try #require(secondContext.fetch(FetchDescriptor<Household>()).first)
        let second = RecipeImportCommitter.importAll(
            [recipe("Context B", ingredients: ["1 onion"])],
            household: secondHousehold, createdByName: nil, context: secondContext
        )
        let dishB = try #require(second.dishes.first)
        let dishBID = dishB.uuid
        try secondContext.save()

        try DishBuilder.refresh(
            recipe("Context A refreshed", ingredients: ["225 g ground beef"]),
            to: dishA,
            context: firstContext
        )

        let reloadedDishes = try secondContext.fetch(FetchDescriptor<Dish>())
        let reloadedA = try #require(reloadedDishes.first { $0.uuid == dishA.uuid })
        let reloadedB = try #require(reloadedDishes.first { $0.uuid == dishBID })
        #expect(reloadedA.sortedIngredients.count == 1)
        #expect(reloadedA.sortedIngredients.first?.dish?.uuid == reloadedA.uuid)
        #expect(reloadedA.sortedIngredients.first?.rawText == "225 g ground beef")
        #expect(reloadedA.sortedIngredients.first?.dimension == .mass)
        #expect(reloadedB.sortedIngredients.count == 1)
        #expect(reloadedB.sortedIngredients.first?.dish?.uuid == reloadedB.uuid)
        #expect(reloadedB.sortedIngredients.first?.rawText == "1 onion")
        #expect(reloadedB.sortedIngredients.first?.dimension == .count)
        #expect(try secondContext.fetch(FetchDescriptor<DishIngredient>()).count == 2)
    }

    @Test func legacyTripleAndWrongCanonicalFixturesAreReadOnlyForAudit() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let household = makeHousehold(in: context)
        let dish = Dish(name: "Legacy duplicate")
        let wrongCanonical = Ingredient(name: "Schweinenacken ohne Knochen")
        dish.household = household
        wrongCanonical.household = household
        household.dishes = [dish]
        household.ingredients = [wrongCanonical]
        context.insert(dish)
        context.insert(wrongCanonical)

        let lines = (0..<3).map { index in
            let line = DishIngredient(
                canonicalValue: 10,
                dimension: .volume,
                displayUnit: "ml",
                rawText: "225 g ground beef",
                sortIndex: index
            )
            line.dish = dish
            line.ingredient = wrongCanonical
            context.insert(line)
            return line
        }
        try context.save()
        let before = lineStates(for: dish)
        let auditBefore = IngredientIntegrityAuditor.audit(household: household, context: context)
        let after = lineStates(for: dish)

        #expect(lines.count == 3)
        #expect(before == after)
        #expect(Set(before.map(\.uuid)).count == 3)
        #expect(before.map(\.rawText) == ["225 g ground beef", "225 g ground beef", "225 g ground beef"])
        #expect(before.map(\.ingredientName) == [
            "Schweinenacken ohne Knochen", "Schweinenacken ohne Knochen", "Schweinenacken ohne Knochen",
        ])
        #expect(before.map(\.canonicalValue) == [10, 10, 10])
        #expect(before.map(\.dimension) == [.volume, .volume, .volume])
        #expect(before.map(\.dishUUID).allSatisfy { $0 == dish.uuid })
        #expect(auditBefore.householdUUID == household.uuid)
        let duplicateFinding = try #require(
            auditBefore.recipeIngredientIssues.first { $0.kind == .duplicateDishIngredientContent }
        )
        #expect(duplicateFinding.classification == .reviewRecommended)
        #expect(duplicateFinding.relatedDishIngredientUUIDs.count == 3)
        #expect(duplicateFinding.rawText == "225 g ground beef")
        #expect(duplicateFinding.canonicalName == "Schweinenacken ohne Knochen")
        #expect(duplicateFinding.quantityValue == 10)
        #expect(duplicateFinding.quantityDimensionRaw == QuantityDimension.volume.rawValue)
    }

    @Test func auditSurfacesUnambiguousRawTextCanonicalMismatchWithoutChangingTheLine() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let household = makeHousehold(in: context)
        let dish = Dish(name: "Wrong canonical")
        let expected = Ingredient(name: "ground beef")
        let wrong = Ingredient(name: "Schweinenacken ohne Knochen")
        dish.household = household
        expected.household = household
        wrong.household = household
        household.dishes = [dish]
        household.ingredients = [expected, wrong]
        let line = DishIngredient(
            canonicalValue: 225,
            dimension: .mass,
            displayUnit: "g",
            rawText: "ground beef"
        )
        line.dish = dish
        line.ingredient = wrong
        context.insert(dish)
        context.insert(expected)
        context.insert(wrong)
        context.insert(line)
        try context.save()

        let before = lineStates(for: dish)
        let audit = IngredientIntegrityAuditor.audit(household: household, context: context)
        let finding = try #require(
            audit.recipeIngredientIssues.first { $0.kind == .dishIngredientRawTextMismatch }
        )
        #expect(finding.classification == .reviewRecommended)
        #expect(finding.rawText == "ground beef")
        #expect(finding.canonicalName == "Schweinenacken ohne Knochen")
        #expect(finding.suggestedIngredientUUID == expected.uuid)
        #expect(lineStates(for: dish) == before)
    }

    @Test func cleanupDoesNotDeleteLegitimateRepeatedLinesWithDifferentRoles() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let household = makeHousehold(in: context)
        let canonical = Ingredient(name: "Butter")
        let duplicate = Ingredient(name: "butter")
        let dish = Dish(name: "Sauce and garnish")
        canonical.household = household
        duplicate.household = household
        dish.household = household
        household.ingredients = [canonical, duplicate]
        household.dishes = [dish]
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(dish)
        let lines = [
            DishIngredient(canonicalValue: 100, dimension: .mass, displayUnit: "g", note: "sauce", rawText: "100 g butter", sortIndex: 0),
            DishIngredient(canonicalValue: 15, dimension: .volume, displayUnit: "ml", note: "garnish", rawText: "15 ml butter", sortIndex: 1),
        ]
        for line in lines {
            line.dish = dish
            line.ingredient = duplicate
            context.insert(line)
        }
        try context.save()
        let before = lineStates(for: dish)

        _ = try IngredientCleanupService.reconcileObviousDuplicates(in: household, context: context, limit: 10)

        let after = lineStates(for: dish)
        #expect(after.count == 2)
        #expect(after.map(\.uuid) == before.map(\.uuid))
        #expect(after.map(\.rawText) == before.map(\.rawText))
        #expect(after.map(\.canonicalValue) == before.map(\.canonicalValue))
        #expect(after.map(\.dimension) == before.map(\.dimension))
        #expect(after.map(\.note) == before.map(\.note))
        #expect(after.allSatisfy { $0.dishUUID == dish.uuid })
    }
}
