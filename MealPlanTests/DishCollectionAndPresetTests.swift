import Testing
import Foundation
@testable import MealPlan

/// Collections, bulk label edits, saved searches and the recipe-metric sorts.
/// Transient `Dish` objects only — no container in the test host.
@MainActor
struct DishCollectionAndPresetTests {

    // MARK: - Collections

    @Test func renamingRewritesEveryMemberAndLeavesOthersAlone() {
        let soup = Dish(name: "Soup")
        soup.collectionNames = ["Weeknight", "Winter"]
        let pasta = Dish(name: "Pasta")
        pasta.collectionNames = ["weeknight"]
        let cake = Dish(name: "Cake")
        cake.collectionNames = ["Baking"]
        let cakeModified = cake.modifiedAt

        let changed = DishCollection.rename("Weeknight", to: "Quick dinners", in: [soup, pasta, cake])

        #expect(changed.count == 2)
        #expect(soup.collectionNames == ["Quick dinners", "Winter"])
        #expect(pasta.collectionNames == ["Quick dinners"])
        #expect(cake.collectionNames == ["Baking"])
        #expect(cake.modifiedAt == cakeModified)
    }

    @Test func renamingOntoAnExistingCollectionMergesWithoutDuplicates() {
        let soup = Dish(name: "Soup")
        soup.collectionNames = ["Weeknight", "Quick"]
        DishCollection.rename("Weeknight", to: "quick", in: [soup])
        #expect(soup.collectionNames == ["Quick"])
    }

    @Test func renamingToBlankChangesNothing() {
        let soup = Dish(name: "Soup")
        soup.collectionNames = ["Weeknight"]
        #expect(DishCollection.rename("Weeknight", to: "  ", in: [soup]).isEmpty)
        #expect(soup.collectionNames == ["Weeknight"])
    }

    @Test func deletingRemovesTheCollectionButKeepsTagsAndOtherCollections() {
        let soup = Dish(name: "Soup")
        soup.collectionNames = ["Weeknight", "Winter"]
        soup.tagNames = ["Weeknight"]
        let cake = Dish(name: "Cake")

        let changed = DishCollection.delete("weeknight", from: [soup, cake])

        #expect(changed.count == 1)
        #expect(soup.collectionNames == ["Winter"])
        #expect(soup.tagNames == ["Weeknight"])
    }

    @Test func usageCountsDishesPerCollectionAlphabetically() {
        let usage = DishCollection.usage(fromCollectionLists: [["Winter", "Baking"], ["winter"], []])
        #expect(usage.map(\.name) == ["Baking", "Winter"])
        #expect(usage.map(\.count) == [1, 2])
    }

    @Test func collectionFilterMatchesAnySpelling() {
        let soup = Dish(name: "Soup")
        soup.collectionNames = ["Winter"]
        let cake = Dish(name: "Cake")
        var filter = DishFilter()
        filter.collection = "winter"
        #expect(filter.isActive)
        #expect(filter.apply(to: [soup, cake]) == [soup])
    }

    // MARK: - Bulk edits

    @Test func bulkEditTouchesOnlyChangedDishesAndUndoRestores() {
        let soup = Dish(name: "Soup")
        soup.tagNames = ["Vegan"]
        let stew = Dish(name: "Stew")
        stew.tagNames = ["Quick"]
        let stewModified = stew.modifiedAt

        let addSnapshot = DishLabelEdit.addTag("vegan").apply(to: [soup, stew])
        #expect(addSnapshot.labels.count == 1)
        #expect(stew.tagNames == ["Quick", "vegan"])
        #expect(soup.tagNames == ["Vegan"])

        let collectSnapshot = DishLabelEdit.addToCollection("Winter").apply(to: [soup, stew])
        #expect(collectSnapshot.labels.count == 2)
        #expect(soup.collectionNames == ["Winter"])

        DishLabelEdit.restore(collectSnapshot, on: [soup, stew])
        DishLabelEdit.restore(addSnapshot, on: [soup, stew])
        #expect(soup.collectionNames.isEmpty)
        #expect(stew.collectionNames.isEmpty)
        #expect(stew.tagNames == ["Quick"])
        #expect(soup.tagNames == ["Vegan"])
        #expect(stew.modifiedAt >= stewModified)
    }

