import Foundation

/// How Discover recipes is ordered.
enum RecipeArticleSort: String, CaseIterable, Identifiable, Sendable {
    case newest, oldest, title

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .newest: String(localized: "Newest first")
        case .oldest: String(localized: "Oldest first")
        case .title: String(localized: "By title")
        }
    }
}

/// Which articles Discover recipes shows.
enum RecipeArticleScope: String, CaseIterable, Identifiable, Sendable {
    /// What the feeds are publishing now.
    case current
    /// Only what has not been opened yet.
    case unread
    /// Everything ever fetched, including posts the feed has since dropped.
    case archive

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .current: String(localized: "Recent")
        case .unread: String(localized: "Unread")
        case .archive: String(localized: "Everything")
        }
    }
}

/// The pure half of Discover recipes' searching, filtering and sorting, kept
/// out of the view so it can be tested without a store.
enum RecipeArticleFilter {
    /// One article, reduced to what the list needs to decide about it.
    struct Candidate: Sendable {
        var title: String
        var summary: String?
        var author: String?
        var feedTitle: String
        var date: Date
        var isArchived: Bool
        var isRead: Bool
    }

    static func matches(_ candidate: Candidate, scope: RecipeArticleScope, search: String) -> Bool {
        switch scope {
        case .current where candidate.isArchived: return false
        case .unread where candidate.isArchived || candidate.isRead: return false
        default: break
        }

        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        // Every word has to appear somewhere, so "soup tomato" finds a tomato
        // soup however the title is worded.
        let haystack = [candidate.title, candidate.summary, candidate.author, candidate.feedTitle]
            .compactMap { $0 }
            .joined(separator: " ")
        return query.split(separator: " ").allSatisfy {
            haystack.localizedCaseInsensitiveContains($0)
        }
    }

    static func areInOrder(_ lhs: Candidate, _ rhs: Candidate, sort: RecipeArticleSort) -> Bool {
        switch sort {
        case .newest: lhs.date > rhs.date
        case .oldest: lhs.date < rhs.date
        case .title: lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
