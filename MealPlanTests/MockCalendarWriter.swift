import Foundation
@testable import MealPlan

/// A stand-in for EventKit's write side. Keeps its own tiny in-memory
/// "calendar" — an eventIdentifier → (calendar, payload) map — so
/// `PublishedCalendarService`'s create/update/remove logic can be tested
/// without touching anyone's real calendar.
actor MockCalendarWriter: CalendarEventWriting {
    private var status: CalendarAuthorization
    private var statusAfterRequest: CalendarAuthorization
    private var calendars: [MealCalendarInfo]
    private var failure: (any Error)?
    private var nextEventID = 0

    private(set) var events: [String: (calendarID: String, payload: MealPlanPublishPayload)] = [:]
    private(set) var syncCount = 0
    private(set) var requestAccessCount = 0
    private(set) var removeEventsCalls: [[String]] = []

    init(
        status: CalendarAuthorization = .fullAccess,
        statusAfterRequest: CalendarAuthorization? = nil,
        calendars: [MealCalendarInfo] = [],
        failure: (any Error)? = nil
    ) {
        self.status = status
        self.statusAfterRequest = statusAfterRequest ?? status
        self.calendars = calendars
        self.failure = failure
    }

    // MARK: - Test control

    func setStatus(_ status: CalendarAuthorization) { self.status = status }
    func setFailure(_ failure: (any Error)?) { self.failure = failure }

    /// The payloads currently mirrored into `calendarIdentifier`, as a test
    /// would see them by reading the calendar back.
    func mirroredPayloads(in calendarIdentifier: String) -> [MealPlanPublishPayload] {
        events.values.filter { $0.calendarID == calendarIdentifier }.map(\.payload)
    }

    // MARK: - CalendarEventWriting

    func authorization() async -> CalendarAuthorization { status }

    func requestAccess() async -> CalendarAuthorization {
        requestAccessCount += 1
        guard status.canRequestAccess else { return status }
        status = statusAfterRequest
        return status
    }

    func writableCalendars() async throws -> [MealCalendarInfo] {
        if let failure { throw failure }
        guard status.canWrite else { throw CalendarWriteError.notAuthorized }
        return calendars
    }

    func sync(
        payloads: [MealPlanPublishPayload],
        calendarIdentifier: String,
        knownEventIDs: [UUID: String]
    ) async throws -> [UUID: String] {
        syncCount += 1
        if let failure { throw failure }
        guard status.canWrite else { throw CalendarWriteError.notAuthorized }
        guard calendars.contains(where: { $0.id == calendarIdentifier }) else {
            throw CalendarWriteError.calendarNotFound
        }

        var updatedMap = knownEventIDs
        var seen = Set<UUID>()

        for payload in payloads {
            seen.insert(payload.uuid)
            if let existingID = knownEventIDs[payload.uuid], events[existingID] != nil {
                events[existingID] = (calendarIdentifier, payload)
            } else {
                let identifier = "mock-event-\(nextEventID)"
                nextEventID += 1
                events[identifier] = (calendarIdentifier, payload)
                updatedMap[payload.uuid] = identifier
            }
        }

        for (uuid, eventID) in knownEventIDs where !seen.contains(uuid) {
            events.removeValue(forKey: eventID)
            updatedMap.removeValue(forKey: uuid)
        }

        return updatedMap
    }

    func removeEvents(identifiers: [String]) async {
        removeEventsCalls.append(identifiers)
        for identifier in identifiers { events.removeValue(forKey: identifier) }
    }
}
