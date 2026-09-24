import Foundation

/// Extracts the visible recipe regions from rendered HTML when a page does
/// not provide usable structured data. This intentionally works on a small
/// DOM representation instead of regular expressions over the complete page:
/// headings, list boundaries and excluded regions are meaningful signals here.
struct SemanticRecipeExtractor {

    struct Result: Sendable, Equatable {
        var name: String?
        var ingredientLines: [String]
        var instructionLines: [String]
        var fieldEvidence: [String: RecipeFieldEvidence]

        var hasContent: Bool { !ingredientLines.isEmpty || !instructionLines.isEmpty }
    }

    private enum SectionKind {
        case ingredients
        case instructions
    }

    private struct SectionCandidate {
        var heading: HTMLNode
        var kind: SectionKind
        var lines: [String]
        var score: Double
        var order: Int
    }

    private static let ingredientHeadings: Set<String> = [
        "ingredient", "ingredients", "what you'll need", "what you need",
        "zutaten", "zutatenliste", "zutaten list"
    ]

    private static let instructionHeadings: Set<String> = [
        "instruction", "instructions", "direction", "directions", "method",
        "preparation", "how to make", "steps", "step", "zubereitung",
        "anleitung", "zubereitungsschritte"
    ]

    private static let excludedWords = [
        "advert", "advertisement", "banner", "comment", "cookie", "footer",
        "newsletter", "related", "recommend", "sidebar", "social", "share",
        "subscribe", "sign up", "signup", "author", "print recipe", "jump to",
        "navigation", "breadcrumb", "privacy", "login", "log in", "read more"
    ]

    private static let ingredientUnits = [
        "g", "gram", "grams", "kg", "kilogram", "ml", "milliliter", "millilitre",
        "l", "liter", "litre", "tsp", "teaspoon", "teaspoons", "tl", "tbsp",
        "tablespoon", "tablespoons", "el", "cup", "cups", "oz", "ounce", "ounces",
        "lb", "pound", "pounds", "pinch", "teaspoon", "esslöffel", "teelöffel",
        "prise", "bund", "stück", "stueck", "dose"
    ]

    private static let imperativeWords = [
        "add", "bake", "beat", "blend", "boil", "bring", "chop", "combine", "cook",
        "cut", "fold", "heat", "mix", "place", "pour", "preheat", "remove", "roast",
        "season", "serve", "simmer", "stir", "whisk", "aufkochen", "backen", "braten",
        "geben", "hinzufügen", "hinzufuegen", "kochen", "mischen", "schneiden", "servieren",
        "umrühren", "umruehren", "vorheizen", "vermengen", "würzen", "wuerzen"
    ]

