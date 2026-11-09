import Testing
import Foundation
@testable import MealPlan

/// Transient models only — no container — so these run in the test host.
@MainActor
struct LibraryDuplicateScannerTests {

    private func dish(
        _ name: String,
        ingredients: [String] = [],
        source: String? = nil,
        app: String? = nil,
        sourceID: String? = nil
    ) -> Dish {
        let dish = Dish(name: name)
        dish.sourceURL = source.flatMap(URL.init(string:))
        dish.importedSourceApp = app
        dish.importedSourceID = sourceID
        dish.ingredients = ingredients.enumerated().map { index, raw in
            let line = DishIngredient(rawText: raw, sortIndex: index)
            line.ingredient = Ingredient(name: raw)
            line.dish = dish
            return line
        }
        return dish
    }

    @Test func sameSourceRecordIsFoundDespiteARename() {
        let a = dish("Omas Bolognese", app: "Paprika", sourceID: "ABC")
        let b = dish("Bolognese Classico", app: "Paprika", sourceID: "ABC")
        let other = dish("Pancakes")
        let found = LibraryDuplicateScanner.candidates(in: [a, b, other])
        #expect(found.count == 1)
        #expect(found.first?.reason == .sameSourceRecord)
        #expect(Set([found.first?.first, found.first?.second]) == Set([a.uuid, b.uuid]))
    }

    @Test func sameSourceIDFromDifferentAppsIsNotADuplicate() {
        let a = dish("Soup", ingredients: ["Leek"], app: "Paprika", sourceID: "1")
        let b = dish("Stew", ingredients: ["Beef"], app: "Other", sourceID: "1")
        #expect(LibraryDuplicateScanner.candidates(in: [a, b]).isEmpty)
    }

    @Test func sameLinkIgnoringQueryIsFound() {
        let a = dish("Gnocchiauflauf", source: "https://www.chefkoch.de/rezepte/1/Gnocchi.html?portionen=3")
        let b = dish("Gnocchi-Auflauf", source: "https://www.chefkoch.de/rezepte/1/Gnocchi.html?portionen=6")
        let found = LibraryDuplicateScanner.candidates(in: [a, b])
        #expect(found.map(\.reason) == [.sameSourceLink])
    }

    @Test func sameNameNeedsMatchingIngredients() {
        let a = dish("Burger", ingredients: ["Beef", "Bun", "Cheese", "Onion", "Tomato"])
        let b = dish("burger", ingredients: ["Beef", "Bun", "Cheese", "Onion", "Tomato"])
        let variant = dish("Burger", ingredients: ["Halloumi", "Bun", "Rocket"])
        let found = LibraryDuplicateScanner.candidates(in: [a, b, variant])
        #expect(found.count == 1)
        #expect(found.first?.reason == .sameNameAndIngredients)
        #expect(Set([found.first?.first, found.first?.second]) == Set([a.uuid, b.uuid]))
    }

    @Test func dishesAlreadyGroupedAsVariantsAreSkipped() {
        let a = dish("Burger", ingredients: ["Beef", "Bun"])
        let b = dish("Burger", ingredients: ["Beef", "Bun"])
        DishVariants.join(b, with: a)
        #expect(LibraryDuplicateScanner.candidates(in: [a, b]).isEmpty)
    }

    @Test func dismissedPairsStayHiddenInEitherOrder() {
        let a = dish("Soup", source: "https://example.com/soup")
        let b = dish("Soup", source: "https://example.com/soup")
        let key = DuplicatePairKey.make(b.uuid, a.uuid)
        #expect(key == DuplicatePairKey.make(a.uuid, b.uuid))
        #expect(LibraryDuplicateScanner.candidates(in: [a, b], dismissed: [key]).isEmpty)
        #expect(DuplicatePairKey.decode(DuplicatePairKey.encode([key])) == [key])
    }

    @Test func aPairMatchingSeveralSignalsIsListedOnceWithTheStrongest() {
        let a = dish("Soup", source: "https://example.com/soup", app: "Paprika", sourceID: "1")
        let b = dish("Soup", source: "https://example.com/soup", app: "Paprika", sourceID: "1")
        let found = LibraryDuplicateScanner.candidates(in: [a, b])
        #expect(found.map(\.reason) == [.sameSourceRecord])
    }

