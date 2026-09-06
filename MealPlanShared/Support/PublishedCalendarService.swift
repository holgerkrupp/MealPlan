import Foundation
import SwiftData

/// Writes the household's plan to a plain `.ics` file at a location the user
/// picked (typically inside iCloud Drive), and keeps it up to date there.
///
/// There is no server here and none is needed: once the user turns the file
/// itself into a public link (Files → the file → Share → "Anyone with the
/// link can view"), that link *is* the subscribable calendar — any calendar
/// app that supports "subscribe from URL" re-fetches the same bytes this
/// writes. All this service does is keep those bytes current in place, via a
/// security-scoped bookmark saved in `PublishedCalendarSettings`, so the link
/// never has to change.
@MainActor
enum PublishedCalendarService {

    enum ServiceError: LocalizedError {
        case noLocationChosen
        case staleBookmark
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .noLocationChosen:
                String(localized: "Choose where to publish the calendar first.")
            case .staleBookmark:
                String(localized: "MealPlan lost access to the published file. Choose its location again.")
            case .encodingFailed:
                String(localized: "Couldn’t build the calendar file.")
            }
        }
    }

    private static var pendingTask: Task<Void, Never>?

    // MARK: - Building the feed

    /// The current feed's bytes, for the household and window in `settings`.
    /// Used both to hand `.fileExporter` its first copy and to rewrite the
    /// published file on every refresh.
    static func makeData(household: Household?, settings: PublishedCalendarSettings, context: ModelContext) throws -> Data {
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
        let ics = MealPlanICSExporter.makeICS(
            calendarName: calendarName(household: household),
            entries: entries,
            mealTypesByKey: mealsByKey
        )
        guard let data = ics.data(using: .utf8) else { throw ServiceError.encodingFailed }
        return data
    }

    static func calendarName(household: Household?) -> String {
        guard let household, !household.name.isEmpty else { return String(localized: "Meal Plan") }
        return String(localized: "\(household.name) Meal Plan")
    }

    static func suggestedFilename(household: Household?) -> String {
        let sanitized = calendarName(household: household)
            .replacingOccurrences(of: "/", with: "-")
        return "\(sanitized).\(PublishedCalendarFileType.fileExtension)"
    }

    // MARK: - Publishing

    /// Call once `.fileExporter` hands back the URL it wrote `data` to.
    /// Rewrites those same bytes directly (belt and braces — some hosts
    /// coerce the content type on the way through) and remembers the location
    /// for future refreshes.
    static func confirmPublished(at url: URL, data: Data, settings: PublishedCalendarSettings) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
        let bookmark = try url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        settings.setPublishedLocation(bookmark: bookmark, filename: url.lastPathComponent)
        settings.markPublished(at: .now)
    }

    /// Rewrites the file at the remembered location with the current plan.
    static func refresh(household: Household?, settings: PublishedCalendarSettings, context: ModelContext) throws {
        guard let bookmark = settings.bookmark() else { throw ServiceError.noLocationChosen }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard accessing else { throw ServiceError.staleBookmark }

        let data = try makeData(household: household, settings: settings, context: context)
        try data.write(to: url, options: .atomic)

        if isStale, let refreshed = try? url.bookmarkData(
            options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            settings.setPublishedLocation(bookmark: refreshed, filename: url.lastPathComponent)
        }
        settings.markPublished(at: .now)
    }

    /// Debounced auto-refresh, safe to call after every plan edit. A no-op
    /// until a location has actually been chosen.
    static func scheduleRefreshIfNeeded(household: Household?, settings: PublishedCalendarSettings, context: ModelContext) {
        guard settings.isPublishing else { return }
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            try? refresh(household: household, settings: settings, context: context)
        }
    }

    // MARK: - One-off sharing

    /// A snapshot for `ShareLink`/AirDrop that never touches the published
    /// location — for sending someone a one-time copy of the plan rather than
    /// setting them up to subscribe.
    static func makeSnapshotFile(household: Household?, settings: PublishedCalendarSettings, context: ModelContext) throws -> URL {
        let data = try makeData(household: household, settings: settings, context: context)
        let url = FileManager.default.temporaryDirectory.appending(path: suggestedFilename(household: household))
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Bookmark options

    /// `.withSecurityScope` only exists on macOS; on iOS a file handed back by
    /// a document picker (which is what `.fileExporter` uses under the hood)
    /// is already security-scoped without asking for the option explicitly.
    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }
}
