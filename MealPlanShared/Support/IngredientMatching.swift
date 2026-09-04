import Foundation

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

    /// The catalogue entry that means the same as `name`. An exact match on the
    /// normalized name wins; only then is a near one considered.
    static func match(_ name: String, in ingredients: [Ingredient]) -> Ingredient? {
        let normalized = Ingredient.normalize(name)
        guard !normalized.isEmpty else { return nil }
        if let exact = ingredients.first(where: { $0.normalizedName == normalized }) {
            return exact
        }
        let wanted = key(for: name)
        return ingredients.first { keysMatch(key(for: $0.name), wanted) }
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
    private static func isInflection(of base: String, _ candidate: String) -> Bool {
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
