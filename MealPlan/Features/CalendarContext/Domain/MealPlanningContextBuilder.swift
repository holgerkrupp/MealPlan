import Foundation

/// Turns the events of one day into what they mean for one meal.
///
/// Pure, deterministic and conservative on purpose: it counts overlaps and
/// clock times, and never tries to guess what an event *is* about. No title
/// parsing, no heuristics about travel or absence, no AI.
enum MealPlanningContextBuilder {

    /// Events shown behind a chip before the list is cut off.
    static let maxDetailLines = 5
    /// All-day events are listed, never enumerated endlessly.
    static let maxAllDayEvents = 3
    /// From this many overlapping appointments a meal window counts as busy.
    static let busyEventThreshold = 3
    /// …or from this share of the window being taken.
    static let busyCoverageRatio = 0.5
    /// Below this much free time inside the window, something quick fits better.
    static let quickMealThreshold: TimeInterval = 60 * 60
    /// People becoming free more than this far apart count as staggered.
    static let staggeredThreshold: TimeInterval = 45 * 60

    /// Build the context for one meal, or `nil` when the calendar has nothing
    /// to say about it — in which case the planner shows no calendar row at all.
    ///
    /// - Parameters:
    ///   - events: events of `date` from the selected calendars only.
    ///   - calendarOwners: calendar identifier → household member name, already
    ///     restricted to selected calendars. Empty when the user mapped nobody.
    ///   - calendars: calendar identifier → the calendar itself, so the detail
    ///     lines can name and colour where an event came from.
    static func context(
        date: Date,
        mealKey: String,
        mealName: String,
        window: MealTimeWindow,
        events: [MealCalendarEvent],
        privacyMode: CalendarPrivacyMode,
        calendarOwners: [String: String] = [:],
        calendars: [String: MealCalendarInfo] = [:],
        calendar: Calendar = .current
    ) -> MealPlanningContext? {
        let day = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(24 * 60 * 60)
        let dayInterval = DateInterval(start: day, end: dayEnd)
        let windowInterval = window.interval(on: day, calendar: calendar)
        let relevance = window.relevanceInterval(on: day, calendar: calendar)

        let sorted = events.sorted { ($0.startDate, $0.endDate, $0.id) < ($1.startDate, $1.endDate, $1.id) }
        // The same occurrence can arrive twice — an invitation that lives in two
        // selected calendars, or overlapping fetches around a refresh.
        let unique = deduplicated(sorted, includingCalendar: false)
        // For per-person availability the calendar matters, so keep one copy
        // per calendar there.
        let perCalendar = deduplicated(sorted, includingCalendar: true)
        // Every calendar each surviving occurrence came from, so a merged
        // duplicate can still say it is in both "Family" and "Work".
        let calendarsPerOccurrence = calendarIdentifiers(byOccurrenceIn: sorted)

        let showsTitles = privacyMode == .eventTitles
        func presentable(_ event: MealCalendarEvent) -> MealCalendarEvent {
            showsTitles ? event : event.withoutTitle()
        }

        let timed = unique
            .filter { !$0.isAllDay && $0.intersects(relevance) }
            .map(presentable)
        let allDay = unique
            .filter { $0.isAllDay && $0.intersects(dayInterval) }
            .prefix(maxAllDayEvents)
            .map(presentable)

        guard !timed.isEmpty || !allDay.isEmpty else { return nil }

        let busySpans = merged(clip(timed.filter { $0.availability.blocksTime }, to: relevance))

        let isBusyThroughout = busySpans.contains {
            $0.start <= windowInterval.start && $0.end >= windowInterval.end
        }
        let busyUntil = busySpans.filter { $0.end < windowInterval.end }.map(\.end).max()
        let busyFrom = busySpans
            .filter { $0.end >= windowInterval.end && $0.start > windowInterval.start }
            .map(\.start)
            .min()

        let inWindow = timed.filter { $0.intersects(windowInterval) }
        let blockingInWindow = inWindow.filter { $0.availability.blocksTime }
        let coverage = busySpans.reduce(0.0) { total, span in
            let start = max(span.start, windowInterval.start)
            let end = min(span.end, windowInterval.end)
            return total + max(0, end.timeIntervalSince(start))
        }
        let windowLength = windowInterval.duration
        let ratio = windowLength > 0 ? coverage / windowLength : 0

        let busyness: ScheduleBusyness
        if isBusyThroughout || blockingInWindow.count >= busyEventThreshold || ratio >= busyCoverageRatio {
            busyness = .busy
        } else if !inWindow.isEmpty || busyUntil != nil || busyFrom != nil {
            busyness = .light
        } else {
            busyness = .clear
        }

        let freeStart = max(busyUntil ?? windowInterval.start, windowInterval.start)
        let freeEnd = min(busyFrom ?? windowInterval.end, windowInterval.end)
        let availableTime = isBusyThroughout ? 0 : max(0, freeEnd.timeIntervalSince(freeStart))

        let complexity: MealComplexityHint
        if busyness == .busy || isBusyThroughout || availableTime < quickMealThreshold {
            complexity = .quick
        } else if busyness == .light {
            complexity = .standard
        } else {
            complexity = .unhurried
        }

        let people = availability(
            for: calendarOwners,
            events: perCalendar,
            window: windowInterval
        )
        let staggered = isStaggered(people, window: windowInterval)

        return MealPlanningContext(
            date: day,
            mealKey: mealKey,
            mealName: mealName,
            window: windowInterval,
            relevantEvents: timed,
            allDayEvents: Array(allDay),
            busyIntervals: busySpans,
            busyness: busyness,
            busyUntil: busyUntil,
            busyFrom: busyFrom,
            isBusyThroughout: isBusyThroughout,
            householdAvailability: people,
            hasStaggeredAvailability: staggered,
            suggestedComplexity: complexity,
            detailLines: detailLines(
                timed: timed,
                allDay: Array(allDay),
                showsTitles: showsTitles,
                calendarsPerOccurrence: calendarsPerOccurrence,
                calendars: calendars
            )
        )
    }

