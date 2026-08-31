import Foundation

/// How full the schedule around a meal is. Deliberately coarse — three levels
/// the planner can phrase in one short line.
enum ScheduleBusyness: Int, Sendable, Codable, Comparable, CaseIterable {
    case clear = 0, light = 1, busy = 2

    static func < (lhs: ScheduleBusyness, rhs: ScheduleBusyness) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var localizedName: String {
        switch self {
        case .clear: String(localized: "Schedule is clear")
        case .light: String(localized: "A little going on")
        case .busy: String(localized: "Busy")
        }
    }
}

/// A hint for a future recommendation engine. Nothing in the app acts on it
/// yet — meals are never changed automatically.
enum MealComplexityHint: String, Sendable, Codable, CaseIterable {
    /// Plenty of time around the meal.
    case unhurried
    /// Normal amount of time.
    case standard
    /// Little time — something quick would fit better.
    case quick

    var localizedName: String {
        switch self {
        case .unhurried: String(localized: "Time to cook")
        case .standard: String(localized: "Normal cooking time")
        case .quick: String(localized: "Something quick")
        }
    }
}

/// Availability of one household member around a meal, derived only from the
/// calendars the user explicitly mapped to that person.
///
/// The planner never infers *why* someone is busy and never claims someone is
/// away: it only reports that their time is taken.
struct PersonAvailability: Sendable, Equatable, Identifiable, Hashable {
    enum State: String, Sendable, Codable {
        /// Nothing in the mapped calendars overlaps the meal.
        case free
        /// Something overlaps part of the meal window.
        case partlyBusy
        /// Something covers the whole meal window.
        case busyThroughout
    }

    let name: String
    let state: State
    /// When their last overlapping event ends, if that is inside the window.
    let freeFrom: Date?

    var id: String { name }

    var localizedSummary: String {
        switch state {
        case .free:
            String(localized: "\(name): nothing planned")
        case .partlyBusy:
            if let freeFrom {
                String(localized: "\(name): free from \(freeFrom.formatted(date: .omitted, time: .shortened))")
            } else {
                String(localized: "\(name): partly busy")
            }
        case .busyThroughout:
            String(localized: "\(name): busy the whole time")
        }
    }
}

/// One line of detail behind a context chip, already reduced to what the
/// current privacy level allows.
struct MealContextDetailLine: Sendable, Equatable, Identifiable, Hashable {
    let id: String
    /// `nil` unless the user chose the "Event titles" privacy level.
    let title: String?
    /// "16:30 – 17:30", or "All day".
    let timeText: String
    let isAllDay: Bool
    /// Which of the user's calendars this came from — more than one when the
    /// same appointment sits in several selected calendars. Always safe to
    /// show: these are names the user picked in Settings, not event content.
    let calendarNames: [String]
    /// The colour Calendar uses for the first of `calendarNames`.
    let calendarColor: MealCalendarColor?
    /// Whether this event is what makes the meal look busy.
    let blocksTime: Bool

    init(
        id: String,
        title: String?,
        timeText: String,
        isAllDay: Bool,
        calendarNames: [String] = [],
        calendarColor: MealCalendarColor? = nil,
        blocksTime: Bool = true
    ) {
        self.id = id
        self.title = title
        self.timeText = timeText
        self.isAllDay = isAllDay
        self.calendarNames = calendarNames
        self.calendarColor = calendarColor
        self.blocksTime = blocksTime
    }

    /// "Family", or "Family, Work" when the same appointment is in both.
    var calendarText: String? {
        calendarNames.isEmpty ? nil : calendarNames.joined(separator: ", ")
    }

    /// One string for VoiceOver and for places that show a single line.
    var spokenText: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        parts.append(timeText)
        if let calendarText { parts.append(calendarText) }
        return parts.joined(separator: ", ")
    }
}

/// What the calendar means for one meal on one day.
///
/// Built by `MealPlanningContextBuilder` from already privacy-filtered events;
/// nothing in here can carry event notes, attendees, URLs or locations.
struct MealPlanningContext: Sendable, Equatable, Identifiable {
    let date: Date
    let mealKey: String
    /// The household's display name for the meal ("Dinner", "Abendbrot", …).
    let mealName: String
    /// The meal's window on this day.
    let window: DateInterval
    /// Timed events near the meal, earliest first.
    let relevantEvents: [MealCalendarEvent]
    /// All-day events on this day, capped so they can't swamp the planner.
    let allDayEvents: [MealCalendarEvent]
    /// Merged, de-duplicated busy time, clipped to the relevance range.
    let busyIntervals: [DateInterval]
    let busyness: ScheduleBusyness
    /// The end of the busy stretch before the meal is free again, when that
    /// happens inside the window ("busy until 18:30").
    let busyUntil: Date?
    /// The start of a busy stretch that runs past the end of the window
    /// ("busy from 20:00").
    let busyFrom: Date?
    /// Busy time covers the entire meal window.
    let isBusyThroughout: Bool
    /// Availability per mapped household member (empty when nothing is mapped).
    let householdAvailability: [PersonAvailability]
    /// Mapped people become free at noticeably different times.
    let hasStaggeredAvailability: Bool
    let suggestedComplexity: MealComplexityHint
    let detailLines: [MealContextDetailLine]

