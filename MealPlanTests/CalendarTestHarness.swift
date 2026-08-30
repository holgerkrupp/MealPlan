import Foundation
@testable import MealPlan

/// Wires a `CalendarContextStore` to a mock provider and a throwaway
/// `UserDefaults`, so every test starts from a clean, calendar-free world.
@MainActor
final class CalendarTestHarness {

    static let familyCalendar = MealCalendarInfo(id: "family", title: "Family", sourceTitle: "iCloud")
    static let workCalendar = MealCalendarInfo(id: "work", title: "Work", sourceTitle: "Exchange")
    static let kidsCalendar = MealCalendarInfo(id: "kids", title: "Kids", sourceTitle: "iCloud")

    let settings: CalendarIntegrationSettings
    let provider: MockCalendarProvider
    let store: CalendarContextStore
    private let defaults: UserDefaults
    private let suiteName: String

    init(
        status: CalendarAuthorization = .fullAccess,
        statusAfterRequest: CalendarAuthorization? = nil,
        enabled: Bool = true,
        selected: Set<String> = ["family"],
        privacy: CalendarPrivacyMode = .availabilityOnly,
        events: [MealCalendarEvent] = [],
        calendars: [MealCalendarInfo]? = nil,
        failure: (any Error)? = nil,
        leaksTitles: Bool = false
    ) {
        suiteName = "de.holgerkrupp.mealplan.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        settings = CalendarIntegrationSettings(defaults: defaults)
        settings.isEnabled = enabled
        settings.selectedCalendarIdentifiers = selected
        settings.privacyMode = privacy
        provider = MockCalendarProvider(
            status: status,
            statusAfterRequest: statusAfterRequest,
            calendars: calendars ?? [Self.familyCalendar, Self.workCalendar, Self.kidsCalendar],
            events: events,
            failure: failure,
            leaksTitles: leaksTitles
        )
        store = CalendarContextStore(settings: settings, provider: provider)
    }

    /// Removes the throwaway defaults suite. Optional — each harness uses a
    /// fresh, uniquely named one.
    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var today: Date { Date.now.startOfDay }
    var week: Date { Date.now.startOfWeek() }

    /// Bring the store to the state the planner puts it in: started, showing
    /// this week, events loaded.
    func activate() async {
        await store.start()
        store.requestWeek(week)
        await store.refreshNow()
    }

    /// Let any debounced refresh finish, so fetch counts are stable.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - Building events relative to today

    static func time(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let day = Date.now.startOfDay.adding(days: dayOffset)
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    static func event(
        from start: Date,
        to end: Date,
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
}
