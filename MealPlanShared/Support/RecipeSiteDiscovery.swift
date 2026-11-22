import Foundation

/// The kind of public URL that arrived through Share.  A recipe URL is kept
/// separate from a collection page: a page linking to recipes is not itself a
/// recipe just because it contains Recipe-shaped links.
enum SharedRecipeURLKind: Equatable, Sendable {
    case recipe(RecipeImportCandidate)
    case recipeSite(RecipeSiteCandidate)
    case feed(DiscoveredFeed)
    case ambiguous(URL)
    case unsupported(URL)
}

struct RecipeImportCandidate: Equatable, Sendable {
    let url: URL
    let title: String?
    /// A recipe page may advertise the site's feed as well. Keep that
    /// subscription choice available without changing the primary result from
    /// "import this recipe" to "subscribe to this site".
    let subscriptionCandidate: RecipeSiteCandidate?

    init(url: URL, title: String?, subscriptionCandidate: RecipeSiteCandidate? = nil) {
        self.url = url
        self.title = title
        self.subscriptionCandidate = subscriptionCandidate
    }
}

enum RecipeSiteSourceKind: String, Codable, Sendable {
    case feed
    case builtInCollection
    case websiteDiscovery
}

struct RecipeSiteCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let siteURL: URL
    let contentURL: URL
    let feedURL: URL?
    let sourceKind: RecipeSiteSourceKind
    let providerID: String?
    let detail: String

    init(
        id: String? = nil,
        title: String,
        siteURL: URL,
        contentURL: URL? = nil,
        feedURL: URL? = nil,
        sourceKind: RecipeSiteSourceKind = .feed,
        providerID: String? = nil,
        detail: String? = nil
    ) {
        self.siteURL = siteURL
        self.contentURL = contentURL ?? siteURL
        self.feedURL = feedURL
        self.sourceKind = sourceKind
        self.providerID = providerID
        self.title = title
        self.detail = detail ?? siteURL.host() ?? siteURL.absoluteString
        self.id = id ?? [siteURL.absoluteString, feedURL?.absoluteString ?? "", sourceKind.rawValue].joined(separator: "|")
    }

    static func manual(for url: URL) -> RecipeSiteCandidate {
        RecipeSiteCandidate(
            title: url.host()?.replacingOccurrences(of: "www.", with: "").capitalized ?? String(localized: "Recipe site"),
            siteURL: url,
            sourceKind: .websiteDiscovery,
            detail: url.host() ?? url.absoluteString
        )
    }
}

struct DiscoveredFeed: Equatable, Sendable {
    let title: String
    let siteURL: URL
    let feedURL: URL
}

/// Sites with public, stable collection semantics can provide an adapter
/// without leaking those assumptions into the generic HTML/feed discovery.
protocol RecipeDiscoveryProvider: Sendable {
    var id: String { get }
    func recognizes(_ url: URL) -> Bool
    func subscriptionCandidates(for url: URL) async throws -> [RecipeSiteCandidate]
    func discoverArticles(from candidate: RecipeSiteCandidate) async throws -> [ParsedFeedArticle]
}

enum RecipeSiteDiscoveryError: LocalizedError {
    case notARecipeSite
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .notARecipeSite: String(localized: "This page does not look like a recipe or recipe site.")
        case .invalidURL: RecipeFeedParserError.invalidURL.localizedDescription
        }
    }
}

/// Generic, conservative source discovery. It reads one HTML document, uses
/// advertised feeds first, and only recognizes feed-less pages when their
/// markup looks like a recipe index. It never crawls linked recipe pages.
enum RecipeSiteDiscoveryService {
    static let providers: [any RecipeDiscoveryProvider] = [ChefkochDiscoveryProvider()]

