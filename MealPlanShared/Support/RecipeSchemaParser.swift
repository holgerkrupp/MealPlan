import Foundation

/// Fetches a web page and extracts a recipe from `schema.org/Recipe`
/// structured data — JSON-LD first, then microdata, then a best-effort
/// heuristic. German quantity strings are handed to `GermanUnitParser`
/// downstream (this type only produces raw ingredient lines).
struct RecipeSchemaParser: RecipeImporter {

    var session: URLSession = .shared

    func importRecipe(from url: URL) async throws -> ImportedRecipe {
        let page = try await fetchRecipePage(from: url)
        let html = page.html
        let sourceURL = page.url
        return await withImage(parseRenderedHTML(html, sourceURL: sourceURL), html: html)
    }

    /// Parses HTML the caller already has, rather than fetching it. The
    /// in-app browser uses this so the import reads the page the user is
    /// actually looking at — cookie banners dismissed, lazy content rendered —
    /// instead of whatever a fresh anonymous request would return.
    func importRecipe(fromHTML html: String, sourceURL: URL) async throws -> ImportedRecipe {
        return await withImage(parseRenderedHTML(html, sourceURL: sourceURL), html: html)
    }

    /// Structured data remains authoritative, but a page can have a useful
    /// visible ingredient card while publishing only a name (or placeholder
    /// headings) in JSON-LD. Semantic HTML is therefore evaluated once after
    /// the structured/site-specific parsers and used only to fill holes.
    private func parseRenderedHTML(_ html: String, sourceURL: URL) -> ImportedRecipe {
        // KptnCook's page contains a hidden, incomplete microdata block as
        // well as the rows a person actually sees. Give its narrow parser
        // first refusal so generic extraction cannot mix the two.
        let structured = parseKptnCook(html: html, sourceURL: sourceURL)
            ?? parseJSONLD(html: html, sourceURL: sourceURL)
            ?? parseChefkoch(html: html, sourceURL: sourceURL)
            ?? parseMicrodata(html: html, sourceURL: sourceURL)
        let semantic = SemanticRecipeExtractor.extract(html: html, sourceURL: sourceURL)

        if var structured {
            if let semantic { augment(&structured, with: semantic) }
            return structured
        }
        if let semantic, semantic.hasContent {
            return recipe(from: semantic, sourceURL: sourceURL)
        }
        return heuristic(html: html, sourceURL: sourceURL)
    }

    private func recipe(from semantic: SemanticRecipeExtractor.Result, sourceURL: URL) -> ImportedRecipe {
        var recipe = ImportedRecipe(
            name: semantic.name ?? heuristic(html: "", sourceURL: sourceURL).name,
            sourceURL: sourceURL
        )
        recipe.needsReview = true
        recipe.ingredientLines = semantic.ingredientLines
        recipe.instructions = Self.numberedSteps(semantic.instructionLines)
        recipe.fieldEvidence = semantic.fieldEvidence
        return recipe
    }

    private func augment(_ recipe: inout ImportedRecipe, with semantic: SemanticRecipeExtractor.Result) {
        if Self.isPlaceholderPayload(recipe.ingredientLines) || recipe.ingredientLines.isEmpty {
            if !semantic.ingredientLines.isEmpty {
                recipe.ingredientLines = semantic.ingredientLines
                if let evidence = semantic.fieldEvidence["ingredients"] { recipe.fieldEvidence["ingredients"] = evidence }
            }
        }

        let structuredInstructions = recipe.instructions.map { [$0] } ?? []
        if Self.isPlaceholderPayload(structuredInstructions) || (recipe.instructions ?? "").trimmedCollapsed.isEmpty {
            if !semantic.instructionLines.isEmpty {
                recipe.instructions = Self.numberedSteps(semantic.instructionLines)
                if let evidence = semantic.fieldEvidence["instructions"] { recipe.fieldEvidence["instructions"] = evidence }
            }
        }
        // A partial structured candidate is still reviewable. A complete
        // structured candidate keeps its stronger status and field evidence.
        if recipe.ingredientLines.isEmpty && (recipe.instructions ?? "").isEmpty { recipe.needsReview = true }
    }

