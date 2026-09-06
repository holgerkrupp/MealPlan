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

/// Everything the "publish a subscribable calendar" feature remembers.
///
/// Stored in `UserDefaults` on this device only, the same way
/// `CalendarIntegrationSettings` keeps calendar choices local: the file this
/// publishes to lives wherever this device put it (typically iCloud Drive),
/// and the bookmark that lets MealPlan write to it again is meaningless on
/// another family member's device.
@MainActor
@Observable
final class PublishedCalendarSettings {

    enum Keys {
        static let bookmark = "publishedCalendar.bookmark"
        static let filename = "publishedCalendar.filename"
        static let range = "publishedCalendar.range"
        static let lastPublishedAt = "publishedCalendar.lastPublishedAt"
    }

    private let defaults: UserDefaults

    private var bookmarkValue: Data?
    private var filenameValue: String?
    private var rangeValue: PublishedCalendarRange
    private var lastPublishedAtValue: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bookmarkValue = defaults.data(forKey: Keys.bookmark)
        filenameValue = defaults.string(forKey: Keys.filename)
        rangeValue = defaults.string(forKey: Keys.range).flatMap(PublishedCalendarRange.init(rawValue:)) ?? .tenWeeks
        lastPublishedAtValue = defaults.object(forKey: Keys.lastPublishedAt) as? Date
    }

    /// Whether a location has been chosen — the feature is "on" exactly when
    /// this is true, there is no separate switch to forget to flip.
    var isPublishing: Bool { bookmarkValue != nil }

    var range: PublishedCalendarRange {
        get { rangeValue }
        set {
            rangeValue = newValue
            defaults.set(newValue.rawValue, forKey: Keys.range)
        }
    }

    /// Display name of the published file, for the settings screen.
    var filename: String? { filenameValue }

    var lastPublishedAt: Date? { lastPublishedAtValue }

    func bookmark() -> Data? { bookmarkValue }

    func setPublishedLocation(bookmark: Data, filename: String) {
        bookmarkValue = bookmark
        filenameValue = filename
        defaults.set(bookmark, forKey: Keys.bookmark)
        defaults.set(filename, forKey: Keys.filename)
    }

    /// Stops updating the file. Leaves the file itself (and whatever public
    /// link points at it) alone — MealPlan just forgets where it was.
    func stopPublishing() {
        bookmarkValue = nil
        filenameValue = nil
        lastPublishedAtValue = nil
        defaults.removeObject(forKey: Keys.bookmark)
        defaults.removeObject(forKey: Keys.filename)
        defaults.removeObject(forKey: Keys.lastPublishedAt)
    }

    func markPublished(at date: Date) {
        lastPublishedAtValue = date
        defaults.set(date, forKey: Keys.lastPublishedAt)
    }
}
