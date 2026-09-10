import Testing
import Foundation
import CoreGraphics
@testable import MealPlan

/// Transient model objects only — no `ModelContext`, per the rest of the suite.
/// Assertions stick to the recipe's own words and numbers, never to localized
/// labels, so they hold whatever language the test host runs in.
@MainActor
@Suite(.serialized)
struct RecipeShareTests {

    private let locale = Locale(identifier: "en_US")

    // MARK: - Fixtures

    private func pancakes() -> Dish {
        let dish = Dish(name: "Pancakes")
        dish.servings = 2
        dish.prepTimeMinutes = 10
        dish.cookTimeMinutes = 20
        dish.sourceURLString = "https://www.example.com/pancakes"
        dish.recipeText = "1. Whisk the flour and eggs.\n\nFor the topping:\n2) Fry in butter."

        let flour = DishIngredient(canonicalValue: 250, dimension: .mass, sortIndex: 0)
        flour.ingredient = Ingredient(name: "flour")
        let salt = DishIngredient(note: "to taste", sortIndex: 1)
        salt.ingredient = Ingredient(name: "salt")
        for line in [flour, salt] { line.dish = dish }
        dish.ingredients = [flour, salt]
        return dish
    }

    private func content(_ dish: Dish, servings: Int) -> RecipeShareContent {
        RecipeShareContent.make(
            dish: dish,
            servings: servings,
            translated: false,
            system: .metric,
            roundsAmounts: true,
            energyUnit: nil,
            includesImage: false,
            locale: locale
        )
    }

    // MARK: - Content & text

    @Test func amountsAreScaledToTheSharedServings() {
        let shared = content(pancakes(), servings: 4)
        #expect(shared.ingredients.first?.amount == "500 g")
        #expect(shared.plainText.contains("500 g flour"))
    }

    @Test func aNoteWithoutAnAmountFollowsTheName() {
        let salt = content(pancakes(), servings: 2).ingredients.last
        #expect(salt?.amount == nil)
        #expect(salt?.text == "salt, to taste")
    }

