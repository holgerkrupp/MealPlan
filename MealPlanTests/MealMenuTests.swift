import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
@Suite(.serialized)
struct MealMenuTests {
    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Date.mondayCalendar
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!.startOfDay
    }

    @Test func menuKeepsReferencesAndReportsMissingDishes() {
        let menu = MealMenu(name: "Taco night")
        let tacos = Dish(name: "Tacos")
        let missing = MealMenuEntry(mealKey: "dinner", sortIndex: 1)
        let entry = MealMenuEntry(dish: tacos, mealKey: "dinner", servingsOverride: 6, sortIndex: 0)
        menu.entries = [entry, missing]

        #expect(menu.sortedEntries.map { $0.dish?.name } == ["Tacos", nil])
        #expect(menu.availableDishCount == 1)
        #expect(menu.missingDishCount == 1)
        #expect(entry.dish?.uuid == tacos.uuid)
    }

    @Test func applyingMenuPreservesExistingMealsAndSkipsDuplicates() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let existingDish = Dish(name: "Existing")
        let addedDish = Dish(name: "Added")
        household.dishes = [existingDish, addedDish]
        context.insert(household)
        context.insert(existingDish)
        context.insert(addedDish)

        let day = date("2026-09-08")
        let existing = MealPlanEntry(date: day, mealKey: "dinner", dish: existingDish)
        existing.household = household
        context.insert(existing)
        let menu = MealMenu(name: "Dinner pair")
        menu.household = household
        context.insert(menu)
        let first = MealMenuEntry(dish: existingDish, mealKey: "dinner", sortIndex: 0)
        first.menu = menu
        let second = MealMenuEntry(dish: addedDish, mealKey: "dinner", sortIndex: 1)
        second.menu = menu
        context.insert(first)
        context.insert(second)
        try context.save()

        let preview = MealMenuPlanner.preview(menu, on: day, mealKey: nil, replaceExisting: false, household: household, context: context)
        #expect(preview.itemsToAdd == 1)
        #expect(preview.duplicateItems == 1)
        #expect(preview.itemsToReplace == 0)

        let result = try MealMenuPlanner.apply(menu, on: day, mealKey: nil, replaceExisting: false, household: household, memberName: "Me", context: context)
        #expect(result.insertedEntryIDs.count == 1)
        #expect(result.skippedDuplicateCount == 1)
        #expect(try context.fetch(FetchDescriptor<MealPlanEntry>()).count == 2)
    }

    @Test func replacementCanBeUndoneWithoutChangingTheMenu() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let oldDish = Dish(name: "Old")
        let newDish = Dish(name: "New")
        household.dishes = [oldDish, newDish]
        context.insert(household)
        context.insert(oldDish)
        context.insert(newDish)

        let day = date("2026-09-09")
        let oldEntry = MealPlanEntry(date: day, mealKey: "dinner", dish: oldDish)
        oldEntry.household = household
        context.insert(oldEntry)
        let menu = MealMenu(name: "Replacement")
        menu.household = household
        context.insert(menu)
        let menuEntry = MealMenuEntry(dish: newDish, mealKey: "dinner")
        menuEntry.menu = menu
        context.insert(menuEntry)
        try context.save()

        let result = try MealMenuPlanner.apply(menu, on: day, mealKey: nil, replaceExisting: true, household: household, memberName: "Me", context: context)
        #expect(result.replacedEntries.count == 1)
        #expect((try context.fetch(FetchDescriptor<MealPlanEntry>())).compactMap { $0.dish?.name } == ["New"])

        try MealMenuPlanner.undo(result, in: context)
        let restored = try context.fetch(FetchDescriptor<MealPlanEntry>())
        #expect(restored.count == 1)
        #expect(restored.first?.dish?.name == "Old")
        #expect(menu.name == "Replacement")
        #expect(menu.sortedEntries.first?.dish?.name == "New")
    }

    @Test func plannedDayMenuStaysScopedToItsHousehold() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let firstHousehold = Household(name: "First")
        let secondHousehold = Household(name: "Second")
        let firstDish = Dish(name: "First dish")
        let secondDish = Dish(name: "Second dish")
        firstHousehold.dishes = [firstDish]
        secondHousehold.dishes = [secondDish]
        context.insert(firstHousehold)
        context.insert(secondHousehold)
        context.insert(firstDish)
        context.insert(secondDish)
        let day = date("2026-09-10")
        let firstEntry = MealPlanEntry(date: day, mealKey: "dinner", dish: firstDish)
        firstEntry.household = firstHousehold
        let secondEntry = MealPlanEntry(date: day, mealKey: "dinner", dish: secondDish)
        secondEntry.household = secondHousehold
        context.insert(firstEntry)
        context.insert(secondEntry)
        try context.save()

        let menu = try MealMenuPlanner.makeFromPlannedDate(day, name: "First day", household: firstHousehold, createdBy: "Me", context: context)
        #expect(menu?.sortedEntries.compactMap { $0.dish?.name } == ["First dish"])
    }
}
