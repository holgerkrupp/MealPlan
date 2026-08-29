import Foundation

/// How the dish library is sorted and filtered. Kept as plain value state on
/// `AppState` so the choice survives navigation.
struct DishFilter: Equatable {
    enum Sort: String, CaseIterable, Identifiable {
        case alphabetical
        case recentlyAdded
        case mostCooked
        case leastRecentlyCooked
        case neverCooked

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .alphabetical: String(localized: "A–Z")
            case .recentlyAdded: String(localized: "Recently added")
            case .mostCooked: String(localized: "Cooked most often")
            case .leastRecentlyCooked: String(localized: "Not cooked in a while")
            case .neverCooked: String(localized: "Never cooked")
            }
        }
    }

    var sort: Sort = .alphabetical
    var searchText: String = ""
    var mealType: MealTypeTag?
    var dietary: Set<DietaryTag> = []
    var season: Season?
    /// Only dishes whose total time is at or below this many minutes.
    var maxMinutes: Int?
    /// Only dishes not cooked within this many days (or never).
    var notCookedWithinDays: Int?
    var favoritesOnly = false
    var minimumRating: Int?
    var collection: String?

    var isActive: Bool {
        mealType != nil || !dietary.isEmpty || season != nil
            || maxMinutes != nil || notCookedWithinDays != nil
            || favoritesOnly || minimumRating != nil || collection != nil
    }

    /// Apply the non-sort filters and search ranking to a fetched list.
    func apply(to dishes: [Dish], now: Date = .now) -> [Dish] {
        var result = dishes.filter { dish in
            if let mealType, !dish.mealTypeTags.contains(mealType) { return false }
            if !dietary.isEmpty, !dietary.isSubset(of: dish.dietaryTags) { return false }
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
            if let collection, !dish.collectionNames.contains(where: {
                $0.localizedCaseInsensitiveCompare(collection) == .orderedSame
            }) { return false }
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
            result = sortDishes(result, now: now)
        }
        return result
    }

    private func sortDishes(_ dishes: [Dish], now: Date) -> [Dish] {
        switch sort {
        case .alphabetical:
            dishes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recentlyAdded:
            dishes.sorted { $0.dateCreated > $1.dateCreated }
        case .mostCooked:
            dishes.sorted { $0.usageCount > $1.usageCount }
        case .leastRecentlyCooked:
            dishes.sorted {
                ($0.lastUsedDate ?? .distantPast) < ($1.lastUsedDate ?? .distantPast)
            }
        case .neverCooked:
            dishes
                .filter { $0.usageCount == 0 && $0.lastUsedDate == nil }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}
