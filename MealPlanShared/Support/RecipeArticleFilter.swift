import Foundation

/// Broad, source-agnostic groups for browsing the mixed recipe stream. An
/// article may belong to more than one group (a cake can be both baking and a
/// dessert), which better reflects how people look for food than a rigid tree.
enum RecipeDiscoveryCategory: String, CaseIterable, Identifiable, Sendable {
    case breakfast, soups, salads, pastaAndRice, mainDishes, vegetarian, baking, desserts, drinks

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .breakfast: String(localized: "Breakfast")
        case .soups: String(localized: "Soups & stews")
        case .salads: String(localized: "Salads")
        case .pastaAndRice: String(localized: "Pasta & rice")
        case .mainDishes: String(localized: "Main dishes")
        case .vegetarian: String(localized: "Vegetarian")
        case .baking: String(localized: "Baking")
        case .desserts: String(localized: "Desserts")
        case .drinks: String(localized: "Drinks")
        }
    }

    var symbolName: String {
        switch self {
        case .breakfast: "sunrise"
        case .soups: "takeoutbag.and.cup.and.straw"
        case .salads: "leaf"
        case .pastaAndRice: "fork.knife"
        case .mainDishes: "frying.pan"
        case .vegetarian: "carrot"
        case .baking: "birthday.cake"
        case .desserts: "cup.and.saucer"
        case .drinks: "waterbottle"
        }
    }

    private var keywords: [String] {
        switch self {
        case .breakfast:
            ["breakfast", "brunch", "fruhstuck", "pancake", "waffle", "omelet", "oatmeal", "granola", "cereal"]
        case .soups:
            ["soup", "stew", "chowder", "broth", "chili", "suppe", "eintopf", "gulasch", "borscht", "pho", "ramen"]
        case .salads:
            ["salad", "salat", "slaw", "tabouleh", "ceviche"]
        case .pastaAndRice:
            ["pasta", "spaghetti", "noodle", "nudel", "lasagna", "lasagne", "risotto", "rice", "reis", "paella", "quinoa", "gnocchi", "ravioli"]
        case .mainDishes:
            ["main", "dinner", "chicken", "beef", "pork", "lamb", "fish", "salmon", "steak", "roast", "curry", "burger", "pizza", "taco", "casserole", "auflauf"]
        case .vegetarian:
            ["vegetarian", "vegan", "fasting", "tofu", "lentil", "linsen", "chickpea", "bean", "vegetable", "veggie"]
        case .baking:
            ["baking", "bread", "brot", "cake", "kuchen", "pie", "pastry", "cookie", "biscuit", "muffin", "dough", "pizza"]
        case .desserts:
            ["dessert", "sweet", "cake", "kuchen", "pie", "cookie", "biscuit", "pudding", "ice cream", "icecream", "chocolate", "brownie", "tiramisu", "candy"]
        case .drinks:
            ["drink", "tea", "coffee", "cocktail", "smoothie", "juice", "milkshake", "kombucha", "chai"]
        }
    }

    static func categories(title: String, summary: String?, providerTags: [String]) -> Set<Self> {
        let text = ([title, summary].compactMap { $0 } + providerTags).joined(separator: " ")
        let haystack = DishGlyphSuggester.tokenized(text)
        return Set(allCases.filter { category in
            category.keywords.contains { DishGlyphSuggester.contains(haystack, $0) }
        })
    }
}

/// Keeps general blog posts, promotions and affiliate advertorials out of the
/// recipe stream. Feed metadata is intentionally judged conservatively: one
/// strong recipe signal is enough, but an explicit non-recipe/ad label wins.
enum RecipeArticleClassifier {
    private static let excludedWords = [
        "advertisement", "advertorial", "anzeige", "affiliate", "coupon",
        "erfahrungsbericht", "giveaway", "gewinnspiel", "gutschein", "interview",
        "newsletter", "podcast", "product review", "produktvorstellung", "rabatt",
        "review", "sponsored", "testbericht", "werbung",
    ]

    private static let recipeWords = [
        "ingredient", "ingredients", "instruction", "instructions", "method",
        "preparation", "recipe", "recipes", "rezept", "rezepte", "servings",
        "zubereitung", "zutat", "zutaten",
    ]

    static func isLikelyRecipe(_ article: ParsedFeedArticle) -> Bool {
        isLikelyRecipe(
            title: article.title,
            summary: article.summary,
            url: article.url,
            providerTags: article.categories,
            body: article.body
        )
    }

    static func isLikelyRecipe(
        title: String,
        summary: String?,
        url: URL?,
        providerTags: [String] = [],
        body: String? = nil
    ) -> Bool {
        // Disclosures in a post body are common even for genuine recipes, so
        // rejection terms are limited to the title and the provider's tags.
        let labelText = ([title] + providerTags).joined(separator: " ")
        let labels = DishGlyphSuggester.tokenized(labelText)
        if excludedWords.contains(where: { DishGlyphSuggester.contains(labels, $0) }) {
            return false
        }

        let metadata = DishGlyphSuggester.tokenized(
            ([title, summary].compactMap { $0 } + providerTags).joined(separator: " ")
        )
        if recipeWords.contains(where: { DishGlyphSuggester.contains(metadata, $0) }) {
            return true
        }
        if !RecipeDiscoveryCategory.categories(
            title: title,
            summary: summary,
            providerTags: providerTags
        ).isEmpty {
            return true
        }
        if DishGlyphSuggester.match(name: [title, summary].compactMap { $0 }.joined(separator: " ")) != nil {
            return true
        }

        let recipePathWords: Set<String> = ["recipe", "recipes", "rezept", "rezepte"]
        if let url, !recipePathWords.isDisjoint(with: url.pathComponents.map { $0.lowercased() }) {
            return true
        }

        // Full-content feeds sometimes omit every useful tag but include the
        // page's schema.org recipe payload.
        if let body {
            let structuredPatterns = [
                #"[\"']@type[\"']\s*:\s*[\"']Recipe[\"']"#,
                #"[\"']recipeIngredient[\"']\s*:"#,
                #"itemtype\s*=\s*[\"']https?://schema.org/Recipe[\"']"#,
            ]
            if structuredPatterns.contains(where: {
                body.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
            }) {
                return true
            }
        }
        return false
    }
}

/// How Discover recipes is ordered.
enum RecipeArticleSort: String, CaseIterable, Identifiable, Sendable {
    case mixed, newest, oldest, title

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .mixed: String(localized: "Mixed sources")
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
        case .mixed, .newest: lhs.date > rhs.date
        case .oldest: lhs.date < rhs.date
        case .title: lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// Takes one item from each source in turn. Each source is expected to be
    /// in its preferred order already; empty and uneven groups are fine.
    static func interleave<T>(_ groups: [[T]]) -> [T] {
        guard let longest = groups.map(\.count).max() else { return [] }
        return (0..<longest).flatMap { index in
            groups.compactMap { index < $0.count ? $0[index] : nil }
        }
    }
}
