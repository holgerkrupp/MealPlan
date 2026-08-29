import Foundation

extension String {
    /// Lowercased, diacritic-insensitive form for search matching.
    var searchFolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A light fuzzy score against `query` in the range 0...1. Returns 0 when
    /// the query's characters don't appear in order. Good enough for ranking
    /// a dish library as the user types.
    func fuzzyScore(query: String) -> Double {
        let haystack = searchFolded
        let needle = query.searchFolded
        guard !needle.isEmpty else { return 1 }
        guard !haystack.isEmpty else { return 0 }

        if haystack == needle { return 1 }
        if haystack.hasPrefix(needle) { return 0.95 }
        if haystack.contains(needle) { return 0.85 }

        // Subsequence match with a bonus for consecutive hits.
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
        return min(0.8, 0.3 + coverage * 0.3 + bonus / Double(max(needle.count, 1)) * 0.1)
    }
}
