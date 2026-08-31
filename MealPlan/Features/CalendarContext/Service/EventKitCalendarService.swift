import EventKit
import Foundation

/// The one place in the app that imports EventKit for the meal planner.
///
/// An actor, so the `EKEventStore` is only touched from one place at a time and
/// everything crossing back out is an immutable value type. The service reads;
/// it never creates, changes, moves or deletes anything in Calendar.
actor EventKitCalendarService: CalendarEventProviding {

    private let store = EKEventStore()
    private nonisolated let changeBridge: EventKitChangeBridge

    init() {
        changeBridge = EventKitChangeBridge()
    }

    nonisolated var changes: AsyncStream<Void> { changeBridge.stream }

    nonisolated func currentAuthorization() -> CalendarAuthorization {
        CalendarAuthorization(EKEventStore.authorizationStatus(for: .event))
    }

    func authorization() async -> CalendarAuthorization {
        currentAuthorization()
    }

    func requestAccess() async -> CalendarAuthorization {
        // Anything but `notDetermined` can only be changed by the user in
        // system Settings — asking again would do nothing but annoy.
        guard currentAuthorization().canRequestAccess else { return currentAuthorization() }
        _ = await Self.requestFullAccess()
        // Let the long-lived store pick up the new permission.
        store.reset()
        return currentAuthorization()
    }

    /// Asks on a throwaway store: authorization belongs to the app, not to an
    /// `EKEventStore` instance, and this keeps the actor's own store off the
    /// async call. Reading events requires EventKit's "full access" even
    /// though this app only ever reads.
    private nonisolated static func requestFullAccess() async -> Bool {
        let store = EKEventStore()
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    func availableCalendars() async throws -> [MealCalendarInfo] {
        guard currentAuthorization().canReadEvents else { throw CalendarProviderError.notAuthorized }
        return store.calendars(for: .event)
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

    func events(
        in interval: DateInterval,
        calendarIdentifiers: Set<String>,
        includeTitles: Bool
    ) async throws -> [MealCalendarEvent] {
        guard currentAuthorization().canReadEvents else { throw CalendarProviderError.notAuthorized }
        guard !calendarIdentifiers.isEmpty else { return [] }

        let calendars = store.calendars(for: .event)
            .filter { calendarIdentifiers.contains($0.calendarIdentifier) }
        // Every chosen calendar disappeared (deleted, account signed out).
        guard !calendars.isEmpty else { return [] }

        let predicate = store.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: calendars
        )
        return store.events(matching: predicate)
            .compactMap { Self.makeEvent(from: $0, includeTitle: includeTitles) }
    }

    // MARK: - EventKit → domain

    /// The conversion that keeps EventKit inside this file. Anything not needed
    /// for meal planning — notes, URL, attendees, location, organizer, alarms —
    /// is simply not read.
    private static func makeEvent(from event: EKEvent, includeTitle: Bool) -> MealCalendarEvent? {
        // EventKit hands these back as implicitly unwrapped optionals; treat
        // them as genuinely optional and skip anything malformed.
        let start: Date? = event.startDate
        let end: Date? = event.endDate
        let calendarID: String? = event.calendar?.calendarIdentifier
        guard let start, let end, let calendarID else { return nil }

        let rawIdentifier: String? = event.eventIdentifier
        let identifier = rawIdentifier ?? "\(calendarID)#\(start.timeIntervalSinceReferenceDate)"
        let rawTitle: String? = event.title
        let title = includeTitle ? rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        return MealCalendarEvent(
            // Occurrences of a repeating event share an identifier, so the
            // start date is part of the id.
            id: "\(identifier)@\(start.timeIntervalSinceReferenceDate)",
            startDate: start,
            endDate: end,
            isAllDay: event.isAllDay,
            displayTitle: (title?.isEmpty ?? true) ? nil : title,
            calendarIdentifier: calendarID,
            availability: MealCalendarAvailability(event.availability),
            // Shared by every calendar the same appointment landed in, so the
            // planner can list it once instead of once per calendar.
            sharedIdentifier: event.calendarItemExternalIdentifier
        )
    }
}

// MARK: - EventKit mapping

extension CalendarAuthorization {
    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .fullAccess: self = .fullAccess
        case .writeOnly: self = .writeOnly
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .unknown
        }
    }
}

extension MealCalendarColor {
    /// The calendar's colour, converted into plain sRGB components.
    ///
    /// `EKCalendar.cgColor` can be in any colour space (and is a generic grey
    /// for some accounts), so it is converted rather than read directly.
    init?(_ cgColor: CGColor?) {
        guard let cgColor else { return nil }
        guard
            let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
            let components = converted.components,
            components.count >= 3
        else { return nil }
        self.init(
            red: Double(components[0]),
            green: Double(components[1]),
            blue: Double(components[2]),
            alpha: components.count >= 4 ? Double(components[3]) : 1
        )
    }
}

extension MealCalendarAvailability {
    init(_ availability: EKEventAvailability) {
        switch availability {
        case .busy: self = .busy
        case .free: self = .free
        case .tentative: self = .tentative
        case .unavailable: self = .unavailable
        case .notSupported: self = .unknown
        @unknown default: self = .unknown
        }
    }
}

/// Bridges `EKEventStoreChanged` into an `AsyncStream`.
///
/// Deliberately tiny and free of the notification object itself: only a "the
/// calendar changed" tick crosses into Swift concurrency.
final class EventKitChangeBridge: @unchecked Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let center: NotificationCenter
    // Written in `init`, read in `deinit`, never concurrently.
    private var token: (any NSObjectProtocol)?

    init(center: NotificationCenter = .default) {
        self.center = center
        // Coalesce bursts: only the newest tick matters.
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.stream = stream
        self.continuation = continuation
        token = center.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { _ in
            continuation.yield(())
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
        continuation.finish()
    }
}
