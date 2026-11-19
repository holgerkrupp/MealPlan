import Foundation
import SwiftData

/// Searchable dish content detached from SwiftData relationships. Build it on
/// a model actor before ranking so keystrokes never fault ingredients on the
/// UI context.
struct DishSearchSnapshot: Sendable, Identifiable {
    let id: UUID
    let modifiedAt: Date
    let name: String
    let recipeText: String
    let translatedName: String?
    let translatedRecipeText: String?
    let ingredientNames: [String]
    let translatedIngredientNames: [String]
    let tags: [String]
    let mealTypes: [String]
    let season: String?
    let prepTimeMinutes: Int?
    let cookTimeMinutes: Int?
    let isFavorite: Bool
    let rating: Int
    let lastUsedDate: Date?
    let usageCount: Int
    let needsReview: Bool
    let isBlankDraft: Bool

    init(dish: Dish) {
        id = dish.uuid
        modifiedAt = dish.modifiedAt
        name = dish.name
        recipeText = dish.recipeText ?? ""
        translatedName = dish.translatedName
        translatedRecipeText = dish.translatedRecipeText
        let ingredients = dish.sortedIngredients
        ingredientNames = ingredients.compactMap { line in
            let name = (line.ingredient?.name ?? line.rawText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        translatedIngredientNames = ingredients.compactMap { line in
            guard let name = line.translatedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            return name
        }
        tags = dish.tagNames
        mealTypes = dish.mealTypeTags.map(\.rawValue)
        season = dish.season?.rawValue
        prepTimeMinutes = dish.prepTimeMinutes
        cookTimeMinutes = dish.cookTimeMinutes
        isFavorite = dish.isFavorite
        rating = dish.rating
        lastUsedDate = dish.lastUsedDate
        usageCount = dish.usageCount
        needsReview = dish.needsReview
        isBlankDraft = dish.isBlankDraft
    }

    var searchableText: String {
        ([name, recipeText, translatedName ?? "", translatedRecipeText ?? ""]
            + ingredientNames + translatedIngredientNames + tags)
            .joined(separator: " ")
    }
}

struct DishSearchSnapshotRevision: Equatable, Sendable {
    var generation: Int
}

struct DishSearchRequest: Equatable, Sendable {
    var householdID: UUID
    var query: String
    var generation: Int
    var candidateIDs: [UUID]?

    var revision: DishSearchSnapshotRevision {
        DishSearchSnapshotRevision(generation: generation)
    }
}

struct DishSearchProfile: Sendable {
    /// Ingredients that make a recipe unavailable to the current household
    /// member profiles. Soft preferences do not exclude a dish.
    var excludedIngredientTerms: [String]
}

struct DishSearchValueResult: Sendable, Identifiable {
    var id: UUID
    var score: Double
    var reason: String?
}

struct DishSearchResponse: Sendable {
    var results: [DishSearchValueResult]
    var hasExactNameMatch: Bool

    static let empty = DishSearchResponse(results: [], hasExactNameMatch: false)
}

/// Fetches relationship-backed search fields once per household revision and
/// performs ranking using only Sendable values.
@ModelActor
actor DishSearchSnapshotActor {
    private struct CacheEntry {
        var revision: DishSearchSnapshotRevision
        var snapshots: [DishSearchSnapshot]
    }

    private var cache: [UUID: CacheEntry] = [:]

    private func snapshots(
        householdID: UUID,
        revision: DishSearchSnapshotRevision
    ) -> [DishSearchSnapshot]? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache[householdID], cached.revision == revision {
            return cached.snapshots
        }
        guard let dishes = try? modelContext.fetch(FetchDescriptor<Dish>(
            predicate: #Predicate { $0.household?.uuid == householdID },
            sortBy: [SortDescriptor(\Dish.name), SortDescriptor(\Dish.uuid)]
        )) else { return nil }
        var built: [DishSearchSnapshot] = []
        built.reserveCapacity(dishes.count)
        for dish in dishes {
            guard !Task.isCancelled else { return nil }
            built.append(DishSearchSnapshot(dish: dish))
        }
        guard !Task.isCancelled else { return nil }
        cache[householdID] = CacheEntry(revision: revision, snapshots: built)
        return built
    }

    func search(
        householdID: UUID,
        revision: DishSearchSnapshotRevision,
        query: String,
        profile: DishSearchProfile,
        limit: Int = 12
    ) -> DishSearchResponse {
        guard let snapshots = snapshots(householdID: householdID, revision: revision),
              !Task.isCancelled else { return .empty }
        let hardTerms = profile.excludedIngredientTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let allowed = snapshots.filter { snapshot in
            let ingredients = snapshot.ingredientNames.joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return hardTerms.allSatisfy { !ingredients.localizedCaseInsensitiveContains($0) }
        }
        guard !Task.isCancelled else { return .empty }
        let foldedQuery = query.searchFolded
        return DishSearchResponse(
            results: DishSearch.rank(allowed, query: query, limit: limit),
            hasExactNameMatch: !foldedQuery.isEmpty && allowed.contains { $0.name.searchFolded == foldedQuery }
        )
    }

    /// Ranks only the currently loaded page IDs while reading ingredient and
    /// recipe text from the shared household snapshot cache.
    func filterSearch(
        householdID: UUID,
        revision: DishSearchSnapshotRevision,
        query: String,
        candidateIDs: [UUID]? = nil
    ) -> [DishSearchValueResult] {
        guard let snapshots = snapshots(householdID: householdID, revision: revision),
              !Task.isCancelled else { return [] }
        let ids = candidateIDs.map { Set($0) }
        let candidates = snapshots.filter { snapshot in
            guard !snapshot.isBlankDraft else { return false }
            return ids?.contains(snapshot.id) ?? true
        }
        return DishSearch.rankForFilter(candidates, query: query)
    }
}

/// Ranks the dish library for one free-text query, and remembers *why* each
/// dish surfaced. A dish found through its ingredients or tags looks like a
/// non sequitur next to one found by name, so every result carries the reason
/// the row can show.
enum DishSearch {
    struct Result: Identifiable {
        let dish: Dish
        let score: Double
        /// What matched, when it wasn't the dish's name — ready to display.
        let reason: String?

