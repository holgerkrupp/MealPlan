import Foundation

enum CalendarWriteError: Error, Equatable, LocalizedError {
    /// The app may not write events (never asked, denied, restricted, …).
    case notAuthorized
    /// The chosen calendar no longer exists (deleted, account signed out).
    case calendarNotFound
    /// The chosen calendar exists but doesn't accept new events (a holiday
    /// calendar, a read-only subscription).
    case calendarNotWritable

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            String(localized: "MealPlan doesn’t have permission to add events to Calendar.")
        case .calendarNotFound:
            String(localized: "That calendar isn’t available anymore. Choose another.")
        case .calendarNotWritable:
            String(localized: "That calendar doesn’t accept new events. Choose another.")
        }
    }
}

/// The app's whole contract with EventKit for *writing*.
///
/// Kept separate from `CalendarEventProviding`, which only ever reads: that
/// protocol's whole point is a promise that nothing it touches is ever
/// changed, and this one exists specifically to change things — keeping them
/// apart means each promise stays easy to audit on its own. Implementations
/// hand back and take only Sendable value types, so `EKEvent`/`EKEventStore`
/// never travel through the app, and the feature can be tested with a mock.
protocol CalendarEventWriting: Sendable {

    /// Current authorization. Cheap, never prompts.
    func authorization() async -> CalendarAuthorization

    /// Ask the system for access. Only ever prompts when the status is
    /// `notDetermined`.
    func requestAccess() async -> CalendarAuthorization

    /// The user's calendars that will actually accept new events — excludes
    /// read-only subscriptions (holidays, a shared calendar without edit
    /// rights) up front, so the picker never offers a choice that would fail.
    func writableCalendars() async throws -> [MealCalendarInfo]

    /// Brings `calendarIdentifier` in line with `payloads`: creates an event
    /// for any payload not yet mirrored there, updates one whose content
    /// changed, and removes any mirrored event whose payload dropped out of
    /// the list (deleted, skipped, or scrolled out of the published window).
    ///
    /// `knownEventIDs` is this feature's own record of which event belongs to
    /// which entry, keyed by `MealPlanPublishPayload.uuid`; the returned map
    /// replaces it, and the caller is responsible for persisting it.
    func sync(
        payloads: [MealPlanPublishPayload],
        calendarIdentifier: String,
        knownEventIDs: [UUID: String]
    ) async throws -> [UUID: String]

    /// Removes every one of this feature's own events — used when the user
    /// turns publishing off. Missing events (already deleted by hand) are
    /// silently skipped.
    func removeEvents(identifiers: [String]) async
}