    // MARK: - Pieces

    /// One entry per appointment.
    ///
    /// `MealCalendarEvent.occurrenceKey` is deliberately *not* the event id:
    /// the same appointment shared into two of the user's calendars arrives
    /// with a different id per copy, and listing it twice is the most visible
    /// way this feature can look broken.
    private static func deduplicated(
        _ events: [MealCalendarEvent],
        includingCalendar: Bool
    ) -> [MealCalendarEvent] {
        var seen = Set<String>()
        var result: [MealCalendarEvent] = []
        for event in events {
            let key = includingCalendar
                ? "\(event.calendarIdentifier)|\(event.occurrenceKey)"
                : event.occurrenceKey
            if seen.insert(key).inserted { result.append(event) }
        }
        return result
    }

    /// occurrence key → the calendars that copy of the appointment lives in,
    /// first seen first.
    private static func calendarIdentifiers(
        byOccurrenceIn events: [MealCalendarEvent]
    ) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for event in events {
            var identifiers = result[event.occurrenceKey] ?? []
            guard !identifiers.contains(event.calendarIdentifier) else { continue }
            identifiers.append(event.calendarIdentifier)
            result[event.occurrenceKey] = identifiers
        }
        return result
    }

    private static func clip(_ events: [MealCalendarEvent], to range: DateInterval) -> [DateInterval] {
        events.compactMap { event in
            let start = max(event.startDate, range.start)
            let end = min(event.endDate, range.end)
            guard end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    /// Overlapping and touching spans become one.
    static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var result: [DateInterval] = []
        for interval in sorted {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = DateInterval(
                    start: last.start,
                    end: max(last.end, interval.end)
                )
            } else {
                result.append(interval)
            }
        }
        return result
    }

    private static func availability(
        for owners: [String: String],
        events: [MealCalendarEvent],
        window: DateInterval
    ) -> [PersonAvailability] {
        guard !owners.isEmpty else { return [] }
        var byPerson: [String: Set<String>] = [:]
        for (calendarID, name) in owners where !name.isEmpty {
            byPerson[name, default: []].insert(calendarID)
        }

        return byPerson.keys.sorted().map { name in
            let calendars = byPerson[name] ?? []
            let theirs = events.filter {
                calendars.contains($0.calendarIdentifier)
                    && !$0.isAllDay
                    && $0.availability.blocksTime
                    && $0.intersects(window)
            }
            guard !theirs.isEmpty else {
                return PersonAvailability(name: name, state: .free, freeFrom: nil)
            }
            let spans = merged(clip(theirs, to: window))
            let covered = spans.contains { $0.start <= window.start && $0.end >= window.end }
            if covered {
                return PersonAvailability(name: name, state: .busyThroughout, freeFrom: nil)
            }
            let freeFrom = spans.filter { $0.end < window.end }.map(\.end).max()
            return PersonAvailability(name: name, state: .partlyBusy, freeFrom: freeFrom)
        }
    }

    private static func isStaggered(_ people: [PersonAvailability], window: DateInterval) -> Bool {
        let arrivals = people
            .filter { $0.state != .busyThroughout }
            .map { $0.freeFrom ?? window.start }
        guard let earliest = arrivals.min(), let latest = arrivals.max(), arrivals.count > 1 else {
            return false
        }
        return latest.timeIntervalSince(earliest) > staggeredThreshold
    }

    private static func detailLines(
        timed: [MealCalendarEvent],
        allDay: [MealCalendarEvent],
        showsTitles: Bool,
        calendarsPerOccurrence: [String: [String]],
        calendars: [String: MealCalendarInfo]
    ) -> [MealContextDetailLine] {
        /// The calendars one occurrence came from, named and coloured the way
        /// Calendar does. Falls back to the event's own calendar so a missing
        /// lookup only costs the extra names, never the line itself.
        func sources(for event: MealCalendarEvent) -> [MealCalendarInfo] {
            let identifiers = calendarsPerOccurrence[event.occurrenceKey] ?? [event.calendarIdentifier]
            return identifiers.compactMap { calendars[$0] }
        }

        func line(_ event: MealCalendarEvent, timeText: String, isAllDay: Bool) -> MealContextDetailLine {
            let sources = sources(for: event)
            return MealContextDetailLine(
                id: event.occurrenceKey,
                title: showsTitles ? event.displayTitle : nil,
                timeText: timeText,
                isAllDay: isAllDay,
                calendarNames: sources.map(\.title).filter { !$0.isEmpty },
                calendarColor: sources.first?.color,
                blocksTime: event.availability.blocksTime
            )
        }

        var lines: [MealContextDetailLine] = timed.prefix(maxDetailLines).map { event in
            let start = event.startDate.formatted(date: .omitted, time: .shortened)
            let end = event.endDate.formatted(date: .omitted, time: .shortened)
            return line(
                event,
                timeText: event.startDate == event.endDate ? start : "\(start) – \(end)",
                isAllDay: false
            )
        }
        lines += allDay.map { event in
            line(event, timeText: String(localized: "All day"), isAllDay: true)
        }
        return lines
    }
}
