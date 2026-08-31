import Foundation
import Observation

/// Owns the calendar feature: permission state, the user's choices, a small
/// cache of the events the visible plan needs, and the derived meal context.
///
/// Views ask this for a `MealPlanningContext` and get `nil` whenever the
/// feature is off, permission is missing, no calendar is selected or EventKit
/// failed — so the planner degrades to exactly what it was before.
@MainActor
@Observable
final class CalendarContextStore {

    /// Weeks kept in the cache. The planner scrolls endlessly; the calendar
    /// only ever follows the few weeks around what is on screen.
    private static let maxCachedWeeks = 5
    /// Coalesces the burst of week requests a scroll produces.
    private static let refreshDebounce: Duration = .milliseconds(150)

    let settings: CalendarIntegrationSettings
    private let provider: any CalendarEventProviding
    private let calendar: Calendar

    private(set) var authorization: CalendarAuthorization = .notDetermined
    private(set) var availableCalendars: [MealCalendarInfo] = []
    /// `availableCalendars` keyed by identifier, so building a day's context
    /// doesn't rebuild the lookup on every redraw. Always written through
    /// `setAvailableCalendars(_:)`.
    private var calendarsByIdentifier: [String: MealCalendarInfo] = [:]
    private(set) var isLoadingCalendars = false
    /// Set when a calendar read failed. Purely informational — the planner
    /// keeps working either way.
    private(set) var lastErrorDescription: String?

    private var eventsByDay: [String: [MealCalendarEvent]] = [:]
    private var requestedWeeks: [Date] = []
    /// The range the cache was last filled from, so an unchanged set of visible
    /// weeks never triggers a second query.
    private var loadedRange: DateInterval?
    private var refreshTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?

    init(
        settings: CalendarIntegrationSettings = CalendarIntegrationSettings(),
        provider: any CalendarEventProviding = EventKitCalendarService(),
        calendar: Calendar = .current
    ) {
        self.settings = settings
        self.provider = provider
        self.calendar = calendar
    }

    // MARK: - State

    /// True only when calendar context may actually be shown.
    var isActive: Bool {
        settings.isEnabled
            && authorization.canReadEvents
            && !settings.selectedCalendarIdentifiers.isEmpty
    }

    /// The feature is on but can't produce anything yet — Settings uses this to
    /// explain what is missing.
    var needsAttention: Bool {
        settings.isEnabled && !isActive
    }

    // MARK: - Lifecycle

    /// Called once when the app starts. Reads the current authorization state
    /// (which never prompts) and only touches the calendar if the user has
    /// already turned the feature on.
    func start() async {
        await refreshAuthorization()
        guard settings.isEnabled else { return }
        observeCalendarChanges()
        await loadAvailableCalendars()
        await refreshNow()
    }

    /// Re-checks permission when the app comes back to the foreground: access
    /// can be revoked in system Settings while the app is in the background.
    func applicationBecameActive() async {
        guard settings.isEnabled else { return }
        await refreshAuthorization()
        await refreshNow()
    }

    func refreshAuthorization() async {
        let status = await provider.authorization()
        guard status != authorization else { return }
        authorization = status
        if !status.canReadEvents {
            // Access went away: drop everything derived from it, keep the
            // user's selection so turning access back on just works.
            eventsByDay = [:]
            loadedRange = nil
            setAvailableCalendars([])
        }
    }

    /// The user flipped the switch on. Deliberately does **not** ask the
    /// system for permission: the UI explains why access is needed first and
    /// only `requestCalendarAccess()` may prompt.
    func enableIntegration() async {
        settings.isEnabled = true
        await refreshAuthorization()
        observeCalendarChanges()
        guard authorization.canReadEvents else { return }
        await loadAvailableCalendars()
        await refreshNow()
    }

    /// The explicit "Allow Calendar access" action, taken after the user has
    /// read what the access is for. Prompts only while the system has never
    /// asked — a denied or restricted user is never asked again.
    func requestCalendarAccess() async {
        guard settings.isEnabled else { return }
        guard authorization.canRequestAccess else {
            await refreshAuthorization()
            return
        }
        authorization = await provider.requestAccess()
        guard authorization.canReadEvents else { return }
        observeCalendarChanges()
        await loadAvailableCalendars()
        await refreshNow()
    }

    /// The user flipped the switch off: stop observing, stop querying, forget
    /// every event held in memory. Their calendar choices are kept so turning
    /// the feature back on doesn't start from scratch.
    func disableIntegration() {
        settings.isEnabled = false
        refreshTask?.cancel()
        refreshTask = nil
        observationTask?.cancel()
        observationTask = nil
        eventsByDay = [:]
        loadedRange = nil
        setAvailableCalendars([])
        requestedWeeks = []
        lastErrorDescription = nil
    }

    func loadAvailableCalendars() async {
        guard settings.isEnabled, authorization.canReadEvents else {
            setAvailableCalendars([])
            return
        }
        isLoadingCalendars = true
        defer { isLoadingCalendars = false }
        do {
            let calendars = try await provider.availableCalendars()
            setAvailableCalendars(calendars)
            lastErrorDescription = nil
            // Only reconcile against a list we actually read — an empty result
            // from a failing store must not wipe the user's selection.
            if !calendars.isEmpty {
                settings.reconcile(with: calendars)
            }
        } catch {
            setAvailableCalendars([])
            lastErrorDescription = error.localizedDescription
        }
    }

