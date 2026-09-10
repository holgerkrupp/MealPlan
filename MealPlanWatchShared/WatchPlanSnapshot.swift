import Foundation

/// What the watch is told about the plan and the shopping list.
///
/// The watch deliberately does **not** open the SwiftData store: that would
/// mean a second CloudKit-syncing copy of the whole schema on a device that
/// only ever shows two read-mostly lists. Instead the phone flattens what the
/// watch needs into these plain `Codable` values and ships them over
/// WatchConnectivity — see `PhoneWatchSyncService` on the phone side and
/// `WatchDataStore` on the watch side.
///
/// Everything here is pure Foundation on purpose: this folder is a member of
/// the app target *and* the watch target, so nothing in it may reach for a
/// framework that is missing on either platform.

// MARK: - Shopping

/// One line of the shopping list.
struct WatchShoppingItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Ready-to-read amount, e.g. "500 g" — `nil` when the line has none.
    var amount: String?
    /// The aisle the line was filed under, already resolved from the
    /// ingredient's category or its custom aisle name.
    var aisle: String
    /// Where that aisle falls in the walk through the shop.
    var aisleOrder: Int
    var sortIndex: Int
    var isChecked: Bool
}

/// One aisle's worth of the list — the watch's equivalent of `ShoppingAisle`.
struct WatchShoppingAisle: Identifiable, Hashable, Sendable {
    var name: String
    var sortOrder: Int
    var items: [WatchShoppingItem]

    var id: String { name }
}

extension Array where Element == WatchShoppingItem {
    /// Groups the list by aisle, in the same order the phone shows it, so the
    /// two screens read as one list rather than two takes on it.
    var aisles: [WatchShoppingAisle] {
        Dictionary(grouping: self, by: \.aisle)
            .map { name, values in
                WatchShoppingAisle(
                    name: name,
                    sortOrder: values.map(\.aisleOrder).min() ?? Int.max,
                    items: values.sorted { $0.sortIndex < $1.sortIndex }
                )
            }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    var remainingCount: Int { lazy.filter { !$0.isChecked }.count }
}

// MARK: - Plan

/// One planned meal.
struct WatchMeal: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// The household's name for the meal, e.g. "Dinner".
    var mealName: String
    /// The SF Symbol that meal is configured with.
    var mealSymbol: String
    var title: String
    /// The dish's glyph, already split so the watch needs no `DishGlyph`.
    var emoji: String?
    var symbolName: String?
    var isEatingOut: Bool = false
    var placeName: String?
    var note: String?
    var servings: Int?

    /// Shown when the dish has neither an emoji nor a symbol of its own.
    var fallbackSymbol: String {
        isEatingOut ? "takeoutbag.and.cup.and.straw" : "fork.knife"
    }
}

/// One calendar day. Empty days are kept so the watch can say "nothing
/// planned" for a day rather than silently skipping it.
struct WatchDay: Codable, Identifiable, Hashable, Sendable {
    var date: Date
    var meals: [WatchMeal] = []

    var id: Date { date }
    var isEmpty: Bool { meals.isEmpty }
}

// MARK: - Snapshot

/// Everything the watch knows, as of `generatedAt`.
struct WatchPlanSnapshot: Codable, Hashable, Sendable {
    /// When the phone built this. Also the tie-breaker against check marks the
    /// watch has made but not yet had acknowledged — see `WatchDataStore`.
    var generatedAt: Date = .now
    var days: [WatchDay] = []
    var shopping: [WatchShoppingItem] = []
    /// The range the list was built for ("This week"), for the list's subtitle.
    var shoppingRangeName: String?

    static let empty = WatchPlanSnapshot(generatedAt: .distantPast)

    var isEmpty: Bool { days.allSatisfy(\.isEmpty) && shopping.isEmpty }

    /// Days that actually have something on them, from `date` onwards.
    func plannedDays(from date: Date = .now) -> [WatchDay] {
        let start = Calendar.current.startOfDay(for: date)
        return days.filter { $0.date >= start && !$0.isEmpty }
    }

    /// The next meal still ahead — what the watch leads with.
    func nextMeal(from date: Date = .now) -> (day: WatchDay, meal: WatchMeal)? {
        for day in plannedDays(from: date) {
            if let meal = day.meals.first { return (day, meal) }
        }
        return nil
    }
}

// MARK: - Check marks travelling back

/// A single tick made on the watch, on its way to the phone.
///
/// `changedAt` is what lets the two sides disagree safely: a snapshot built
/// before the tick never un-ticks it.
struct WatchShoppingCheck: Codable, Hashable, Sendable {
    var id: UUID
    var isChecked: Bool
    var changedAt: Date
}