    private static func isPlaceholderPayload(_ values: [String]) -> Bool {
        guard !values.isEmpty else { return true }
        let headings: Set<String> = [
            "ingredient", "ingredients", "zutaten", "directions", "direction",
            "instructions", "instruction", "method", "preparation", "zubereitung",
            "anleitung", "steps", "step"
        ]
        return values.allSatisfy { value in
            var normalized = value.trimmedCollapsed.lowercased()
            normalized = normalized.replacingOccurrences(of: #"^\d+[.)]\s*"#, with: "", options: .regularExpression)
            return headings.contains(normalized.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
        }
    }

    // MARK: - Fetch

    /// KptnCook's share domain is an Appsflyer landing page. Its useful
    /// recipe URL lives in JavaScript, so URLSession never reaches the page
    /// that contains the ingredients and steps without this extra hop.
    private func fetchRecipePage(from url: URL) async throws -> (html: String, url: URL) {
        let html = try await fetchHTML(from: url)
        guard let destination = Self.kptnCookDestination(in: html, from: url) else {
            return (html, url)
        }
        return (try await fetchHTML(from: destination), destination)
    }

    static func kptnCookDestination(in html: String, from url: URL) -> URL? {
        guard url.host?.lowercased() == "share.kptncook.com" else { return nil }
        let pattern = #"(?:mac_redirect|store_link)\s*=\s*['\"]([^'\"]+)['\"]"#
        guard let value = firstCapture(of: pattern, in: html),
              let destination = URL(string: value),
              destination.scheme == "https",
              destination.host?.lowercased() == "mobile.kptncook.com" else { return nil }
        return destination
    }

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
        if Self.isPlaceholderPayload(recipe.ingredientLines) { recipe.ingredientLines = [] }
        recipe.instructions = instructions(dict["recipeInstructions"])
        if let instructions = recipe.instructions, Self.isPlaceholderPayload([instructions]) { recipe.instructions = nil }
        recipe.servings = servings(dict["recipeYield"] ?? dict["yield"])
        recipe.tagNames = tagList([
            dict["keywords"], dict["recipeCategory"], dict["recipeCuisine"], dict["suitableForDiet"]
        ])
        recipe.prepTimeMinutes = minutes(dict["prepTime"])
        recipe.cookTimeMinutes = minutes(dict["cookTime"])
        if recipe.prepTimeMinutes == nil, recipe.cookTimeMinutes == nil {
            recipe.cookTimeMinutes = minutes(dict["totalTime"])
        }

        recipe.nutritionPerServing = nutrition(dict["nutrition"])

        recipe.fieldEvidence["name"] = RecipeFieldEvidence(source: .jsonLD, locator: "application/ld+json name", confidence: 0.99)
        if !recipe.ingredientLines.isEmpty { recipe.fieldEvidence["ingredients"] = RecipeFieldEvidence(source: .jsonLD, locator: "recipeIngredient", confidence: 0.99) }
        if recipe.instructions != nil { recipe.fieldEvidence["instructions"] = RecipeFieldEvidence(source: .jsonLD, locator: "recipeInstructions", confidence: 0.99) }
        if recipe.imageURLString != nil { recipe.fieldEvidence["image"] = RecipeFieldEvidence(source: .jsonLD, locator: "image", confidence: 0.95) }

        if recipe.ingredientLines.isEmpty && recipe.instructions == nil {
            recipe.needsReview = true
        }
        return recipe
    }

    /// schema.org `NutritionInformation`, which states everything per serving.
    ///
    /// Its values are strings with units baked in — "540 calories", "31 g",
    /// "2200 kJ" — so each one is scanned for its number and, for energy,
    /// checked for kilojoules before being taken as kilocalories. A block with
    /// no usable energy figure is dropped rather than stored as zero: the
    /// computed estimate is a far better answer than a confident nought.
    static func nutrition(_ any: Any?) -> NutritionFacts? {
        guard let dict = any as? [String: Any] else { return nil }
        guard let energy = energyKcal(dict["calories"] ?? dict["energyContent"]) else { return nil }
        return NutritionFacts(
            energyKcal: energy,
            proteinGrams: measurement(dict["proteinContent"]) ?? 0,
            carbGrams: measurement(dict["carbohydrateContent"]) ?? 0,
            fatGrams: measurement(dict["fatContent"]) ?? 0
        )
    }

    static func energyKcal(_ any: Any?) -> Double? {
        guard let value = measurement(any), value > 0 else { return nil }
        let text = (string(any) ?? "").lowercased()
        // "2200 kJ" and "2200 kilojoules", but not "540 kcal", which contains
        // no "kj" — and not a bare number, which every site means as calories.
        if text.contains("kj") || text.contains("kilojoule") {
            return value / 4.184
        }
        return value
    }

    /// The first number in a value like "31 g", "31g", "about 540 kcal" or 31.
    static func measurement(_ any: Any?) -> Double? {
        if let number = any as? NSNumber { return sane(number.doubleValue) }
        guard let text = string(any) else { return nil }
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let start = normalized.firstIndex(where: \.isNumber) else { return nil }
        let digits = normalized[start...].prefix { $0.isNumber || $0 == "." }
        return Double(digits).flatMap(sane)
    }

    private static func sane(_ value: Double) -> Double? {
        value.isFinite && value >= 0 ? value : nil
    }

    // MARK: - Field coercion

    static func string(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        case let d as [String: Any]:
            return string(d["@value"]) ?? string(d["value"]) ?? string(d["name"]) ?? string(d["text"]) ?? string(d["url"])
        case let a as [Any]: return a.compactMap(string).first
        default: return nil
        }
    }

