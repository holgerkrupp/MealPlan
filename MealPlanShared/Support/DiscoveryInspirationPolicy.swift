import Foundation

/// The starting points Discover offers under "What sounds good today?".
///
/// Each one is decided only from what a source says about its own article —
/// title, summary, the publisher's tags — never guessed from ingredients or
/// prep times we have not read. `seasonal` has no keywords: its members come
/// from `SeasonalRecipeRanking`'s collections.
enum RecipeInspirationTheme: String, CaseIterable, Identifiable, Sendable {
    case quickDinner, seasonal, vegetarian, baking

    var id: String { rawValue }

    /// The source's own words for "quick". Deliberately no bare "fast"
    /// (breakfast, fasting) and no minute counts above 30.
    private static let quickWords = [
        "quick", "schnell", "blitz", "weeknight", "feierabend", "one pot", "onepot",
        "sheet pan", "15 minute", "20 minute", "25 minute", "30 minute",
        "rapide", "veloce",
    ]

    /// Explicit vegetarian/vegan wording only. `RecipeDiscoveryCategory.vegetarian`
    /// also matches "bean" or "lentil", which is fine for browsing but not for
    /// a label that promises no meat.
    private static let vegetarianWords = [
        "vegetarian", "vegetarisch", "vegetarien", "vegetariano", "vegan",
        "veggie", "meatless", "fleischlos",
    ]

    /// Not a quick *dinner* if the article is plainly something else.
    private static let notDinner: Set<RecipeDiscoveryCategory> = [.breakfast, .baking, .desserts, .drinks]

    static func themes(
        title: String,
        summary: String?,
        providerTags: [String],
        categories: Set<RecipeDiscoveryCategory>
    ) -> Set<Self> {
        let haystack = DishGlyphSuggester.tokenized(
            ([title, summary].compactMap { $0 } + providerTags).joined(separator: " ")
        )
        var result = Set<Self>()
        if categories.isDisjoint(with: notDinner),
           quickWords.contains(where: { DishGlyphSuggester.contains(haystack, $0) }) {
            result.insert(.quickDinner)
        }
        if vegetarianWords.contains(where: { DishGlyphSuggester.contains(haystack, $0) }) {
            result.insert(.vegetarian)
        }
        if categories.contains(.baking) {
            result.insert(.baking)
        }
        return result
    }
}

/// The curated top of Discover, chosen from the same article values as the
/// full grid. Built off the main actor next to `RecipeDiscoverySnapshot`, read
/// during layout.
struct DiscoveryInspiration: Sendable {
    struct ThemeChoice: Identifiable, Sendable {
        let theme: RecipeInspirationTheme
        let articles: [RecipeDiscoveryArticle]
        var id: RecipeInspirationTheme { theme }
        /// The first article with a photo, for the tile's background.
        var coverImageURL: URL? { articles.lazy.compactMap(\.imageURL).first }
    }

    static let empty = Self(themes: [], weekIdeas: [], fromYourSites: [], allFromYourSites: [])

    /// Only themes with enough candidates to be worth a tap, in a fixed order.
    let themes: [ThemeChoice]
    /// "Ideas for this week": the first is the hero.
    let weekIdeas: [RecipeDiscoveryArticle]
    /// "New from your sites": unread, newest first, source-capped.
    let fromYourSites: [RecipeDiscoveryArticle]
    /// Every unread subscribed article, for "See all".
    let allFromYourSites: [RecipeDiscoveryArticle]

    func applying(readID: String) -> Self {
        func markRead(_ article: RecipeDiscoveryArticle) -> RecipeDiscoveryArticle {
            article.readStateID == readID && !article.isRead ? article.withReadState(true) : article
        }
        return Self(
            themes: themes.map { ThemeChoice(theme: $0.theme, articles: $0.articles.map(markRead)) },
            weekIdeas: weekIdeas.map(markRead),
            fromYourSites: fromYourSites.map(markRead),
            allFromYourSites: allFromYourSites.map(markRead)
        )
    }

    /// A copy with the seasonal choice put in its place, once the seasonal
    /// collections (loaded separately) are known.
    func withSeasonal(_ articles: [RecipeDiscoveryArticle]) -> Self {
        var choices = themes.filter { $0.theme != .seasonal }
        if articles.count >= DiscoveryInspirationPolicy.minimumThemeArticles {
            choices.append(ThemeChoice(theme: .seasonal, articles: articles))
        }
        let order = RecipeInspirationTheme.allCases
        choices.sort { order.firstIndex(of: $0.theme)! < order.firstIndex(of: $1.theme)! }
        return Self(themes: choices, weekIdeas: weekIdeas, fromYourSites: fromYourSites, allFromYourSites: allFromYourSites)
    }
}

