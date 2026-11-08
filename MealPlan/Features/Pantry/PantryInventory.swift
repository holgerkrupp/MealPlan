import Foundation

/// Which storage location the Pantry screen shows.
enum PantryLocationFilter: Hashable, Identifiable {
    case all
    case location(InventoryStorageLocation)

    var id: String {
        switch self {
        case .all: "all"
        case .location(let location): location.rawValue
        }
    }

    static var allCases: [PantryLocationFilter] {
        [.all] + InventoryStorageLocation.allCases.map { .location($0) }
    }

    var localizedName: String {
        switch self {
        case .all: String(localized: "All")
        case .location(let location): location.localizedName
        }
    }
}

/// The pure half of the Pantry screen: what counts as tracked, how the
/// tracked ingredients are grouped by where they're kept, and the quick
/// quantity transitions. Kept free of `ModelContext` so it can be tested on
/// transient models.
enum PantryInventory {

    /// One storage-location section.
    struct Group: Identifiable {
        /// `pantry`, `fridge`, `freezer`, `custom:<name>` or `none`.
        var id: String
        var title: String
        var ingredients: [Ingredient]
    }

    /// An ingredient the household keeps an eye on: anything with an
    /// inventory state, a storage location, a note, or marked as a staple.
    /// Everything else is just a catalogue entry recipes brought in.
    static func isTracked(_ ingredient: Ingredient) -> Bool {
        ingredient.inventoryMode != .none
            || ingredient.isPantryStaple
            || ingredient.storageLocation != nil
            || !(ingredient.trimmedInventoryNote ?? "").isEmpty
    }

    static func matches(_ ingredient: Ingredient, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return ingredient.name.localizedCaseInsensitiveContains(query)
            || (ingredient.inventoryNote ?? "").localizedCaseInsensitiveContains(query)
    }

    static func matches(_ ingredient: Ingredient, filter: PantryLocationFilter) -> Bool {
        switch filter {
        case .all: true
        case .location(let location): ingredient.storageLocation == location
        }
    }

    /// Tracked ingredients matching `filter` and `search`, grouped by
    /// storage location in a fixed pantry → fridge → freezer → custom order,
    /// with ingredients nobody has put anywhere yet last.
    static func groups(
        _ ingredients: [Ingredient],
        filter: PantryLocationFilter = .all,
        search: String = ""
    ) -> [Group] {
        let visible = ingredients.filter {
            isTracked($0) && matches($0, filter: filter) && matches($0, search: search)
        }
        // Keyed by id alone, so "Cellar" and "cellar" share one section.
        let buckets = Dictionary(grouping: visible, by: { groupKey(for: $0).id })
        return buckets
            .map { id, values in
                let sorted = values.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return Group(id: id, title: groupKey(for: sorted[0]).title, ingredients: sorted)
            }
            .sorted { lhs, rhs in
                let l = sortRank(lhs.id), r = sortRank(rhs.id)
                if l != r { return l < r }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    /// Ingredients in the catalogue that aren't tracked yet but match the
    /// search — so starting to track one is a single tap.
    static func untrackedMatches(_ ingredients: [Ingredient], search: String) -> [Ingredient] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return ingredients
            .filter { !isTracked($0) && $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Quantity

    /// Parse an amount typed into the pantry editor — "500 g", "2", "1,5 l".
    /// Returns `nil` for text that holds no amount.
    static func parseAmount(_ text: String) -> Quantity? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return GermanUnitParser.parse(trimmed).quantity
    }

    /// "Used one": take one piece off a counted stock. Reaching zero marks the
    /// ingredient out. Returns `false` (and changes nothing) for stock that
    /// isn't counted in pieces.
    @discardableResult
    static func useOne(_ ingredient: Ingredient) -> Bool {
        guard let quantity = ingredient.inventoryQuantity, quantity.dimension == .count else { return false }
        let remaining = quantity.value - 1
        if remaining <= 0.000_001 {
            markUsedUp(ingredient)
        } else {
            ingredient.inventoryQuantity = Quantity(value: remaining, dimension: .count)
            if ingredient.inventoryMode == .none || ingredient.inventoryMode == .out {
                ingredient.inventoryMode = .have
            }
            ingredient.modifiedAt = .now
        }
        return true
    }

    /// Mark out of stock. The amount goes too: "out" with 3 left would make
    /// the shopping-list subtraction lie.
    static func markUsedUp(_ ingredient: Ingredient) {
        ingredient.markInventory(.out, quantity: nil, bestBefore: nil)
        ingredient.modifiedAt = .now
    }

    /// Set the have/low/out state, keeping the amount and date unless the
    /// ingredient stops being tracked or runs out.
    static func setMode(_ mode: InventoryMode, for ingredient: Ingredient) {
        switch mode {
        case .none, .out:
            ingredient.markInventory(mode, quantity: nil, bestBefore: nil)
        case .have, .low:
            ingredient.inventoryMode = mode
        }
        ingredient.modifiedAt = .now
    }

    // MARK: - Best before

    enum Freshness: Equatable {
        case fine, useSoon, expired
    }

    static func freshness(of ingredient: Ingredient, now: Date = .now, soonDays: Int = 3) -> Freshness? {
        guard let date = ingredient.inventoryBestBefore else { return nil }
        let today = Calendar.current.startOfDay(for: now)
        if date < today { return .expired }
        let cutoff = Calendar.current.date(byAdding: .day, value: soonDays, to: today) ?? today
        return date <= cutoff ? .useSoon : .fine
    }

    // MARK: - Grouping keys

    private struct GroupKey: Hashable {
        var id: String
        var title: String
    }

    private static func groupKey(for ingredient: Ingredient) -> GroupKey {
        guard let location = ingredient.storageLocation else {
            return GroupKey(id: "none", title: String(localized: "No location"))
        }
        if location == .custom {
            let name = ingredient.trimmedCustomStorageLocation ?? ""
            if !name.isEmpty {
                return GroupKey(id: "custom:" + name.lowercased(), title: name)
            }
        }
        return GroupKey(id: location.rawValue, title: location.localizedName)
    }

    private static func sortRank(_ id: String) -> Int {
        switch id {
        case InventoryStorageLocation.pantry.rawValue: 0
        case InventoryStorageLocation.fridge.rawValue: 1
        case InventoryStorageLocation.freezer.rawValue: 2
        case "none": 4
        default: 3
        }
    }
}

extension Ingredient {
    /// Where the household keeps this ingredient, if anyone said.
    var storageLocation: InventoryStorageLocation? {
        get { inventoryStorageLocationRaw.flatMap(InventoryStorageLocation.init(rawValue:)) }
        set {
            inventoryStorageLocationRaw = newValue?.rawValue
            if newValue != .custom { inventoryCustomStorageLocation = nil }
        }
    }

    var trimmedCustomStorageLocation: String? {
        inventoryCustomStorageLocation?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedInventoryNote: String? {
        inventoryNote?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