    /// Free-form tags out of schema.org's several category fields. `keywords`
    /// is very often one comma-separated string, and `suitableForDiet` a
    /// schema URL such as "https://schema.org/VegetarianDiet" — both are
    /// reduced to plain words. Capped so a keyword-stuffed page contributes a
    /// handful of tags rather than fifty.
    static func tagList(_ values: [Any?], limit: Int = 6) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for value in values {
            for entry in stringArray(value) {
                for piece in entry.components(separatedBy: CharacterSet(charactersIn: ",;|")) {
                    var tag = piece.trimmedCollapsed
                    if let slash = tag.lastIndex(of: "/"), tag.lowercased().hasPrefix("http") {
                        tag = String(tag[tag.index(after: slash)...])
                    }
                    if tag.count > 4, tag.hasSuffix("Diet") { tag.removeLast(4) }
                    tag = DishTag.clean(tag)
                    guard !tag.isEmpty, tag.count <= 24,
                          seen.insert(DishTag.normalize(tag)).inserted else { continue }
                    result.append(tag)
                    if result.count == limit { return result }
                }
            }
        }
        return result
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
        default: return string(any).flatMap(servings)
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

    // MARK: - Site fallbacks

    /// Chefkoch currently renders recipe data as ordinary HTML rather than
    /// relying exclusively on schema.org. Keep this parser as a fallback for
    /// pages where its JSON-LD is omitted (for example, a partially rendered
    /// page captured by the in-app browser).
    func parseChefkoch(html: String, sourceURL: URL) -> ImportedRecipe? {
        guard sourceURL.host?.lowercased().hasSuffix("chefkoch.de") == true else { return nil }

        let ingredientRows = Self.captures(
            of: #"<tr[^>]*class\s*=\s*['\"][^'\"]*\bds-ingredients-table__tr\b[^'\"]*['\"][^>]*>(.*?)</tr>"#,
            in: html
        )
        let ingredients = ingredientRows.compactMap(Self.chefkochIngredientLine)
        let steps = Self.captures(
            of: #"<[^>]*data-testid\s*=\s*['\"]recipe-instruction['\"][^>]*>(.*?)</[^>]+>"#,
            in: html
        )
        .map { $0.strippingHTML.trimmedCollapsed }
        .filter { !$0.isEmpty }

        guard !ingredients.isEmpty || !steps.isEmpty else { return nil }
        var recipe = ImportedRecipe(
            name: heuristicTitle(html) ?? String(localized: "Imported recipe"),
            sourceURL: sourceURL
        )
        recipe.needsReview = false
        recipe.ingredientLines = ingredients
        recipe.instructions = Self.numberedSteps(steps)
        recipe.servings = Self.firstCapture(
            of: #"ds-quantity-control__amount[^>]*>\s*([0-9]+(?:[.,][0-9]+)?)"#,
            in: html
        ).flatMap { Self.servings($0) }
        recipe.prepTimeMinutes = Self.chefkochWorkingTime(in: html)
        return recipe
    }

