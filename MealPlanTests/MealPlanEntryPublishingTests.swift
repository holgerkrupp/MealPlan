import Testing
import Foundation
@testable import MealPlan

/// Covers `MealPlanEntry.publishedSummary`/`publishedNotes` — the single
/// place that decides what a published meal is called, shared by the `.ics`
/// snapshot exporter and by writing straight into a calendar.
@MainActor
struct MealPlanEntryPublishingTests {

    private func dinner() -> MealType { MealType(key: "dinner", name: "Dinner") }
    private func mealsByKey(_ types: MealType...) -> [String: MealType] {
        Dictionary(uniqueKeysWithValues: types.map { ($0.key, $0) })
    }

    private func entry(mealKey: String = "dinner", dishName: String? = "Chili") -> MealPlanEntry {
        let dish = dishName.map { Dish(name: $0) }
        return MealPlanEntry(date: .now, mealKey: mealKey, dish: dish)
    }

    @Test
    func summaryNamesTheMealAndTheDish() {
        let summary = entry().publishedSummary(mealTypesByKey: mealsByKey(dinner()))
        #expect(summary == "Dinner: Chili")
    }

    @Test
    func extraIsNamedByTheDishAlone() {
        let e = entry(mealKey: MealType.extraKey, dishName: "Birthday cake")
        #expect(e.publishedSummary(mealTypesByKey: mealsByKey(dinner())) == "Birthday cake")
    }

    @Test
    func aDeletedMealFallsBackToAGenericName() {
        let summary = entry(mealKey: "gone").publishedSummary(mealTypesByKey: [:])
        #expect(summary == "Meal: Chili")
    }

    @Test
    func withNoNoteAndNotEatingOutThereIsNoDescription() {
        #expect(entry().publishedNotes() == nil)
    }

    @Test
    func noteBecomesTheDescription() {
        let e = entry()
        e.note = "Defrost the mince the night before"
        #expect(e.publishedNotes() == "Defrost the mince the night before")
    }

    @Test
    func eatingOutAddsThePlaceAndAddress() {
        // A dish stays set alongside "eating out" in the domain model even
        // though the UI doesn't offer that combination — used here just to
        // give the entry a title that differs from the place, so both lines
        // show up rather than the place being folded into an equal title.
        let e = entry(dishName: "Pizza Night")
        e.isEatingOut = true
        e.placeName = "Trattoria Milano"
        e.placeAddress = "12 Via Roma"
        #expect(e.publishedNotes() == "Trattoria Milano\n12 Via Roma")
    }

    @Test
    func eatingOutDoesNotRepeatThePlaceNameIfItIsAlreadyTheTitle() {
        let e = entry(dishName: nil)
        e.isEatingOut = true
        e.placeName = "Trattoria Milano"
        #expect(e.publishedNotes() == nil)
    }
}
