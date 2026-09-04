import Foundation

// MARK: - Meal slot

/// The four planning slots that exist on every day of the calendar.
enum MealSlot: String, CaseIterable, Identifiable, Codable, Sendable {
    case breakfast, lunch, dinner, snack

    var id: String { rawValue }

    /// Display order top-to-bottom within a day.
    var sortOrder: Int {
        switch self {
        case .breakfast: 0
        case .lunch: 1
        case .dinner: 2
        case .snack: 3
        }
    }

    var localizedName: String {
        switch self {
        case .breakfast: String(localized: "Breakfast")
        case .lunch: String(localized: "Lunch")
        case .dinner: String(localized: "Dinner")
        case .snack: String(localized: "Snack")
        }
    }

    var symbolName: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "sunset"
        case .snack: "carrot"
        }
    }
}

// MARK: - Meal-type tags (multi-select on a dish)

enum MealTypeTag: String, CaseIterable, Identifiable, Codable, Sendable {
    case breakfast, lunch, dinner, snack

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .breakfast: String(localized: "Breakfast")
        case .lunch: String(localized: "Lunch")
        case .dinner: String(localized: "Dinner")
        case .snack: String(localized: "Snack")
        }
    }

    /// The planning slot this tag naturally maps to.
    var slot: MealSlot {
        switch self {
        case .breakfast: .breakfast
        case .lunch: .lunch
        case .dinner: .dinner
        case .snack: .snack
        }
    }
}

// MARK: - Dietary tags

enum DietaryTag: String, CaseIterable, Identifiable, Codable, Sendable {
    case vegetarian, vegan, glutenFree, lactoseFree, kidFriendly, lowCarb, nutFree

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .vegetarian: String(localized: "Vegetarian")
        case .vegan: String(localized: "Vegan")
        case .glutenFree: String(localized: "Gluten-free")
        case .lactoseFree: String(localized: "Lactose-free")
        case .kidFriendly: String(localized: "Kid-friendly")
        case .lowCarb: String(localized: "Low-carb")
        case .nutFree: String(localized: "Nut-free")
        }
    }

    var symbolName: String {
        switch self {
        case .vegetarian: "leaf"
        case .vegan: "leaf.fill"
        case .glutenFree: "circle.slash"
        case .lactoseFree: "drop"
        case .kidFriendly: "figure.and.child.holdinghands"
        case .lowCarb: "chart.line.downtrend.xyaxis"
        case .nutFree: "allergens"
        }
    }
}

// MARK: - Ingredient category (shopping-list grouping)

enum IngredientCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case produce, dairy, meat, bakery, pantry, spices, frozen, drinks, other

    var id: String { rawValue }

    /// Order the sections appear in on the shopping list (roughly a supermarket walk).
    var sortOrder: Int {
        switch self {
        case .produce: 0
        case .bakery: 1
        case .dairy: 2
        case .meat: 3
        case .frozen: 4
        case .pantry: 5
        case .spices: 6
        case .drinks: 7
        case .other: 8
        }
    }

    var localizedName: String {
        switch self {
        case .produce: String(localized: "Fruit & vegetables")
        case .dairy: String(localized: "Dairy & eggs")
        case .meat: String(localized: "Meat & fish")
        case .bakery: String(localized: "Bakery")
        case .pantry: String(localized: "Pantry")
        case .spices: String(localized: "Herbs & spices")
        case .frozen: String(localized: "Frozen")
        case .drinks: String(localized: "Drinks")
        case .other: String(localized: "Other")
        }
    }

    var symbolName: String {
        switch self {
        case .produce: "carrot"
        case .dairy: "cup.and.saucer"
        case .meat: "fish"
        case .bakery: "birthday.cake"
        case .pantry: "shippingbox"
        case .spices: "leaf"
        case .frozen: "snowflake"
        case .drinks: "waterbottle"
        case .other: "bag"
        }
    }
}

// MARK: - Season

enum Season: String, CaseIterable, Identifiable, Codable, Sendable {
    case spring, summer, autumn, winter

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .spring: String(localized: "Spring")
        case .summer: String(localized: "Summer")
        case .autumn: String(localized: "Autumn")
        case .winter: String(localized: "Winter")
        }
    }

    /// The season a given date falls into (meteorological, Northern hemisphere).
    static func current(for date: Date = .now, calendar: Calendar = .current) -> Season {
        switch calendar.component(.month, from: date) {
        case 3, 4, 5: .spring
        case 6, 7, 8: .summer
        case 9, 10, 11: .autumn
        default: .winter
        }
    }
}

// MARK: - Unit system

enum UnitSystem: String, CaseIterable, Identifiable, Codable, Sendable {
    case metric, imperial

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .metric: String(localized: "Metric (g, ml, °C)")
        case .imperial: String(localized: "Imperial (oz, cups, °F)")
        }
    }
}

// MARK: - Calendar style

enum CalendarStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case week

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .week: String(localized: "Grouped by week")
        }
    }
}

// MARK: - Reaction

enum Reaction: String, CaseIterable, Identifiable, Codable, Sendable {
    case up, down, star

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .up: "hand.thumbsup.fill"
        case .down: "hand.thumbsdown.fill"
        case .star: "star.fill"
        }
    }

    var localizedName: String {
        switch self {
        case .up: String(localized: "Liked it")
        case .down: String(localized: "Didn’t like it")
        case .star: String(localized: "Favourite")
        }
    }
}

// MARK: - Quantity dimension

/// The physical dimension a quantity is measured in. Everything is stored
/// internally in the canonical unit for its dimension (see `Quantity`).
enum QuantityDimension: String, CaseIterable, Identifiable, Codable, Sendable {
    case mass      // canonical: grams
    case volume    // canonical: millilitres
    case count     // canonical: pieces

    var id: String { rawValue }
}
