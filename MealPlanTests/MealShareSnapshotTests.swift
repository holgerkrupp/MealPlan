import Foundation
import Testing
@testable import MealPlan

@MainActor
struct MealShareSnapshotTests {
    @Test func countsCookedAndPlannedMealsWithoutDuplicatingNutrition() throws {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        let household = Household(name: "Home")

        let pasta = Dish(name: "Pasta")
        pasta.household = household
        pasta.setStatedNutritionPerServing(
            NutritionFacts(energyKcal: 600, proteinGrams: 20, carbGrams: 80, fatGrams: 15)
        )
        let soup = Dish(name: "Soup")
        soup.household = household
        soup.setStatedNutritionPerServing(
            NutritionFacts(energyKcal: 400, proteinGrams: 10, carbGrams: 45, fatGrams: 12)
        )

        let cookedEntry = MealPlanEntry(date: today, dish: pasta)
        cookedEntry.household = household
        let cooked = CookedLog(date: today, dish: pasta, servings: 2)
        cooked.household = household
        cooked.entry = cookedEntry
        cookedEntry.cookedLog = cooked

        let planned = MealPlanEntry(date: today, dish: soup)
        planned.household = household

        let snapshot = MealShareSnapshot.make(
            logs: [cooked],
            entries: [cookedEntry, planned],
            householdID: household.uuid,
            period: .week,
            date: today,
            calendar: calendar
        )

        #expect(snapshot.cookedCount == 1)
        #expect(snapshot.plannedCount == 2)
        #expect(snapshot.uniqueMealCount == 2)
        #expect(snapshot.nutritionMealCount == 2)
        #expect(snapshot.averageNutrition?.energyKcal == 500)
        #expect(snapshot.rankings.first?.name == "Pasta")
        #expect(snapshot.rankings.first?.cookedCount == 1)
        #expect(snapshot.rankings.first?.plannedCount == 1)
        #expect(snapshot.calendarDays.count == 1)
        #expect(snapshot.calendarDays.first?.meals.count == 2)
        #expect(snapshot.calendarDays.first?.nutrition?.energyKcal == 1_000)
    }

    @Test func excludesOtherHouseholdsAndBuildsTwelveYearBuckets() {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        let home = Household(name: "Home")
        let elsewhere = Household(name: "Elsewhere")

        let ownDish = Dish(name: "Own")
        ownDish.household = home
        ownDish.setStatedNutritionPerServing(NutritionFacts(energyKcal: 450))
        let otherDish = Dish(name: "Other")
        otherDish.household = elsewhere
        otherDish.setStatedNutritionPerServing(NutritionFacts(energyKcal: 900))

        let own = MealPlanEntry(date: today, dish: ownDish)
        own.household = home
        let other = MealPlanEntry(date: today, dish: otherDish)
        other.household = elsewhere

        let snapshot = MealShareSnapshot.make(
            logs: [],
            entries: [own, other],
            householdID: home.uuid,
            period: .year,
            date: today,
            calendar: calendar
        )

        #expect(snapshot.plannedCount == 1)
        #expect(snapshot.uniqueMealCount == 1)
        #expect(snapshot.averageNutrition?.energyKcal == 450)
        #expect(snapshot.nutritionPoints.count == 12)
        #expect(snapshot.calendarDays.first?.meals.map(\.name) == ["Own"])
    }
}
