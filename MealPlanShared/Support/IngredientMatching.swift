import Foundation

/// Why an ingredient was considered a candidate.
enum IngredientMatchReason: String, CaseIterable, Codable, Sendable {
    case exactName
    case exactAlias
    case normalizedKey
    case inflection
    case spellingDistance
    case tokenOverlap
    case candidateCollision
}

/// How much trust an automatic caller can put in a candidate.
enum IngredientMatchClass: String, CaseIterable, Codable, Sendable {
    case certain
    case highConfidence
    case needsConfirmation
    case noMatch

    var isSafeForSilentReuse: Bool {
        switch self {
        case .certain, .highConfidence: true
        case .needsConfirmation, .noMatch: false
        }
    }
}

/// The explainable result of matching one recipe spelling against a catalogue.
///
/// A result can carry several `candidates` when the catalogue is ambiguous.
/// In that case `candidate` is deliberately `nil`: callers must not silently
/// choose one merely because it happened to be first in a SwiftData fetch.
struct IngredientMatchResult {
    let query: String
    let candidate: Ingredient?
    let candidates: [Ingredient]
    let confidence: Double
    let matchClass: IngredientMatchClass
    let reasons: [IngredientMatchReason]

    var isSafeForSilentReuse: Bool {
        candidate != nil && matchClass.isSafeForSilentReuse
    }

    /// A descriptive alias for clients that use the policy wording.
    var isSafeForAutomaticReuse: Bool { isSafeForSilentReuse }

    var isAmbiguous: Bool { reasons.contains(.candidateCollision) }
}

/// An indexed ingredient catalogue. Build it once for a bulk import or list
/// rebuild so each lookup only examines keys whose lengths could match.
struct IngredientMatcher {
    private struct Term {
        let ingredient: Ingredient
        let normalizedName: String
        let key: String
        let isCanonical: Bool
        let aliasSource: IngredientAliasSource?
    }

    private struct ScoredCandidate {
        let ingredient: Ingredient
        let rank: Int
        let confidence: Double
        let matchClass: IngredientMatchClass
        let reasons: [IngredientMatchReason]
    }

    private var termsByLength: [Int: [Term]] = [:]
    private var termsByNormalizedName: [String: [Term]] = [:]

    init(ingredients: [Ingredient] = []) {
        for ingredient in ingredients { add(ingredient) }
    }

    mutating func add(_ ingredient: Ingredient) {
        add(Term(
            ingredient: ingredient,
            normalizedName: ingredient.normalizedName,
            key: IngredientMatching.key(for: ingredient.name),
            isCanonical: true,
            aliasSource: nil
        ))
        for alias in ingredient.aliases ?? [] where !alias.normalizedName.isEmpty {
            add(Term(
                ingredient: ingredient,
                normalizedName: alias.normalizedName,
                key: IngredientMatching.key(for: alias.name),
                isCanonical: false,
                aliasSource: alias.source
            ))
        }
    }

    func result(for name: String) -> IngredientMatchResult {
        let normalized = Ingredient.normalize(name)
        guard !normalized.isEmpty else {
            return IngredientMatchResult(
                query: name, candidate: nil, candidates: [], confidence: 0,
                matchClass: .noMatch, reasons: []
            )
        }

        let exactTerms = (termsByNormalizedName[normalized] ?? [])
            .filter { !$0.ingredient.rejectsMatch(for: name) }
        let exactIngredients = distinctIngredients(exactTerms)
        if !exactIngredients.isEmpty {
            let canonical = exactTerms.filter(\.isCanonical)
            let reason: IngredientMatchReason = canonical.isEmpty ? .exactAlias : .exactName
            let allConfirmed = exactTerms
                .filter { !$0.isCanonical }
                .allSatisfy { $0.aliasSource == .userConfirmed }

            if exactIngredients.count == 1 {
                let exactClass: IngredientMatchClass
                let confidence: Double
                if reason == .exactName || allConfirmed {
                    exactClass = .certain
                    confidence = 1
                } else {
                    // Imported/automatic aliases are useful evidence, but a
                    // person has not explicitly confirmed them yet.
                    exactClass = .needsConfirmation
                    confidence = 0.92
                }
                return IngredientMatchResult(
                    query: name,
                    candidate: exactIngredients[0],
                    candidates: exactIngredients,
                    confidence: confidence,
                    matchClass: exactClass,
                    reasons: [reason]
                )
            }

            return collisionResult(
                query: name,
                candidates: exactIngredients,
                confidence: 1,
                reasons: [reason, .candidateCollision]
            )
        }

        let wanted = IngredientMatching.key(for: name)
        let plausibleTerms = (max(0, wanted.count - 2)...(wanted.count + 2))
            .flatMap { termsByLength[$0] ?? [] }
            .filter { !$0.ingredient.rejectsMatch(for: name) }
        var bestByIngredient: [ObjectIdentifier: ScoredCandidate] = [:]

        for term in plausibleTerms {
            guard IngredientMatching.keysMatch(term.key, wanted) else { continue }
            let scored = score(term: term, query: name, wantedKey: wanted)
            let id = ObjectIdentifier(term.ingredient)
            if let previous = bestByIngredient[id], previous.rank <= scored.rank {
                continue
            }
            bestByIngredient[id] = scored
        }

        let best = bestByIngredient.values.sorted { $0.rank < $1.rank }
        guard let first = best.first else {
            return IngredientMatchResult(
                query: name, candidate: nil, candidates: [], confidence: 0,
                matchClass: .noMatch, reasons: []
            )
        }
        let tied = best.filter { $0.rank == first.rank }
        if tied.count > 1 {
            return collisionResult(
                query: name,
                candidates: tied.map(\.ingredient),
                confidence: first.confidence,
                reasons: first.reasons + [.candidateCollision]
            )
        }

        return IngredientMatchResult(
            query: name,
            candidate: first.ingredient,
            candidates: [first.ingredient],
            confidence: first.confidence,
            matchClass: first.matchClass,
            reasons: first.reasons
        )
    }