    /// Extracts the strongest ingredient/instruction pair in the visible DOM.
    /// The result is nil when the page contains headings but no payload below
    /// them; a heading is never considered recipe content by itself.
    static func extract(html: String, sourceURL: URL? = nil) -> Result? {
        let document = HTMLDocumentParser.parse(html)
        let nodes = document.allElements
        let headings = nodes.enumerated().compactMap { order, node -> (Int, HTMLNode, SectionKind)? in
            guard let kind = sectionKind(for: node), !node.isExcludedRegion else { return nil }
            return (order, node, kind)
        }

        var ingredients: [SectionCandidate] = []
        var instructions: [SectionCandidate] = []
        for (order, heading, kind) in headings {
            let content = contentAfter(heading: heading)
            let lines: [String]
            let score: Double
            switch kind {
            case .ingredients:
                lines = ingredientLines(in: content)
                score = sectionScore(heading: heading, lines: lines, kind: kind)
                if !lines.isEmpty { ingredients.append(SectionCandidate(heading: heading, kind: kind, lines: lines, score: score, order: order)) }
            case .instructions:
                lines = instructionLines(in: content)
                score = sectionScore(heading: heading, lines: lines, kind: kind)
                if !lines.isEmpty { instructions.append(SectionCandidate(heading: heading, kind: kind, lines: lines, score: score, order: order)) }
            }
        }

        // Many recipe cards expose useful class/id/ARIA names but use a
        // decorative heading, or no heading at all. Treat those containers as
        // candidate regions, still subject to the same noise and line scoring.
        if ingredients.isEmpty {
            for (order, node) in nodes.enumerated() where !node.isExcludedRegion && node.semanticName.contains("ingredient") {
                let lines = ingredientLines(in: [node])
                if !lines.isEmpty {
                    ingredients.append(SectionCandidate(heading: node, kind: .ingredients, lines: lines, score: sectionScore(heading: node, lines: lines, kind: .ingredients), order: order))
                }
            }
        }
        if instructions.isEmpty {
            for (order, node) in nodes.enumerated() where !node.isExcludedRegion && (node.semanticName.contains("instruction") || node.semanticName.contains("direction") || node.semanticName.contains("method") || node.semanticName.contains("step")) {
                let lines = instructionLines(in: [node])
                if !lines.isEmpty {
                    instructions.append(SectionCandidate(heading: node, kind: .instructions, lines: lines, score: sectionScore(heading: node, lines: lines, kind: .instructions), order: order))
                }
            }
        }

        let ingredient = ingredients.max { lhs, rhs in
            pairScore(lhs, with: instructions.first) < pairScore(rhs, with: instructions.first)
        }
        let instruction = instructions.max { lhs, rhs in
            pairScore(lhs, with: ingredient) < pairScore(rhs, with: ingredient)
        }
        guard ingredient != nil || instruction != nil else { return nil }

        var evidence: [String: RecipeFieldEvidence] = [:]
        if let ingredient {
            evidence["ingredients"] = RecipeFieldEvidence(
                source: .semanticHTML,
                locator: "\(ingredient.heading.name) \(ingredient.heading.visibleText)",
                confidence: confidence(for: ingredient.score)
            )
        }
        if let instruction {
            evidence["instructions"] = RecipeFieldEvidence(
                source: .semanticHTML,
                locator: "\(instruction.heading.name) \(instruction.heading.visibleText)",
                confidence: confidence(for: instruction.score)
            )
        }

        return Result(
            name: recipeName(in: document, sourceURL: sourceURL),
            ingredientLines: ingredient?.lines ?? [],
            instructionLines: instruction?.lines ?? [],
            fieldEvidence: evidence
        )
    }

    // MARK: Sections

    private static func sectionKind(for node: HTMLNode) -> SectionKind? {
        guard (1...6).contains(node.name.dropFirst().compactMap(\.wholeNumberValue).first ?? 0) else { return nil }
        let heading = normalized(node.visibleText)
        if ingredientHeadings.contains(heading) { return .ingredients }
        if instructionHeadings.contains(heading) { return .instructions }
        return nil
    }

    /// Sibling traversal keeps a section bounded by the next sibling heading.
    /// The preorder fallback covers cards where the heading and payload are
    /// separated by one wrapper element.
    private static func contentAfter(heading: HTMLNode) -> [HTMLNode] {
        guard let parent = heading.parent else { return [] }
        guard let index = parent.children.firstIndex(where: { $0 === heading }) else { return [] }
        var result: [HTMLNode] = []
        for sibling in parent.children.dropFirst(index + 1) {
            if let level = headingLevel(sibling), level <= (headingLevel(heading) ?? 6) { break }
            result.append(sibling)
        }
        if result.contains(where: { !$0.visibleText.isEmpty }) { return result }

        var foundHeading = false
        var fallback: [HTMLNode] = []
        for node in heading.document?.allElements ?? [] {
            if node === heading { foundHeading = true; continue }
            guard foundHeading else { continue }
            if let level = headingLevel(node), level <= (headingLevel(heading) ?? 6) { break }
            fallback.append(node)
            if fallback.reduce(0, { $0 + $1.visibleText.count }) > 16_000 { break }
        }
        return fallback
    }

