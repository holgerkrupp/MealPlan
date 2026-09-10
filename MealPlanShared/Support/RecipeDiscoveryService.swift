import Foundation

/// A recipe collection that appears in Discover without asking every household
/// to subscribe to it first.
struct RecipeDiscoverySource: Identifiable, Hashable, Sendable {
    enum Format: Hashable, Sendable {
        case feed
        case openStoveHTML
        case mealDBHTML
        case publicDomainHTML
    }

    let id: String
    let name: String
    let siteURL: URL
    let contentURL: URL
    let format: Format
}

struct RecipeDiscoverySourceResult: Sendable {
    let source: RecipeDiscoverySource
    let articles: [ParsedFeedArticle]
}

struct RecipeDiscoveryLoad: Sendable {
    let sources: [RecipeDiscoverySourceResult]
    let failedSourceNames: [String]
}

enum RecipeDiscoveryService {
    /// These are deliberately global rather than locale-specific. Discover is
    /// meant to cross-pollinate a household's usual sources, while the optional
    /// subscription suggestions remain tailored to its region.
    static let sources: [RecipeDiscoverySource] = [
        RecipeDiscoverySource(
            id: "themealdb",
            name: "TheMealDB",
            siteURL: URL(string: "https://www.themealdb.com")!,
            contentURL: URL(string: "https://www.themealdb.com")!,
            format: .mealDBHTML
        ),
        RecipeDiscoverySource(
            id: "openstove",
            name: "OpenStove",
            siteURL: URL(string: "https://openstove.org")!,
            contentURL: URL(string: "https://openstove.org/recipes")!,
            format: .openStoveHTML
        ),
        RecipeDiscoverySource(
            id: "public-domain-recipes",
            name: "Public Domain Recipes",
            siteURL: URL(string: "https://publicdomainrecipes.com")!,
            contentURL: URL(string: "https://publicdomainrecipes.com")!,
            format: .publicDomainHTML
        ),
    ]

    static func load() async -> RecipeDiscoveryLoad {
        enum Outcome: Sendable {
            case success(Int, RecipeDiscoverySourceResult)
            case failure(Int, String)
        }

        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        return .success(index, try await fetch(source))
                    } catch {
                        return .failure(index, source.name)
                    }
                }
            }

            var collected: [Outcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        var successes: [(Int, RecipeDiscoverySourceResult)] = []
        var failures: [(Int, String)] = []
        for outcome in outcomes {
            switch outcome {
            case .success(let index, let result): successes.append((index, result))
            case .failure(let index, let name): failures.append((index, name))
            }
        }
        return RecipeDiscoveryLoad(
            sources: successes.sorted { $0.0 < $1.0 }.map(\.1),
            failedSourceNames: failures.sorted { $0.0 < $1.0 }.map(\.1)
        )
    }

    static func fetch(_ source: RecipeDiscoverySource) async throws -> RecipeDiscoverySourceResult {
        var request = URLRequest(url: source.contentURL, cachePolicy: .reloadRevalidatingCacheData)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RecipeFeedParserError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let articles: [ParsedFeedArticle]
        switch source.format {
        case .feed:
            articles = try RecipeFeedParser.parse(
                data,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                sourceURL: source.contentURL
            ).articles
        case .openStoveHTML:
            articles = RecipeDiscoveryHTMLParser.openStoveArticles(in: data, baseURL: source.siteURL)
        case .mealDBHTML:
            articles = RecipeDiscoveryHTMLParser.mealDBArticles(in: data, baseURL: source.siteURL)
        case .publicDomainHTML:
            articles = RecipeDiscoveryHTMLParser.publicDomainArticles(in: data, baseURL: source.siteURL)
        }

        guard !articles.isEmpty else { throw RecipeFeedParserError.unsupportedFormat }
        return RecipeDiscoverySourceResult(source: source, articles: Array(articles.prefix(40)))
    }
}