    func match(_ name: String) -> Ingredient? {
        let result = result(for: name)
        return result.isSafeForSilentReuse ? result.candidate : nil
    }

    private mutating func add(_ term: Term) {
        guard !term.normalizedName.isEmpty, !term.key.isEmpty else { return }
        termsByLength[term.key.count, default: []].append(term)
        termsByNormalizedName[term.normalizedName, default: []].append(term)
    }

    private func score(term: Term, query: String, wantedKey: String) -> ScoredCandidate {
        if term.key == wantedKey {
            let queryTokens = IngredientMatching.tokens(for: query)
            let candidateTokens = IngredientMatching.tokens(for: term.isCanonical ? term.ingredient.name : term.normalizedName)
            let reordered = queryTokens != candidateTokens
                && Set(queryTokens) == Set(candidateTokens)
            if reordered {
                return ScoredCandidate(
                    ingredient: term.ingredient,
                    rank: 3,
                    confidence: 0.76,
                    matchClass: .needsConfirmation,
                    reasons: [.normalizedKey, .tokenOverlap]
                )
            }
            return ScoredCandidate(
                ingredient: term.ingredient,
                rank: 1,
                confidence: 0.91,
                matchClass: .highConfidence,
                reasons: [.normalizedKey]
            )
        }

        if IngredientMatching.isInflection(of: wantedKey, term.key)
            || IngredientMatching.isInflection(of: term.key, wantedKey) {
            return ScoredCandidate(
                ingredient: term.ingredient,
                rank: 2,
                confidence: 0.88,
                matchClass: .highConfidence,
                reasons: [.inflection]
            )
        }

        return ScoredCandidate(
            ingredient: term.ingredient,
            rank: 4,
            confidence: 0.62,
            matchClass: .needsConfirmation,
            reasons: [.spellingDistance]
        )
    }

    private func distinctIngredients(_ terms: [Term]) -> [Ingredient] {
        var result: [Ingredient] = []
        var seen: Set<ObjectIdentifier> = []
        for term in terms {
            let id = ObjectIdentifier(term.ingredient)
            if seen.insert(id).inserted { result.append(term.ingredient) }
        }
        return result
    }

    private func collisionResult(
        query: String,
        candidates: [Ingredient],
        confidence: Double,
        reasons: [IngredientMatchReason]
    ) -> IngredientMatchResult {
        IngredientMatchResult(
            query: query,
            candidate: nil,
            candidates: candidates,
            confidence: confidence,
            matchClass: .needsConfirmation,
            reasons: reasons
        )
    }
}

/// Deciding when two ingredient names mean the same thing to buy.
///
/// Recipes arrive from everywhere — typed by hand, scanned, imported from a
/// blog — so one ingredient turns up as "Joghurt", "Jogurt", "Salz*" and
/// "Salz (nach Geschmack)". Matching only on `Ingredient.normalizedName`
/// leaves the shopping list with a row for each of them, which is the one
/// thing a shopping list must not do.
///
/// Two names match when their *keys* are equal or near enough. A key is the
/// normalized name with footnote markers, brackets and filler words taken out
/// and the remaining words sorted, so punctuation and word order stop
/// mattering. "Near enough" is a German plural ending, or a typo or two in a
/// name long enough that a slip is likelier than a coincidence — short names
/// are compared strictly, because "Salz" and "Malz" are one letter apart and
/// are not the same shopping trip.
enum IngredientMatching {

    /// Words that say nothing about what to buy, so two names that differ only
    /// in these are the same thing.
    private static let filler: Set<String> = [
        "ca", "etwa", "etwas", "evtl", "eventuell", "ggf", "optional",
        "nach", "geschmack", "belieben", "bedarf", "wunsch",
        "und", "oder", "sowie", "bzw", "bio", "je", "pro",
    ]

    /// Separators that join two things into one line: "Salz und Pfeffer".
    private static let compoundSeparators = [" und ", " sowie ", " & ", " + ", "&", "+"]

