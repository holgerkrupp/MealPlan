import SwiftUI

/// Calendar context for `#Preview`s. Nothing here touches EventKit or the
/// user's real defaults — the whole feature is driven by canned events, so a
/// preview shows the busy-evening case that is the reason the feature exists.
enum PreviewCalendar {

    static let familyID = "preview.family"
    static let workID = "preview.work"

    static let calendars: [MealCalendarInfo] = [
        MealCalendarInfo(
            id: familyID,
            title: "Familie",
            sourceTitle: "iCloud",
            color: MealCalendarColor(red: 0.20, green: 0.62, blue: 0.95, alpha: 1)
        ),
        MealCalendarInfo(
            id: workID,
            title: "Arbeit",
            sourceTitle: "Gmail",
            color: MealCalendarColor(red: 0.95, green: 0.45, blue: 0.20, alpha: 1)
        ),
    ]

    /// A busy late afternoon and one all-day event, on today.
    static var events: [MealCalendarEvent] {
        let day = Date.now.startOfDay
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            Calendar.current.date(byAdding: .minute, value: hour * 60 + minute, to: day) ?? day
        }
        return [
            MealCalendarEvent(
                id: "preview.training",
                startDate: at(16, 30),
                endDate: at(18, 15),
                displayTitle: "Fußballtraining",
                calendarIdentifier: familyID
            ),
            MealCalendarEvent(
                id: "preview.call",
                startDate: at(18, 30),
                endDate: at(19, 0),
                displayTitle: "Team-Call",
                calendarIdentifier: workID
            ),
            MealCalendarEvent(
                id: "preview.holiday",
                startDate: day,
                endDate: day.adding(days: 1),
                isAllDay: true,
                displayTitle: "Ferien",
                calendarIdentifier: familyID,
                availability: .free
            ),
        ]
    }

    /// Settings backed by a throwaway defaults suite, so previews never write
    /// into the real `UserDefaults` — calendar choices are personal, and a
    /// preview must not be able to change them.
    @MainActor
    static func settings() -> CalendarIntegrationSettings {
        let suite = "de.holgerkrupp.mealplan.previews"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let settings = CalendarIntegrationSettings(defaults: defaults)
        settings.isEnabled = true
        settings.selectedCalendarIdentifiers = Set(calendars.map(\.id))
        settings.privacyMode = .eventTitles
        return settings
    }

    @MainActor
    static func store() -> CalendarContextStore {
        CalendarContextStore(
            settings: settings(),
            provider: PreviewCalendarProvider(calendars: calendars, events: events)
        )
    }

    /// The day's context, built straight from the canned events — for the
    /// views that take a summary rather than reading the store.
    @MainActor
    static var summary: MealCalendarDaySummary {
        let day = Date.now.startOfDay
        let settings = settings()
        let calendarsByID = Dictionary(uniqueKeysWithValues: calendars.map { ($0.id, $0) })
        let contexts = PreviewData.dayMeals.compactMap { meal in
            MealPlanningContextBuilder.context(
                date: day,
                mealKey: meal.key,
                mealName: meal.name,
                window: settings.window(forMealKey: meal.key),
                events: events,
                privacyMode: .eventTitles,
                calendars: calendarsByID
            )
        }
        return MealCalendarDaySummary(contexts: contexts)
    }
}

/// A stand-in for EventKit that answers from a fixed list.
struct PreviewCalendarProvider: CalendarEventProviding {
    var calendars: [MealCalendarInfo]
    var events: [MealCalendarEvent]

    var changes: AsyncStream<Void> { AsyncStream { $0.finish() } }

    func authorization() async -> CalendarAuthorization { .fullAccess }
    func requestAccess() async -> CalendarAuthorization { .fullAccess }
    func availableCalendars() async throws -> [MealCalendarInfo] { calendars }

    func events(
        in interval: DateInterval,
        calendarIdentifiers: Set<String>,
        includeTitles: Bool
    ) async throws -> [MealCalendarEvent] {
        events
            .filter { calendarIdentifiers.contains($0.calendarIdentifier) }
            .filter { $0.intersects(interval) }
            .map { includeTitles ? $0 : $0.withoutTitle() }
    }
}

/// Wraps a preview in a live `CalendarContextStore` — the store loads its
/// calendars asynchronously, so it can't simply be handed to `.environment`
/// fully formed.
@MainActor
struct PreviewCalendarHost<Content: View>: View {
    @State private var store = PreviewCalendar.store()
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environment(store)
            .task { await store.start() }
    }
}
