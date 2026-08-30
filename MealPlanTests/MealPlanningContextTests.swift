import Testing
import Foundation
@testable import MealPlan

/// The interpretation layer: what a day's events mean for one meal.
struct MealPlanningContextTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }()

    private let dinner = MealTimeWindow.standard(forMealKey: "dinner") // 16:00–21:00

    private func date(day: Int = 15, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 9, day: day, hour: hour, minute: minute
        )) ?? .now
    }

    private func event(
        _ start: Date,
        _ end: Date,
        id: String = UUID().uuidString,
        title: String? = nil,
        allDay: Bool = false,
        calendarID: String = "family",
        availability: MealCalendarAvailability = .busy
    ) -> MealCalendarEvent {
        MealCalendarEvent(
            id: id,
            startDate: start,
            endDate: end,
            isAllDay: allDay,
            displayTitle: title,
            calendarIdentifier: calendarID,
            availability: availability
        )
    }

    private func context(
        _ events: [MealCalendarEvent],
        day: Int = 15,
        window: MealTimeWindow? = nil,
        privacy: CalendarPrivacyMode = .availabilityOnly,
        owners: [String: String] = [:]
    ) -> MealPlanningContext? {
        MealPlanningContextBuilder.context(
            date: date(day: day, 12),
            mealKey: "dinner",
            mealName: "Dinner",
            window: window ?? dinner,
            events: events,
            privacyMode: privacy,
            calendarOwners: owners,
            calendar: calendar
        )
    }

    // MARK: - Nothing to say

    @Test func noEventsMeansNoContext() {
        #expect(context([]) == nil)
    }

    @Test func eventsFarFromTheMealAreIgnored() {
        // 08:00–09:00 is nowhere near the 16:00–21:00 dinner window.
        #expect(context([event(date(8), date(9))]) == nil)
    }

    @Test func eventsOnAnotherDayAreIgnored() {
        #expect(context([event(date(day: 16, 18), date(day: 16, 19))]) == nil)
    }

    // MARK: - Deterministic interpretation

    @Test func oneEventEndingBeforeDinnerReportsWhenItEnds() throws {
        let result = try #require(context([event(date(14), date(15, 30))]))
        #expect(result.busyUntil == date(15, 30))
        #expect(result.busyness == .light)
        #expect(result.isBusyThroughout == false)
        #expect(result.suggestedComplexity == .standard)
    }

    @Test func oneEventOverlappingDinnerReportsWhenItEnds() throws {
        let result = try #require(context([event(date(17, 30), date(18, 30))]))
        #expect(result.busyUntil == date(18, 30))
        #expect(result.relevantEvents.count == 1)
        #expect(result.busyness == .light)
        #expect(result.availableTime == 2.5 * 60 * 60)
    }

    @Test func severalEveningEventsMeanBusy() throws {
        let result = try #require(context([
            event(date(16, 30), date(17, 15)),
            event(date(17, 30), date(18, 15)),
            event(date(19), date(19, 45)),
        ]))
        #expect(result.busyness == .busy)
        #expect(result.suggestedComplexity == .quick)
        #expect(result.relevantEvents.count == 3)
    }

    @Test func anEventCoveringTheWholeWindowLeavesNoTime() throws {
        let result = try #require(context([event(date(15), date(22))]))
        #expect(result.isBusyThroughout)
        #expect(result.busyUntil == nil)
        #expect(result.availableTime == 0)
        #expect(result.busyness == .busy)
        #expect(result.suggestedComplexity == .quick)
    }

    @Test func anEventRunningPastTheWindowReportsWhenItStarts() throws {
        let result = try #require(context([event(date(20), date(23))]))
        #expect(result.busyFrom == date(20))
        #expect(result.busyUntil == nil)
    }

    @Test func freeTimeEventsDoNotCountAsBusy() throws {
        let result = try #require(context([
            event(date(17), date(18), availability: .free)
        ]))
        #expect(result.busyIntervals.isEmpty)
        #expect(result.busyUntil == nil)
        #expect(result.busyness == .light)
    }

    @Test func overlappingEventsMergeIntoOneBusyStretch() throws {
        let result = try #require(context([
            event(date(17), date(18, 30)),
            event(date(18), date(19)),
        ]))
        #expect(result.busyIntervals.count == 1)
        #expect(result.busyUntil == date(19))
    }

    @Test func duplicateEventsAreCountedOnce() throws {
        let duplicate = event(date(17), date(18), id: "same")
        let result = try #require(context([duplicate, duplicate]))
        #expect(result.relevantEvents.count == 1)
        #expect(result.busyIntervals.count == 1)
        #expect(result.detailLines.count == 1)
    }

    @Test func eventsSpanningMidnightAreHandled() throws {
        // A late meal window, so the event that starts at 23:00 is relevant.
        let lateSupper = MealTimeWindow(startHour: 20, endHour: 23, endMinute: 30)
        let result = try #require(context(
            [event(date(23), date(day: 16, 1))],
            window: lateSupper
        ))
        #expect(result.busyFrom == date(23))
        #expect(result.isBusyThroughout == false)
    }

    @Test func allDayEventsDoNotOverwhelmTheContext() throws {
        let all = (0..<6).map { index in
            event(
                date(0),
                date(day: 16, 0),
                id: "allday-\(index)",
                allDay: true
            )
        }
        let result = try #require(context(all))
        #expect(result.allDayEvents.count == MealPlanningContextBuilder.maxAllDayEvents)
        #expect(result.detailLines.count == MealPlanningContextBuilder.maxAllDayEvents)
        // All-day events say nothing about the time around the meal.
        #expect(result.busyness == .clear)
        #expect(result.busyIntervals.isEmpty)
    }

    @Test func timedEventListIsCapped() throws {
        let many = (0..<9).map { index in
            event(date(16 + index / 3, (index % 3) * 15), date(16 + index / 3, (index % 3) * 15 + 10), id: "e\(index)")
        }
        let result = try #require(context(many))
        #expect(result.detailLines.count <= MealPlanningContextBuilder.maxDetailLines)
    }

    @Test func eventsFromAnotherTimeZoneUseAbsoluteTime() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        // 15:30–16:30 UTC is 17:30–18:30 in Berlin — inside the dinner window.
        let start = try #require(utc.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 15, minute: 30)))
        let end = try #require(utc.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 16, minute: 30)))
        let result = try #require(context([event(start, end)]))
        #expect(result.busyUntil == end)
        #expect(result.busyUntil == date(18, 30))
    }

    // MARK: - Meal windows

    @Test func breakfastUsesItsOwnWindow() throws {
        let result = MealPlanningContextBuilder.context(
            date: date(12),
            mealKey: "breakfast",
            mealName: "Breakfast",
            window: .standard(forMealKey: "breakfast"),
            events: [event(date(7, 30), date(8, 15))],
            privacyMode: .availabilityOnly,
            calendar: calendar
        )
        let breakfast = try #require(result)
        #expect(breakfast.busyUntil == date(8, 15))
        // The same event says nothing about dinner.
        #expect(context([event(date(7, 30), date(8, 15))]) == nil)
    }

    @Test func aCustomWindowMovesWhatCounts() throws {
        let lateDinner = MealTimeWindow(startHour: 19, endHour: 22)
        #expect(context([event(date(16), date(17))], window: lateDinner) == nil)
        let result = try #require(context([event(date(19, 30), date(20))], window: lateDinner))
        #expect(result.busyUntil == date(20))
    }

    // MARK: - People (optional mapping)

    @Test func mappedCalendarsBecomePerPersonAvailability() throws {
        let result = try #require(context(
            [
                event(date(17), date(18), calendarID: "emma"),
                event(date(15), date(22), calendarID: "alex"),
            ],
            owners: ["emma": "Emma", "alex": "Alex"]
        ))
        let emma = try #require(result.householdAvailability.first { $0.name == "Emma" })
        let alex = try #require(result.householdAvailability.first { $0.name == "Alex" })
        #expect(emma.state == .partlyBusy)
        #expect(emma.freeFrom == date(18))
        #expect(alex.state == .busyThroughout)
        // Nothing claims anyone is "away" — only that their time is taken.
        #expect(alex.freeFrom == nil)
    }

    @Test func peopleFreeAtDifferentTimesAreStaggered() throws {
        let result = try #require(context(
            [
                event(date(16), date(17), calendarID: "emma"),
                event(date(16), date(18, 30), calendarID: "alex"),
            ],
            owners: ["emma": "Emma", "alex": "Alex"]
        ))
        #expect(result.hasStaggeredAvailability)
    }

    @Test func contextWorksWithoutAnyPersonMapping() throws {
        let result = try #require(context([event(date(17), date(18))]))
        #expect(result.householdAvailability.isEmpty)
        #expect(result.hasStaggeredAvailability == false)
    }

    // MARK: - Recommendation input

    @Test func recommendationContextMirrorsTheDerivedFacts() throws {
        let result = try #require(context([event(date(17, 30), date(18, 30))]))
        let recommendation = result.recommendationContext
        #expect(recommendation.mealKey == "dinner")
        #expect(recommendation.scheduleBusyness == .light)
        #expect(recommendation.availableCookingTime == 2.5 * 60 * 60)
        #expect(recommendation.suggestedComplexity == .standard)
    }
}
