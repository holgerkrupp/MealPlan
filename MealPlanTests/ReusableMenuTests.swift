import Foundation
import Testing

@MainActor
struct ReusableMenuTests {
    @Test func menuPreviewReportsMissingDishesAndExistingMeals() {
        let household = Household(name: "Test")
        let pasta = Dish(name: "Pasta")
        let missing = UUID()
        let menu = ReusableMenu(name: "Weeknight", items: [
            .init(dishID: pasta.uuid, servings: 2, mealKey: MealSlot.dinner.rawValue),
            .init(dishID: missing, servings: nil, mealKey: nil)
        ])
        let entry = MealPlanEntry(date: .now, slot: .lunch, dish: pasta)
        entry.household = household
        let preview = ReusableMenuStore.preview(menu, on: .now, dishes: [pasta], entries: [entry])
        #expect(preview.existingCount == 1)
        #expect(preview.availableItems == 1)
        #expect(preview.missingDishIDs == [missing])
    }

    @Test func menuPayloadRoundTripsOnHousehold() {
        let household = Household(name: "Test")
        let menu = ReusableMenu(name: "Family favourites", items: [.init(dishID: UUID(), servings: 4, mealKey: nil)])
        household.reusableMenus = [menu]
        #expect(household.reusableMenus == [menu])
        #expect(household.reusableMenusData != nil)
    }
}
