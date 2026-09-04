import Foundation
import SwiftData

/// A recipe site's syndication feed. Article bodies are intentionally absent:
/// they are a bounded local cache, while this subscription metadata syncs.
@Model
final class RecipeFeed {
    var uuid: UUID = UUID()
    var title: String = ""
    var siteURLString: String = ""
    var feedURLString: String = ""
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

    init(title: String = "", siteURL: URL, feedURL: URL) {
        self.title = title
        siteURLString = siteURL.absoluteString
        feedURLString = feedURL.absoluteString
    }

    var siteURL: URL? { URL(string: siteURLString) }
    var feedURL: URL? { URL(string: feedURLString) }

    var sortedItems: [RecipeFeedItem] {
        (items ?? []).sorted {
            ($0.publishedAt ?? $0.fetchedAt) > ($1.publishedAt ?? $1.fetchedAt)
        }
    }

    var hasBeenMissingForFortnight: Bool {
        lastHTTPStatus == 404
            && firstFailureAt.map { Date.now.timeIntervalSince($0) >= 14 * 24 * 60 * 60 } == true
    }
}

@Model
final class RecipeFeedItem {
    var uuid: UUID = UUID()
    /// Feed-provided id, or a deterministic URL/title fallback.
    var stableID: String = ""
    var title: String = ""
    var urlString: String = ""
    var author: String?
    var summary: String?
    var publishedAt: Date?
    var fetchedAt: Date = Date.now

    var feed: RecipeFeed?

    init(stableID: String, title: String, url: URL) {
        self.stableID = stableID
        self.title = title
        urlString = url.absoluteString
    }

    var url: URL? { URL(string: urlString) }
}
