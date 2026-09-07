import Foundation
import SwiftData
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

/// Keeps subscribed feeds fresh, and puts enough of each article on disk that
/// the household can read recipes on a train with no signal.
///
/// Refreshing the metadata is only half of it: an article is a web page, so
/// browsing offline means the page and its photo have to already be cached.
/// Both caches are bounded and local, and neither syncs.
@MainActor
enum RecipeFeedBackgroundRefresh {
    /// Must match the identifier registered in Info.plist's
    /// `BGTaskSchedulerPermittedIdentifiers`.
    static let taskIdentifier = "de.holgerkrupp.mealplan.feedrefresh"

    /// How long to leave between background refreshes. Recipe blogs publish
    /// daily at most, and this is a courtesy to the battery.
    private static let interval: TimeInterval = 6 * 60 * 60

    /// Articles warmed for offline reading per run, newest first. Each one is
    /// an HTML page plus a photo, so this is deliberately modest.
    private static let prefetchLimit = 12

    /// Entry point for the background task, which runs outside the main actor.
    /// Only the container crosses the boundary — `ModelContext` is not Sendable.
    static func run(container: ModelContainer) async {
        await run(context: container.mainContext)
    }

    /// Refreshes every feed and then warms the newest unread articles.
    static func run(context: ModelContext) async {
        await RecipeFeedService.refreshAll(context: context)
        await prefetchNewestArticles(context: context)
    }

    /// Downloads the article pages and photos most likely to be opened next, so
    /// they are already on disk when the connection isn't.
    static func prefetchNewestArticles(context: ModelContext) async {
        let feeds = (try? context.fetch(FetchDescriptor<RecipeFeed>())) ?? []
        let newest = feeds
            .flatMap { $0.currentItems.prefix(prefetchLimit) }
            .sorted { ($0.publishedAt ?? $0.fetchedAt) > ($1.publishedAt ?? $1.fetchedAt) }
            .filter { !RecipeFeedReadState.isRead($0.stableID) }
            .prefix(prefetchLimit)

        for item in newest {
            guard !Task.isCancelled, let url = item.url else { continue }
            // Fetching the page fills the article cache and, for a feed that
            // carries no artwork, is also where the picture comes from.
            guard let html = try? await RecipeArticleCache.shared.articleHTML(for: url) else { continue }
            if item.imageURL == nil, item.imageLookupAt == nil {
                item.imageURLString = RecipeFeedImageResolver
                    .imageURL(inHTML: html, relativeTo: url)?.absoluteString
                item.imageLookupAt = .now
            }
            if let imageURL = item.imageURL {
                await RecipeFeedImagePrefetch.warm(imageURL)
            }
        }
        try? context.save()
    }

    // MARK: - Scheduling

    #if canImport(BackgroundTasks) && os(iOS)
    /// Asks the system for another run. iOS decides when — and whether — that
    /// actually happens, so nothing in the app may depend on it having run.
    static func scheduleNextRun() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }
    #else
    static func scheduleNextRun() {}
    #endif
}

/// Pulls an image through `URLSession`'s shared cache so it is on disk for
/// later. The bytes are dropped straight away — the point is the HTTP cache
/// entry, not holding a picture in memory.
enum RecipeFeedImagePrefetch {
    static func warm(_ url: URL) async {
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        _ = try? await URLSession.shared.data(for: request)
    }
}
