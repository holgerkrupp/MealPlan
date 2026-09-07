import Testing
import Foundation
@testable import MealPlan

/// What the "publish into a calendar" feature remembers, and what it forgets
/// when told to.
@MainActor
struct PublishedCalendarSettingsTests {

    private func makeSettings() -> PublishedCalendarSettings {
        let suite = UserDefaults(suiteName: "de.holgerkrupp.mealplan.tests.\(UUID().uuidString)") ?? .standard
        return PublishedCalendarSettings(defaults: suite)
    }

    @Test
    func startsWithNoDestination() {
        let settings = makeSettings()
        #expect(settings.isPublishing == false)
        #expect(settings.destinationCalendarID == nil)
        #expect(settings.range == .tenWeeks)
        #expect(settings.eventMap.isEmpty)
    }

    @Test
    func choicesSurviveARestart() {
        let suite = UserDefaults(suiteName: "de.holgerkrupp.mealplan.tests.\(UUID().uuidString)") ?? .standard
        let settings = PublishedCalendarSettings(defaults: suite)
        let id = UUID()

        settings.setDestination(calendarID: "family", title: "Family")
        settings.range = .wholeYear
        settings.eventMap = [id: "event-1"]
        settings.markPublished(at: Date(timeIntervalSinceReferenceDate: 1000))

        let reloaded = PublishedCalendarSettings(defaults: suite)
        #expect(reloaded.isPublishing)
        #expect(reloaded.destinationCalendarID == "family")
        #expect(reloaded.destinationCalendarTitle == "Family")
        #expect(reloaded.range == .wholeYear)
        #expect(reloaded.eventMap == [id: "event-1"])
        #expect(reloaded.lastPublishedAt == Date(timeIntervalSinceReferenceDate: 1000))
    }

    @Test
    func clearingForgetsEverything() {
        let settings = makeSettings()
        settings.setDestination(calendarID: "family", title: "Family")
        settings.eventMap = [UUID(): "event-1"]
        settings.markPublished(at: .now)

        settings.clearDestination()

        #expect(settings.isPublishing == false)
        #expect(settings.destinationCalendarID == nil)
        #expect(settings.destinationCalendarTitle == nil)
        #expect(settings.eventMap.isEmpty)
        #expect(settings.lastPublishedAt == nil)
    }
}
