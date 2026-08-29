import Foundation

/// Fetches a web page and extracts a recipe from `schema.org/Recipe`
/// structured data — JSON-LD first, then microdata, then a best-effort
/// heuristic. German quantity strings are handed to `GermanUnitParser`
/// downstream (this type only produces raw ingredient lines).
struct RecipeSchemaParser: RecipeImporter {

    var session: URLSession = .shared

    func importRecipe(from url: URL) async throws -> ImportedRecipe {
        let html = try await fetchHTML(from: url)

        if let recipe = parseJSONLD(html: html, sourceURL: url) {
            return await withImage(recipe, html: html)
        }
        if let recipe = parseMicrodata(html: html, sourceURL: url) {
            return await withImage(recipe, html: html)
        }
        return await withImage(heuristic(html: html, sourceURL: url), html: html)
    }

    /// Parses HTML the caller already has, rather than fetching it. The
    /// in-app browser uses this so the import reads the page the user is
    /// actually looking at — cookie banners dismissed, lazy content rendered —
    /// instead of whatever a fresh anonymous request would return.
    func importRecipe(fromHTML html: String, sourceURL: URL) async throws -> ImportedRecipe {
        if let recipe = parseJSONLD(html: html, sourceURL: sourceURL) {
            return await withImage(recipe, html: html)
        }
        if let recipe = parseMicrodata(html: html, sourceURL: sourceURL) {
            return await withImage(recipe, html: html)
        }
        return await withImage(heuristic(html: html, sourceURL: sourceURL), html: html)
    }

    // MARK: - Fetch

    private func fetchHTML(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw RecipeImportError.notReachable
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw RecipeImportError.notReachable
    }

    /// Downloads the recipe's picture. Structured markup is preferred, but a
    /// page that declares no recipe image usually still has a social-preview
    /// one, so fall back to those before giving up and leaving the dish with
    /// its suggested placeholder.
    private func withImage(_ recipe: ImportedRecipe, html: String) async -> ImportedRecipe {
        guard recipe.imageData == nil else { return recipe }
        var copy = recipe

        for candidate in ([recipe.imageURLString] + Self.pageImageURLs(in: html)).compactMap({ $0 }) {
            guard let imageURL = URL(string: candidate),
                  imageURL.scheme?.hasPrefix("http") == true else { continue }
            if let data = await ImagePreparation.download(imageURL) {
                copy.imageData = data
                copy.imageURLString = candidate
                return copy
            }
        }
        return copy
    }

    /// Image URLs a page advertises for previews, best first.
    static func pageImageURLs(in html: String) -> [String] {
        let patterns = [
            #"property\s*=\s*['"]og:image(:secure_url|:url)?['"][^>]*content\s*=\s*['"]([^'"]+)"#,
            #"name\s*=\s*['"]twitter:image(:src)?['"][^>]*content\s*=\s*['"]([^'"]+)"#,
            #"itemprop\s*=\s*['"]image['"][^>]*(content|src)\s*=\s*['"]([^'"]+)"#,
            #"rel\s*=\s*['"]image_src['"][^>]*href\s*=\s*['"]([^'"]+)"#,
        ]
        var found: [String] = []
        for pattern in patterns {
            guard let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                  let value = extractLastQuotedValue(String(html[range])),
                  !found.contains(value) else { continue }
            found.append(value)
        }
        return found
    }

    // MARK: - JSON-LD

    func parseJSONLD(html: String, sourceURL: URL) -> ImportedRecipe? {
        for json in Self.jsonLDBlocks(in: html) {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            for candidate in Self.recipeDicts(in: object) {
                if let recipe = Self.map(candidate, sourceURL: sourceURL) {
                    return recipe
                }
            }
        }
        return nil
    }

