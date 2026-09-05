import Testing
import Foundation
@testable import MealPlan

/// Dishes planned on a day without one of the household's meals — the birthday
/// cake, the batch of jam. The rules live in pure helpers so they can be
/// checked without a store; see the SwiftData note in
/// `MealTypeDeduplicationTests`.
@MainActor
struct ExtraMealTests {

    private func meal(_ key: String, _ name: String, order: Int) -> MealType {
        MealType(key: key, name: name, sortOrder: order)
    }

    private var household: [MealType] {
        [meal("breakfast", "Breakfast", order: 0), meal("dinner", "Dinner", order: 1)]
    }

    // MARK: - What a day draws

    @Test func aDayWithNoExtraShowsOnlyTheHouseholdsMeals() {
        let meals = DayMeal.forDay(mealTypes: household, plannedKeys: ["dinner"])

        #expect(meals.map(\.key) == ["breakfast", "dinner"])
    }

    @Test func extrasAppearOnlyOnTheDayTheyArePlannedFor() {
        let planned = DayMeal.forDay(mealTypes: household, plannedKeys: ["dinner", MealType.extraKey])
        let otherDay = DayMeal.forDay(mealTypes: household, plannedKeys: ["dinner"])

        #expect(planned.map(\.key) == ["breakfast", "dinner", MealType.extraKey])
        #expect(planned.last?.isExtra == true)
        #expect(otherDay.contains(where: { $0.isExtra }) == false)
    }

    @Test func extrasComeAfterAMealThatOnlyExistsOnEntries() {
        let meals = DayMeal.forDay(
            mealTypes: household,
            plannedKeys: ["dinner", "snack", MealType.extraKey]
        )

        #expect(meals.map(\.key) == ["breakfast", "dinner", "snack", MealType.extraKey])
    }

    @Test func theExtraCardIsNamedAndDrawnLikeAMeal() {
        let meals = DayMeal.forDay(mealTypes: household, plannedKeys: [MealType.extraKey])

        #expect(meals.last?.name == MealType.extraName)
        #expect(meals.last?.symbolName == MealType.extraSymbolName)
        #expect(MealType.legacyName(for: MealType.extraKey) == MealType.extraName)
        #expect(MealType.legacySymbol(for: MealType.extraKey) == MealType.extraSymbolName)
    }

    // MARK: - The extra key never becomes a meal

    @Test func extrasAreNeverBackfilledIntoTheHouseholdsMeals() {
        let keys = MealType.backfillKeys(
            planned: ["dinner", MealType.extraKey, "snack", ""],
            known: ["breakfast", "dinner"]
        )

        // "snack" is a real meal an older build planned into and has to come
        // back; the extra key would put a card on every day of the year.
        #expect(keys == ["snack"])
    }

    @Test func aPlanMadeOnlyOfExtrasNeedsNoNewMeals() {
        let keys = MealType.backfillKeys(
            planned: [MealType.extraKey, MealType.extraKey],
            known: ["breakfast", "dinner"]
        )

        #expect(keys.isEmpty)
    }

    // MARK: - Entries

    @Test func anEntryKnowsItIsAnExtra() {
        let extra = MealPlanEntry(date: .now, mealKey: MealType.extraKey)
        let dinner = MealPlanEntry(date: .now, mealKey: "dinner")

        #expect(extra.isExtra)
        #expect(!dinner.isExtra)
    }

    @Test func draggingAnExtraOntoAnotherDayKeepsItAnExtra() {
        let monday = DeepLink.parseDate("2026-09-14")!

        let plan = MealPlanner.dropPlan(
            from: MealPlanner.DropOrigin(date: monday, mealKey: MealType.extraKey),
            onto: monday.adding(days: 3),
            mealKey: nil
        )

        #expect(plan == .move(date: monday.adding(days: 3), mealKey: MealType.extraKey))
    }

    // MARK: - The planner stripe

    @Test func theExtrasRowDoesNotCountTowardADaysProgress() {
        let slots = household.map { MealStripSlot(key: $0.key, name: $0.name, symbolName: $0.symbolName) }
            + [MealStripSlot(
                key: MealType.extraKey,
                name: MealType.extraName,
                symbolName: MealType.extraSymbolName,
                countsTowardCompletion: false
            )]

        #expect(slots.filter(\.countsTowardCompletion).map(\.key) == ["breakfast", "dinner"])
    }
}
