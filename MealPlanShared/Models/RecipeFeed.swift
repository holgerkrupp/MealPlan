import Foundation
import SwiftData

/// A recipe site's syndication feed. Article bodies are intentionally absent:
/// they are a bounded local cache, while this subscription metadata syncs.
@Model
final class RecipeFeed {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    var title: String = ""
    var siteURLString: String = ""
    var feedURLString: String = ""
    /// `feed` is the normal RSS/Atom/JSON case. The other two values retain
    /// enough information to refresh a public collection without pretending it
    /// has a syndication endpoint.
    var sourceKindRaw: String = RecipeSiteSourceKind.feed.rawValue
    var sourceID: String?
    var contentURLString: String?
    var etag: String?
    var lastModified: String?
    var lastFetchedAt: Date?
    var firstFailureAt: Date?
    var consecutiveFailures: Int = 0
    var nextRetryAt: Date?
    var lastHTTPStatus: Int?
    var lastErrorMessage: String?
    var dateAdded: Date = Date.now

    var household: Household?

    @Relationship(deleteRule: .cascade, inverse: \RecipeFeedItem.feed)
    var items: [RecipeFeedItem]? = []

    init(
        title: String = "",
        siteURL: URL,
        feedURL: URL? = nil,
        sourceKind: RecipeSiteSourceKind = .feed,
        sourceID: String? = nil,
        contentURL: URL? = nil
    ) {
        self.title = title
        siteURLString = siteURL.absoluteString
        feedURLString = feedURL?.absoluteString ?? ""
        sourceKindRaw = sourceKind.rawValue
        self.sourceID = sourceID
        contentURLString = contentURL?.absoluteString
    }

    var siteURL: URL? { URL(string: siteURLString) }
    var feedURL: URL? { URL(string: feedURLString) }
    var contentURL: URL? { contentURLString.flatMap(URL.init(string:)) ?? siteURL }
    var sourceKind: RecipeSiteSourceKind { RecipeSiteSourceKind(rawValue: sourceKindRaw) ?? .feed }

    var sortedItems: [RecipeFeedItem] {
        (items ?? []).sorted {
            ($0.publishedAt ?? $0.fetchedAt) > ($1.publishedAt ?? $1.fetchedAt)
        }
    }

    /// What the feed is publishing right now, newest first.
    var currentItems: [RecipeFeedItem] {
        sortedItems.filter { !$0.isArchived }
    }

    var hasBeenMissingForFortnight: Bool {
        lastHTTPStatus == 404
            && firstFailureAt.map { Date.now.timeIntervalSince($0) >= 14 * 24 * 60 * 60 } == true
    }
}

@Model
final class RecipeFeedItem {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    /// Feed-provided id, or a deterministic URL/title fallback.
    var stableID: String = ""
    var title: String = ""
    var urlString: String = ""
    var author: String?
    var summary: String?
    var publishedAt: Date?
    var fetchedAt: Date = Date.now
    /// Where the article's photo lives. Only the address syncs — the bytes are
    /// fetched on demand and cached locally, like the article bodies.
    var imageURLString: String?
    /// When the article's own page was searched for a picture the feed did not
    /// carry. Set whether or not one was found, so a page with no photo is
    /// asked once rather than on every scroll. Stays nil if the page could not
    /// be reached, which leaves the lookup to be retried later.
    var imageLookupAt: Date?
    /// When this article dropped off the end of its feed. Archived articles are
    /// kept and stay readable — a feed that only publishes ten posts at a time
    /// should not mean a recipe is gone if you didn't open the app that week.
    var archivedAt: Date?

    var isArchived: Bool { archivedAt != nil }

    var feed: RecipeFeed?

    init(stableID: String, title: String, url: URL) {
        self.stableID = stableID
        self.title = title
        urlString = url.absoluteString
    }

    var url: URL? { URL(string: urlString) }
    var imageURL: URL? { imageURLString.flatMap(URL.init(string:)) }
}