    static func jsonLDBlocks(in html: String) -> [String] {
        let pattern = #"<script[^>]*type\s*=\s*['"]application/ld\+json['"][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    /// Walk an arbitrary JSON structure collecting objects that look like a Recipe.
    static func recipeDicts(in object: Any) -> [[String: Any]] {
        var found: [[String: Any]] = []
        func visit(_ any: Any) {
            if let dict = any as? [String: Any] {
                if isRecipe(dict) { found.append(dict) }
                if let graph = dict["@graph"] { visit(graph) }
            } else if let array = any as? [Any] {
                array.forEach(visit)
            }
        }
        visit(object)
        return found
    }

    static func isRecipe(_ dict: [String: Any]) -> Bool {
        let type = dict["@type"]
        if let s = type as? String { return s.caseInsensitiveCompare("Recipe") == .orderedSame }
        if let arr = type as? [String] { return arr.contains { $0.caseInsensitiveCompare("Recipe") == .orderedSame } }
        return dict["recipeIngredient"] != nil || dict["recipeInstructions"] != nil
    }

    static func map(_ dict: [String: Any], sourceURL: URL) -> ImportedRecipe? {
        let name = string(dict["name"]) ?? string(dict["headline"]) ?? ""
        guard !name.isEmpty else { return nil }

        var recipe = ImportedRecipe(name: name.trimmedCollapsed, sourceURL: sourceURL)
        recipe.needsReview = false

        recipe.imageURLString = imageURL(dict["image"])
        recipe.ingredientLines = stringArray(dict["recipeIngredient"] ?? dict["ingredients"])
            .map { $0.trimmedCollapsed }
            .filter { !$0.isEmpty }
        recipe.instructions = instructions(dict["recipeInstructions"])
        recipe.servings = servings(dict["recipeYield"] ?? dict["yield"])
        recipe.prepTimeMinutes = minutes(dict["prepTime"])
        recipe.cookTimeMinutes = minutes(dict["cookTime"])
        if recipe.prepTimeMinutes == nil, recipe.cookTimeMinutes == nil {
            recipe.cookTimeMinutes = minutes(dict["totalTime"])
        }

        if recipe.ingredientLines.isEmpty && recipe.instructions == nil {
            recipe.needsReview = true
        }
        return recipe
    }

    // MARK: - Field coercion

    static func string(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        case let d as [String: Any]:
            return string(d["@value"]) ?? string(d["name"]) ?? string(d["text"]) ?? string(d["url"])
        case let a as [Any]: return a.compactMap(string).first
        default: return nil
        }
    }

    static func stringArray(_ any: Any?) -> [String] {
        switch any {
        case let s as String:
            return s.contains("\n") ? s.components(separatedBy: .newlines).map { $0.trimmedCollapsed } : [s]
        case let a as [Any]: return a.compactMap { string($0) }
        case let d as [String: Any]: return string(d).map { [$0] } ?? []
        default: return []
        }
    }