    // MARK: - Merge before delete

    @Test func deletingMovesPlansHistoryAndRoutinesToTheKeptDish() {
        let kept = dish("Soup")
        let removed = dish("Soup")
        removed.usageCount = 3
        removed.isFavorite = true
        removed.addTag("winter")
        removed.sourceURL = URL(string: "https://example.com/soup")
        let entry = MealPlanEntry(dish: removed)
        let log = CookedLog(dish: removed)
        let routine = MealRoutine(dish: removed)
        let slot = WeekTemplateEntry(dish: removed)
        removed.entries = [entry]
        removed.cookedLogs = [log]
        removed.routines = [routine]
        removed.templateEntries = [slot]

        let preview = DuplicateDishMerge.preview(removing: removed, keeping: kept)
        #expect(preview.plannedMeals == 1 && preview.cookedLogs == 1 && preview.routines == 1 && preview.templateEntries == 1)

        DuplicateDishMerge.moveReferences(from: removed, to: kept)
        #expect(entry.dish === kept)
        #expect(log.dish === kept)
        #expect(routine.dish === kept)
        #expect(slot.dish === kept)
        #expect(kept.usageCount == 3)
        #expect(kept.isFavorite)
        #expect(kept.hasTag("winter"))
        #expect(kept.sourceURL?.absoluteString == "https://example.com/soup")
    }

    @Test func previewReportsContentThatWillBePreserved() {
        let kept = dish("Soup", ingredients: ["Leek", "Potato"])
        let removed = dish("Soup", ingredients: ["Leek", "Potato", "Cream"])
        removed.recipeText = "Blend and add cream."
        removed.images = [DishImage(data: Data([1, 2, 3]))]
        let preview = DuplicateDishMerge.preview(removing: removed, keeping: kept)
        #expect(preview.uniqueImages == 1)
        #expect(preview.uniqueIngredients == 1)
        #expect(preview.hasDifferentRecipeText)
    }

    @Test func deletingPreservesUniqueRecipeContentAndMergesMetadata() {
        let kept = dish("Soup", ingredients: ["Leek"])
        let removed = dish("Soup", ingredients: ["Leek", "Cream"])
        let cream = removed.ingredients!.last!
        cream.canonicalValue = 200
        cream.dimension = .mass
        cream.displayUnit = "g"
        cream.note = "softened"
        cream.translatedName = "Sahne"
        removed.recipeText = "Blend until smooth."
        removed.images = [DishImage(data: Data([1, 2, 3]))]
        removed.collectionNames = ["Weeknight"]
        removed.statedEnergyKcalPerServing = 310
        removed.prepTimeMinutes = 15

        DuplicateDishMerge.moveReferences(from: removed, to: kept)

        #expect(kept.ingredients?.contains(where: { $0 === cream }) == true)
        #expect(cream.dish === kept)
        #expect(cream.note == "softened")
        #expect(cream.canonicalValue == 200)
        #expect(cream.translatedName == "Sahne")
        #expect(kept.images?.contains(where: { $0.data == Data([1, 2, 3]) }) == true)
        #expect(kept.recipeText?.contains("Blend until smooth.") == true)
        #expect(kept.collectionNames == ["Weeknight"])
        #expect(kept.statedEnergyKcalPerServing == 310)
        #expect(kept.prepTimeMinutes == 15)
    }

    @Test func identicalImagesAndIngredientLinesAreNotDuplicated() {
        let kept = dish("Soup", ingredients: ["Leek"])
        let removed = dish("Soup", ingredients: ["Leek"])
        let existingImage = DishImage(data: Data([8, 9]))
        kept.images = [existingImage]
        removed.images = [DishImage(data: Data([8, 9]))]
        let keptCount = kept.ingredients?.count

        DuplicateDishMerge.moveReferences(from: removed, to: kept)

        #expect(kept.images?.count == 1)
        #expect(kept.ingredients?.count == keptCount)
    }
}
