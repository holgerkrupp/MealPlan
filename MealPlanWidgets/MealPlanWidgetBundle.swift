import WidgetKit
import SwiftUI

@main
struct MealPlanWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayMealsWidget()
        WeekMealsWidget()
        UpcomingMealsWidget()
        #if os(iOS)
        CookingTimerLiveActivity()
        #endif
    }
}
