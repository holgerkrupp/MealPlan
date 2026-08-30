import Foundation

/// Free-form dish labels ("vegan", "pork", "quick") and the rules that keep a
/// household's vocabulary from fragmenting.
///
/// Tags are stored on the dish as the words the cook actually typed, not as
/// identifiers: there is no separate tag record to sync, rename or garbage
/// collect, and the vocabulary is simply whatever the household's dishes use.
/// Everything that compares two tags does so through `normalize`, so "Vegan",
/// "vegan " and "VEGAN" are one tag that keeps its first spelling.
enum DishTag {

    /// Longest tag we keep. Long enough for "Short prepwork", short enough
    /// that a pasted paragraph can't become a tag.
    static let maxLength = 40

    /// The display form: trimmed, whitespace collapsed, leading "#" dropped,
    /// clipped to `maxLength`. Empty when there is nothing left worth keeping.
    static func clean(_ raw: String) -> String {
        var value = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        while value.hasPrefix("#") { value.removeFirst() }
        value = value.trimmingCharacters(in: .whitespaces)
        guard value.count > 1 else { return "" }
        return String(value.prefix(maxLength))
    }

    /// The comparison form. Two tags are the same tag when these match.
    static func normalize(_ raw: String) -> String {
        clean(raw)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    static func areSame(_ lhs: String, _ rhs: String) -> Bool {
        let normalized = normalize(lhs)
        return !normalized.isEmpty && normalized == normalize(rhs)
    }

    static func contains(_ tags: [String], _ tag: String) -> Bool {
        let needle = normalize(tag)
        return !needle.isEmpty && tags.contains { normalize($0) == needle }
    }

    /// Cleans, de-duplicates and sorts a list of tags. The first spelling of a
    /// tag wins, so appending "VEGAN" to a list that already says "Vegan"
    /// changes nothing.
    static func merge(_ existing: [String], adding additions: [String] = []) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for candidate in existing + additions {
            let display = clean(candidate)
            let key = normalize(display)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(display)
        }
        return sorted(result)
    }

    static func removing(_ tag: String, from tags: [String]) -> [String] {
        let key = normalize(tag)
        return tags.filter { normalize($0) != key }
    }

    static func sorted(_ tags: [String]) -> [String] {
        tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Vocabulary

    /// Every tag in use across a set of dishes with the number of dishes
    /// carrying it, most-used first and ties broken alphabetically. Where the
    /// same tag has been typed with different capitalisation, the spelling
    /// used by the most dishes wins so the vocabulary reads consistently.
    @MainActor
    static func usage(from dishes: [Dish]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        var spellings: [String: [String: Int]] = [:]
        for dish in dishes {
            var counted: Set<String> = []
            for raw in dish.tagNames {
                let display = clean(raw)
                let key = normalize(display)
                guard !key.isEmpty, counted.insert(key).inserted else { continue }
                counts[key, default: 0] += 1
                spellings[key, default: [:]][display, default: 0] += 1
            }
        }
        return counts
            .compactMap { key, count in
                preferredSpelling(spellings[key] ?? [:]).map { (tag: $0, count: count) }
            }
            .sorted { lhs, rhs in
                lhs.count != rhs.count
                    ? lhs.count > rhs.count
                    : lhs.tag.localizedCaseInsensitiveCompare(rhs.tag) == .orderedAscending
            }
    }

    /// Every tag in use across a set of dishes, alphabetically.
    @MainActor
    static func vocabulary(from dishes: [Dish]) -> [String] {
        sorted(usage(from: dishes).map(\.tag))
    }

    /// The tags worth putting in front of the cook: the ones most of their
    /// dishes actually carry.
    @MainActor
    static func mostUsed(from dishes: [Dish], limit: Int = 12) -> [String] {
        usage(from: dishes).prefix(limit).map(\.tag)
    }

    /// The spelling most dishes use; ties go to the alphabetically first so
    /// every device derives the same vocabulary from the same dishes.
    private static func preferredSpelling(_ counts: [String: Int]) -> String? {
        counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }?.key
    }

    /// The vocabulary entry a tag resolves to, so a suggested "Pork" reuses
    /// the household's existing "pork" rather than adding a near-twin.
    static func canonical(_ tag: String, in vocabulary: [String]) -> String {
        let key = normalize(tag)
        return vocabulary.first { normalize($0) == key } ?? clean(tag)
    }

    // MARK: - Autocomplete

    /// Vocabulary entries offered while typing `query`, best match first:
    /// prefix matches before substring ones, already-applied tags omitted.
    /// An empty query offers the whole remaining vocabulary.
    static func completions(
        for query: String,
        in vocabulary: [String],
        excluding applied: [String] = [],
        limit: Int = 8
    ) -> [String] {
        let appliedKeys = Set(applied.map(normalize))
        let candidates = vocabulary.filter { !appliedKeys.contains(normalize($0)) }
        let needle = normalize(query)
        guard !needle.isEmpty else { return Array(candidates.prefix(limit)) }

        let prefixed = candidates.filter { normalize($0).hasPrefix(needle) }
        let contained = candidates.filter {
            let key = normalize($0)
            return !key.hasPrefix(needle) && key.contains(needle)
        }
        return Array((prefixed + contained).prefix(limit))
    }

    /// True when what the user typed is not a tag yet, i.e. committing it
    /// creates one.
    static func isNew(_ query: String, in vocabulary: [String]) -> Bool {
        let key = normalize(query)
        return !key.isEmpty && !vocabulary.contains { normalize($0) == key }
    }
}