    static func imageURL(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let d as [String: Any]:
            return string(d["url"]) ?? (d["@list"].map { imageURL($0) } ?? nil)
        case let a as [Any]:
            return a.compactMap { imageURL($0) }.first
        default: return nil
        }
    }

    static func instructions(_ any: Any?) -> String? {
        switch any {
        case let s as String:
            let cleaned = s.strippingHTML.trimmedCollapsed
            return cleaned.isEmpty ? nil : cleaned
        case let a as [Any]:
            let steps = a.flatMap { element -> [String] in
                if let s = element as? String { return [s] }
                if let d = element as? [String: Any] {
                    let type = (d["@type"] as? String) ?? ""
                    if type.caseInsensitiveCompare("HowToSection") == .orderedSame {
                        return stringArray(d["itemListElement"])
                    }
                    if let text = string(d["text"]) ?? string(d["name"]) { return [text] }
                }
                return []
            }
            .map { $0.strippingHTML.trimmedCollapsed }
            .filter { !$0.isEmpty }
            return steps.isEmpty ? nil : steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
        case let d as [String: Any]:
            return instructions(d["itemListElement"]) ?? string(d)
        default: return nil
        }
    }

    static func servings(_ any: Any?) -> Int? {
        switch any {
        case let n as NSNumber: return max(1, n.intValue)
        case let s as String:
            let digits = s.firstInteger
            return digits.map { max(1, $0) }
        case let a as [Any]: return a.compactMap { servings($0) }.first
        default: return nil
        }
    }

    /// ISO-8601 duration ("PT1H15M", "P0DT0H30M") → minutes.
    static func minutes(_ any: Any?) -> Int? {
        guard let raw = string(any), raw.hasPrefix("P") else {
            if let n = any as? NSNumber { return max(0, n.intValue) }
            return nil
        }
        var hours = 0, mins = 0, days = 0
        var number = ""
        var inTime = false
        for ch in raw.dropFirst() {
            switch ch {
            case "T": inTime = true; number = ""
            case "0"..."9": number.append(ch)
            case "D": days = Int(number) ?? 0; number = ""
            case "H": hours = Int(number) ?? 0; number = ""
            case "M": if inTime { mins = Int(number) ?? 0 }; number = ""
            default: number = ""
            }
        }
        let total = days * 1440 + hours * 60 + mins
        return total > 0 ? total : nil
    }

    // MARK: - Microdata fallback

    func parseMicrodata(html: String, sourceURL: URL) -> ImportedRecipe? {
        guard html.range(of: #"itemtype\s*=\s*['"]https?://schema.org/Recipe['"]"#,
                         options: [.regularExpression, .caseInsensitive]) != nil else { return nil }

        func props(_ name: String) -> [String] {
            let pattern = "itemprop\\s*=\\s*['\"]\(name)['\"][^>]*>(.*?)<"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
            let ns = html as NSString
            return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap {
                $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)).strippingHTML.trimmedCollapsed : nil
            }.filter { !$0.isEmpty }
        }

        let name = props("name").first ?? heuristicTitle(html) ?? ""
        guard !name.isEmpty else { return nil }
        var recipe = ImportedRecipe(name: name, sourceURL: sourceURL)
        recipe.needsReview = true
        recipe.ingredientLines = props("recipeIngredient") + props("ingredients")
        recipe.instructions = props("recipeInstructions").joined(separator: "\n\n").nilIfEmpty
        if let content = html.range(of: #"itemprop\s*=\s*['"]image['"][^>]*(content|src)\s*=\s*['"]([^'"]+)"#,
                                    options: [.regularExpression, .caseInsensitive]) {
            recipe.imageURLString = extractLastQuoted(String(html[content]))
        }
        return recipe
    }

    // MARK: - Heuristic

    func heuristic(html: String, sourceURL: URL) -> ImportedRecipe {
        var recipe = ImportedRecipe(
            name: heuristicTitle(html) ?? sourceURL.host()?.replacingOccurrences(of: "www.", with: "").capitalized ?? String(localized: "Imported recipe"),
            sourceURL: sourceURL
        )
        recipe.needsReview = true
        if let og = html.range(of: #"property\s*=\s*['"]og:image['"][^>]*content\s*=\s*['"]([^'"]+)"#,
                               options: [.regularExpression, .caseInsensitive]) {
            recipe.imageURLString = extractLastQuoted(String(html[og]))
        }
        return recipe
    }

    private func heuristicTitle(_ html: String) -> String? {
        if let og = html.range(of: #"property\s*=\s*['"]og:title['"][^>]*content\s*=\s*['"]([^'"]+)"#,
                               options: [.regularExpression, .caseInsensitive]) {
            return extractLastQuoted(String(html[og]))?.strippingHTML.trimmedCollapsed
        }
        if let h1 = html.range(of: #"<h1[^>]*>(.*?)</h1>"#, options: [.regularExpression, .caseInsensitive]) {
            return String(html[h1]).strippingHTML.trimmedCollapsed.nilIfEmpty
        }
        if let title = html.range(of: #"<title[^>]*>(.*?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            return String(html[title]).strippingHTML.trimmedCollapsed.nilIfEmpty
        }
        return nil
    }

    private func extractLastQuoted(_ s: String) -> String? {
        Self.extractLastQuotedValue(s)
    }

    static func extractLastQuotedValue(_ s: String) -> String? {
        let parts = s.split(whereSeparator: { $0 == "\"" || $0 == "'" })
        return parts.last.map(String.init)
    }
}

// MARK: - String helpers

extension String {
    var trimmedCollapsed: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var strippingHTML: String {
        let withoutTags = replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&auml;", with: "ä")
            .replacingOccurrences(of: "&ouml;", with: "ö")
            .replacingOccurrences(of: "&uuml;", with: "ü")
            .replacingOccurrences(of: "&szlig;", with: "ß")
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }

    var firstInteger: Int? {
        var digits = ""
        for ch in self {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        return Int(digits)
    }
}
