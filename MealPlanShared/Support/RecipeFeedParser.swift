import Foundation

struct ParsedRecipeFeed: Equatable, Sendable {
    var title: String
    var homeURL: URL?
    var articles: [ParsedFeedArticle]
}

struct ParsedFeedArticle: Equatable, Sendable {
    var id: String
    var title: String
    var url: URL
    var author: String?
    var summary: String?
    var body: String?
    var publishedAt: Date?
}

enum RecipeFeedParserError: LocalizedError {
    case unsupportedFormat
    case noFeedLink
    case invalidURL
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: String(localized: "This site did not return an RSS, Atom or JSON feed.")
        case .noFeedLink: String(localized: "No recipe feed was advertised by this site.")
        case .invalidURL: String(localized: "Enter a valid website address.")
        case .httpStatus(let status): String(localized: "The site returned HTTP status \(status).")
        }
    }
}

enum RecipeFeedParser {
    static func parse(_ data: Data, contentType: String? = nil, sourceURL: URL) throws -> ParsedRecipeFeed {
        let type = contentType?.lowercased() ?? ""
        let first = data.first { ![9, 10, 13, 32].contains($0) }
        if type.contains("json") || first == Character("{").asciiValue {
            return try parseJSON(data, sourceURL: sourceURL)
        }
        let delegate = XMLFeedDelegate(sourceURL: sourceURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), !delegate.articles.isEmpty || delegate.recognizedFeed else {
            throw RecipeFeedParserError.unsupportedFormat
        }
        return ParsedRecipeFeed(
            title: delegate.feedTitle ?? sourceURL.host() ?? sourceURL.absoluteString,
            homeURL: delegate.feedHomeURL,
            articles: delegate.articles
        )
    }

    private static func parseJSON(_ data: Data, sourceURL: URL) throws -> ParsedRecipeFeed {
        let decoded = try JSONDecoder().decode(JSONFeed.self, from: data)
        guard decoded.version.lowercased().contains("jsonfeed.org") else {
            throw RecipeFeedParserError.unsupportedFormat
        }
        let articles = decoded.items.compactMap { item -> ParsedFeedArticle? in
            guard let rawURL = item.url ?? item.externalURL,
                  let url = URL(string: rawURL, relativeTo: sourceURL)?.absoluteURL else { return nil }
            let published = parseDate(item.datePublished) ?? parseDate(item.dateModified)
            let title = clean(item.title) ?? url.host() ?? String(localized: "Untitled recipe")
            return ParsedFeedArticle(
                id: item.id.isEmpty ? url.absoluteString : item.id,
                title: title,
                url: url,
                author: item.authors?.compactMap(\.name).first,
                summary: clean(item.summary ?? item.contentText),
                body: item.contentHTML ?? item.contentText,
                publishedAt: published
            )
        }
        return ParsedRecipeFeed(
            title: decoded.title,
            homeURL: decoded.homePageURL.flatMap { URL(string: $0, relativeTo: sourceURL)?.absoluteURL },
            articles: articles
        )
    }

    fileprivate static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    fileprivate static func clean(_ value: String?) -> String? {
        let text = value?
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private struct JSONFeed: Decodable {
        var version: String
        var title: String
        var homePageURL: String?
        var items: [JSONItem]

        enum CodingKeys: String, CodingKey {
            case version, title, items
            case homePageURL = "home_page_url"
        }
    }

    private struct JSONItem: Decodable {
        var id: String
        var url: String?
        var externalURL: String?
        var title: String?
        var contentHTML: String?
        var contentText: String?
        var summary: String?
        var datePublished: String?
        var dateModified: String?
        var authors: [JSONAuthor]?

        enum CodingKeys: String, CodingKey {
            case id, url, title, summary, authors
            case externalURL = "external_url"
            case contentHTML = "content_html"
            case contentText = "content_text"
            case datePublished = "date_published"
            case dateModified = "date_modified"
        }
    }

    private struct JSONAuthor: Decodable { var name: String? }
}

private final class XMLFeedDelegate: NSObject, XMLParserDelegate {
    let sourceURL: URL
    var recognizedFeed = false
    var feedTitle: String?
    var feedHomeURL: URL?
    var articles: [ParsedFeedArticle] = []