/// Pure and deterministic: the same articles always give the same shelves.
///
/// * A theme is offered only with at least `minimumThemeArticles` matches.
/// * No single site dominates a shelf (`weekPerSource`, `sitesPerSource`).
/// * "Ideas for this week" prefers unread, photographed, local-market
///   articles that read as a meal (not drinks or desserts), and skips
///   anything already on the "In season" shelf below.
/// * "New from your sites" never repeats a week idea.
///
/// No personalisation: nothing here learns from the person.
enum DiscoveryInspirationPolicy {
    static let minimumThemeArticles = 4
    static let themeLimit = 60
    static let themePerSource = 8
    static let weekLimit = 5
    static let weekMinimum = 3
    static let weekPerSource = 1
    static let sitesLimit = 8
    static let sitesPerSource = 2

    private static let notAMeal: Set<RecipeDiscoveryCategory> = [.drinks, .desserts]

    static func make(
        articles: [RecipeDiscoveryArticle],
        lowAffinitySourceIDs: Set<String> = [],
        excludingIDs: Set<String> = [],
        seasonalArticles: [RecipeDiscoveryArticle] = []
    ) -> DiscoveryInspiration {
        let current = articles
            .filter { !$0.isArchived }
            .sorted(by: newestFirst)

        let themes = RecipeInspirationTheme.allCases.compactMap { theme -> DiscoveryInspiration.ThemeChoice? in
            let members = theme == .seasonal
                ? seasonalArticles
                : diversified(current.filter { $0.inspirationThemes.contains(theme) },
                              limit: themeLimit, perSource: themePerSource)
            guard members.count >= minimumThemeArticles else { return nil }
            return .init(theme: theme, articles: members)
        }

        let weekCandidates = current.filter { article in
            !article.isRead
                && !excludingIDs.contains(article.id)
                && !lowAffinitySourceIDs.contains(article.sourceID)
                && !(article.categories.isEmpty == false && article.categories.isSubset(of: notAMeal))
        }
        // Photographed articles first, so the hero has a picture whenever any
        // candidate does; the sort is stable, so recency order is kept within.
        let photographedFirst = weekCandidates.filter { $0.imageURL != nil }
            + weekCandidates.filter { $0.imageURL == nil }
        var week = diversified(photographedFirst, limit: weekLimit, perSource: weekPerSource)
        if week.count < weekMinimum {
            week = diversified(photographedFirst, limit: weekLimit, perSource: weekPerSource + 1)
        }
        if week.count < weekMinimum { week = [] }

        let weekIDs = Set(week.map(\.id))
        let unreadSubscribed = current.filter { $0.isSubscribed && !$0.isRead }
        let sites = diversified(
            unreadSubscribed.filter { !weekIDs.contains($0.id) },
            limit: sitesLimit,
            perSource: sitesPerSource
        )

        return DiscoveryInspiration(
            themes: themes,
            weekIdeas: week,
            fromYourSites: sites,
            allFromYourSites: unreadSubscribed
        )
    }

    /// The "Seasonal ideas" choice: every active moment's articles, in the
    /// calendar's order, each article once.
    static func seasonalArticles(_ collections: [SeasonalRecipeCollection]) -> [RecipeDiscoveryArticle] {
        var seen = Set<String>()
        return collections.flatMap(\.articles).filter { seen.insert($0.id).inserted }
    }

    /// Keeps order, taking at most `perSource` from any one site.
    static func diversified(
        _ articles: [RecipeDiscoveryArticle],
        limit: Int,
        perSource: Int
    ) -> [RecipeDiscoveryArticle] {
        var counts: [String: Int] = [:]
        var result: [RecipeDiscoveryArticle] = []
        for article in articles {
            guard result.count < limit else { break }
            let count = counts[article.sourceID, default: 0]
            guard count < perSource else { continue }
            counts[article.sourceID] = count + 1
            result.append(article)
        }
        return result
    }

    private static func newestFirst(_ lhs: RecipeDiscoveryArticle, _ rhs: RecipeDiscoveryArticle) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        return lhs.id < rhs.id
    }
}

extension RecipeDiscoveryArticle {
    /// Subscribed feeds' source ids start with `feed:`; built-in sources with
    /// `discovery:`.
    var isSubscribed: Bool { sourceID.hasPrefix("feed:") }
}
