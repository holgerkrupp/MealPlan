import Foundation

/// How far back and forward a published feed reaches.
///
/// Kept to a short, fixed menu rather than free-form dates — a calendar
/// someone else has subscribed to is meant to be set up once and then just
/// work, not maintained by hand, so the choice is "how much of a rolling
/// window" rather than "until when".
enum PublishedCalendarRange: String, CaseIterable, Identifiable, Sendable, Codable {
    case fourWeeks
    case tenWeeks
    case wholeYear

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .fourWeeks: String(localized: "2 weeks back, 4 weeks ahead")
        case .tenWeeks: String(localized: "2 weeks back, 10 weeks ahead")
        case .wholeYear: String(localized: "This calendar year")
        }
    }

    /// The window to publish, anchored to `now`. Always includes a couple of
    /// weeks in the past so a subscriber who opens the feed for the first
    /// time on a Wednesday still sees what was cooked since the weekend.
    func interval(now: Date = .now) -> DateInterval {
        let start = now.startOfDay
        switch self {
        case .fourWeeks:
            return DateInterval(start: start.adding(days: -14), end: start.adding(days: 28))
        case .tenWeeks:
            return DateInterval(start: start.adding(days: -14), end: start.adding(days: 70))
        case .wholeYear:
            let calendar = Calendar.current
            let startOfYear = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? start
            let endOfYear = calendar.date(byAdding: DateComponents(year: 1), to: startOfYear) ?? start.adding(days: 365)
            return DateInterval(start: startOfYear, end: endOfYear)
        }
    }
}

/// Everything the "publish the plan into a calendar" feature remembers.
///
/// Stored in `UserDefaults` on this device only, the same way
/// `CalendarIntegrationSettings` keeps calendar choices local: which calendar
/// this device writes into, and this feature's own record of which
/// `EKEvent` mirrors which `MealPlanEntry` — both meaningless on another
/// family member's device, which has its own `EKEventStore`.
@MainActor
@Observable
final class PublishedCalendarSettings {

    enum Keys {
        static let calendarID = "publishedCalendar.destinationCalendarID"
        static let calendarTitle = "publishedCalendar.destinationCalendarTitle"
        static let range = "publishedCalendar.range"
        static let lastPublishedAt = "publishedCalendar.lastPublishedAt"
        static let eventMap = "publishedCalendar.eventMap"
    }

    private let defaults: UserDefaults

    private var calendarIDValue: String?
    private var calendarTitleValue: String?
    private var rangeValue: PublishedCalendarRange
    private var lastPublishedAtValue: Date?
    private var eventMapValue: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        calendarIDValue = defaults.string(forKey: Keys.calendarID)
        calendarTitleValue = defaults.string(forKey: Keys.calendarTitle)
        rangeValue = defaults.string(forKey: Keys.range).flatMap(PublishedCalendarRange.init(rawValue:)) ?? .tenWeeks
        lastPublishedAtValue = defaults.object(forKey: Keys.lastPublishedAt) as? Date
        eventMapValue = Self.load([String: String].self, from: defaults, key: Keys.eventMap) ?? [:]
    }

    /// Whether a destination calendar has been chosen — the feature is "on"
    /// exactly when this is true, there is no separate switch to forget.
    var isPublishing: Bool { calendarIDValue != nil }

    /// `EKCalendar.calendarIdentifier` of the calendar entries are written
    /// into.
    var destinationCalendarID: String? { calendarIDValue }

    /// Cached display name of that calendar, so Settings has something to
    /// show without asking EventKit again.
    var destinationCalendarTitle: String? { calendarTitleValue }

    var range: PublishedCalendarRange {
        get { rangeValue }
        set {
            rangeValue = newValue
            defaults.set(newValue.rawValue, forKey: Keys.range)
        }
    }

    var lastPublishedAt: Date? { lastPublishedAtValue }

    func setDestination(calendarID: String, title: String) {
        calendarIDValue = calendarID
        calendarTitleValue = title
        defaults.set(calendarID, forKey: Keys.calendarID)
        defaults.set(title, forKey: Keys.calendarTitle)
    }

    /// Forgets the destination and this feature's record of which event
    /// belongs to which entry. Does not itself remove anything from
    /// Calendar — the caller does that first, while the map that says what
    /// to remove still exists.
    func clearDestination() {
        calendarIDValue = nil
        calendarTitleValue = nil
        lastPublishedAtValue = nil
        eventMapValue = [:]
        defaults.removeObject(forKey: Keys.calendarID)
        defaults.removeObject(forKey: Keys.calendarTitle)
        defaults.removeObject(forKey: Keys.lastPublishedAt)
        defaults.removeObject(forKey: Keys.eventMap)
    }

    func markPublished(at date: Date) {
        lastPublishedAtValue = date
        defaults.set(date, forKey: Keys.lastPublishedAt)
    }

    // MARK: - Entry → event mapping

    /// This feature's own record of which `EKEvent` mirrors which
    /// `MealPlanEntry`, so the next sync updates or removes the right event
    /// instead of guessing or duplicating.
    var eventMap: [UUID: String] {
        get { Dictionary(uniqueKeysWithValues: eventMapValue.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } }) }
        set {
            eventMapValue = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) })
            store(eventMapValue, forKey: Keys.eventMap)
        }
    }

    // MARK: - Storage helpers

    private func store<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