        var id: PersistentIdentifier { dish.persistentModelID }
    }

    /// Sendable counterpart used by asynchronous search tasks.
    typealias ValueResult = DishSearchValueResult

    /// Content matches rank below a name match of the same strength: someone
    /// typing "onion" wants "Onion soup" before every dish containing an onion.
    private static let ingredientWeight = 0.8
    private static let labelWeight = 0.75
    private static let methodScore = 0.6
    /// Below this a match is more noise than help.
    private static let threshold = 0.3

    /// The best matches for `query`, strongest first. An empty query keeps the
    /// order it was given, so the caller decides what an untouched field shows.
    static func rank(_ dishes: [Dish], query: String, limit: Int = 12) -> [Result] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return dishes.prefix(limit).map { Result(dish: $0, score: 0, reason: nil) }
        }
        let snapshots = dishes.map(DishSearchSnapshot.init(dish:))
        let ranked = rank(snapshots, query: query, limit: limit)
        let byID = Dictionary(dishes.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.compactMap { result in
            guard let dish = byID[result.id] else { return nil }
            return Result(dish: dish, score: result.score, reason: result.reason)
        }
    }

    /// Value-only implementation shared by the picker, library, and sidebar.
    static func rank(
        _ dishes: [DishSearchSnapshot],
        query: String,
        limit: Int = 12
    ) -> [ValueResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return dishes.prefix(limit).map { ValueResult(id: $0.id, score: 0, reason: nil) }
        }
        var ranked: [(result: ValueResult, name: String)] = []
        ranked.reserveCapacity(dishes.count)
        for dish in dishes {
            guard !Task.isCancelled else { return [] }
            if let match = result(for: dish, query: query) {
                ranked.append(match)
            }
        }
        ranked.sort { lhs, rhs in
            if lhs.result.score == rhs.result.score {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.result.score > rhs.result.score
        }
        return ranked.prefix(limit).map { $0.result }
    }

    /// The score used by all search surfaces. Results are computed from the
    /// same value snapshots and retain the picker’s explanatory reason.
    static func rankForFilter(
        _ dishes: [DishSearchSnapshot],
        query: String
    ) -> [ValueResult] {
        rank(dishes.filter { !$0.isBlankDraft }, query: query, limit: dishes.count)
    }

    /// A page of globally ranked IDs. The caller fetches only this page of
    /// live SwiftData models, then restores this order after the fetch.
    static func pageIDs(_ ids: [UUID], pageIndex: Int, pageSize: Int) -> [UUID] {
        guard pageIndex >= 0, pageSize > 0 else { return [] }
        let start = pageIndex * pageSize
        guard start < ids.count else { return [] }
        return Array(ids[start..<min(start + pageSize, ids.count)])
    }

    /// True when a dish already carries exactly this name, i.e. there is
    /// nothing new to create.
    static func hasExactMatch(_ dishes: [Dish], name: String) -> Bool {
        let folded = name.searchFolded
        return !folded.isEmpty && dishes.contains { $0.name.searchFolded == folded }
    }

    /// The dish named exactly `name`, if there is one.
    static func exactMatch(_ dishes: [Dish], name: String) -> Dish? {
        let folded = name.searchFolded
        guard !folded.isEmpty else { return nil }
        return dishes.first { $0.name.searchFolded == folded }
    }

    private static func result(for dish: DishSearchSnapshot, query: String) -> (result: ValueResult, name: String)? {
        var best = max(
            dish.name.fuzzyScore(query: query),
            dish.translatedName?.fuzzyScore(query: query) ?? 0
        )
        var reason: String?

        for name in dish.ingredientNames + dish.translatedIngredientNames {
            let score = name.fuzzyScore(query: query) * ingredientWeight
            if score > best {
                best = score
                reason = String(localized: "Contains \(name)")
            }
        }

        for label in dish.tags {
            let score = label.fuzzyScore(query: query) * labelWeight
            if score > best {
                best = score
                reason = label
            }
        }

        // The method is long enough that fuzzy matching it would pull in half
        // the library, so it only counts on the words as typed.
        if best < methodScore, (!dish.recipeText.isEmpty || !(dish.translatedRecipeText ?? "").isEmpty) {
            let folded = ([dish.recipeText, dish.translatedRecipeText ?? ""].joined(separator: " ")).searchFolded
            let words = query.searchWords
            if !words.isEmpty, words.allSatisfy(folded.contains) {
                best = methodScore
                reason = String(localized: "Mentioned in the recipe")
            }
        }

        guard best >= threshold else { return nil }
        return (ValueResult(id: dish.id, score: best, reason: reason), dish.name)
    }
}
