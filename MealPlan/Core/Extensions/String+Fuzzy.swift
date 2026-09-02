import Foundation

extension String {
    /// Lowercased, diacritic-insensitive form for search matching.
    var searchFolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The folded string split into words, for matching a query against a name
    /// or an ingredient line one word at a time.
    var searchWords: [String] {
        searchFolded
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// A light fuzzy score against `query` in the range 0...1. Returns 0 when
    /// nothing in the string resembles the query. Literal matches rank highest,
    /// then words matched in any order, then near-misses a letter or two off,
    /// so "lasgane" and "onion red" both still find "Red onion lasagne". Good
    /// enough for ranking a dish library as the user types.
    func fuzzyScore(query: String) -> Double {
        let haystack = searchFolded
        let needle = query.searchFolded
        guard !needle.isEmpty else { return 1 }
        guard !haystack.isEmpty else { return 0 }

        if haystack == needle { return 1 }
        if haystack.hasPrefix(needle) { return 0.95 }
        if haystack.contains(needle) { return 0.85 }

        // Every word the user typed has to land somewhere, in any order; one
        // word with no home at all rules the string out.
        var wordScore = 0.0
        let words = haystack.searchWords
        let queryWords = needle.searchWords
        if !words.isEmpty, !queryWords.isEmpty {
            var total = 0.0
            for queryWord in queryWords {
                let best = words.map { Self.tokenScore(needle: queryWord, word: $0) }.max() ?? 0
                if best == 0 {
                    total = 0
                    break
                }
                total += best
            }
            // Kept under the substring tiers above so literal hits still win.
            wordScore = min(0.84, total / Double(queryWords.count) * 0.84)
        }

        // Falling back to the whole string catches initials typed across word
        // boundaries, e.g. "spagbol" for "Spaghetti Bolognese".
        return max(wordScore, Self.subsequenceScore(needle: needle, haystack: haystack))
    }

    /// How well one folded query word matches one folded word of the text.
    private static func tokenScore(needle: String, word: String) -> Double {
        if word == needle { return 1 }
        if word.hasPrefix(needle) { return 0.9 }
        if word.contains(needle) { return 0.8 }

        // Typo tolerance: one edit for a word long enough that a single slip is
        // more likely than a coincidence, two once it is longer still.
        let tolerance = needle.count >= 8 ? 2 : (needle.count >= 4 ? 1 : 0)
        if tolerance > 0 {
            // Measured against the head of the word as well as the whole of
            // it, so a word still being typed — and mistyped — counts too:
            // "lasgan" is one swap away from the front of "lasagne".
            let heads = Set([needle.count, needle.count + tolerance, word.count]
                .map { Swift.min($0, word.count) })
            let needleCharacters = Array(needle)
            let distance = heads
                .map { editDistance(needleCharacters, Array(word.prefix($0)), limit: tolerance) }
                .min() ?? tolerance + 1
            if distance <= tolerance {
                return 0.78 - 0.06 * Double(distance - 1)
            }
        }

        return Swift.min(0.6, subsequenceScore(needle: needle, haystack: word))
    }

    /// Scores `needle` as a subsequence of `haystack`, with a bonus for letters
    /// that land consecutively. 0 when the letters don't appear in order.
    private static func subsequenceScore(needle: String, haystack: String) -> Double {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }

        var hIndex = haystack.startIndex
        var matched = 0
        var streak = 0
        var bonus = 0.0
        for ch in needle {
            var found = false
            while hIndex < haystack.endIndex {
                let current = haystack[hIndex]
                hIndex = haystack.index(after: hIndex)
                if current == ch {
                    matched += 1
                    streak += 1
                    bonus += Double(streak) * 0.5
                    found = true
                    break
                } else {
                    streak = 0
                }
            }
            if !found { return 0 }
        }
        guard matched == needle.count else { return 0 }
        let coverage = Double(matched) / Double(haystack.count)
        return Swift.min(0.8, 0.3 + coverage * 0.3 + bonus / Double(Swift.max(needle.count, 1)) * 0.1)
    }

    /// Optimal string alignment distance — Levenshtein plus swapped neighbours,
    /// which is what most typos are — giving up as soon as it passes `limit`.
    private static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var beforePrevious = [Int]()
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            var rowBest = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = Swift.min(value, beforePrevious[j - 2] + 1)
                }
                current[j] = value
                rowBest = Swift.min(rowBest, value)
            }
            if rowBest > limit { return limit + 1 }
            beforePrevious = previous
            previous = current
        }
        return previous[b.count]
    }
}