/// Small, site-shaped parsers for collections that do not publish a feed. They
/// only read card metadata; the existing article reader still parses the full
/// recipe page when somebody opens a card.
enum RecipeDiscoveryHTMLParser {
    static func openStoveArticles(in data: Data, baseURL: URL) -> [ParsedFeedArticle] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        return anchorBlocks(in: html, pathPrefix: "/recipes/").compactMap { href, body in
            guard href != "/recipes/saved",
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  let rawTitle = firstCapture(#"<h3\b[^>]*>(.*?)</h3>"#, in: body) else { return nil }
            let title = clean(rawTitle)
            guard !title.isEmpty else { return nil }
            let summary = firstCapture(#"<p\b[^>]*>(.*?)</p>"#, in: body).map(clean)
            let categories = allCaptures(#"<span\b[^>]*>(.*?)</span>"#, in: body).map(clean)
            let image = firstCapture(#"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#, in: body)
                .flatMap { URL(string: decodeEntities($0), relativeTo: baseURL)?.absoluteURL }
            return ParsedFeedArticle(
                id: url.absoluteString,
                title: title,
                url: url,
                author: nil,
                summary: summary?.isEmpty == false ? summary : nil,
                body: nil,
                publishedAt: nil,
                imageURL: image,
                categories: categories
            )
        }.uniquedByURL()
    }

    static func publicDomainArticles(in data: Data, baseURL: URL) -> [ParsedFeedArticle] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        let pattern = #"<li\b[^>]*\bdata-tags\s*=\s*["']\[([^\]]*)\]["'][^>]*>(.*?)</li>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let tagsRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html) else { return nil }
            let body = String(html[bodyRange])
            guard let href = firstCapture(#"<a\b[^>]*\bhref\s*=\s*["']([^"']+)["']"#, in: body),
                  let rawTitle = firstCapture(#"<a\b[^>]*>(.*?)</a>"#, in: body),
                  let url = URL(string: decodeEntities(href), relativeTo: baseURL)?.absoluteURL else { return nil }
            let title = clean(rawTitle)
            guard !title.isEmpty else { return nil }
            return ParsedFeedArticle(
                id: url.absoluteString,
                title: title,
                url: url,
                author: nil,
                summary: nil,
                body: nil,
                publishedAt: nil,
                imageURL: nil,
                categories: String(html[tagsRange]).split(separator: " ").map(String.init)
            )
        }.uniquedByURL()
    }

    static func mealDBArticles(in data: Data, baseURL: URL) -> [ParsedFeedArticle] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        return anchorBlocks(in: html, pathPrefix: "/meal/").compactMap { href, body in
            guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else { return nil }
            let image = firstCapture(#"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#, in: body)
                .flatMap { URL(string: decodeEntities($0), relativeTo: baseURL)?.absoluteURL }
            let title = clean(body)
            guard !title.isEmpty else { return nil }
            return ParsedFeedArticle(
                id: url.absoluteString,
                title: title,
                url: url,
                author: nil,
                summary: nil,
                body: nil,
                publishedAt: nil,
                imageURL: image
            )
        }.uniquedByURL()
    }

    private static func anchorBlocks(in html: String, pathPrefix: String) -> [(String, String)] {
        let escaped = NSRegularExpression.escapedPattern(for: pathPrefix)
        let pattern = #"<a\b[^>]*\bhref\s*=\s*["']("# + escaped + #"[^"']*)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html) else { return nil }
            return (String(html[hrefRange]), String(html[bodyRange]))
        }
    }

    private static func firstCapture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func allCaptures(_ pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func clean(_ value: String) -> String {
        decodeEntities(value)
            .replacingOccurrences(of: "<script\\b[^>]*>.*?</script>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&rsquo;", with: "’")
    }
}

private extension Array where Element == ParsedFeedArticle {
    func uniquedByURL() -> [ParsedFeedArticle] {
        var seen: Set<URL> = []
        return filter { seen.insert($0.url).inserted }
    }
}
