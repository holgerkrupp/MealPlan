import Testing
import Foundation
@testable import MealPlan

/// The store: when the calendar is queried at all, what it caches, and how it
/// behaves when things go wrong.
@MainActor
struct CalendarContextStoreTests {

    private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        CalendarTestHarness.time(hour, minute, dayOffset: dayOffset)
    }

    private func event(
        from start: Date,
        to end: Date,
        id: String = UUID().uuidString,
        calendarID: String = "family"
    ) -> MealCalendarEvent {
        CalendarTestHarness.event(from: start, to: end, id: id, calendarID: calendarID)
    }

    // MARK: - Off by default

    @Test func aDisabledIntegrationNeverTouchesTheCalendar() async {
        let harness = CalendarTestHarness(enabled: false, selected: [])
        await harness.activate()
        await harness.settle()

        let fetches = await harness.provider.fetchCount
        let requests = await harness.provider.requestAccessCount
        let calendars = await harness.provider.calendarsCount
        #expect(fetches == 0)
        #expect(requests == 0)
        #expect(calendars == 0)
        #expect(harness.store.isActive == false)
        #expect(harness.store.context(for: harness.today, mealKey: "dinner", mealName: "Dinner") == nil)
        harness.cleanUp()
    }

    @Test func nothingHappensWithoutASelectedCalendar() async {
        let harness = CalendarTestHarness(
            selected: [],
            events: [event(from: at(17), to: at(18))]
        )
        await harness.activate()
        let fetches = await harness.provider.fetchCount
        #expect(fetches == 0)
        #expect(harness.store.isActive == false)
        harness.cleanUp()
    }

    // MARK: - Fetching

    @Test func anActiveStoreQueriesOnlyTheVisibleWeek() async throws {
        let harness = CalendarTestHarness(
            events: [event(from: at(17, 30), to: at(18, 30))]
        )
        await harness.activate()

        let interval = try #require(await harness.provider.lastInterval)
        #expect(interval.start == harness.week)
        #expect(interval.duration <= 8 * 24 * 60 * 60)

        let context = try #require(
            harness.store.context(for: harness.today, mealKey: "dinner", mealName: "Dinner")
        )
        #expect(context.busyUntil == at(18, 30))
        harness.cleanUp()
    }

    @Test func turningTheFeatureOffStopsEveryQuery() async {
        let harness = CalendarTestHarness(
            events: [event(from: at(17), to: at(18))]
        )
        await harness.activate()
        await harness.settle()
        let before = await harness.provider.fetchCount
        #expect(before >= 1)

        harness.store.disableIntegration()
        harness.store.requestWeek(harness.week)
        await harness.store.refreshNow()
        await harness.settle()

        let after = await harness.provider.fetchCount
        #expect(after == before)
        #expect(harness.store.isActive == false)
        #expect(harness.store.context(for: harness.today, mealKey: "dinner", mealName: "Dinner") == nil)
        // The user's choices survive being switched off.
        #expect(harness.settings.selectedCalendarIdentifiers == ["family"])
        harness.cleanUp()
    }

    @Test func onlySelectedCalendarsContributeEvents() async throws {
        let harness = CalendarTestHarness(
            selected: ["family"],
            events: [
                event(from: at(17), to: at(18), calendarID: "family"),
                event(from: at(19), to: at(20), calendarID: "work"),
            ]
        )
        await harness.activate()

        let identifiers = await harness.provider.lastIdentifiers
        #expect(identifiers == ["family"])
        let context = try #require(
            harness.store.context(for: harness.today, mealKey: "dinner", mealName: "Dinner")
        )
        #expect(context.relevantEvents.count == 1)
        #expect(context.relevantEvents.allSatisfy { $0.calendarIdentifier == "family" })
        harness.cleanUp()
    }

    @Test func eventsOutsideTheVisibleRangeAreIgnored() async {
        let harness = CalendarTestHarness(
            events: [event(from: at(17, dayOffset: 30), to: at(18, dayOffset: 30))]
        )
        await harness.activate()

        #expect(harness.store.events(on: harness.today).isEmpty)
        #expect(harness.store.context(for: harness.today, mealKey: "dinner", mealName: "Dinner") == nil)
        harness.cleanUp()
    }

    @Test func anEventOverMidnightBelongsToBothDays() async {
        let harness = CalendarTestHarness(
            events: [event(from: at(23), to: at(1, dayOffset: 1), id: "night")]
        )
        await harness.activate()

        #expect(harness.store.events(on: harness.today).contains { $0.id == "night" })
        #expect(harness.store.events(on: harness.today.adding(days: 1)).contains { $0.id == "night" })
        harness.cleanUp()
    }

    // MARK: - Permission

    @Test func aDeniedUserIsNeverAskedAgain() async {
        let harness = CalendarTestHarness(status: .denied, enabled: false)
        await harness.store.enableIntegration()
        await harness.store.requestCalendarAccess()
        await harness.store.requestCalendarAccess()

        let requests = await harness.provider.requestAccessCount
        #expect(requests == 0)
        #expect(harness.store.authorization == .denied)
        #expect(harness.store.isActive == false)
        #expect(harness.store.needsAttention)
        harness.cleanUp()
    }

    @Test func restrictedAccessKeepsThePlannerRunning() async {
        let harness = CalendarTestHarness(status: .restricted, enabled: false)
        await harness.store.enableIntegration()
        #expect(harness.store.isActive == false)
        #expect(harness.store.authorization.needsSystemSettings)
        let fetches = await harness.provider.fetchCount
        #expect(fetches == 0)
        harness.cleanUp()
    }

    @Test func writeOnlyAccessIsNotEnoughToReadEvents() async {
        let harness = CalendarTestHarness(status: .writeOnly, enabled: false)
        await harness.store.enableIntegration()
        #expect(harness.store.isActive == false)
        #expect(harness.store.authorization == .writeOnly)
        harness.cleanUp()
    }

    @Test func turningTheFeatureOnDoesNotPromptOnItsOwn() async {
        let harness = CalendarTestHarness(
            status: .notDetermined,
            statusAfterRequest: .fullAccess,
            enabled: false
        )
        await harness.store.enableIntegration()
        var requests = await harness.provider.requestAccessCount
        // The switch alone must never trigger Apple's dialog.
        #expect(requests == 0)
        #expect(harness.store.settings.isEnabled)

        await harness.store.requestCalendarAccess()
        requests = await harness.provider.requestAccessCount
        #expect(requests == 1)
        #expect(harness.store.authorization == .fullAccess)

        // Asking a second time must not reach the system again.
        await harness.store.requestCalendarAccess()
        requests = await harness.provider.requestAccessCount
        #expect(requests == 1)
        harness.cleanUp()
    }

    @Test func aRefusedPromptIsNotRepeated() async {
        let harness = CalendarTestHarness(
            status: .notDetermined,
            statusAfterRequest: .denied,
            enabled: false
        )
        await harness.store.enableIntegration()
        await harness.store.requestCalendarAccess()
        await harness.store.requestCalendarAccess()

        let requests = await harness.provider.requestAccessCount
        #expect(requests == 1)
        #expect(harness.store.authorization == .denied)
        harness.cleanUp()
    }

    @Test func accessRevokedElsewhereDisablesContextButKeepsChoices() async {
        let harness = CalendarTestHarness(
            events: [event(from: at(17), to: at(18))]
        )
        await harness.activate()
        #expect(harness.store.context(for: harness.today, mealKey: "dinner", mealName: "Dinner") != nil)

        await harness.provider.setStatus(.denied)
        await harness.store.applicationBecameActive()

        #expect(harness.store.isActive == false)
        #expect(harness.store.context(for: harness.today, mealKey: "dinner", mealName: "Dinner") == nil)
        #expect(harness.store.events(on: harness.today).isEmpty)
        #expect(harness.settings.selectedCalendarIdentifiers == ["family"])
        #expect(harness.settings.isEnabled)
        harness.cleanUp()
    }

    // MARK: - Failure

    @Test func aFailingCalendarLeavesMealPlanningAlone() async {
        let harness = CalendarTestHarness(
            events: [event(from: at(17), to: at(18))],
            failure: CalendarTestFailure()
        )
        await harness.activate()

        #expect(harness.store.context(for: harness.today, mealKey: "dinner", mealName: "Dinner") == nil)
        #expect(harness.store.events(on: harness.today).isEmpty)
        #expect(harness.store.lastErrorDescription != nil)
        // Recovering needs no restart.
        await harness.provider.setFailure(nil)
        await harness.store.refreshNow()
        #expect(harness.store.context(for: harness.today, mealKey: "dinner", mealName: "Dinner") != nil)
        harness.cleanUp()
    }

    @Test func aVanishedCalendarSelectionSimplyYieldsNoContext() async {
        let harness = CalendarTestHarness(
            selected: ["deleted-calendar"],
            events: [event(from: at(17), to: at(18))]
        )
        await harness.activate()
        #expect(harness.store.context(for: harness.today, mealKey: "dinner", mealName: "Dinner") == nil)
        harness.cleanUp()
    }

    // MARK: - Change observation

    @Test func aCalendarChangeRefreshesTheCache() async {
        let harness = CalendarTestHarness()
        await harness.activate()
        await harness.settle()
        #expect(harness.store.context(for: harness.today, mealKey: "dinner", mealName: "Dinner") == nil)

        await harness.provider.setEvents([
            event(from: at(17), to: at(18))
        ])
        await harness.provider.emitChange()

        var context: MealPlanningContext?
        for _ in 0..<40 {
            context = harness.store.context(for: harness.today, mealKey: "dinner", mealName: "Dinner")
            if context != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(context != nil)
        harness.cleanUp()
    }
}
