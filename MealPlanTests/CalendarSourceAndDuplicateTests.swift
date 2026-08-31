import Testing
import Foundation
@testable import MealPlan

/// Where a calendar entry came from — its calendar's name and colour — and the
/// guarantee that one appointment is only ever shown once.
struct CalendarSourceAndDuplicateTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }()

    private let familyColor = MealCalendarColor(red: 1, green: 0.2, blue: 0.2)
    private let workColor = MealCalendarColor(red: 0.2, green: 0.4, blue: 1)

    private var calendars: [String: MealCalendarInfo] {
        [
            "family": MealCalendarInfo(id: "family", title: "Family", sourceTitle: "iCloud", color: familyColor),
            "work": MealCalendarInfo(id: "work", title: "Work", sourceTitle: "Exchange", color: workColor),
        ]
    }

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
        sharedIdentifier: String? = nil
    ) -> MealCalendarEvent {
        MealCalendarEvent(
            id: id,
            startDate: start,
            endDate: end,
            isAllDay: allDay,
            displayTitle: title,
            calendarIdentifier: calendarID,
            availability: .busy,
            sharedIdentifier: sharedIdentifier
        )
    }

    private func context(
        _ events: [MealCalendarEvent],
        mealKey: String = "dinner",
        mealName: String = "Dinner",
        privacy: CalendarPrivacyMode = .availabilityOnly
    ) -> MealPlanningContext? {
        MealPlanningContextBuilder.context(
            date: date(12),
            mealKey: mealKey,
            mealName: mealName,
            window: .standard(forMealKey: mealKey),
            events: events,
            privacyMode: privacy,
            calendars: calendars,
            calendar: calendar
        )
    }

    // MARK: - Calendar name and colour

    @Test func detailLineNamesAndColoursItsCalendar() throws {
        let result = try #require(context([event(date(17), date(18), calendarID: "work")]))
        let line = try #require(result.detailLines.first)
        #expect(line.calendarNames == ["Work"])
        #expect(line.calendarText == "Work")
        #expect(line.calendarColor == workColor)
    }

    @Test func calendarNameIsShownEvenWhenTitlesAreHidden() throws {
        let result = try #require(context(
            [event(date(17), date(18), title: "Dentist", calendarID: "family")],
            privacy: .availabilityOnly
        ))
        let line = try #require(result.detailLines.first)
        #expect(line.title == nil)
        #expect(line.calendarNames == ["Family"])
    }

    @Test func busyMealNamesTheCalendarsBehindIt() throws {
        let result = try #require(context([
            event(date(16), date(19), calendarID: "work"),
            event(date(19), date(20), calendarID: "family"),
        ]))
        #expect(result.busyness == .busy)
        #expect(result.busyCalendarNames == ["Work", "Family"])
    }

    @Test func freeEventsAreNotCountedAsBusyCalendars() throws {
        let free = MealCalendarEvent(
            id: "free",
            startDate: date(17),
            endDate: date(18),
            calendarIdentifier: "work",
            availability: .free
        )
        let result = try #require(context([free]))
        #expect(result.busyCalendarNames.isEmpty)
    }

    @Test func anUnknownCalendarStillProducesALine() throws {
        let result = try #require(context([event(date(17), date(18), calendarID: "gone")]))
        let line = try #require(result.detailLines.first)
        #expect(line.calendarNames.isEmpty)
        #expect(line.calendarText == nil)
    }

    // MARK: - Duplicates

    @Test func theSameAppointmentInTwoCalendarsIsListedOnce() throws {
        // What EventKit hands back for an invitation that landed in both
        // calendars: different event identifiers, one shared external id.
        let shared = "invitation-42"
        let result = try #require(context([
            event(date(17), date(18), id: "family-copy", calendarID: "family", sharedIdentifier: shared),
            event(date(17), date(18), id: "work-copy", calendarID: "work", sharedIdentifier: shared),
        ]))
        #expect(result.relevantEvents.count == 1)
        #expect(result.detailLines.count == 1)
        let line = try #require(result.detailLines.first)
        // …but the user still sees that it is in both.
        #expect(line.calendarNames == ["Family", "Work"])
    }

    @Test func duplicatesDoNotInflateBusyness() throws {
        let shared = "standup"
        let copies = ["family", "work"].map {
            event(date(17), date(17, 30), id: "\($0)-copy", calendarID: $0, sharedIdentifier: shared)
        }
        let result = try #require(context(copies))
        #expect(result.busyIntervals.count == 1)
        // One short appointment is not a busy evening — counting the copy
        // separately used to push it towards the "busy" threshold.
        #expect(result.busyness == .light)
    }

    @Test func differentAppointmentsAtTheSameTimeStayApart() throws {
        let result = try #require(context([
            event(date(17), date(18), id: "a", calendarID: "family", sharedIdentifier: "a"),
            event(date(17), date(18), id: "b", calendarID: "work", sharedIdentifier: "b"),
        ]))
        #expect(result.relevantEvents.count == 2)
        #expect(result.detailLines.count == 2)
    }

    @Test func repeatingOccurrencesStayDistinct() throws {
        // Every occurrence of a repeating event shares one external identifier,
        // so the start time has to be part of the identity.
        let result = try #require(context([
            event(date(16), date(16, 30), id: "a", sharedIdentifier: "weekly"),
            event(date(18), date(18, 30), id: "b", sharedIdentifier: "weekly"),
        ]))
        #expect(result.relevantEvents.count == 2)
    }

    // MARK: - All-day events belong to the day, not to each meal

    @Test func anAllDayEventIsListedOncePerDay() throws {
        let holiday = event(
            date(0), date(day: 16, 0),
            id: "holiday", title: "School holiday", allDay: true,
            sharedIdentifier: "holiday"
        )
        let contexts = ["breakfast", "lunch", "dinner"].compactMap {
            context([holiday], mealKey: $0, mealName: $0.capitalized, privacy: .eventTitles)
        }
        // The builder does give every meal the day's all-day event…
        #expect(contexts.count == 3)

        // …and the day summary collapses them back into one entry.
        let summary = MealCalendarDaySummary(contexts: contexts)
        #expect(summary.allDayLines.count == 1)
        #expect(summary.allDayLines.first?.title == "School holiday")
        // Nothing timed happened, so no meal gets a chip of its own.
        #expect(summary.mealContexts.isEmpty)
        #expect(summary.chips.count == 1)
    }

    @Test func mealsWithTheirOwnEventsStillGetTheirOwnChip() throws {
        let holiday = event(
            date(0), date(day: 16, 0),
            id: "holiday", allDay: true, sharedIdentifier: "holiday"
        )
        let training = event(date(17), date(18, 30), id: "training", sharedIdentifier: "training")
        let contexts = [
            context([holiday], mealKey: "lunch", mealName: "Lunch"),
            context([holiday, training], mealKey: "dinner", mealName: "Dinner"),
        ].compactMap { $0 }

        let summary = MealCalendarDaySummary(contexts: contexts)
        #expect(summary.allDayLines.count == 1)
        #expect(summary.mealContexts.map(\.mealName) == ["Dinner"])
        // One all-day chip plus the dinner chip — the all-day event is not
        // repeated under lunch.
        #expect(summary.chips.count == 2)
    }

    @Test func aDayWithoutAnyCalendarContentHasNoRow() {
        #expect(MealCalendarDaySummary(contexts: []).isEmpty)
    }
}
