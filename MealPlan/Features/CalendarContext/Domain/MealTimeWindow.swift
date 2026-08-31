import Foundation

/// The stretch of a day one meal is planned for, as minutes after midnight.
///
/// Windows are what keeps the calendar context useful: only events near the
/// meal being planned are considered, so a meal cell never turns into a dump of
/// the whole day. Defaults are derived from the meal's key and can be changed
/// per household meal in Settings.
struct MealTimeWindow: Sendable, Equatable, Codable, Hashable {
    /// Minutes after midnight, e.g. 16 * 60 for 16:00.
    var startMinutes: Int
    var endMinutes: Int

    /// Events that end shortly before the window still shape the meal ("home
    /// from practice at 17:45"), so relevance reaches back this far.
    static let leadIn: TimeInterval = 60 * 60

    static let minimumDurationMinutes = 30

    init(startMinutes: Int, endMinutes: Int) {
        let start = min(max(startMinutes, 0), 24 * 60 - Self.minimumDurationMinutes)
        self.startMinutes = start
        self.endMinutes = min(max(endMinutes, start + Self.minimumDurationMinutes), 24 * 60)
    }

    init(startHour: Int, startMinute: Int = 0, endHour: Int, endMinute: Int = 0) {
        self.init(
            startMinutes: startHour * 60 + startMinute,
            endMinutes: endHour * 60 + endMinute
        )
    }

    /// The window itself on a given day.
    func interval(on day: Date, calendar: Calendar = .current) -> DateInterval {
        let midnight = calendar.startOfDay(for: day)
        let start = calendar.date(byAdding: .minute, value: startMinutes, to: midnight) ?? midnight
        let end = calendar.date(byAdding: .minute, value: endMinutes, to: midnight) ?? start
        return DateInterval(start: start, end: max(start, end))
    }

    /// The window plus the lead-in before it — the range of events the planner
    /// considers relevant to this meal.
    func relevanceInterval(on day: Date, calendar: Calendar = .current) -> DateInterval {
        let window = interval(on: day, calendar: calendar)
        return DateInterval(start: window.start.addingTimeInterval(-Self.leadIn), end: window.end)
    }

    var startText: String { Self.timeText(minutes: startMinutes) }
    var endText: String { Self.timeText(minutes: endMinutes) }

    private static func timeText(minutes: Int) -> String {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        let reference = Calendar.current.date(from: components) ?? Date.now
        return reference.formatted(date: .omitted, time: .shortened)
    }

    /// The default window for a meal key. The keys match `MealType.defaultSeeds`
    /// (and the legacy `MealSlot` raw values); meals the household invented get
    /// the evening window, which is the one where scheduling matters most, and
    /// can be adjusted in Settings.
    static func standard(forMealKey key: String) -> MealTimeWindow {
        switch key {
        case "breakfast": MealTimeWindow(startHour: 6, endHour: 10)
        case "lunch": MealTimeWindow(startHour: 11, startMinute: 30, endHour: 14)
        case "dinner": MealTimeWindow(startHour: 16, endHour: 21)
        case "snack": MealTimeWindow(startHour: 14, endHour: 16)
        default: MealTimeWindow(startHour: 16, endHour: 21)
        }
    }
}