    @Test func stepsAreRenumberedAndHeadingsAreNot() {
        let steps = content(pancakes(), servings: 2).steps
        #expect(steps == [
            .init(number: 1, text: "Whisk the flour and eggs."),
            .init(number: nil, text: "For the topping", isHeading: true),
            .init(number: 2, text: "Fry in butter."),
        ])
        let text = content(pancakes(), servings: 2).plainText
        #expect(text.contains("1. Whisk the flour and eggs."))
        #expect(text.contains("2. Fry in butter."))
    }

    @Test func aSingleParagraphIsNotNumbered() {
        let steps = RecipeShareContent.steps(from: "Mix everything and bake for 20 minutes.")
        #expect(steps.count == 1)
        #expect(steps.first?.number == nil)
    }

    @Test func theTextLinksTheSourceUnlessItIsGone() {
        var shared = content(pancakes(), servings: 2)
        #expect(shared.plainText.contains("https://www.example.com/pancakes"))

        shared.sourceIsGone = true
        #expect(!shared.plainText.contains("https://"))
        #expect(shared.plainText.contains("example.com"))
    }

    @Test func aNonWebSourceIsNeverShared() {
        let dish = pancakes()
        dish.sourceURLString = "paprika://recipe/123"
        let shared = content(dish, servings: 2)
        #expect(!shared.hasWebSource)
        #expect(!shared.plainText.contains("paprika://"))
        #expect(!RecipePDFRenderer.blocks(for: shared, contentWidth: 530).contains(.source))
    }

    // MARK: - Source link

    @Test func onlyAServerThatSaysSoMakesAPageGone() {
        #expect(RecipeSourceLink.availability(forStatusCode: 200) == .available)
        #expect(RecipeSourceLink.availability(forStatusCode: 206) == .available)
        #expect(RecipeSourceLink.availability(forStatusCode: 301) == .available)
        #expect(RecipeSourceLink.availability(forStatusCode: 404) == .gone)
        #expect(RecipeSourceLink.availability(forStatusCode: 410) == .gone)
        // A bot wall or a bad moment proves nothing.
        #expect(RecipeSourceLink.availability(forStatusCode: 403) == .unknown)
        #expect(RecipeSourceLink.availability(forStatusCode: 429) == .unknown)
        #expect(RecipeSourceLink.availability(forStatusCode: 503) == .unknown)
    }

    @Test func aVanishedDomainIsGoneButBeingOfflineIsNot() {
        #expect(RecipeSourceLink.availability(for: URLError(.cannotFindHost)) == .gone)
        #expect(RecipeSourceLink.availability(for: URLError(.notConnectedToInternet)) == .unknown)
        #expect(RecipeSourceLink.availability(for: URLError(.timedOut)) == .unknown)
    }

    // MARK: - PDF layout

    private func lines(_ count: Int) -> [RecipeShareContent.IngredientLine] {
        (1...count).map { .init(amount: "\($0) g", name: "item \($0)") }
    }

    private func step(_ number: Int) -> RecipePDFRenderer.Block {
        .step(.init(number: number, text: "Step \(number)"), continuation: false)
    }

    /// Stand-in for rendering: 20 pt a row of ingredients, fixed heights else.
    private func fakeHeight(_ block: RecipePDFRenderer.Block) -> CGFloat {
        switch block {
        case .header: 300
        case .sectionTitle: 30
        case .ingredients(let items, let columns):
            CGFloat(RecipePDFRenderer.rowCount(items.count, columns: columns)) * 20
        case .step: 100
        case .note: 20
        case .source: 30
        }
    }

    @Test func aLongIngredientListCarriesOverWithoutLosingALine() {
        let items = lines(30)
        let pages = RecipePDFRenderer.paginate(
            [.header, .sectionTitle("Ingredients", detail: nil), .ingredients(items, columns: 2)],
            pageHeight: 500,
            measure: fakeHeight
        )
        #expect(pages.count == 2)
        // 170 pt left under the header and title: eight rows of two.
        guard case .ingredients(let first, 2)? = pages[0].last,
              case .ingredients(let rest, 2)? = pages[1].first
        else {
            Issue.record("expected the list on both pages")
            return
        }
        #expect(first.count == 16)
        #expect(first + rest == items)
    }

    @Test func aSectionTitleNeverEndsAPage() {
        let pages = RecipePDFRenderer.paginate(
            [.header, step(1), .sectionTitle("Method", detail: nil), step(2)],
            pageHeight: 500,
            measure: fakeHeight
        )
        #expect(pages.count == 2)
        #expect(pages[1].first == .sectionTitle("Method", detail: nil))
    }

    @Test func aBlockTallerThanAPageGetsOneToItself() {
        let pages = RecipePDFRenderer.paginate(
            [.header, step(1), .source],
            pageHeight: 500,
            measure: { if case .step = $0 { 900 } else { fakeHeight($0) } }
        )
        #expect(pages == [[.header], [step(1)], [.source]])
    }

    @Test func longIngredientListsGoIntoTwoColumnsOnlyWhereTheyFit() {
        var shared = content(pancakes(), servings: 2)
        shared.ingredients = lines(8)
        let a4 = RecipePDFRenderer.blocks(for: shared, contentWidth: 531)
        let a5 = RecipePDFRenderer.blocks(for: shared, contentWidth: 376)
        #expect(a4.contains(.ingredients(lines(8), columns: 2)))
        #expect(a5.contains(.ingredients(lines(8), columns: 1)))
    }

    @Test func anOverlongStepIsCutAtSentenceEnds() {
        let sentence = "Stir the sauce slowly until it thickens and coats the back of a spoon."
        let text = Array(repeating: sentence, count: 30).joined(separator: " ")
        let pieces = RecipePDFRenderer.splitLongText(text)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= 700 && $0.hasSuffix(".") })
        #expect(pieces.joined(separator: " ") == text)
    }

    // MARK: - Files

    @Test func fileNamesKeepTheRecipeNameAndLoseOnlyWhatFilesCannotHold() {
        #expect(ShareFileName.sanitized("Omas Käsekuchen / Rezept?", fallback: "x") == "Omas Käsekuchen Rezept")
        #expect(ShareFileName.sanitized("担々麺 🍜", fallback: "x") == "担々麺 🍜")
        #expect(ShareFileName.sanitized(".hidden", fallback: "x") == "hidden")
        #expect(ShareFileName.sanitized("  ", fallback: "Recipe") == "Recipe")
    }

    @Test func aSharedArchiveIsNamedAfterTheDishAndStillImports() throws {
        let url = try MealPlanRecipeArchive.temporaryFile(for: [pancakes()])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.lastPathComponent == "Pancakes.mealplanrecipes")
        let recipes = try RecipeImportCommitter.recipes(fromFileAt: url)
        #expect(recipes.map(\.name) == ["Pancakes"])
    }

    @Test func receivingOneRecipeNamesIt() {
        let dish = Dish(name: "Pancakes")
        let single = RecipeImportCommitter.Result(imported: 1, dishes: [dish])
        #expect(single.summary.contains("Pancakes"))
        let several = RecipeImportCommitter.Result(imported: 2, dishes: [dish, Dish(name: "Waffles")])
        #expect(!several.summary.contains("Pancakes"))
    }
}