    var id: String { "\(date.dayID)#\(mealKey)" }

    var isEmpty: Bool { relevantEvents.isEmpty && allDayEvents.isEmpty }

    /// The lines about events happening at a time — the ones that belong to
    /// this meal specifically.
    var timedDetailLines: [MealContextDetailLine] {
        detailLines.filter { !$0.isAllDay }
    }

    /// All-day events apply to the whole day, not to this meal, so the UI shows
    /// them once per day rather than repeating them under every meal.
    var allDayDetailLines: [MealContextDetailLine] {
        detailLines.filter(\.isAllDay)
    }

    /// True when the calendar has something to say about *this meal* rather
    /// than about the whole day. A context carrying nothing but all-day events
    /// is shown once at day level instead of repeated under every meal.
    var hasTimedEvents: Bool { !relevantEvents.isEmpty }

    /// True when the summary talks about busy time — the case where naming the
    /// calendar behind it actually tells the user something.
    var indicatesBusyTime: Bool {
        isBusyThroughout || busyness == .busy || busyUntil != nil || busyFrom != nil
    }

    /// The calendars behind the busy time around this meal, in the order they
    /// appear. Shown in the detail sheet so "Busy" says *which* calendar.
    var busyCalendarNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for line in timedDetailLines where line.blocksTime {
            for name in line.calendarNames where seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    /// Free time inside the window, once the busy stretches are taken out of
    /// its edges. `0` when the window is fully taken.
    var availableTime: TimeInterval {
        guard !isBusyThroughout else { return 0 }
        let start = busyUntil.map { max($0, window.start) } ?? window.start
        let end = busyFrom.map { min($0, window.end) } ?? window.end
        return max(0, end.timeIntervalSince(start))
    }

    /// SF Symbol for the chip. Busyness is never communicated by colour alone —
    /// the symbol and the text carry it.
    var symbolName: String {
        if isBusyThroughout || busyness == .busy { return "calendar.badge.exclamationmark" }
        if busyUntil != nil || busyFrom != nil { return "clock" }
        return "calendar"
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// The one-line summary shown in the week overview.
    var summary: String {
        if isBusyThroughout {
            return String(localized: "Busy during \(mealName)")
        }
        if let busyUntil {
            return String(localized: "Busy until \(timeText(busyUntil))")
        }
        if let busyFrom {
            return String(localized: "Busy from \(timeText(busyFrom))")
        }
        let count = relevantEvents.count
        if count > 1 {
            return String(localized: "\(count) events around \(mealName)")
        }
        if count == 1 {
            return String(localized: "1 event around \(mealName)")
        }
        if allDayEvents.count > 1 {
            return String(localized: "\(allDayEvents.count) all-day events")
        }
        if allDayEvents.count == 1 {
            if let title = allDayEvents[0].displayTitle, !title.isEmpty {
                return String(localized: "All day: \(title)")
            }
            return String(localized: "All-day event")
        }
        return busyness.localizedName
    }

    /// VoiceOver description, e.g. "Calendar context: busy until 6:30 PM."
    var accessibilitySummary: String {
        String(localized: "Calendar context: \(summary).")
    }

    /// The reusable input a future calendar-aware recommendation engine would
    /// take. Nothing consumes it yet — meals are never changed automatically.
    var recommendationContext: MealRecommendationContext {
        MealRecommendationContext(
            date: date,
            mealKey: mealKey,
            availableCookingTime: isEmpty ? nil : availableTime,
            householdAvailability: householdAvailability,
            scheduleBusyness: busyness,
            hasStaggeredAvailability: hasStaggeredAvailability,
            suggestedComplexity: suggestedComplexity
        )
    }
}

/// Calendar-derived input for a future meal recommendation engine.
///
/// Kept as a plain value so a recommender can be added later without touching
/// the calendar layer — and so removing calendar integration means deleting
/// this file, not unpicking the planner.
struct MealRecommendationContext: Sendable, Equatable {
    let date: Date
    let mealKey: String
    /// Free time inside the meal window, when a context exists.
    let availableCookingTime: TimeInterval?
    let householdAvailability: [PersonAvailability]
    let scheduleBusyness: ScheduleBusyness
    let hasStaggeredAvailability: Bool
    let suggestedComplexity: MealComplexityHint
}
