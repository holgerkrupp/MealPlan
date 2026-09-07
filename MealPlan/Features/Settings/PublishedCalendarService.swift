import Foundation
import SwiftData

/// Orchestrates "publish the plan into a calendar": turns the current plan
/// into payloads, hands them to a `CalendarEventWriting` implementation, and
/// keeps `PublishedCalendarSettings` in step with what actually happened.
///
/// Everything EventKit-shaped stays behind `CalendarEventWriting` — this type
/// only ever talks to that protocol, never to `EKEventStore` directly, so it
/// can be exercised with a mock in tests.
@MainActor
enum PublishedCalendarService {

    enum ServiceError: LocalizedError {
        case noDestinationChosen
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .noDestinationChosen:
                String(localized: "Choose a calendar to publish to first.")
            case .encodingFailed:
                String(localized: "Couldn’t build the calendar file.")
            }
        }
    }

    private static var pendingTask: Task<Void, Never>?

    // MARK: - Building payloads

    /// The current window's payloads, for the household in `settings.range`.
    static func fetchPayloads(household: Household?, settings: PublishedCalendarSettings, context: ModelContext) throws -> [MealPlanPublishPayload] {
        let (entries, mealsByKey) = try fetchEntries(household: household, settings: settings, context: context)
        return MealPlanPublishPayloadBuilder.payloads(for: entries, mealTypesByKey: mealsByKey)
    }

    /// Everything planned in `settings.range` for `household`, plus a lookup
    /// of the household's meals — the shared fetch behind both the payload
    /// builder above and the `.ics` snapshot below.
    private static func fetchEntries(
        household: Household?, settings: PublishedCalendarSettings, context: ModelContext
    ) throws -> (entries: [MealPlanEntry], mealsByKey: [String: MealType]) {
        let interval = settings.range.interval()
        let start = interval.start
        let end = interval.end
        let descriptor = FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end && $0.skipped == false }
        )
        var entries = try context.fetch(descriptor)
        if let household {
            entries = entries.filter { $0.household?.uuid == household.uuid }
        }
        let mealsByKey = Dictionary(
            uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<MealType>())) ?? []).map { ($0.key, $0) }
        )
        return (entries, mealsByKey)
    }

    static func calendarName(household: Household?) -> String {
        guard let household, !household.name.isEmpty else { return String(localized: "Meal Plan") }
        return String(localized: "\(household.name) Meal Plan")
    }

    // MARK: - Publishing

    /// First-time publish (or switching to a different destination): remembers
    /// the calendar, then writes the current window into it.
    static func publish(
        calendarID: String,
        calendarTitle: String,
        household: Household?,
        settings: PublishedCalendarSettings,
        context: ModelContext,
        writer: any CalendarEventWriting
    ) async throws {
        // A previous destination's events don't belong in the new one.
        if settings.isPublishing, !settings.eventMap.isEmpty {
            await writer.removeEvents(identifiers: Array(settings.eventMap.values))
        }
        settings.setDestination(calendarID: calendarID, title: calendarTitle)
        settings.eventMap = [:]
        try await refresh(household: household, settings: settings, context: context, writer: writer)
    }

    /// Brings the destination calendar in line with the current plan.
    static func refresh(
        household: Household?,
        settings: PublishedCalendarSettings,
        context: ModelContext,
        writer: any CalendarEventWriting
    ) async throws {
        guard let calendarID = settings.destinationCalendarID else { throw ServiceError.noDestinationChosen }
        let payloads = try fetchPayloads(household: household, settings: settings, context: context)
        let updatedMap = try await writer.sync(
            payloads: payloads,
            calendarIdentifier: calendarID,
            knownEventIDs: settings.eventMap
        )
        settings.eventMap = updatedMap
        settings.markPublished(at: .now)
    }

    /// Removes every event this feature wrote, then forgets the destination.
    static func stopPublishing(settings: PublishedCalendarSettings, writer: any CalendarEventWriting) async {
        if !settings.eventMap.isEmpty {
            await writer.removeEvents(identifiers: Array(settings.eventMap.values))
        }
        settings.clearDestination()
    }

    /// Debounced auto-refresh, safe to call after every plan edit. A no-op
    /// until a destination has actually been chosen.
    static func scheduleRefreshIfNeeded(
        household: Household?,
        settings: PublishedCalendarSettings,
        context: ModelContext,
        writer: any CalendarEventWriting
    ) {
        guard settings.isPublishing else { return }
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            try? await refresh(household: household, settings: settings, context: context, writer: writer)
        }
    }

    // MARK: - One-off sharing

    /// A snapshot `.ics` for `ShareLink`/AirDrop — doesn't touch the
    /// published calendar, for sending someone a one-time copy of the plan
    /// rather than setting up a live calendar.
    static func makeSnapshotFile(household: Household?, settings: PublishedCalendarSettings, context: ModelContext) throws -> URL {
        let (entries, mealsByKey) = try fetchEntries(household: household, settings: settings, context: context)
        let ics = MealPlanICSExporter.makeICS(calendarName: calendarName(household: household), entries: entries, mealTypesByKey: mealsByKey)
        guard let data = ics.data(using: .utf8) else { throw ServiceError.encodingFailed }
        let filename = "\(calendarName(household: household).replacingOccurrences(of: "/", with: "-")).\(PublishedCalendarFileType.fileExtension)"
        let url = FileManager.default.temporaryDirectory.appending(path: filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}