    private static func chefkochIngredientLine(_ row: String) -> String? {
        let cells = captures(of: #"<td[^>]*>(.*?)</td>"#, in: row)
        guard cells.count >= 2 else { return nil }
        let amount = cells[0].strippingHTML.trimmedCollapsed
        let ingredient = cells[1].strippingHTML.trimmedCollapsed
        return [amount, ingredient]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .nilIfEmpty
    }

    private static func chefkochWorkingTime(in html: String) -> Int? {
        let pattern = #"recipe-meta-property-group__value[^>]*>(.*?)</[^>]+>\s*<[^>]*recipe-meta-property-group__title[^>]*>\s*Arbeitszeit"#
        guard let value = firstCapture(of: pattern, in: html) else { return nil }
        return value.strippingHTML.firstInteger
    }

    // MARK: - Generic HTML fallback

    /// A best-effort parser for recipe sites that do not expose schema.org.
    /// It deliberately looks only at visible recipe regions, semantic headings
    /// and recipe-like classes, so navigation lists and page chrome do not
    /// become ingredients.
    func parseGenericHTML(html: String, sourceURL: URL) -> ImportedRecipe? {
        guard let semantic = SemanticRecipeExtractor.extract(html: html, sourceURL: sourceURL), semantic.hasContent else { return nil }
        return recipe(from: semantic, sourceURL: sourceURL)
    }

    private static func genericIngredientLines(in html: String) -> [String] {
        let keyword = #"(?:ingredient|ingredients|zutaten)"#
        let itemPatterns = [
            #"<li[^>]*(?:class|id|data-testid)\s*=\s*['\"][^'\"]*"# + keyword + #"[^'\"]*['\"][^>]*>(.*?)</li>"#,
            #"<[^>]*(?:class|id|data-testid)\s*=\s*['\"][^'\"]*"# + keyword + #"[^'\"]*['\"][^>]*>([^<]+)</[^>]+>"#,
        ]
        var lines = itemPatterns.flatMap { captures(of: $0, in: html) }

        // Ingredient tables are common on publisher sites. Combine the cells
        // of each row so a quantity and its ingredient stay together.
        let tables = captures(
            of: #"<table[^>]*(?:class|id)\s*=\s*['\"][^'\"]*"# + keyword + #"[^'\"]*['\"][^>]*>(.*?)</table>"#,
            in: html
        )
        for table in tables {
            for row in captures(of: #"<tr[^>]*>(.*?)</tr>"#, in: table) {
                let cells = captures(of: #"<t[dh][^>]*>(.*?)</t[dh]>"#, in: row)
                    .map { $0.strippingHTML.trimmedCollapsed }
                    .filter { !$0.isEmpty }
                if !cells.isEmpty { lines.append(cells.joined(separator: " ")) }
            }
        }

        if lines.isEmpty, let section = recipeSection(afterHeadingMatching: keyword, in: html) {
            lines = captures(of: #"<li[^>]*>(.*?)</li>"#, in: section)
        }
        return cleanedUnique(lines)
    }

    private static func genericInstructionSteps(in html: String) -> [String] {
        let keyword = #"(?:instruction|instructions|direction|directions|preparation|method|step|zubereitung|anleitung)"#
        let itemPatterns = [
            #"<li[^>]*(?:class|id|data-testid)\s*=\s*['\"][^'\"]*"# + keyword + #"[^'\"]*['\"][^>]*>(.*?)</li>"#,
            #"<[^>]*(?:class|id|data-testid)\s*=\s*['\"][^'\"]*"# + keyword + #"[^'\"]*['\"][^>]*>([^<]+)</[^>]+>"#,
        ]
        var steps = itemPatterns.flatMap { captures(of: $0, in: html) }
        if steps.isEmpty, let section = recipeSection(afterHeadingMatching: keyword, in: html) {
            steps = captures(of: #"<li[^>]*>(.*?)</li>"#, in: section)
            if steps.isEmpty { steps = captures(of: #"<p[^>]*>(.*?)</p>"#, in: section) }
        }
        return cleanedUnique(steps)
    }

    /// Returns the content after a recipe heading up to the next heading. It
    /// is intentionally bounded to avoid accidentally collecting a page's
    /// footer or related-recipe cards.
    private static func recipeSection(afterHeadingMatching keyword: String, in html: String) -> String? {
        let pattern = #"<h[1-4][^>]*>\s*[^<]*"# + keyword + #"[^<]*</h[1-4]>"#
        guard let heading = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let remaining = String(html[heading.upperBound...])
        let end = remaining.range(of: #"<h[1-4][^>]*>"#, options: [.regularExpression, .caseInsensitive])?.lowerBound
        return end.map { String(remaining[..<$0]) } ?? String(remaining.prefix(12_000))
    }

    private static func cleanedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let line = value.strippingHTML.trimmedCollapsed
            guard !line.isEmpty, line.count > 1 else { return nil }
            let key = line.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return seen.insert(key).inserted ? line : nil
        }
    }

    private static func numberedSteps(_ steps: [String]) -> String? {
        guard !steps.isEmpty else { return nil }
        return steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
    }

    /// KptnCook puts a second, hidden microdata ingredient list on its pages.
    /// It has proved unreliable: it can contain values from another recipe.
    /// The displayed paired amount/name rows are the only ingredient source we
    /// trust. If those rows are unavailable, importing no ingredients is much
    /// safer than adding a believable but wrong shopping list.
    func parseKptnCook(html: String, sourceURL: URL) -> ImportedRecipe? {
        guard sourceURL.host?.lowercased().hasSuffix("kptncook.com") == true,
              let name = Self.firstCapture(
                of: #"<[^>]*class\s*=\s*['\"][^'\"]*\bkptn-recipetitle\b[^'\"]*['\"][^>]*>(.*?)</[^>]+>"#,
                in: html
              )?.strippingHTML.trimmedCollapsed.nilIfEmpty else { return nil }

        var recipe = ImportedRecipe(name: name, sourceURL: sourceURL)
        recipe.needsReview = false
        recipe.imageURLString = Self.firstCapture(
            of: #"itemprop\s*=\s*['\"]image['\"][^>]*(?:content|src)\s*=\s*['\"]([^'\"]+)['\"]"#,
            in: html
        )
        let ingredients = Self.kptnCookVisibleIngredientLines(in: html)
        recipe.ingredientLines = ingredients
        // A repeated name with several different amounts is precisely the
        // failure this parser is protecting against. It is not trustworthy
        // enough to put on the family's shopping list.
        let parsedNames = ingredients.map { GermanUnitParser.parse($0).name }
        let hasOnlyOneRepeatedName = parsedNames.count >= 3
            && Set(parsedNames.map(Ingredient.normalize)).count == 1
        if ingredients.isEmpty || hasOnlyOneRepeatedName {
            recipe.ingredientLines = []
            recipe.needsReview = true
        }
        recipe.instructions = Self.captures(
            of: #"<[^>]*class\s*=\s*['\"][^'\"]*\bkptn-step-title\b[^'\"]*['\"][^>]*>\s*<[^>]*>(.*?)</[^>]+>\s*</[^>]+>"#,
            in: html
        )
        .map { $0.strippingHTML.trimmedCollapsed }
        .filter { !$0.isEmpty }
        .enumerated()
        .map { "\($0.offset + 1). \($0.element)" }
        .joined(separator: "\n\n")
        .nilIfEmpty
        recipe.servings = Self.firstCapture(
            of: #"itemprop\s*=\s*['\"]recipeYield['\"][^>]*>(.*?)<"#,
            in: html
        ).flatMap { Self.servings($0) }
        recipe.cookTimeMinutes = Self.firstCapture(
            of: #"itemprop\s*=\s*['\"]totalTime['\"][^>]*>(.*?)<"#,
            in: html
        ).flatMap { Self.minutes($0) }
        recipe.deepLinkURL = Self.kptnCookDeepLink(in: html)
        recipe.importedSourceApp = "KptnCook"
        return recipe
    }

    /// Each KptnCook ingredient the page asks the cook to buy is rendered as
    /// an amount cell immediately followed by a name cell. Deliberately avoid
    /// `itemprop=ingredients`: that hidden fallback markup is not authoritative.
    private static func kptnCookVisibleIngredientLines(in html: String) -> [String] {
        let pattern = #"<[^>]*class\s*=\s*['\"][^'\"]*\bkptn-ingredient-measure\b[^'\"]*['\"][^>]*>(.*?)</div>\s*</div>\s*<div[^>]*>\s*<[^>]*class\s*=\s*['\"][^'\"]*\bkptn-ingredient\b[^'\"]*['\"][^>]*>(.*?)</div>"#
        return pairedCaptures(of: pattern, in: html).compactMap { amount, name in
            let amount = amount.strippingHTML.trimmedCollapsed
            let name = name.strippingHTML.trimmedCollapsed
            guard !name.isEmpty else { return nil }
            return [amount, name].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// The preview page writes this universal link to its "Copy link" button.
    /// iOS opens it in KptnCook when the app is installed, where the complete
    /// recipe is available.
    static func kptnCookDeepLink(in html: String) -> URL? {
        let patterns = [
            #"navigator\.clipboard\s*\.writeText\(\s*['\"]([^'\"]+)['\"]\s*\)"#,
            #"(https://mobile\.kptncook\.com/r/[^'\"\s<]+)"#,
        ]
        for pattern in patterns {
            guard let value = firstCapture(of: pattern, in: html),
                  let url = URL(string: value),
                  url.scheme == "https",
                  url.host?.lowercased() == "mobile.kptncook.com",
                  url.path.hasPrefix("/r/") else { continue }
            return url
        }
        return nil
    }

    func parseMicrodata(html: String, sourceURL: URL) -> ImportedRecipe? {
        guard html.range(of: #"itemtype\s*=\s*['"][^'"]*schema\.org/Recipe/?['"]"#,
                         options: [.regularExpression, .caseInsensitive]) != nil else { return nil }

        func props(_ name: String) -> [String] {
            // A schema.org microdata property can be expressed either as the
            // element's text or as a `content` / `value` attribute.  The
            // latter is common on publisher sites and its attributes can be
            // in either order, so read it from the opening tag first.
            var values = Self.captures(of: #"(<[^>]+>)"#, in: html).compactMap { tag -> String? in
                guard let itemprop = Self.htmlAttribute("itemprop", in: tag),
                      itemprop.split(whereSeparator: \.isWhitespace).contains(where: {
                          $0.caseInsensitiveCompare(name) == .orderedSame
                      }) else { return nil }
                return Self.htmlAttribute("content", in: tag)
                    ?? Self.htmlAttribute("value", in: tag)
            }

            let pattern = "itemprop\\s*=\\s*['\"][^'\"]*\\b\(name)\\b[^'\"]*['\"][^>]*>(.*?)<"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
            let ns = html as NSString
            values += regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap {
                $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)).strippingHTML.trimmedCollapsed : nil
            }
            return Self.uniqueNonEmpty(values)
        }

        let name = props("name").first ?? heuristicTitle(html) ?? ""
        guard !name.isEmpty else { return nil }
        var recipe = ImportedRecipe(name: name, sourceURL: sourceURL)
        recipe.needsReview = true
        recipe.ingredientLines = props("recipeIngredient") + props("ingredients")
        recipe.instructions = props("recipeInstructions").joined(separator: "\n\n").nilIfEmpty
        if Self.isPlaceholderPayload(recipe.ingredientLines) { recipe.ingredientLines = [] }
        if let instructions = recipe.instructions, Self.isPlaceholderPayload([instructions]) { recipe.instructions = nil }
        recipe.fieldEvidence["name"] = RecipeFieldEvidence(source: .microdata, locator: "itemprop=name", confidence: 0.92)
        if !recipe.ingredientLines.isEmpty { recipe.fieldEvidence["ingredients"] = RecipeFieldEvidence(source: .microdata, locator: "itemprop=recipeIngredient", confidence: 0.92) }
        if recipe.instructions != nil { recipe.fieldEvidence["instructions"] = RecipeFieldEvidence(source: .microdata, locator: "itemprop=recipeInstructions", confidence: 0.92) }
        // Some publishers, including REWE, expose the ingredient rows and
        // portion count as microdata when their JSON-LD is unavailable to the
        // importer.  Without carrying the yield over, `DishBuilder` applies
        // its two-serving default even though the quantities belong to the
        // source recipe's stated number of portions.
        recipe.servings = (props("recipeYield") + props("yield"))
            .lazy
            .compactMap(Self.servings)
            .first
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

    private static func firstCapture(of pattern: String, in html: String) -> String? {
        captures(of: pattern, in: html).first
    }

    private static func captures(of pattern: String, in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    private static func pairedCaptures(of pattern: String, in html: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap {
            guard $0.numberOfRanges > 2 else { return nil }
            return (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    private static func htmlAttribute(_ name: String, in tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\s"# + escaped + #"\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        let ns = tag as NSString
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            return ns.substring(with: match.range(at: index))
        }
        return nil
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let cleaned = value.strippingHTML.trimmedCollapsed
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { return nil }
            return cleaned
        }
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

    /// Script and style contents often contain strings such as "ingredient"
    /// and "step". Excluding them before the generic fallback avoids treating
    /// CSS, embedded application state or signup chrome as recipe content.
    var removingScriptsAndStyles: String {
        var result = self
        for element in ["script", "style", "form", "nav", "footer", "aside", "template", "noscript"] {
            result = result.replacingOccurrences(
                of: "<\(element)\\b[^>]*>[\\s\\S]*?</\(element)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }

    var firstInteger: Int? {
        var value = 0
        var found = false
        for ch in self {
            if let digit = ch.wholeNumberValue {
                found = true
                let (shifted, shiftOverflow) = value.multipliedReportingOverflow(by: 10)
                let (next, addOverflow) = shifted.addingReportingOverflow(digit)
                guard !shiftOverflow, !addOverflow else { return nil }
                value = next
            } else if found {
                break
            }
        }
        return found ? value : nil
    }
}
