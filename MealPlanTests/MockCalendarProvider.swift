import Foundation
@testable import MealPlan

/// A stand-in for EventKit. Behaves like the real service — it filters by
/// calendar and date range and only hands back titles when asked to — so the
/// whole calendar feature can be tested without touching anyone's calendar.
actor MockCalendarProvider: CalendarEventProviding {

    private var status: CalendarAuthorization
    private var statusAfterRequest: CalendarAuthorization
    private var calendars: [MealCalendarInfo]
    private var storedEvents: [MealCalendarEvent]
    private var failure: (any Error)?
    /// Simulates a provider that hands out titles it wasn't asked for, so the
    /// privacy guarantees can be tested at the layer above too.
    private var leaksTitles: Bool

    private(set) var fetchCount = 0
    private(set) var requestAccessCount = 0
    private(set) var calendarsCount = 0
    private(set) var lastInterval: DateInterval?
    private(set) var lastIdentifiers: Set<String> = []
    private(set) var lastIncludeTitles: Bool?

    nonisolated let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(
        status: CalendarAuthorization = .fullAccess,
        statusAfterRequest: CalendarAuthorization? = nil,
        calendars: [MealCalendarInfo] = [],
        events: [MealCalendarEvent] = [],
        failure: (any Error)? = nil,
        leaksTitles: Bool = false
    ) {
        self.status = status
        self.statusAfterRequest = statusAfterRequest ?? status
        self.calendars = calendars
        self.storedEvents = events
        self.failure = failure
        self.leaksTitles = leaksTitles
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.changes = stream
        self.continuation = continuation
    }

    // MARK: - Test control

    func setStatus(_ status: CalendarAuthorization) { self.status = status }
    func setEvents(_ events: [MealCalendarEvent]) { storedEvents = events }
    func setCalendars(_ calendars: [MealCalendarInfo]) { self.calendars = calendars }
    func setFailure(_ failure: (any Error)?) { self.failure = failure }
    func emitChange() { continuation.yield(()) }

    // MARK: - CalendarEventProviding

    func authorization() async -> CalendarAuthorization { status }

    func requestAccess() async -> CalendarAuthorization {
        requestAccessCount += 1
        guard status.canRequestAccess else { return status }
        status = statusAfterRequest
        return status
    }

    func availableCalendars() async throws -> [MealCalendarInfo] {
        calendarsCount += 1
        if let failure { throw failure }
        guard status.canReadEvents else { throw CalendarProviderError.notAuthorized }
        return calendars
    }

    func events(
        in interval: DateInterval,
        calendarIdentifiers: Set<String>,
        includeTitles: Bool
    ) async throws -> [MealCalendarEvent] {
        fetchCount += 1
        lastInterval = interval
        lastIdentifiers = calendarIdentifiers
        lastIncludeTitles = includeTitles
        if let failure { throw failure }
        guard status.canReadEvents else { throw CalendarProviderError.notAuthorized }
        return storedEvents
            .filter { calendarIdentifiers.contains($0.calendarIdentifier) }
            .filter { $0.intersects(interval) }
            .map { includeTitles || leaksTitles ? $0 : $0.withoutTitle() }
    }
}

/// A failure the calendar layer can hit in the wild.
struct CalendarTestFailure: Error, Equatable {}