    private static func ingredientLines(in nodes: [HTMLNode]) -> [String] {
        let listItems = descendantNodes(in: nodes, named: "li").filter { !$0.isExcludedRegion }
        let rows = descendantNodes(in: nodes, named: "tr").filter { !$0.isExcludedRegion }
        var candidates: [String] = []

        if !listItems.isEmpty {
            candidates += listItems.map { $0.visibleText }
        }
        if !rows.isEmpty {
            candidates += rows.map { row in
                descendantNodes(in: [row], named: "td")
                    .map(\.visibleText)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
        }
        if candidates.isEmpty {
            candidates = leafBlockTexts(in: nodes)
        }
        return unique(candidates.compactMap { ingredientLine($0) })
    }

    private static func instructionLines(in nodes: [HTMLNode]) -> [String] {
        let orderedItems = descendantNodes(in: nodes, named: "ol")
            .flatMap { descendantNodes(in: [$0], named: "li") }
            .filter { !$0.isExcludedRegion }
        var candidates = orderedItems.map { $0.visibleText }

        if candidates.isEmpty {
            candidates = descendantNodes(in: nodes, named: "li")
                .filter { node in
                    node.isExcludedRegion == false && node.semanticName.contains("step")
                }
                .map(\.visibleText)
        }
        if candidates.isEmpty {
            candidates = leafBlockTexts(in: nodes)
        }
        return unique(candidates.compactMap { instructionLine($0) })
    }

    private static func leafBlockTexts(in nodes: [HTMLNode]) -> [String] {
        let blocks = descendantNodes(in: nodes, named: "p")
        if !blocks.isEmpty { return blocks.map(\.visibleText) }

        return nodes.flatMap { node in
            descendantNodes(in: [node], named: "div")
                .filter { div in
                    !div.isExcludedRegion
                        && div.visibleText.count > 1
                        && !div.hasDescendant(named: "p")
                        && !div.hasDescendant(named: "li")
                        && !div.hasDescendant(named: "table")
                        && !div.hasDescendant(named: "div")
                }
                .map(\.visibleText)
        }
    }

    // MARK: Scoring and cleaning

    private static func ingredientLine(_ raw: String) -> String? {
        let line = cleanPayload(raw, removeListMarker: true)
        guard !line.isEmpty, line.count <= 180, !isNoise(line) else { return nil }
        let lower = line.lowercased()
        let hasQuantity = line.range(of: #"(?:\b\d+(?:[.,]\d+)?|[¼½¾⅓⅔⅛⅜⅝⅞])"#, options: .regularExpression) != nil
        let hasUnit = ingredientUnits.contains { lower.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#, options: .regularExpression) != nil }
        let isUnquantified = lower.contains("to taste") || lower.contains("nach geschmack") || lower.contains("as needed") || lower.contains("nach bedarf")
        let wordCount = line.split(whereSeparator: \.isWhitespace).count
        guard hasQuantity || hasUnit || isUnquantified || (wordCount <= 9 && !startsLikeInstruction(lower)) else { return nil }
        return line
    }

    private static func instructionLine(_ raw: String) -> String? {
        let line = cleanPayload(raw, removeListMarker: true)
        guard line.count >= 4, line.count <= 600, !isNoise(line) else { return nil }
        guard !isHeadingPayload(line) else { return nil }
        let lower = line.lowercased()
        guard startsLikeInstruction(lower)
            || line.range(of: #"[.!?]"#, options: .regularExpression) != nil
            || line.split(whereSeparator: \.isWhitespace).count >= 4 else { return nil }
        return line
    }

    private static func startsLikeInstruction(_ lower: String) -> Bool {
        let first = lower.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." }).first.map(String.init) ?? ""
        return imperativeWords.contains(first) || lower.hasPrefix("then ") || lower.hasPrefix("next ") || lower.hasPrefix("dann ") || lower.hasPrefix("anschließend ")
    }

    private static func sectionScore(heading: HTMLNode, lines: [String], kind: SectionKind) -> Double {
        var score = Double(lines.count * 3)
        score += Double(lines.filter { $0.range(of: #"\d|[¼½¾⅓⅔⅛⅜⅝⅞]"#, options: .regularExpression) != nil }.count)
        score += heading.contextScore
        if kind == .instructions { score += Double(lines.filter { startsLikeInstruction($0.lowercased()) }.count) }
        return score
    }

    private static func pairScore(_ lhs: SectionCandidate, with other: SectionCandidate?) -> Double {
        guard let other else { return lhs.score }
        let distance = abs(lhs.order - other.order)
        return lhs.score + other.score + max(0, 10 - Double(distance) / 20)
    }

    private static func confidence(for score: Double) -> Double {
        min(0.99, max(0.5, score / 30))
    }

    private static func cleanPayload(_ raw: String, removeListMarker: Bool) -> String {
        var result = normalized(raw)
        if removeListMarker {
            result = result.replacingOccurrences(of: #"^\s*(?:[-•*]|\d+[.)])\s*"#, with: "", options: .regularExpression)
        }
        return result
    }

    private static func isNoise(_ line: String) -> Bool {
        let lower = line.lowercased()
        return excludedWords.contains { lower.contains($0) }
            || lower.contains("http://") || lower.contains("https://")
            || line.split(whereSeparator: \.isWhitespace).count > 32
    }

    private static func isHeadingPayload(_ line: String) -> Bool {
        let key = normalized(line)
        return ingredientHeadings.contains(key) || instructionHeadings.contains(key)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return seen.insert(key).inserted ? value : nil
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ":："))
            .lowercased()
    }

    private static func recipeName(in document: HTMLDocument, sourceURL: URL?) -> String? {
        if let h1 = document.allElements.first(where: { $0.name == "h1" && !$0.isExcludedRegion }),
           !h1.visibleText.isEmpty, !isHeadingPayload(h1.visibleText) {
            return h1.visibleText
        }
        if let title = document.metaContent(property: "og:title") ?? document.title,
           !title.isEmpty { return title }
        return sourceURL?.host?.replacingOccurrences(of: "www.", with: "").capitalized
    }

    private static func descendantNodes(in nodes: [HTMLNode], named name: String) -> [HTMLNode] {
        nodes.flatMap { node in
            node.allDescendants.filter { $0.name == name }
        }
    }

    private static func headingLevel(_ node: HTMLNode) -> Int? {
        guard node.name.first == "h" else { return nil }
        return Int(node.name.dropFirst())
    }
}

// MARK: - Minimal rendered-HTML tree

private class HTMLNode {
    let name: String
    let attributes: [String: String]
    weak var parent: HTMLNode?
    weak var document: HTMLDocument?
    var children: [HTMLNode] = []
    var ownText = ""

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name.lowercased()
        self.attributes = attributes
    }

    var allDescendants: [HTMLNode] {
        children.flatMap { [$0] + $0.allDescendants }
    }

    var visibleText: String {
        guard !isHidden, !["script", "style", "template", "noscript"].contains(name) else { return "" }
        return (ownText.isEmpty ? children.map(\.visibleText).joined(separator: " ") : ([ownText] + children.map(\.visibleText)).joined(separator: " "))
            .decodingHTMLEntities
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var semanticName: String {
        [attributes["class"], attributes["id"], attributes["aria-label"], attributes["data-testid"]]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
    }

    var isHidden: Bool {
        attributes["aria-hidden"] == "true"
            || attributes["hidden"] != nil
            || (attributes["style"]?.lowercased().contains("display:none") == true)
            || (attributes["style"]?.lowercased().contains("visibility:hidden") == true)
    }

    var isExcludedRegion: Bool {
        let excluded = ["nav", "footer", "aside", "header", "form", "script", "style", "template", "noscript"]
        var current: HTMLNode? = self
        while let node = current {
            if excluded.contains(node.name) { return true }
            let marker = node.semanticName
            if ["nav", "footer", "sidebar", "comment", "advert", "related", "recommend", "social", "share", "cookie", "newsletter"].contains(where: marker.contains) {
                return true
            }
            current = node.parent
        }
        return isHidden
    }

    var contextScore: Double {
        var score = 0.0
        var current: HTMLNode? = self
        while let node = current {
            let marker = node.semanticName
            if marker.contains("recipe") || marker.contains("dish") || marker.contains("cooking") { score += 5 }
            if marker.contains("ingredient") || marker.contains("instruction") || marker.contains("direction") { score += 2 }
            if ["nav", "footer", "aside", "header", "comment", "advert", "related", "recommend", "social", "share", "cookie"].contains(where: marker.contains) { score -= 8 }
            current = node.parent
        }
        return score
    }

    func hasDescendant(named name: String) -> Bool {
        allDescendants.contains { $0.name == name }
    }
}

private final class HTMLDocument: HTMLNode {
    override init(name: String, attributes: [String: String] = [:]) {
        super.init(name: name, attributes: attributes)
    }

    var allElements: [HTMLNode] { allDescendants.filter { !$0.name.isEmpty } }

    var title: String? {
        allElements.first(where: { $0.name == "title" })?.visibleText.nilIfEmpty
    }

    func metaContent(property: String) -> String? {
        allElements.first { node in
            (node.name == "meta" && (node.attributes["property"]?.caseInsensitiveCompare(property) == .orderedSame || node.attributes["name"]?.caseInsensitiveCompare(property) == .orderedSame))
        }?.attributes["content"]?.decodingHTMLEntities.nilIfEmpty
    }
}

private enum HTMLDocumentParser {
    static func parse(_ html: String) -> HTMLDocument {
        let document = HTMLDocument(name: "#document")
        var stack: [HTMLNode] = [document]
        var cursor = html.startIndex

        while cursor < html.endIndex {
            guard let open = html[cursor...].firstIndex(of: "<") else {
                stack.last?.ownText += String(html[cursor...])
                break
            }
            if open > cursor { stack.last?.ownText += String(html[cursor..<open]) }
            guard let close = html[open...].firstIndex(of: ">") else { break }
            let raw = String(html[open...close])
            cursor = html.index(after: close)

            if raw.hasPrefix("<!--") { continue }
            if raw.hasPrefix("</") {
                let closing = raw.dropFirst(2).dropLast().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let index = stack.lastIndex(where: { $0.name == closing }) { stack.removeSubrange(index...) }
                continue
            }
            if raw.hasPrefix("<!") || raw.hasPrefix("<?") { continue }

            let inside = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            let selfClosing = inside.hasSuffix("/")
            let tagText = selfClosing ? String(inside.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : String(inside)
            guard let name = tagText.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first else { continue }
            let node = HTMLNode(name: String(name), attributes: attributes(in: tagText))
            node.parent = stack.last
            node.document = document
            stack.last?.children.append(node)
            let voidTags = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
            if !selfClosing && !voidTags.contains(node.name) { stack.append(node) }
        }

        func assignDocument(_ node: HTMLNode) {
            node.document = document
            for child in node.children { assignDocument(child) }
        }
        assignDocument(document)
        return document
    }

    private static func attributes(in tag: String) -> [String: String] {
        let pattern = #"([:\w-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let range = tag.range(of: tag) else { return [:] }
        let ns = tag as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(range, in: tag)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            for index in 2..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                result[key] = ns.substring(with: match.range(at: index)).decodingHTMLEntities
                break
            }
        }
        return result
    }
}

private extension String {
    var decodingHTMLEntities: String {
        var value = self
        let replacements = [
            "&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'",
            "&apos;": "'", "&lt;": "<", "&gt;": ">", "&frac12;": "½",
            "&frac14;": "¼", "&frac34;": "¾"
        ]
        for (entity, replacement) in replacements { value = value.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-f]+|[0-9]+);", options: .caseInsensitive) else { return value }
        let ns = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length)).reversed()
        for match in matches {
            let token = ns.substring(with: match.range(at: 1))
            let code = token.lowercased().hasPrefix("x") ? Int(token.dropFirst(), radix: 16) : Int(token)
            if let code, let scalar = UnicodeScalar(code) {
                value = (value as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
            }
        }
        return value
    }
}