    static func canonicalize(_ rawURL: URL) -> URL {
        guard var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: true) else { return rawURL }
        components.scheme = (components.scheme ?? "https").lowercased()
        components.host = components.host?.lowercased()
        if components.path.isEmpty { components.path = "/" }
        return components.url ?? rawURL
    }

    static func classify(_ rawURL: URL) async -> SharedRecipeURLKind {
        let url = canonicalize(rawURL)
        guard url.scheme == "http" || url.scheme == "https" else { return .unsupported(url) }

        for provider in providers where provider.recognizes(url) {
            if let candidate = try? await provider.subscriptionCandidates(for: url).first {
                return .recipeSite(candidate)
            }
        }

        do {
            let page = try await fetchPage(at: url)
            return classifyHTML(page.data, response: page.response, sourceURL: page.finalURL)
        } catch {
            // A failed inspection must not prevent the user from explicitly
            // subscribing or importing a URL through the existing fallback.
            return .unsupported(url)
        }
    }

    static func classifyHTML(_ data: Data, response: HTTPURLResponse? = nil, sourceURL: URL) -> SharedRecipeURLKind {
        let url = canonicalize(sourceURL)
        let contentType = response?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("rss") || contentType.contains("atom") || contentType.contains("json") {
            return .feed(DiscoveredFeed(
                title: url.host() ?? String(localized: "Recipe feed"),
                siteURL: url,
                feedURL: url
            ))
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return .unsupported(url)
        }

        let feedURLs = RecipeFeedDiscovery.feedURLs(inHTML: html, baseURL: url)
        let canonical = canonicalURL(in: html, baseURL: url) ?? url
        let itemList = containsItemList(in: html)
        let recipeLinks = recipeLinkCount(in: html, baseURL: url)
        // Use the same JSON-LD, embedded JSON and microdata candidate parser
        // as the importer. Counting raw JSON-LD blocks is not sufficient: a
        // collection page may publish a featured Recipe object, while an
        // individual recipe can also advertise the site's feed and related
        // recipe links.
        let structuredCandidates = RecipeSchemaParser()
            .structuredCandidates(in: html, sourceURL: url)
        let recipeCandidates = uniqueRecipeCandidates(structuredCandidates)
        let bestRecipe = structuredCandidates.max { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.recipe.ingredientLines.count < rhs.recipe.ingredientLines.count
        }
        let semanticRecipe = SemanticRecipeExtractor.extract(html: html, sourceURL: url)
        let hasRecipePayload = bestRecipe.map {
            !$0.recipe.ingredientLines.isEmpty || !($0.recipe.instructions ?? "").trimmedCollapsed.isEmpty
        } ?? (semanticRecipe?.hasContent == true)
        let recipeTitle = bestRecipe?.recipe.name ?? semanticRecipe?.name
        let title = pageTitle(in: html) ?? recipeTitle ?? canonical.host() ?? String(localized: "Recipe site")
        let hasCollectionSignals = itemList
            || recipeCandidates.count > 1
            || isCollectionPath(url.path)
            || (recipeLinks >= 2 && !isLikelyIndividualRecipePath(url.path))

        // A credible individual recipe wins over an advertised feed. The
        // feed remains attached as an optional subscription action for the
        // share UI instead of being discarded.
        if hasRecipePayload, !hasCollectionSignals {
            return .recipe(RecipeImportCandidate(
                url: url,
                title: recipeTitle?.nilIfEmpty ?? title,
                subscriptionCandidate: feedURLs.first.map {
                    subscriptionCandidate(
                        feedURL: $0,
                        pageURL: url,
                        title: title,
                        canonicalURL: canonical
                    )
                }
            ))
        }

        let looksLikeIndex = itemList || recipeLinks >= 2 || isCollectionPath(url.path) || recipeCandidates.count > 1
        if !feedURLs.isEmpty || looksLikeIndex {
            let candidates = feedURLs.map { feedURL in
                RecipeSiteCandidate(
                    title: title,
                    siteURL: canonical,
                    contentURL: url,
                    feedURL: feedURL,
                    sourceKind: .feed,
                    detail: feedURL.host() ?? String(localized: "RSS / Atom feed")
                )
            }
            if let first = candidates.first { return .recipeSite(first) }
            if looksLikeIndex {
                return .recipeSite(RecipeSiteCandidate(
                    title: title,
                    siteURL: canonical,
                    contentURL: url,
                    sourceKind: .websiteDiscovery,
                    detail: String(localized: "Recipe discovery page")
                ))
            }
        }

        // Structured markup that is not strong enough to identify one
        // individual recipe should still be offered to the explicit import /
        // review flow rather than being treated as a dead end.
        if bestRecipe != nil { return .ambiguous(url) }
        return .unsupported(url)
    }

    static func subscriptionCandidates(for rawURL: URL) async throws -> [RecipeSiteCandidate] {
        let url = canonicalize(rawURL)
        for provider in providers where provider.recognizes(url) {
            if let candidates = try? await provider.subscriptionCandidates(for: url), !candidates.isEmpty {
                return candidates
            }
        }
        let page = try await fetchPage(at: url)
        switch classifyHTML(page.data, response: page.response, sourceURL: page.finalURL) {
        case .recipeSite(let candidate): return [candidate]
        case .feed(let feed):
            return [RecipeSiteCandidate(title: feed.title, siteURL: feed.siteURL, feedURL: feed.feedURL)]
        default: return [RecipeSiteCandidate.manual(for: url)]
        }
    }

    static func fetchArticles(for candidate: RecipeSiteCandidate) async throws -> [ParsedFeedArticle] {
        for provider in providers where candidate.providerID == provider.id {
            return try await provider.discoverArticles(from: candidate)
        }
        let url = candidate.feedURL ?? candidate.contentURL
        let page = try await fetchPage(at: url)
        if let parsed = try? RecipeFeedParser.parse(page.data, contentType: page.response.value(forHTTPHeaderField: "Content-Type"), sourceURL: page.finalURL) {
            return parsed.articles
        }
        guard let html = String(data: page.data, encoding: .utf8) else { return [] }
        return RecipeDiscoveryHTMLParser.genericRecipeIndexArticles(in: html, baseURL: page.finalURL)
    }

    struct FetchedPage: Sendable {
        let data: Data
        let response: HTTPURLResponse
        let finalURL: URL
    }

    static func fetchPage(at url: URL) async throws -> FetchedPage {
        var request = URLRequest(url: canonicalize(url), cachePolicy: .reloadRevalidatingCacheData)
        request.timeoutInterval = 20
        request.setValue("text/html,application/xhtml+xml,application/rss+xml,application/atom+xml,application/feed+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RecipeFeedParserError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return FetchedPage(data: data, response: http, finalURL: response.url ?? url)
    }

    private static func canonicalURL(in html: String, baseURL: URL) -> URL? {
        guard let tag = html.range(of: #"<link\b[^>]*\brel\s*=\s*[\"']canonical[\"'][^>]*>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let value = attribute("href", in: String(html[tag]))
        return value.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }.map(canonicalize)
    }

    private static func pageTitle(in html: String) -> String? {
        guard let range = html.range(of: #"<title\b[^>]*>(.*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return clean(String(html[range]).replacingOccurrences(of: #"</?title\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive]))
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*[\"']([^\"']+)[\"']"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let value = String(tag[range])
        return value.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
    }

    private static func containsItemList(in html: String) -> Bool {
        html.range(of: #"itemlist|\"@type\"\s*:\s*\"?ItemList"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func recipeLinkCount(in html: String, baseURL: URL) -> Int {
        let pattern = #"<a\b[^>]*\bhref\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match -> URL? in
            guard let range = Range(match.range(at: 1), in: html), let link = URL(string: String(html[range]), relativeTo: baseURL)?.absoluteURL else { return nil }
            return isRecipePath(link.path) ? link : nil
        }.count
    }

    private static func isCollectionPath(_ path: String) -> Bool {
        let path = path.lowercased()
        if path.isEmpty || path == "/" || path == "/index.html" || path == "/index.htm"
            || path == "/home" || path == "/home/" || path == "/rezepte" || path == "/recipes" {
            return true
        }
        return ["/category", "/categories", "/blog", "/suche", "/search", "/collection", "/collections", "/tag", "/tags", "/author", "/authors", "/featured", "/highlights"]
            .contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func isLikelyIndividualRecipePath(_ path: String) -> Bool {
        let normalized = path.lowercased()
        guard !normalized.isEmpty, normalized != "/" else { return false }
        if isRecipePath(normalized) { return true }
        let lastComponent = normalized.split(separator: "/").last.map(String.init) ?? ""
        return lastComponent.hasSuffix(".html") || lastComponent.hasSuffix(".htm")
    }

    private static func uniqueRecipeCandidates(_ candidates: [RecipeExtractionCandidate]) -> [RecipeExtractionCandidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            let name = candidate.recipe.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let ingredients = candidate.recipe.ingredientLines
                .prefix(2)
                .joined(separator: "|")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let key = "\(name)|\(ingredients)"
            return seen.insert(key).inserted
        }
    }

    private static func subscriptionCandidate(
        feedURL: URL,
        pageURL: URL,
        title: String,
        canonicalURL: URL
    ) -> RecipeSiteCandidate {
        var siteComponents = URLComponents(url: canonicalURL, resolvingAgainstBaseURL: false)
        siteComponents?.path = "/"
        siteComponents?.query = nil
        siteComponents?.fragment = nil
        let siteURL = siteComponents?.url ?? canonicalURL
        return RecipeSiteCandidate(
            title: title,
            siteURL: siteURL,
            contentURL: pageURL,
            feedURL: feedURL,
            sourceKind: .feed,
            detail: feedURL.host() ?? String(localized: "RSS / Atom feed")
        )
    }

    private static func isRecipePath(_ path: String) -> Bool {
        let path = path.lowercased()
        return path.contains("/rezept") || path.contains("/recipe") || path.contains("/rezepte/") || path.contains("/recipes/")
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

struct ChefkochDiscoveryProvider: RecipeDiscoveryProvider {
    let id = "chefkoch"
    private let host = "chefkoch.de"
    private let recipeOfTheDayFeed = URL(string: "https://www.chefkoch.de/recipe-of-the-day/rss")!
    private let recipeOfTheDayPage = URL(string: "https://www.chefkoch.de/rezept-des-tages/")!

    func recognizes(_ url: URL) -> Bool {
        url.host()?.lowercased().hasSuffix(host) == true
    }

    func subscriptionCandidates(for url: URL) async throws -> [RecipeSiteCandidate] {
        let site = URL(string: "https://www.chefkoch.de")!
        let path = url.path.lowercased()
        let isIndividualRecipe = path.range(of: #"/rezepte/\d+/.+"#, options: .regularExpression) != nil || path.hasSuffix(".html")
        if isIndividualRecipe { return [] }
        var result = [RecipeSiteCandidate(
            id: "chefkoch:recipe-of-the-day",
            title: "Chefkoch – Rezept des Tages",
            siteURL: site,
            contentURL: recipeOfTheDayPage,
            feedURL: recipeOfTheDayFeed,
            sourceKind: .builtInCollection,
            providerID: id,
            detail: "chefkoch.de"
        )]
        if path.contains("was-koche-ich-heute") || path == "/" || path == "/rezepte/" || path.contains("/rezepte/") {
            result.append(RecipeSiteCandidate(
                id: "chefkoch:discovery",
                title: "Chefkoch",
                siteURL: site,
                contentURL: url,
                sourceKind: .websiteDiscovery,
                providerID: id,
                detail: String(localized: "Chefkoch discovery page")
            ))
        }
        return result
    }

    func discoverArticles(from candidate: RecipeSiteCandidate) async throws -> [ParsedFeedArticle] {
        let url = candidate.feedURL ?? candidate.contentURL
        let page = try await RecipeSiteDiscoveryService.fetchPage(at: url)
        if let parsed = try? RecipeFeedParser.parse(page.data, contentType: page.response.value(forHTTPHeaderField: "Content-Type"), sourceURL: page.finalURL) {
            return parsed.articles
        }
        guard let html = String(data: page.data, encoding: .utf8) else { return [] }
        return RecipeDiscoveryHTMLParser.genericRecipeIndexArticles(in: html, baseURL: page.finalURL)
    }
}
