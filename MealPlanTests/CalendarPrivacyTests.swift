import Testing
import Foundation
@testable import MealPlan

/// The promises the feature makes about what may be seen.
struct CalendarPrivacyTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }()

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: hour, minute: minute)) ?? .now
    }

    private func football() -> MealCalendarEvent {
        MealCalendarEvent(
            id: "football",
            startDate: date(16, 30),
            endDate: date(17, 30),
            displayTitle: "Football practice",
            calendarIdentifier: "kids"
        )
    }

    private func context(_ privacy: CalendarPrivacyMode) -> MealPlanningContext? {
        MealPlanningContextBuilder.context(
            date: date(12),
            mealKey: "dinner",
            mealName: "Dinner",
            window: .standard(forMealKey: "dinner"),
            events: [football()],
            privacyMode: privacy,
            calendar: calendar
        )
    }

    /// Every string the planner could show for this context.
    private func allText(_ context: MealPlanningContext) -> [String] {
        var text = [context.summary, context.accessibilitySummary, context.mealName]
        text += context.detailLines.flatMap { [$0.title ?? "", $0.timeText, $0.spokenText] }
        text += context.relevantEvents.map { $0.displayTitle ?? "" }
        text += context.allDayEvents.map { $0.displayTitle ?? "" }
        text += context.householdAvailability.map(\.localizedSummary)
        return text
    }

    @Test func availabilityOnlyNeverShowsATitle() throws {
        let result = try #require(context(.availabilityOnly))
        #expect(result.relevantEvents.allSatisfy { $0.displayTitle == nil })
        #expect(result.detailLines.allSatisfy { $0.title == nil })
        for text in allText(result) {
            #expect(text.localizedCaseInsensitiveContains("Football") == false)
        }
    }

    @Test func eventTitlesModeMayShowTheTitle() throws {
        let result = try #require(context(.eventTitles))
        #expect(result.relevantEvents.first?.displayTitle == "Football practice")
        #expect(result.detailLines.contains { $0.title == "Football practice" })
    }

    @Test func theDomainEventHasNowhereToPutSensitiveDetail() {
        let event = MealCalendarEvent(
            id: "1",
            startDate: .now,
            endDate: .now,
            calendarIdentifier: "c"
        )
        let fields = Set(Mirror(reflecting: event).children.compactMap(\.label))
        #expect(fields == [
            "id", "startDate", "endDate", "isAllDay",
            "displayTitle", "calendarIdentifier", "availability",
        ])
    }

    /// The same football practice, but on today so the store's week query
    /// covers it.
    @MainActor
    private func footballToday() -> MealCalendarEvent {
        CalendarTestHarness.event(
            from: CalendarTestHarness.time(16, 30),
            to: CalendarTestHarness.time(17, 30),
            id: "football",
            title: "Football practice",
            calendarID: "kids"
        )
    }

    @MainActor
    @Test func availabilityOnlyDoesNotEvenAskForTitles() async {
        let harness = CalendarTestHarness(events: [footballToday()], selected: ["kids"])
        await harness.activate()
        let askedInAvailabilityMode = await harness.provider.lastIncludeTitles
        #expect(askedInAvailabilityMode == false)

        harness.settings.privacyMode = .eventTitles
        harness.store.settingsChanged()
        await harness.store.refreshNow()
        let askedInTitleMode = await harness.provider.lastIncludeTitles
        #expect(askedInTitleMode == true)
        harness.cleanUp()
    }

    @MainActor
    @Test func titlesAreStrippedEvenIfTheProviderHandsThemOver() async throws {
        // A provider that ignores `includeTitles` must still not leak titles
        // into the planner.
        let harness = CalendarTestHarness(events: [footballToday()], selected: ["kids"], leaksTitles: true)
        await harness.activate()

        let result = try #require(harness.store.context(
            for: harness.today,
            mealKey: "dinner",
            mealName: "Dinner"
        ))
        #expect(result.relevantEvents.allSatisfy { $0.displayTitle == nil })
        for text in allText(result) {
            #expect(text.localizedCaseInsensitiveContains("Football") == false)
        }
        harness.cleanUp()
    }
}