    private var insideItem = false
    private var currentText = ""
    private var item: [String: String] = [:]

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = (qName ?? elementName).lowercased()
        currentText = ""
        if element == "rss" || element == "feed" { recognizedFeed = true }
        if element == "item" || element == "entry" {
            insideItem = true
            item = [:]
        }
        guard element == "link", let href = attributeDict["href"],
              let url = URL(string: href, relativeTo: sourceURL)?.absoluteURL else { return }
        let rel = attributeDict["rel"]?.lowercased()
        if insideItem, rel == nil || rel == "alternate" {
            item["link"] = url.absoluteString
        } else if !insideItem, rel == nil || rel == "alternate" {
            feedHomeURL = url
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        currentText += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = (qName ?? elementName).lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if element == "item" || element == "entry" {
            finishItem()
            insideItem = false
            currentText = ""
            return
        }
        guard !text.isEmpty else { return }
        if insideItem {
            switch element {
            case "title", "link", "guid", "id", "author", "name", "description", "summary", "content", "content:encoded", "pubdate", "published", "updated":
                if item[element] == nil { item[element] = text }
            default: break
            }
        } else {
            if element == "title", feedTitle == nil { feedTitle = RecipeFeedParser.clean(text) }
            if element == "link", feedHomeURL == nil {
                feedHomeURL = URL(string: text, relativeTo: sourceURL)?.absoluteURL
            }
        }
        currentText = ""
    }

    private func finishItem() {
        guard let rawURL = item["link"],
              let url = URL(string: rawURL, relativeTo: sourceURL)?.absoluteURL else { return }
        let title = RecipeFeedParser.clean(item["title"]) ?? url.host() ?? String(localized: "Untitled recipe")
        let body = item["content:encoded"] ?? item["content"] ?? item["description"]
        let id = item["guid"] ?? item["id"] ?? url.absoluteString
        articles.append(ParsedFeedArticle(
            id: id,
            title: title,
            url: url,
            author: RecipeFeedParser.clean(item["author"] ?? item["name"]),
            summary: RecipeFeedParser.clean(item["summary"] ?? item["description"]),
            body: body,
            publishedAt: RecipeFeedParser.parseDate(item["pubdate"] ?? item["published"] ?? item["updated"])
        ))
    }
}

enum RecipeFeedDiscovery {
    static func feedURLs(inHTML html: String, baseURL: URL) -> [URL] {
        let pattern = #"<link\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var result: [URL] = []
        for match in regex.matches(in: html, range: range) {
            guard let swiftRange = Range(match.range, in: html) else { continue }
            let attributes = parseAttributes(String(html[swiftRange]))
            let relWords = Set((attributes["rel"] ?? "").lowercased().split(separator: " ").map(String.init))
            let type = (attributes["type"] ?? "").lowercased()
            guard relWords.contains("alternate"),
                  type.contains("rss") || type.contains("atom") || type.contains("json"),
                  let href = attributes["href"],
                  let url = URL(string: decodeEntities(href), relativeTo: baseURL)?.absoluteURL,
                  !result.contains(url) else { continue }
            result.append(url)
        }
        return result
    }

    private static func parseAttributes(_ tag: String) -> [String: String] {
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*([\"'])(.*?)\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [:] }
        let range = NSRange(tag.startIndex..., in: tag)
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: tag),
                  let valueRange = Range(match.range(at: 3), in: tag) else { continue }
            result[String(tag[keyRange]).lowercased()] = String(tag[valueRange])
        }
        return result
    }

    private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

enum RecipeFeedRefreshPolicy {
    static func retryDate(after failures: Int, now: Date = .now) -> Date {
        let hours = min(48, Int(pow(2, Double(max(0, failures - 1)))))
        return now.addingTimeInterval(TimeInterval(hours * 60 * 60))
    }
}
