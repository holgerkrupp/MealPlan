import Foundation

/// How an event affects someone's availability. A deliberately small subset of
/// EventKit's vocabulary — enough to decide "is this time taken?".
enum MealCalendarAvailability: String, Sendable, Codable, CaseIterable, Equatable {
    case busy, free, tentative, unavailable, unknown

    /// Whether an event with this availability takes time away from the meal.
    /// Anything but an explicit "free" counts, so the planner errs on the side
    /// of assuming the evening is taken rather than assuming it is open.
    var blocksTime: Bool { self != .free }
}

/// A calendar event as the meal planner sees it: the few facts needed to say
/// something useful about a meal, and nothing else.
///
/// This is the *only* representation of calendar data that leaves the EventKit
/// service. There is intentionally no place to put notes, URLs, attendees,
/// locations, organizers or meeting links — they cannot leak into the planner
/// because the model cannot carry them.
struct MealCalendarEvent: Sendable, Identifiable, Equatable, Hashable {
    /// Stable per occurrence: EventKit's identifier plus the start date, so two
    /// occurrences of a repeating event stay distinct.
    let id: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    /// Only populated when the user explicitly chose the "Event titles" privacy
    /// level. `nil` in the default availability-only mode.
    let displayTitle: String?
    let calendarIdentifier: String
    let availability: MealCalendarAvailability
    /// The same appointment in two of the user's calendars — a shared family
    /// event, an invitation that also landed in a work account — has a
    /// different `id` per copy but the same value here (EventKit's
    /// `calendarItemExternalIdentifier`). It is what lets the planner list such
    /// an event once instead of once per calendar. `nil` when EventKit has
    /// none, in which case `id` is the best available identity.
    let sharedIdentifier: String?

    init(
        id: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        displayTitle: String? = nil,
        calendarIdentifier: String,
        availability: MealCalendarAvailability = .busy,
        sharedIdentifier: String? = nil
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = max(startDate, endDate)
        self.isAllDay = isAllDay
        self.displayTitle = displayTitle
        self.calendarIdentifier = calendarIdentifier
        self.availability = availability
        self.sharedIdentifier = sharedIdentifier
    }

    /// Identity across calendars: two copies of the same appointment share it,
    /// two genuinely different appointments never do.
    var occurrenceKey: String {
        [
            sharedIdentifier ?? id,
            String(startDate.timeIntervalSinceReferenceDate),
            String(endDate.timeIntervalSinceReferenceDate),
            isAllDay ? "allDay" : "timed",
        ].joined(separator: "|")
    }

    var interval: DateInterval {
        DateInterval(start: startDate, end: max(startDate, endDate))
    }

    func intersects(_ other: DateInterval) -> Bool {
        startDate < other.end && endDate > other.start
            // A zero-length event still counts if it sits inside the range.
            || (startDate == endDate && other.contains(startDate))
    }

    /// The same occurrence, with the title removed. Used as a belt-and-braces
    /// guard when the privacy level says availability only.
    func withoutTitle() -> MealCalendarEvent {
        guard displayTitle != nil else { return self }
        return MealCalendarEvent(
            id: id,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            displayTitle: nil,
            calendarIdentifier: calendarIdentifier,
            availability: availability,
            sharedIdentifier: sharedIdentifier
        )
    }
}

/// One of the user's calendars, as offered in Settings.
struct MealCalendarInfo: Sendable, Identifiable, Equatable, Hashable {
    /// `EKCalendar.calendarIdentifier` — stable enough to persist, and the key
    /// the user's selection is stored under.
    let id: String
    let title: String
    /// The account the calendar comes from ("iCloud", "Gmail", …), shown as a
    /// subtitle so two "Family" calendars can be told apart.
    let sourceTitle: String
    /// The colour Calendar shows this calendar in, so MealPlan can use the one
    /// the user already recognises. `nil` when the system has none.
    let color: MealCalendarColor?

    init(id: String, title: String, sourceTitle: String, color: MealCalendarColor? = nil) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
        self.color = color
    }
}