    // MARK: - Keys

    /// The form two spellings of the same ingredient have in common.
    static func key(for name: String) -> String {
        let stripped = removingBracketed(Ingredient.normalize(name))
        let words = stripped
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !filler.contains($0) && !$0.allSatisfy(\.isNumber) }
        // A name that is nothing but filler and punctuation keeps its plain
        // normalized form, so unrelated leftovers don't all collapse together.
        guard !words.isEmpty else { return Ingredient.normalize(name) }
        return words.sorted().joined(separator: " ")
    }

    /// Whether two names mean the same ingredient.
    static func isSame(_ a: String, _ b: String) -> Bool {
        keysMatch(key(for: a), key(for: b))
    }

    /// Whether two keys — from `key(for:)` — mean the same ingredient.
    static func keysMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return a == b }
        if a == b { return true }
        if isInflection(of: a, b) || isInflection(of: b, a) { return true }
        let tolerance = editTolerance(for: min(a.count, b.count))
        guard tolerance > 0 else { return false }
        return editDistance(Array(a), Array(b), limit: tolerance) <= tolerance
    }

    /// The catalogue entry that means the same as `name`. Exact canonical
    /// names and confirmed aliases are safe. Fuzzy and reordered candidates
    /// are returned by `matchResult` for user-facing suggestions, but are not
    /// silently reused by this compatibility helper.
    static func match(_ name: String, in ingredients: [Ingredient]) -> Ingredient? {
        IngredientMatcher(ingredients: ingredients).match(name)
    }

    /// Explain every candidate decision without coupling matching to SwiftUI
    /// or a model context. For repeated lookups, keep an `IngredientMatcher`.
    static func matchResult(for name: String, in ingredients: [Ingredient]) -> IngredientMatchResult {
        IngredientMatcher(ingredients: ingredients).result(for: name)
    }

    /// Short form for callers that prefer the noun used by the API goal.
    static func result(for name: String, in ingredients: [Ingredient]) -> IngredientMatchResult {
        matchResult(for: name, in: ingredients)
    }

    // MARK: - Compounds

    /// Split a name that lists two things — "Salz und Pfeffer" — into them.
    /// Anything else comes back as a single element.
    ///
    /// Deliberately timid: only two or three parts, each one or two words and
    /// free of digits, so "Öl und Essig Dressing" or "2 Dosen Tomaten und
    /// Bohnen" are left alone rather than torn in half.
    static func components(of name: String) -> [String] {
        let marker = "\u{1}"
        var text = name
        for separator in compoundSeparators {
            text = text.replacingOccurrences(of: separator, with: marker, options: [.caseInsensitive])
        }
        let parts = text
            .split(separator: Character(marker))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard (2...3).contains(parts.count) else { return [name] }
        for part in parts {
            let words = part.split(whereSeparator: \.isWhitespace)
            guard (1...2).contains(words.count),
                  part.count >= 2,
                  !part.contains(where: \.isNumber)
            else { return [name] }
        }
        return parts
    }

    // MARK: - Naming the merged line

    /// Which of two spellings of one ingredient to show: the one carrying the
    /// least noise — "Salz" over "Salz*" — and the shorter when that ties.
    static func preferredName(_ a: String, _ b: String) -> String {
        let (noiseA, noiseB) = (noise(in: a), noise(in: b))
        if noiseA != noiseB { return noiseA < noiseB ? a : b }
        if a.count != b.count { return a.count < b.count ? a : b }
        return a
    }

    // MARK: - Details

    private static func noise(in name: String) -> Int {
        name.filter { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }.count
    }

    fileprivate static func tokens(for name: String) -> [String] {
        let stripped = removingBracketed(Ingredient.normalize(name))
        return stripped
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !filler.contains($0) && !$0.allSatisfy(\.isNumber) }
    }

    /// Drop "(nach Geschmack)" and the like, brackets and all.
    private static func removingBracketed(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            switch character {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth = max(0, depth - 1)
            default: if depth == 0 { result.append(character) }
            }
        }
        return result
    }

    /// "Zwiebel" / "Zwiebeln", "egg" / "eggs" — one is the other plus a plural
    /// or inflection ending.
    fileprivate static func isInflection(of base: String, _ candidate: String) -> Bool {
        guard base.count >= 3, candidate.count > base.count, candidate.hasPrefix(base) else {
            return false
        }
        return ["n", "en", "e", "er", "es", "s"].contains(String(candidate.dropFirst(base.count)))
    }

    /// How many typos to forgive in a name of this length. Nothing at all in a
    /// short one: the shorter the name, the likelier a single letter is the
    /// difference between two real ingredients.
    private static func editTolerance(for length: Int) -> Int {
        switch length {
        case ..<5: 0
        case ..<9: 1
        default: 2
        }
    }

    /// Levenshtein distance, giving up as soon as it passes `limit`.
    private static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowBest = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowBest = min(rowBest, current[j])
            }
            if rowBest > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
