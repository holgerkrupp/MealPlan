import Foundation
import SwiftData

@MainActor
enum RecipeFeedService {
    /// A site's feed, fetched and parsed but not yet stored. The subscribe
    /// sheet shows one of these so the recipes can be browsed before the
    /// household commits to the site.
    struct ResolvedFeed {
        let parsed: ParsedRecipeFeed
        let feedURL: URL
        let siteURL: URL
        let response: HTTPURLResponse
    }

    /// Discovers the advertised feed from a human-friendly home page and reads
    /// it, touching nothing in the store.
    static func resolveFeed(at rawURL: URL) async throws -> ResolvedFeed {
        let siteURL = normalizedWebURL(rawURL)
        let request = URLRequest(url: siteURL, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RecipeFeedParserError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")

        let parsed: ParsedRecipeFeed
        let feedURL: URL
        let finalResponse: HTTPURLResponse
        if let direct = try? RecipeFeedParser.parse(data, contentType: contentType, sourceURL: siteURL) {
            parsed = direct
            feedURL = siteURL
            finalResponse = http
        } else {
            guard let html = String(data: data, encoding: .utf8),
                  let discoveredURL = RecipeFeedDiscovery.feedURLs(inHTML: html, baseURL: siteURL).first else {
                throw RecipeFeedParserError.noFeedLink
            }
            feedURL = discoveredURL
            let (feedData, feedResponse) = try await URLSession.shared.data(from: discoveredURL)
            guard let feedHTTP = feedResponse as? HTTPURLResponse, (200..<300).contains(feedHTTP.statusCode) else {
                throw RecipeFeedParserError.httpStatus((feedResponse as? HTTPURLResponse)?.statusCode ?? 0)
            }
            parsed = try RecipeFeedParser.parse(
                feedData,
                contentType: feedHTTP.value(forHTTPHeaderField: "Content-Type"),
                sourceURL: discoveredURL
            )
            finalResponse = feedHTTP
        }

        return ResolvedFeed(parsed: parsed, feedURL: feedURL, siteURL: siteURL, response: finalResponse)
    }

    /// Discovers the advertised feed from a human-friendly home page and
    /// performs the first refresh before inserting anything into the store.
    static func subscribe(to rawURL: URL, household: Household?, context: ModelContext) async throws -> RecipeFeed {
        try await subscribe(to: resolveFeed(at: rawURL), household: household, context: context)
    }

    /// Stores a feed the caller has already read, so subscribing from a preview
    /// does not fetch the same pages twice.
    @discardableResult
    static func subscribe(to resolved: ResolvedFeed, household: Household?, context: ModelContext) async throws -> RecipeFeed {
        if let existing = try context.fetch(FetchDescriptor<RecipeFeed>()).first(where: { $0.feedURLString == resolved.feedURL.absoluteString }) {
            return existing
        }
        let feed = RecipeFeed(
            title: resolved.parsed.title,
            siteURL: resolved.parsed.homeURL ?? resolved.siteURL,
            feedURL: resolved.feedURL
        )
        feed.household = household
        context.insert(feed)
        try await merge(resolved.parsed, into: feed, context: context)
        markSuccess(feed, response: resolved.response)
        try context.save()
        return feed
    }

    /// Whether this household is already subscribed to the given feed.
    static func isSubscribed(toFeedAt feedURL: URL, context: ModelContext) -> Bool {
        let feeds = (try? context.fetch(FetchDescriptor<RecipeFeed>())) ?? []
        return feeds.contains { $0.feedURLString == feedURL.absoluteString }
    }

    static func refreshAll(context: ModelContext, force: Bool = false) async {
        let feeds = (try? context.fetch(FetchDescriptor<RecipeFeed>())) ?? []
        for feed in feeds {
            try? await refresh(feed, context: context, force: force)
        }
    }

    static func refresh(_ feed: RecipeFeed, context: ModelContext, force: Bool = false) async throws {
        guard let url = feed.feedURL else { throw RecipeFeedParserError.invalidURL }
        if !force, let retry = feed.nextRetryAt, retry > .now { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if let etag = feed.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = feed.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RecipeFeedParserError.unsupportedFormat }
            if http.statusCode == 304 {
                markSuccess(feed, response: http)
                try context.save()
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                throw RecipeFeedParserError.httpStatus(http.statusCode)
            }
            let parsed = try RecipeFeedParser.parse(
                data,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                sourceURL: url
            )
            feed.title = parsed.title
            if let home = parsed.homeURL { feed.siteURLString = home.absoluteString }
            try await merge(parsed, into: feed, context: context)
            markSuccess(feed, response: http)
            try context.save()
        } catch {
            markFailure(feed, error: error)
            try? context.save()
            throw error
        }
    }

