import Foundation
import SwiftData

/// The shared family unit. In this first version there is exactly one
/// household per iCloud account; it is created automatically on first launch
/// and later shared with family members via the standard sharing UI.
@Model
final class Household {
    var uuid: UUID = UUID()
    var name: String = ""
    var unitSystemRaw: String = UnitSystem.metric.rawValue
    var calendarStyleRaw: String = CalendarStyle.week.rawValue
    var localeIdentifier: String = Locale.current.identifier
    var dateCreated: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \Dish.household)
    var dishes: [Dish]? = []

    @Relationship(deleteRule: .cascade, inverse: \Ingredient.household)
    var ingredients: [Ingredient]? = []

    @Relationship(deleteRule: .cascade, inverse: \MealPlanEntry.household)
    var entries: [MealPlanEntry]? = []

    @Relationship(deleteRule: .cascade, inverse: \ShoppingListItem.household)
    var shoppingItems: [ShoppingListItem]? = []

    @Relationship(deleteRule: .cascade, inverse: \CookedLog.household)
    var cookedLogs: [CookedLog]? = []

    @Relationship(deleteRule: .cascade, inverse: \WeekTemplate.household)
    var weekTemplates: [WeekTemplate]? = []

    @Relationship(deleteRule: .cascade, inverse: \HouseholdMember.household)
    var members: [HouseholdMember]? = []

    @Relationship(deleteRule: .cascade, inverse: \MealType.household)
    var mealTypes: [MealType]? = []

    /// Meals in display order, falling back to a seeded default set if this
    /// household has none configured yet.
    var sortedMealTypes: [MealType] {
        (mealTypes ?? []).sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    init(name: String = "") {
        self.uuid = UUID()
        self.name = name
        self.dateCreated = .now
    }

    var unitSystem: UnitSystem {
        get { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
        set { unitSystemRaw = newValue.rawValue }
    }

    var calendarStyle: CalendarStyle {
        get { CalendarStyle(rawValue: calendarStyleRaw) ?? .week }
        set { calendarStyleRaw = newValue.rawValue }
    }
}
