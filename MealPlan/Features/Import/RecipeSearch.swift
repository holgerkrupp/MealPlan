import Foundation

/// Which search engine "Find a recipe" uses.
///
/// Neither iOS nor macOS exposes the system's default search engine to apps —
/// Safari's setting is private, and there is no API to read it. So the app
/// carries its own list, defaults to Ecosia, and lets people change it in
/// Settings. If a future OS ever offers the preferred engine, `resolved` is
/// the single place that would need to consult it.
enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case ecosia
    case duckDuckGo
    case startpage
    case google
    case bing

    var id: String { rawValue }

    /// What the app falls back to when the OS can't tell us the preference.
    static let fallback: SearchEngine = .ecosia

    var localizedName: String {
        switch self {
        case .ecosia: "Ecosia"
        case .duckDuckGo: "DuckDuckGo"
        case .startpage: "Startpage"
        case .google: "Google"
        case .bing: "Bing"
        }
    }

    private var queryTemplate: String {
        switch self {
        case .ecosia: "https://www.ecosia.org/search?q="
        case .duckDuckGo: "https://duckduckgo.com/?q="
        case .startpage: "https://www.startpage.com/sp/search?query="
        case .google: "https://www.google.com/search?q="
        case .bing: "https://www.bing.com/search?q="
        }
    }

    func searchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)
        else { return nil }
        return URL(string: queryTemplate + encoded)
    }

    /// The engine for a stored preference, falling back to Ecosia for an unset
    /// or unrecognised value.
    static func resolved(from storedRawValue: String) -> SearchEngine {
        SearchEngine(rawValue: storedRawValue) ?? fallback
    }

    /// True for any page on one of the engines' own sites — results pages,
    /// image tabs, settings. None of them is a recipe, so none is importable.
    static func isSearchResultsPage(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if host.split(separator: ".").contains("google") { return true }
        let domains = ["ecosia.org", "duckduckgo.com", "startpage.com", "bing.com"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The page the browser is showing, if it is one a recipe can be imported
    /// from: a real http(s) document, not a search engine's results and not
    /// the about:blank of a load still in flight.
    static func importableURL(_ url: URL?) -> URL? {
        guard let url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host()?.isEmpty == false,
              !isSearchResultsPage(url) else { return nil }
        return url
    }
}

extension CharacterSet {
    /// `urlQueryAllowed` still permits "&", "+" and "=", which corrupt a query
    /// value once it's concatenated into a URL.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}

/// Builds the web search for a dish.
enum RecipeSearch {
    /// Localized so a German user searches for "Rezept" rather than "recipe".
    static func query(for dishName: String) -> String {
        let name = dishName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return String(localized: "recipe") }
        return "\(name) \(String(localized: "recipe"))"
    }

    static func url(for dishName: String, engine: SearchEngine) -> URL? {
        engine.searchURL(for: query(for: dishName))
    }

    // MARK: - Free text (Discover)

    /// What someone typed into Discover, as a web search. The text is kept
    /// exactly as typed — quotes, `-negation`, `+`, operators — and only gains
    /// the localized "recipe" when it doesn't already ask for recipes or use
    /// a `site:` restriction. Nil for an empty query: there is nothing to send.
    static func query(forFreeText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return asksForRecipes(trimmed) ? trimmed : "\(trimmed) \(String(localized: "recipe"))"
    }

    static func url(forFreeText text: String, engine: SearchEngine) -> URL? {
        query(forFreeText: text).flatMap(engine.searchURL(for:))
    }

    /// "Rezepte", "recipes" and "site:chefkoch.de" already say what is wanted.
    private static func asksForRecipes(_ query: String) -> Bool {
        let fold: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let folded = fold(query)
        if folded.contains("site:") { return true }
        let words = Set([String(localized: "recipe"), "recipe", "rezept"].map(fold))
        return words.contains { folded.contains($0) }
    }

    // MARK: - Importing a found page

    /// Pins the recipe to the page it was read from when the parser found no
    /// usable link of its own (a canonical http(s) link on the page wins), so
    /// attribution and the duplicate check both have a real source URL.
    static func attributed(_ recipe: ImportedRecipe, to visitedURL: URL) -> ImportedRecipe {
        guard SearchEngine.importableURL(recipe.sourceURL) == nil else { return recipe }
        var attributed = recipe
        attributed.sourceURL = visitedURL
        return attributed
    }

    /// "Save link only" for a page that wouldn't yield a recipe: a dish that
    /// is just the title and the link, marked for review.
    static func linkOnlyRecipe(title: String, url: URL) -> ImportedRecipe {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty
            ? (url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString)
            : trimmed
        var recipe = ImportedRecipe(name: name, sourceURL: url)
        recipe.needsReview = true
        return recipe
    }
}
