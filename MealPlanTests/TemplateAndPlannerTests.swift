import Testing
import Foundation
@testable import MealPlan

@MainActor
struct TemplateAndPlannerTests {

    @Test func weekdayIndexMondayIsZero() {
        // 2026-08-31 is a Monday.
        let monday = DeepLink.parseDate("2026-08-31")!
        #expect(TemplateEngine.weekdayIndex(of: monday) == 0)
        #expect(TemplateEngine.weekdayIndex(of: monday.adding(days: 3)) == 3) // Thursday
        #expect(TemplateEngine.weekdayIndex(of: monday.adding(days: 6)) == 6) // Sunday
    }

    @Test func expandPlacesEntriesOnCorrectDates() {
        let template = WeekTemplate(name: "Std")
        for weekday in [0, 2, 4] {
            let te = WeekTemplateEntry(weekday: weekday, slot: .dinner)
            te.servingsOverride = 5
            template.entries = (template.entries ?? []) + [te]
        }

        let targetWeek = DeepLink.parseDate("2026-09-14")! // a Monday
        let planned = TemplateEngine.expand(template, weekStart: targetWeek)

        #expect(planned.count == 3)
        #expect(planned.first?.date == targetWeek)
        #expect(planned.map(\.date).contains(targetWeek.adding(days: 4)))
        #expect(planned.allSatisfy { $0.mealKey == "dinner" && $0.servingsOverride == 5 })
    }
}
