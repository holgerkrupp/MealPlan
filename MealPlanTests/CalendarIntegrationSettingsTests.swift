import Testing
import Foundation
@testable import MealPlan

/// What the app remembers about calendar integration — and what it refuses to
/// decide on the user's behalf.
@MainActor
struct CalendarIntegrationSettingsTests {

    private func makeSettings() -> CalendarIntegrationSettings {
        let suite = UserDefaults(suiteName: "de.holgerkrupp.mealplan.tests.\(UUID().uuidString)") ?? .standard
        return CalendarIntegrationSettings(defaults: suite)
    }

    @Test func integrationIsOffAndEmptyByDefault() {
        let settings = makeSettings()
        #expect(settings.isEnabled == false)
        #expect(settings.selectedCalendarIdentifiers.isEmpty)
        #expect(settings.privacyMode == .availabilityOnly)
        #expect(settings.calendarOwners.isEmpty)
    }

    @Test func choicesSurviveARestart() {
        let suite = UserDefaults(suiteName: "de.holgerkrupp.mealplan.tests.\(UUID().uuidString)") ?? .standard
        let settings = CalendarIntegrationSettings(defaults: suite)
        settings.isEnabled = true
        settings.selectedCalendarIdentifiers = ["family", "kids"]
        settings.privacyMode = .eventTitles
        settings.setWindow(MealTimeWindow(startHour: 17, endHour: 20), forMealKey: "dinner")
        settings.setOwner("Emma", for: "kids")

        let reloaded = CalendarIntegrationSettings(defaults: suite)
        #expect(reloaded.isEnabled)
        #expect(reloaded.selectedCalendarIdentifiers == ["family", "kids"])
        #expect(reloaded.privacyMode == .eventTitles)
        #expect(reloaded.window(forMealKey: "dinner") == MealTimeWindow(startHour: 17, endHour: 20))
        #expect(reloaded.owner(of: "kids") == "Emma")
    }

    @Test func mealsFallBackToTheirStandardWindow() {
        let settings = makeSettings()
        #expect(settings.window(forMealKey: "dinner") == .standard(forMealKey: "dinner"))
        settings.setWindow(MealTimeWindow(startHour: 18, endHour: 20), forMealKey: "dinner")
        #expect(settings.window(forMealKey: "dinner").startMinutes == 18 * 60)
        settings.resetWindow(forMealKey: "dinner")
        #expect(settings.window(forMealKey: "dinner") == .standard(forMealKey: "dinner"))
    }

    @Test func aWindowAlwaysEndsAfterItStarts() {
        let window = MealTimeWindow(startHour: 20, endHour: 8)
        #expect(window.endMinutes > window.startMinutes)
    }

    @Test func newlyDiscoveredCalendarsAreNotSelected() {
        let settings = makeSettings()
        settings.selectedCalendarIdentifiers = ["family"]
        settings.reconcile(with: [
            CalendarTestHarness.familyCalendar,
            CalendarTestHarness.workCalendar,
        ])
        #expect(settings.selectedCalendarIdentifiers == ["family"])
    }

    @Test func disappearedCalendarsAreForgotten() {
        let settings = makeSettings()
        settings.selectedCalendarIdentifiers = ["family", "gone"]
        settings.setOwner("Emma", for: "gone")
        settings.reconcile(with: [CalendarTestHarness.familyCalendar])
        #expect(settings.selectedCalendarIdentifiers == ["family"])
        #expect(settings.owner(of: "gone") == nil)
    }

    @Test func selectAllAndSelectNoneAreExplicitActions() {
        let settings = makeSettings()
        let calendars = [CalendarTestHarness.familyCalendar, CalendarTestHarness.workCalendar]
        settings.selectAll(calendars)
        #expect(settings.selectedCalendarIdentifiers == ["family", "work"])
        settings.selectNone()
        #expect(settings.selectedCalendarIdentifiers.isEmpty)
    }

    @Test func onlySelectedCalendarsCarryAPersonMapping() {
        let settings = makeSettings()
        settings.selectedCalendarIdentifiers = ["family"]
        settings.setOwner("Emma", for: "family")
        settings.setOwner("Alex", for: "work")
        #expect(settings.activeCalendarOwners == ["family": "Emma"])
    }

    @Test func authorizationStatesDriveTheRightUI() {
        #expect(CalendarAuthorization.notDetermined.canRequestAccess)
        #expect(CalendarAuthorization.notDetermined.canReadEvents == false)
        #expect(CalendarAuthorization.fullAccess.canReadEvents)
        #expect(CalendarAuthorization.fullAccess.needsSystemSettings == false)
        for status in [CalendarAuthorization.denied, .restricted, .writeOnly, .unknown] {
            #expect(status.canReadEvents == false)
            #expect(status.canRequestAccess == false)
            #expect(status.needsSystemSettings)
            #expect(status.localizedExplanation != nil)
        }
    }
}
