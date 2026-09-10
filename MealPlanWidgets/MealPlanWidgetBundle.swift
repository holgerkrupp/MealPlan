import WidgetKit
import SwiftUI

@main
struct MealPlanWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayMealsWidget()
        WeekMealsWidget()
        UpcomingMealsWidget()
        ShoppingListWidget()
        #if os(iOS)
        CookingTimerLiveActivity()
        #endif
    }
}
