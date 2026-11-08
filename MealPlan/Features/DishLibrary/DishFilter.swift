import Foundation

/// How the dish library is sorted and filtered. Kept as plain value state on
/// `AppState` so the choice survives navigation, and `Codable` so a filter can
/// be kept as a saved search (`DishFilterPreset`).
struct DishFilter: Equatable, Codable {
    enum Sort: String, CaseIterable, Identifiable, Codable {
        case alphabetical
        case recentlyAdded
        case mostCooked
        case leastRecentlyCooked
        case neverCooked
        case shortestTotalTime
        case longestTotalTime
        case shortestPrepTime
        case longestPrepTime
        case shortestCookTime
        case longestCookTime
        case fewestServings
        case mostServings

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .alphabetical: String(localized: "A–Z")
            case .recentlyAdded: String(localized: "Recently added")
            case .mostCooked: String(localized: "Cooked most often")
            case .leastRecentlyCooked: String(localized: "Not cooked in a while")
            case .neverCooked: String(localized: "Never cooked")
            case .shortestTotalTime: String(localized: "Total time, shortest first")
            case .longestTotalTime: String(localized: "Total time, longest first")
            case .shortestPrepTime: String(localized: "Prep time, shortest first")
            case .longestPrepTime: String(localized: "Prep time, longest first")
            case .shortestCookTime: String(localized: "Cook time, shortest first")
            case .longestCookTime: String(localized: "Cook time, longest first")
            case .fewestServings: String(localized: "Servings, fewest first")
            case .mostServings: String(localized: "Servings, most first")
            }
        }

        /// The sorts that order by a recipe's own numbers rather than by its
        /// name or cooking history. Menus list them in a group of their own.
        var isRecipeMetric: Bool {
            switch self {
            case .alphabetical, .recentlyAdded, .mostCooked, .leastRecentlyCooked, .neverCooked:
                false
            default:
                true
            }
        }

        /// Whether the store can deliver this order page by page. Total time
        /// is computed (prep + cook), and SQLite puts missing prep/cook times
        /// first, so those orders are only right when the whole library is
        /// sorted in memory.
        var isStoreOrderable: Bool {
            switch self {
            case .alphabetical, .recentlyAdded, .mostCooked, .leastRecentlyCooked, .neverCooked,
                 .fewestServings, .mostServings:
                true
            default:
                false
            }
        }
    }

    var sort: Sort = .alphabetical
    var searchText: String = ""
    var mealType: MealTypeTag?
    var season: Season?
    /// Only dishes whose total time is at or below this many minutes.
    var maxMinutes: Int?
    /// Only dishes not cooked within this many days (or never).
    var notCookedWithinDays: Int?
    var favoritesOnly = false
    var minimumRating: Int?
    /// Free-form tags a dish must carry — all of them, so stacking "vegan"
    /// and "short prepwork" narrows rather than widens.
    var tags: Set<String> = []
    /// Only dishes in this collection (`Dish.collectionNames`).
    var collection: String?

    init(sort: Sort = .alphabetical) {
        self.sort = sort
    }

    var isActive: Bool {
        mealType != nil || season != nil
            || maxMinutes != nil || notCookedWithinDays != nil
            || favoritesOnly || minimumRating != nil
            || !tags.isEmpty || collection != nil
    }

    func isSelected(tag: String) -> Bool {
        tags.contains { DishTag.areSame($0, tag) }
    }

    mutating func toggle(tag: String) {
        if let existing = tags.first(where: { DishTag.areSame($0, tag) }) {
            tags.remove(existing)
        } else {
            tags.insert(DishTag.clean(tag))
        }
    }

    func isSelected(collection name: String) -> Bool {
        collection.map { DishTag.areSame($0, name) } ?? false
    }

    // MARK: - Codable

    // Saved searches outlive app versions, so decoding is lenient: a missing
    // field keeps its default, and an unknown sort, meal type or season is
    // dropped rather than making the whole saved search unreadable.
    private enum CodingKeys: String, CodingKey {
        case sort, searchText, mealType, season, maxMinutes, notCookedWithinDays
        case favoritesOnly, minimumRating, tags, collection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSort = try? container.decodeIfPresent(String.self, forKey: .sort)
        sort = rawSort.flatMap { Sort(rawValue: $0) } ?? .alphabetical
        searchText = (try? container.decodeIfPresent(String.self, forKey: .searchText)) ?? ""
        let rawMealType = try? container.decodeIfPresent(String.self, forKey: .mealType)
        mealType = rawMealType.flatMap { MealTypeTag(rawValue: $0) }
        let rawSeason = try? container.decodeIfPresent(String.self, forKey: .season)
        season = rawSeason.flatMap { Season(rawValue: $0) }
        maxMinutes = (try? container.decodeIfPresent(Int.self, forKey: .maxMinutes)) ?? nil
        notCookedWithinDays = (try? container.decodeIfPresent(Int.self, forKey: .notCookedWithinDays)) ?? nil
        favoritesOnly = (try? container.decodeIfPresent(Bool.self, forKey: .favoritesOnly)) ?? false
        minimumRating = (try? container.decodeIfPresent(Int.self, forKey: .minimumRating)) ?? nil
        tags = Set((try? container.decodeIfPresent([String].self, forKey: .tags)) ?? [])
        collection = (try? container.decodeIfPresent(String.self, forKey: .collection)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sort.rawValue, forKey: .sort)
        try container.encode(searchText, forKey: .searchText)
        try container.encodeIfPresent(mealType?.rawValue, forKey: .mealType)
        try container.encodeIfPresent(season?.rawValue, forKey: .season)
        try container.encodeIfPresent(maxMinutes, forKey: .maxMinutes)
        try container.encodeIfPresent(notCookedWithinDays, forKey: .notCookedWithinDays)
        try container.encode(favoritesOnly, forKey: .favoritesOnly)
        try container.encodeIfPresent(minimumRating, forKey: .minimumRating)
        try container.encode(DishTag.sorted(Array(tags)), forKey: .tags)
        try container.encodeIfPresent(collection, forKey: .collection)
    }

    // MARK: - Applying

    /// Apply the non-sort filters and search ranking to a fetched list.
    func apply(
        to dishes: [Dish],
        now: Date = .now,
        sourceIsAlphabeticallySorted: Bool = false
    ) -> [Dish] {
        var result = dishes.filter { dish in
            // A dish the editor has open but nobody has typed into yet is not
            // part of the library: on a Mac or iPad that editor is a window of
            // its own, and the empty draft behind it would otherwise sit in
            // the grid as an untitled card while it is being written.
            if dish.isBlankDraft { return false }
            if let mealType, !dish.mealTypeTags.contains(mealType) { return false }
            if let season, dish.season != season { return false }
            if let maxMinutes {
                guard let total = dish.totalTimeMinutes, total <= maxMinutes else { return false }
            }
            if let notCookedWithinDays {
                if let days = dish.daysSinceLastCooked(reference: now), days < notCookedWithinDays {
                    return false
                }
            }
            if favoritesOnly, !dish.isFavorite { return false }
            if let minimumRating, dish.rating < minimumRating { return false }
            if !tags.isEmpty {
                let dishTags = Set(dish.tagNames.map(DishTag.normalize))
                guard tags.allSatisfy({ dishTags.contains(DishTag.normalize($0)) }) else { return false }
            }
            if let collection, !dish.isInCollection(collection) { return false }
            return true
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let words = query.searchFolded.split(whereSeparator: \.isWhitespace).map(String.init)
            result = result
                .map { dish in
                    let nameScore = dish.name.fuzzyScore(query: query)
                    let content = dish.searchableText.searchFolded
                    let deepMatch = words.allSatisfy(content.contains) ? 0.70 : 0
                    return (dish: dish, score: max(nameScore, deepMatch))
                }
                .filter { $0.score > 0 }
                .sorted { $0.score > $1.score }
                .map(\.dish)
        } else {
            // Both library queries already fetch by name. Filtering preserves
            // that order, so sorting thousands of imported recipes again on
            // every tab presentation only burns main-thread time.
            if sort == .alphabetical, sourceIsAlphabeticallySorted {
                return result
            }
            result = sortDishes(result, now: now)
        }
        return result
    }

    private func sortDishes(_ dishes: [Dish], now: Date) -> [Dish] {
        let byName: (Dish, Dish) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        /// Orders by a number, either way round. Dishes without the number go
        /// last in both directions, and ties fall back to the name so the
        /// order doesn't shuffle between redraws.
        func by(_ value: (Dish) -> Int?, ascending: Bool) -> [Dish] {
            dishes.sorted { lhs, rhs in
                switch (value(lhs), value(rhs)) {
                case let (l?, r?) where l != r: ascending ? l < r : l > r
                case (_?, nil): true
                case (nil, _?): false
                default: byName(lhs, rhs)
                }
            }
        }

        switch sort {
        case .alphabetical:
            return dishes.sorted(by: byName)
        case .recentlyAdded:
            return dishes.sorted { $0.dateCreated > $1.dateCreated }
        case .mostCooked:
            return dishes.sorted { $0.usageCount > $1.usageCount }
        case .leastRecentlyCooked:
            return dishes.sorted {
                ($0.lastUsedDate ?? .distantPast) < ($1.lastUsedDate ?? .distantPast)
            }
        case .neverCooked:
            return dishes
                .filter { $0.usageCount == 0 && $0.lastUsedDate == nil }
                .sorted(by: byName)
        case .shortestTotalTime: return by({ $0.totalTimeMinutes }, ascending: true)
        case .longestTotalTime: return by({ $0.totalTimeMinutes }, ascending: false)
        case .shortestPrepTime: return by({ $0.prepTimeMinutes }, ascending: true)
        case .longestPrepTime: return by({ $0.prepTimeMinutes }, ascending: false)
        case .shortestCookTime: return by({ $0.cookTimeMinutes }, ascending: true)
        case .longestCookTime: return by({ $0.cookTimeMinutes }, ascending: false)
        case .fewestServings: return by({ $0.servings }, ascending: true)
        case .mostServings: return by({ $0.servings }, ascending: false)
        }
    }
}

/// A named, reusable library filter — a "saved search".
///
/// Scope decision: saved searches are personal and per device. They live as
/// JSON in this device's `UserDefaults` (`DishFilterPresetStore`), are not
/// part of the household's synced SwiftData store, and are not shared with
/// other household members — what one cook wants to find quickly is rarely
/// what everyone else wants in their menu. A preset that names a tag or
/// collection the household later renames simply finds nothing until it is
/// saved again.
struct DishFilterPreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var filter: DishFilter
}

/// Reads and writes the device's saved searches. See `DishFilterPreset` for
/// why this is `UserDefaults` rather than the household store.
enum DishFilterPresetStore {
    static let defaultsKey = "DishFilterPresets.v1"

    static func decode(_ data: Data) -> [DishFilterPreset] {
        guard !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([DishFilterPreset].self, from: data)) ?? []
    }

    static func encode(_ presets: [DishFilterPreset]) -> Data {
        (try? JSONEncoder().encode(presets)) ?? Data()
    }

    /// Presets in menu order: alphabetically by name.
    static func sorted(_ presets: [DishFilterPreset]) -> [DishFilterPreset] {
        presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