    @Test func bulkRemovalOfALabelNoDishCarriesIsANoOp() {
        let soup = Dish(name: "Soup")
        let snapshot = DishLabelEdit.removeFromCollection("Winter").apply(to: [soup])
        #expect(snapshot.labels.isEmpty)
    }

    // MARK: - Saved searches

    @Test func presetsRoundTripThroughJSON() {
        var filter = DishFilter(sort: .longestCookTime)
        filter.searchText = "curry"
        filter.mealType = MealTypeTag.allCases.first
        filter.season = Season.allCases.first
        filter.maxMinutes = 30
        filter.notCookedWithinDays = 60
        filter.favoritesOnly = true
        filter.minimumRating = 4
        filter.tags = ["Vegan", "Quick"]
        filter.collection = "Weeknight"
        let presets = [DishFilterPreset(name: "Quick curries", filter: filter)]

        let decoded = DishFilterPresetStore.decode(DishFilterPresetStore.encode(presets))

        #expect(decoded == presets)
    }

    @Test func presetDecodingToleratesMissingAndUnknownFields() throws {
        let json = #"[{"id":"9C1E1F3A-2B7C-4B5E-9F62-3A1D2C4B5E6F","name":"Old","filter":{"sort":"somethingNew","tags":["Vegan"],"futureField":1}}]"#
        let decoded = DishFilterPresetStore.decode(Data(json.utf8))
        let preset = try #require(decoded.first)
        #expect(preset.name == "Old")
        #expect(preset.filter.sort == .alphabetical)
        #expect(preset.filter.tags == ["Vegan"])
        #expect(preset.filter.searchText.isEmpty)
        #expect(!preset.filter.favoritesOnly)
    }

    @Test func unreadablePresetDataIsEmptyRatherThanACrash() {
        #expect(DishFilterPresetStore.decode(Data()).isEmpty)
        #expect(DishFilterPresetStore.decode(Data("not json".utf8)).isEmpty)
    }

    // MARK: - Sorting

    private func timed(_ name: String, prep: Int?, cook: Int?, servings: Int = 2) -> Dish {
        let dish = Dish(name: name)
        dish.prepTimeMinutes = prep
        dish.cookTimeMinutes = cook
        dish.servings = servings
        return dish
    }

    @Test func timeSortsGoBothWaysAndKeepUntimedDishesLast() {
        let quick = timed("Quick", prep: 5, cook: 5)
        let slow = timed("Slow", prep: 30, cook: 120)
        let prepOnly = timed("Prep only", prep: 20, cook: nil)
        let untimed = timed("Untimed", prep: nil, cook: nil)
        let all = [untimed, slow, quick, prepOnly]

        #expect(DishFilter(sort: .shortestTotalTime).apply(to: all).map(\.name) == ["Quick", "Prep only", "Slow", "Untimed"])
        #expect(DishFilter(sort: .longestTotalTime).apply(to: all).map(\.name) == ["Slow", "Prep only", "Quick", "Untimed"])
        #expect(DishFilter(sort: .shortestCookTime).apply(to: all).map(\.name) == ["Quick", "Slow", "Prep only", "Untimed"])
        #expect(DishFilter(sort: .longestPrepTime).apply(to: all).map(\.name) == ["Slow", "Prep only", "Quick", "Untimed"])
    }

    @Test func servingsSortsTieBreakByName() {
        let b = timed("B", prep: nil, cook: nil, servings: 4)
        let a = timed("A", prep: nil, cook: nil, servings: 4)
        let one = timed("Single", prep: nil, cook: nil, servings: 1)
        #expect(DishFilter(sort: .fewestServings).apply(to: [b, a, one]).map(\.name) == ["Single", "A", "B"])
        #expect(DishFilter(sort: .mostServings).apply(to: [one, b, a]).map(\.name) == ["A", "B", "Single"])
    }

    @Test func onlyStoreOrderableSortsArePaged() {
        #expect(DishFilter.Sort.alphabetical.isStoreOrderable)
        #expect(DishFilter.Sort.mostServings.isStoreOrderable)
        #expect(!DishFilter.Sort.shortestTotalTime.isStoreOrderable)
        #expect(!DishFilter.Sort.longestPrepTime.isStoreOrderable)
    }
}