    /// How many articles a single feed keeps, current and archived together.
    /// Generous enough that a weekly blog is kept for years, bounded so a
    /// high-volume magazine cannot grow the shared store without limit.
    static let archiveLimit = 600

    private static func merge(_ parsed: ParsedRecipeFeed, into feed: RecipeFeed, context: ModelContext) async throws {
        var existing = Dictionary(uniqueKeysWithValues: (feed.items ?? []).map { ($0.stableID, $0) })
        for article in parsed.articles.prefix(100) where RecipeArticleClassifier.isLikelyRecipe(article) {
            let item = existing.removeValue(forKey: article.id)
                ?? RecipeFeedItem(stableID: article.id, title: article.title, url: article.url)
            if item.feed == nil { context.insert(item) }
            item.title = article.title
            item.urlString = article.url.absoluteString
            item.author = article.author
            item.summary = article.summary
            item.publishedAt = article.publishedAt
            item.imageURLString = article.imageURL?.absoluteString ?? item.imageURLString
            item.fetchedAt = .now
            // A post can reappear after a site edits and republishes it.
            item.archivedAt = nil
            item.feed = feed
        }

        // Everything the feed no longer lists is archived rather than deleted:
        // a blog that publishes ten posts at a time would otherwise quietly
        // lose a recipe for anyone who didn't open the app that week.
        for stranded in existing.values where stranded.archivedAt == nil {
            stranded.archivedAt = .now
        }

        // The archive is still bounded. The oldest archived posts go first, and
        // only once the feed is over its limit.
        let all = feed.sortedItems
        guard all.count > archiveLimit else { return }
        let doomed = all.dropFirst(archiveLimit).filter(\.isArchived)
        for item in doomed { context.delete(item) }
    }

    private static func markSuccess(_ feed: RecipeFeed, response: HTTPURLResponse) {
        feed.etag = response.value(forHTTPHeaderField: "ETag") ?? feed.etag
        feed.lastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? feed.lastModified
        feed.lastFetchedAt = .now
        feed.firstFailureAt = nil
        feed.consecutiveFailures = 0
        feed.nextRetryAt = nil
        feed.lastHTTPStatus = response.statusCode
        feed.lastErrorMessage = nil
    }

    private static func markFailure(_ feed: RecipeFeed, error: Error) {
        feed.firstFailureAt = feed.firstFailureAt ?? .now
        feed.consecutiveFailures += 1
        feed.nextRetryAt = RecipeFeedRefreshPolicy.retryDate(after: feed.consecutiveFailures)
        feed.lastErrorMessage = error.localizedDescription
        if case RecipeFeedParserError.httpStatus(let status) = error { feed.lastHTTPStatus = status }
    }

    private static func normalizedWebURL(_ url: URL) -> URL {
        guard url.scheme == nil, let withScheme = URL(string: "https://\(url.absoluteString)") else { return url }
        return withScheme
    }
}

/// Reading belongs to an iCloud account, not a household. Key-value iCloud is
/// private to that person, so one family member opening a post does not mark it
/// read for everyone else.
@MainActor
enum RecipeFeedReadState {
    private static let key = "RecipeFeed.readItemIDs.v1"
    private static let store = NSUbiquitousKeyValueStore.default

    static func isRead(_ itemID: String) -> Bool {
        Set(store.array(forKey: key) as? [String] ?? []).contains(itemID)
    }

    static func markRead(_ itemID: String) {
        var ids = Set(store.array(forKey: key) as? [String] ?? [])
        ids.insert(itemID)
        // This is ephemeral presentation state. Capping it prevents an old
        // account from growing the ubiquitous store without bound.
        store.set(Array(ids.suffix(2_000)), forKey: key)
        store.synchronize()
    }
}
