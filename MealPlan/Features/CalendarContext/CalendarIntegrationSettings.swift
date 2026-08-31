import Foundation

/// How much of a calendar event may show up in the meal planner.
enum CalendarPrivacyMode: String, CaseIterable, Identifiable, Sendable, Codable {
    /// The default: times only, never what the appointment is.
    case availabilityOnly
    /// Event titles, only if the user asks for them.
    case eventTitles

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .availabilityOnly: String(localized: "Availability only")
        case .eventTitles: String(localized: "Event titles")
        }
    }

    var localizedDescription: String {
        switch self {
        case .availabilityOnly:
            String(localized: "Shows only when someone is busy, never what they are doing.")
        case .eventTitles:
            String(localized: "Also shows the title of an event. Notes, invitees, locations and links are never shown.")
        }
    }
}

/// Everything the calendar feature remembers.
///
/// Stored in `UserDefaults` on this device only. Calendar choices say a lot
/// about a person, so they are deliberately *not* part of the household's
/// CloudKit-synced model: another family member's device never learns which
/// calendars this one reads, and no event ever reaches the app's own store.
@MainActor
@Observable
final class CalendarIntegrationSettings {

    enum Keys {
        static let enabled = "calendar.integration.enabled"
        static let selectedCalendars = "calendar.integration.selectedCalendarIdentifiers"
        static let privacyMode = "calendar.integration.privacyMode"
        static let mealWindows = "calendar.integration.mealWindows"
        static let calendarOwners = "calendar.integration.calendarOwners"
    }

    // Tracked storage. Views observe these; the properties below are the API
    // and make sure every write is also persisted.
    private var enabledValue: Bool
    private var selectedValue: Set<String>
    private var privacyValue: CalendarPrivacyMode
    private var windowsValue: [String: MealTimeWindow]
    private var ownersValue: [String: String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabledValue = defaults.bool(forKey: Keys.enabled)
        selectedValue = Set(defaults.stringArray(forKey: Keys.selectedCalendars) ?? [])
        privacyValue = (defaults.string(forKey: Keys.privacyMode)
            .flatMap(CalendarPrivacyMode.init(rawValue:))) ?? .availabilityOnly
        windowsValue = Self.load([String: MealTimeWindow].self, from: defaults, key: Keys.mealWindows) ?? [:]
        ownersValue = Self.load([String: String].self, from: defaults, key: Keys.calendarOwners) ?? [:]
    }

    /// Off until the user turns it on. Nothing calendar-related happens — not
    /// even a permission check — while this is false.
    var isEnabled: Bool {
        get { enabledValue }
        set {
            enabledValue = newValue
            defaults.set(newValue, forKey: Keys.enabled)
        }
    }

    /// Empty by default: no calendar takes part until the user picks it, and a
    /// newly discovered calendar never joins on its own.
    var selectedCalendarIdentifiers: Set<String> {
        get { selectedValue }
        set {
            selectedValue = newValue
            defaults.set(newValue.sorted(), forKey: Keys.selectedCalendars)
        }
    }

    var privacyMode: CalendarPrivacyMode {
        get { privacyValue }
        set {
            privacyValue = newValue
            defaults.set(newValue.rawValue, forKey: Keys.privacyMode)
        }
    }

    /// Per-meal windows, keyed by `MealType.key`. Only meals the user retimed
    /// are stored; everything else falls back to `MealTimeWindow.standard`.
    var mealWindows: [String: MealTimeWindow] {
        get { windowsValue }
        set {
            windowsValue = newValue
            store(newValue, forKey: Keys.mealWindows)
        }
    }

    /// Optional calendar identifier → household member name. Purely a user
    /// choice; the app never guesses who a calendar belongs to.
    var calendarOwners: [String: String] {
        get { ownersValue }
        set {
            ownersValue = newValue
            store(newValue, forKey: Keys.calendarOwners)
        }
    }

    // MARK: - Calendars

    func isSelected(_ calendarID: String) -> Bool {
        selectedCalendarIdentifiers.contains(calendarID)
    }

    func setSelected(_ isOn: Bool, for calendarID: String) {
        var updated = selectedCalendarIdentifiers
        if isOn { updated.insert(calendarID) } else { updated.remove(calendarID) }
        selectedCalendarIdentifiers = updated
    }

    func selectAll(_ calendars: [MealCalendarInfo]) {
        selectedCalendarIdentifiers = Set(calendars.map(\.id))
    }

    func selectNone() {
        selectedCalendarIdentifiers = []
    }

    /// Forget calendars that no longer exist, so a deleted calendar doesn't
    /// linger in the selection (or in a person mapping) forever.
    ///
    /// Only called with a list the app actually managed to read — losing access
    /// must not wipe the user's choices.
    func reconcile(with available: [MealCalendarInfo]) {
        let ids = Set(available.map(\.id))
        let stillSelected = selectedCalendarIdentifiers.intersection(ids)
        if stillSelected != selectedCalendarIdentifiers {
            selectedCalendarIdentifiers = stillSelected
        }
        let owners = calendarOwners.filter { ids.contains($0.key) }
        if owners != calendarOwners {
            calendarOwners = owners
        }
    }

    // MARK: - Meal windows

    func window(forMealKey key: String) -> MealTimeWindow {
        mealWindows[key] ?? .standard(forMealKey: key)
    }

    func setWindow(_ window: MealTimeWindow, forMealKey key: String) {
        var updated = mealWindows
        updated[key] = window
        mealWindows = updated
    }

    func resetWindow(forMealKey key: String) {
        guard mealWindows[key] != nil else { return }
        var updated = mealWindows
        updated.removeValue(forKey: key)
        mealWindows = updated
    }

    // MARK: - People

    func owner(of calendarID: String) -> String? {
        calendarOwners[calendarID]
    }

    func setOwner(_ name: String?, for calendarID: String) {
        var updated = calendarOwners
        if let name, !name.isEmpty { updated[calendarID] = name } else { updated.removeValue(forKey: calendarID) }
        calendarOwners = updated
    }

    /// The mappings that still point at a calendar taking part in planning.
    var activeCalendarOwners: [String: String] {
        calendarOwners.filter { selectedCalendarIdentifiers.contains($0.key) }
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
