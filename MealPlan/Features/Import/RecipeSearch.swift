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
}
