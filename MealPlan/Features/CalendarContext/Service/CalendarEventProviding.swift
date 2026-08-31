import Foundation

enum CalendarProviderError: Error, Equatable {
    /// The app may not read events (never asked, denied, restricted, …).
    case notAuthorized
    /// EventKit reported a failure. Calendar context is skipped; meal planning
    /// carries on untouched.
    case unavailable
}

/// The app's whole contract with the calendar.
///
/// Everything EventKit-shaped stops here: implementations hand back Sendable
/// value types, so `EKEvent` and `EKEventStore` never travel through the app —
/// and tests can drive the feature with a mock instead of a real database.
protocol CalendarEventProviding: Sendable {

    /// Current authorization. Cheap, never prompts.
    func authorization() async -> CalendarAuthorization

    /// Ask the system for full access. Only ever prompts when the status is
    /// `notDetermined`; in every other state it just reports what it is, so a
    /// denied user is never asked again.
    func requestAccess() async -> CalendarAuthorization

    /// The user's event calendars.
    func availableCalendars() async throws -> [MealCalendarInfo]

    /// Events from `calendarIdentifiers` overlapping `interval`.
    ///
    /// - Parameter includeTitles: false unless the user chose the "Event
    ///   titles" privacy level, in which case titles are never even read into
    ///   the domain model.
    func events(
        in interval: DateInterval,
        calendarIdentifiers: Set<String>,
        includeTitles: Bool
    ) async throws -> [MealCalendarEvent]

    /// Emits whenever the calendar database changes (including permission
    /// changes), so cached context can be refreshed instead of polled.
    var changes: AsyncStream<Void> { get }
}