    private func setAvailableCalendars(_ calendars: [MealCalendarInfo]) {
        availableCalendars = calendars
        calendarsByIdentifier = Dictionary(calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Fetching

    /// The planner tells the store which week it is showing. Only the weeks
    /// around what is on screen are ever queried.
    func requestWeek(_ weekStart: Date) {
        let normalized = calendar.startOfDay(for: weekStart)
        if let index = requestedWeeks.firstIndex(of: normalized) {
            requestedWeeks.remove(at: index)
        }
        requestedWeeks.append(normalized)
        if requestedWeeks.count > Self.maxCachedWeeks {
            requestedWeeks.removeFirst(requestedWeeks.count - Self.maxCachedWeeks)
        }
        guard isActive, cachedRange() != loadedRange else { return }
        scheduleRefresh()
    }

    /// Settings changed (calendars, privacy level): everything cached was read
    /// under the old rules, so throw it away and read again.
    func settingsChanged() {
        eventsByDay = [:]
        loadedRange = nil
        guard isActive else {
            refreshTask?.cancel()
            refreshTask = nil
            return
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshDebounce)
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }

    /// Fetch the events for the weeks currently on screen. Safe to call any
    /// time: it does nothing at all unless the feature is fully active.
    func refreshNow() async {
        guard isActive, let range = cachedRange() else {
            eventsByDay = [:]
            loadedRange = nil
            return
        }
        do {
            let events = try await provider.events(
                in: range,
                calendarIdentifiers: settings.selectedCalendarIdentifiers,
                includeTitles: settings.privacyMode == .eventTitles
            )
            eventsByDay = Self.bucketByDay(events, in: range, calendar: calendar)
            loadedRange = range
            lastErrorDescription = nil
        } catch {
            // EventKit failed or access vanished mid-flight. The planner simply
            // shows no calendar context.
            eventsByDay = [:]
            loadedRange = nil
            lastErrorDescription = error.localizedDescription
            if (error as? CalendarProviderError) == .notAuthorized {
                await refreshAuthorization()
            }
        }
    }

    /// One query covering every week on screen, never more.
    private func cachedRange() -> DateInterval? {
        guard let first = requestedWeeks.min(), let last = requestedWeeks.max() else { return nil }
        let start = calendar.startOfDay(for: first)
        let end = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: last))
            ?? last.addingTimeInterval(7 * 24 * 60 * 60)
        return DateInterval(start: start, end: max(start, end))
    }

    /// Group events by the days they touch, so an event running over midnight
    /// is available to both days.
    private static func bucketByDay(
        _ events: [MealCalendarEvent],
        in range: DateInterval,
        calendar: Calendar
    ) -> [String: [MealCalendarEvent]] {
        var result: [String: [MealCalendarEvent]] = [:]
        for event in events {
            let eventEnd = max(event.startDate, event.endDate)
            let firstDay = calendar.startOfDay(for: max(event.startDate, range.start))
            let lastDay = calendar.startOfDay(for: min(eventEnd, range.end))
            var day = firstDay
            // Nothing sane spans more than a year; the guard just makes the
            // loop impossible to run away on malformed data.
            var guardrail = 0
            while day <= lastDay, guardrail < 400 {
                guardrail += 1
                // An event ending exactly at midnight belongs to the day before.
                let endsAtThisMidnight = eventEnd == day && eventEnd > event.startDate
                if !endsAtThisMidnight {
                    result[day.dayID, default: []].append(event)
                }
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            }
        }
        return result
    }

    // MARK: - Reading context

    /// Cached events for a day, already limited to the selected calendars.
    func events(on day: Date) -> [MealCalendarEvent] {
        guard isActive else { return [] }
        let selected = settings.selectedCalendarIdentifiers
        return (eventsByDay[day.dayID] ?? []).filter { selected.contains($0.calendarIdentifier) }
    }

    /// What the calendar means for one meal, or `nil` when it has nothing to
    /// say (including whenever the feature is unavailable).
    func context(for day: Date, mealKey: String, mealName: String) -> MealPlanningContext? {
        guard isActive else { return nil }
        let dayEvents = events(on: day)
        guard !dayEvents.isEmpty else { return nil }
        return MealPlanningContextBuilder.context(
            date: day,
            mealKey: mealKey,
            mealName: mealName,
            window: settings.window(forMealKey: mealKey),
            events: dayEvents,
            privacyMode: settings.privacyMode,
            calendarOwners: settings.activeCalendarOwners,
            calendars: calendarsByIdentifier,
            calendar: calendar
        )
    }

    /// Contexts for a day's meals, in the order the meals are planned, skipping
    /// meals the calendar says nothing about.
    func contexts(for day: Date, meals: [DayMeal]) -> [MealPlanningContext] {
        guard isActive else { return [] }
        return meals.compactMap { context(for: day, mealKey: $0.key, mealName: $0.name) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Change observation

    /// Follow EventKit's change notifications instead of polling.
    private func observeCalendarChanges() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            guard let stream = self?.provider.changes else { return }
            for await _ in stream {
                guard let self else { return }
                await self.calendarDatabaseChanged()
            }
        }
    }

    private func calendarDatabaseChanged() async {
        guard settings.isEnabled else { return }
        await refreshAuthorization()
        await loadAvailableCalendars()
        await refreshNow()
    }
}
