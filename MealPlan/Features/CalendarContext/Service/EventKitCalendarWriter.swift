import EventKit
import Foundation

/// Writes the household's plan into a calendar the user already has.
///
/// That's deliberate: MealPlan has no server, so there is nothing of its own
/// to host a feed on. Writing into a calendar the user picks — including one
/// backed by a Google or Outlook account added right on this device — is what
/// lets the plan reach someone who doesn't use an iPhone at all: their
/// calendar app already syncs with that account, MealPlan just needs to be a
/// good citizen of it.
///
/// A dedicated `EKEventStore`, kept apart from `EventKitCalendarService`
/// (which reads calendar context and promises never to touch Calendar) —
/// this is the one place that writes, and keeping the two apart keeps that a
/// promise that's easy to audit rather than one more `if` to remember.
actor EventKitCalendarWriter: CalendarEventWriting {

    private let store = EKEventStore()

    nonisolated func currentAuthorization() -> CalendarAuthorization {
        CalendarAuthorization(EKEventStore.authorizationStatus(for: .event))
    }

    func authorization() async -> CalendarAuthorization {
        currentAuthorization()
    }

    func requestAccess() async -> CalendarAuthorization {
        guard currentAuthorization().canRequestAccess else { return currentAuthorization() }
        _ = try? await store.requestFullAccessToEvents()
        // Let the long-lived store pick up the new permission.
        store.reset()
        return currentAuthorization()
    }

    func writableCalendars() async throws -> [MealCalendarInfo] {
        guard currentAuthorization().canWrite else { throw CalendarWriteError.notAuthorized }
        return store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map {
                MealCalendarInfo(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source?.title ?? "",
                    color: MealCalendarColor($0.cgColor)
                )
            }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    func sync(
        payloads: [MealPlanPublishPayload],
        calendarIdentifier: String,
        knownEventIDs: [UUID: String]
    ) async throws -> [UUID: String] {
        guard currentAuthorization().canWrite else { throw CalendarWriteError.notAuthorized }
        guard let calendar = store.calendar(withIdentifier: calendarIdentifier) else {
            throw CalendarWriteError.calendarNotFound
        }
        guard calendar.allowsContentModifications else { throw CalendarWriteError.calendarNotWritable }

        var updatedMap = knownEventIDs
        var seen = Set<UUID>()

        for payload in payloads {
            seen.insert(payload.uuid)
            let event = existingEvent(for: payload.uuid, in: knownEventIDs, calendar: calendar) ?? {
                let created = EKEvent(eventStore: store)
                created.calendar = calendar
                return created
            }()
            apply(payload, to: event)
            try store.save(event, span: .thisEvent, commit: false)
            if let identifier = event.eventIdentifier {
                updatedMap[payload.uuid] = identifier
            }
        }

        // Remove events for entries that dropped out of the published set
        // (deleted, skipped, or scrolled out of the window).
        for (uuid, eventID) in knownEventIDs where !seen.contains(uuid) {
            if let stale = store.event(withIdentifier: eventID) {
                try? store.remove(stale, span: .thisEvent, commit: false)
            }
            updatedMap.removeValue(forKey: uuid)
        }

        try store.commit()
        return updatedMap
    }

    func removeEvents(identifiers: [String]) async {
        for identifier in identifiers {
            guard let event = store.event(withIdentifier: identifier) else { continue }
            try? store.remove(event, span: .thisEvent, commit: false)
        }
        try? store.commit()
    }

    // MARK: - Helpers

    /// Reuses the event this feature already wrote for `uuid`, as long as
    /// it's still there and still in the calendar being synced — a stale
    /// identifier (event deleted by hand, or the destination calendar
    /// changed) just means a fresh event gets created instead.
    private func existingEvent(for uuid: UUID, in knownEventIDs: [UUID: String], calendar: EKCalendar) -> EKEvent? {
        guard let identifier = knownEventIDs[uuid], let event = store.event(withIdentifier: identifier) else {
            return nil
        }
        return event.calendar?.calendarIdentifier == calendar.calendarIdentifier ? event : nil
    }

    private func apply(_ payload: MealPlanPublishPayload, to event: EKEvent) {
        event.title = payload.title
        event.notes = payload.notes
        event.isAllDay = true
        event.startDate = payload.date
        event.endDate = payload.date
        // Purely informational — never shows as "busy" on anyone's calendar.
        event.availability = .free
    }
}
