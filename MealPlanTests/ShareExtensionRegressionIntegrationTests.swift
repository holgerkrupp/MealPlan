import Foundation
import SwiftData
import Testing
@testable import MealPlan

/// Cross-feature checks for the Safari/share regression. The view itself lives
/// in the extension target, so these tests exercise the exact shared services
/// that the view delegates persistence, planning, subscription and handoff to.
@Suite(.serialized)
@MainActor
struct ShareExtensionRegressionIntegrationTests {
    private let recipeURL = URL(string: "https://example.com/recipes/pizza")!
    private let selectedDate = Date(timeIntervalSince1970: 1_788_393_600) // 2026-09-04 UTC

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/ShareExtension/\(name)")
        return try Data(contentsOf: url)
    }

    private func recipe(
        name: String = "Neapolitanische Pizza",
        sourceURL: URL? = nil,
        needsReview: Bool = false
    ) -> ImportedRecipe {
        var value = ImportedRecipe(name: name, sourceURL: sourceURL ?? recipeURL)
        value.ingredientLines = ["500 g Mehl", "350 ml Wasser", "10 g Salz"]
        value.instructions = "Teig kneten und heiß backen."
        value.servings = 2
        value.needsReview = needsReview
        return value
    }

    private func makeStore() throws -> (ModelContainer, Household, ModelContext, URL) {
        let (container, directory) = try makeTestModelContainer()
        let household = Household(name: "Share regression")
        let context = container.mainContext
        context.insert(household)
        try context.save()
        return (container, household, context, directory)
    }

    @Test("The reported recipe pages retain an explicit import path offline")
    func reportedRecipePagesDoNotBecomeFeedOnlySites() throws {
        let cases = [
            ("bigmeatlove-recipe-with-feed.html", URL(string: "https://bigmeatlove.de/neapolitanische-pizza.html")!),
            ("cookingitaly-recipe-without-jsonld.html", URL(string: "https://cookingitaly.de/recipe-items/pizza-margherita-alla-napoletana/")!),
        ]

        for (fixtureName, sourceURL) in cases {
            let kind = RecipeSiteDiscoveryService.classifyHTML(try fixture(fixtureName), sourceURL: sourceURL)
            switch kind {
            case .recipe, .ambiguous:
                break // Both states expose an explicit import action in the extension.
            default:
                Issue.record("\(fixtureName) lost its recipe import path: \(kind)")
            }
        }
    }

    @Test("True collection pages remain independently subscribable")
    func collectionPagesRemainSitesEvenWithFeaturedRecipeMarkup() throws {
        let homepage = RecipeSiteDiscoveryService.classifyHTML(
            try fixture("homepage-with-feed.html"),
            sourceURL: URL(string: "https://bigmeatlove.de/")!
        )
        guard case .recipeSite(let homepageCandidate) = homepage else {
            Issue.record("Homepage with RSS was not classified as a site: \(homepage)")
            return
        }
        #expect(homepageCandidate.feedURL?.absoluteString == "https://bigmeatlove.de/feed/")

        let collection = RecipeSiteDiscoveryService.classifyHTML(
            try fixture("collection-with-featured-recipe.html"),
            sourceURL: URL(string: "https://cookingitaly.de/recipes/")!
        )
        guard case .recipeSite(let collectionCandidate) = collection else {
            Issue.record("Collection with a featured Recipe was not classified as a site: \(collection)")
            return
        }
        #expect(collectionCandidate.sourceKind == .websiteDiscovery)
    }

    @Test("Save-only is separate from planning and repeated saves are duplicate-safe")
    func saveOnlyDoesNotCreatePlanEntryAndRepeatedTapIsIdempotent() throws {
        let (container, household, context, directory) = try makeStore()
        _ = container
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = RecipeImportCommitter.importAll(
            [recipe()], household: household, createdByName: "Me", context: context
        )
        #expect(first.imported == 1)
        #expect(try context.fetchCount(FetchDescriptor<MealPlanEntry>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Dish>()) == 1)

        let retry = RecipeImportCommitter.importAll(
            [recipe()], household: household, createdByName: "Me", context: context
        )
        #expect(retry.imported == 0)
        #expect(retry.skipped == 1)
        #expect(try context.fetchCount(FetchDescriptor<Dish>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<MealPlanEntry>()) == 0)
    }

    @Test("Save and plan uses the selected date, meal and extras without duplicate retries")
    func saveAndPlanIsIdempotentAndPreservesExtras() throws {
        let (container, household, context, directory) = try makeStore()
        _ = container
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = RecipeImportCommitter.importAll(
            [recipe()], household: household, createdByName: "Me", context: context
        )
        let dish = try #require(result.dishesForPlanning.first)
        let first = MealPlanner.planOnce(
            dish: dish,
            on: selectedDate,
            mealKey: MealSlot.lunch.rawValue,
            household: household,
            memberName: "Me",
            context: context
        )
        guard case .saved = first else {
            Issue.record("First plan attempt did not save: \(String(describing: first))")
            return
        }

        let entry = try #require(try context.fetch(FetchDescriptor<MealPlanEntry>()).first)
        entry.extraItems = ["Basil", "Sparkling water"]
        try context.save()

        let retry = MealPlanner.planOnce(
            dish: dish,
            on: selectedDate,
            mealKey: MealSlot.lunch.rawValue,
            household: household,
            memberName: "Me",
            context: context
        )
        guard case .alreadyPlanned = retry else {
            Issue.record("Repeated plan attempt was not treated as a duplicate: \(String(describing: retry))")
            return
        }
        #expect(try context.fetchCount(FetchDescriptor<MealPlanEntry>()) == 1)
        #expect(entry.date == selectedDate.startOfDay)
        #expect(entry.mealKey == MealSlot.lunch.rawValue)
        #expect(entry.extraItems == ["Basil", "Sparkling water"])
    }

    @Test("Read-only households reject both recipe and planning mutations")
    func readOnlyHouseholdDoesNotPartiallySave() throws {
        let (container, household, context, directory) = try makeStore()
        _ = container
        defer { try? FileManager.default.removeItem(at: directory) }
        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(
            HouseholdShareLocator(
                zoneName: "MealPlanHousehold-\(household.uuid.uuidString)",
                ownerName: "owner",
                shareRecordName: "share",
                isOwner: false,
                isReadOnly: true
            )
        )
        try context.save()

        let importResult = RecipeImportCommitter.importAll(
            [recipe()], household: household, createdByName: "Guest", context: context
        )
        #expect(importResult.isEmpty)

        let dish = Dish(name: "Existing dish")
        dish.household = household
        context.insert(dish)
        try context.save()
        let planResult = MealPlanner.planOnce(
            dish: dish,
            on: selectedDate,
            mealKey: MealSlot.dinner.rawValue,
            household: household,
            memberName: "Guest",
            context: context
        )
        guard case .failed = planResult else {
            Issue.record("Read-only household accepted a plan mutation")
            return
        }
        #expect(try context.fetchCount(FetchDescriptor<MealPlanEntry>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Dish>()) == 1)
    }

    @Test("The planning horizon rejects a locked date before the view offers Save and plan")
    func lockedDateIsNotEligibleForPlanning() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12))!
        let locked = calendar.date(byAdding: .day, value: PlanningAccess.freeDaysAhead + 1, to: now)!
        #expect(!PlanningAccess.canPlan(on: locked, isUnlocked: false, now: now, calendar: calendar))
        #expect(PlanningAccess.canPlan(on: locked, isUnlocked: true, now: now, calendar: calendar))
    }

    @Test("Subscription is independent from dishes and meal entries")
    func subscriptionDoesNotCreateDishOrPlanEntry() async throws {
        let (container, household, context, directory) = try makeStore()
        _ = container
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let siteURL = URL(string: "https://example.com/")!
        let parsed = ParsedRecipeFeed(
            title: "Example recipes",
            homeURL: siteURL,
            articles: [ParsedFeedArticle(
                id: "pizza-1", title: "Pizza", url: recipeURL, author: nil,
                summary: "A pizza", body: nil, publishedAt: selectedDate, imageURL: nil
            )]
        )
        let response = HTTPURLResponse(
            url: feedURL, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/rss+xml"]
        )!
        let resolved = RecipeFeedService.ResolvedFeed(
            parsed: parsed, feedURL: feedURL, siteURL: siteURL, response: response
        )

        let first = try await RecipeFeedService.subscribe(to: resolved, household: household, context: context)
        let retry = try await RecipeFeedService.subscribe(to: resolved, household: household, context: context)
        #expect(first.uuid == retry.uuid)
        #expect(try context.fetchCount(FetchDescriptor<RecipeFeed>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<RecipeFeedItem>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Dish>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<MealPlanEntry>()) == 0)
    }

    @Test("Incomplete extraction remains reviewable after an explicit import")
    func partialExtractionIsFlaggedForReview() throws {
        let (container, household, context, directory) = try makeStore()
        _ = container
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = RecipeImportCommitter.importAll(
            [recipe(name: "Partial recipe", needsReview: true)],
            household: household,
            createdByName: "Me",
            context: context
        )
        let dish = try #require(result.dishes.first)
        #expect(dish.needsReview)
        #expect(dish.recipeText != nil)
        #expect(dish.ingredients?.isEmpty == false)
    }

    @Test("Text and MealPlan archive inputs still reach the shared importer")
    func textAndArchiveSharingRemainImportable() throws {
        let textRecipe = ScannedRecipeParser.importedRecipe(fromText: """
        Pizza Margherita
        500 g Mehl
        350 ml Wasser

        Teig kneten und backen.
        """)
        #expect(textRecipe.name.localizedCaseInsensitiveContains("Pizza"))
        #expect(textRecipe.ingredientLines.isEmpty == false)

        let dish = Dish(name: "Archived soup")
        dish.recipeText = "Simmer."
        let archiveURL = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-share-\(UUID().uuidString).mealplanrecipes")
        let paprikaURL = FileManager.default.temporaryDirectory
            .appending(path: "Paprika-share-\(UUID().uuidString).paprikarecipe")
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: paprikaURL)
        }
        try MealPlanRecipeArchive.data(from: [dish]).write(to: archiveURL)
        try Data(#"{"name":"Paprika soup","ingredients":"2 potatoes","directions":"Boil."}"#.utf8)
            .write(to: paprikaURL)

        #expect(try RecipeImportCommitter.recipes(fromFileAt: archiveURL).first?.name == "Archived soup")
        #expect(try RecipeImportCommitter.recipes(fromFileAt: paprikaURL).first?.name == "Paprika soup")
    }

    @Test("Handoff survives a read, ignores the wrong consumer and is one-shot")
    func handoffQueuePersistsAndConsumesOnce() throws {
#if os(iOS)
        if let old = ShareHandoff.pending() { ShareHandoff.consume(id: old.id) }
        defer {
            if let pending = ShareHandoff.pending() { ShareHandoff.consume(id: pending.id) }
        }
        let siteURL = URL(string: "https://example.com/recipes")!
        #expect(ShareHandoff.store(.site(siteURL)))
        let pending = try #require(ShareHandoff.pending())
        guard case .site(let storedURL) = pending.destination else {
            Issue.record("Expected a site handoff")
            return
        }
        #expect(storedURL == siteURL)
        #expect(ShareHandoff.pending()?.id == pending.id)

        ShareHandoff.consume(id: UUID())
        #expect(ShareHandoff.pending()?.id == pending.id)
        ShareHandoff.consume(id: pending.id)
        #expect(ShareHandoff.pending() == nil)
        ShareHandoff.consume(id: pending.id)
        #expect(ShareHandoff.pending() == nil)
#else
        // The Share Extension/App Group entitlement is iOS-only. The
        // persistence lifecycle is covered by the iOS test build; macOS can
        // still run the shared classification/import/planning cases.
        return
#endif
    }
}
