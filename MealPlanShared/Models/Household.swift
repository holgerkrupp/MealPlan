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
    /// Whether displayed scaled and converted quantities use kitchen-friendly
    /// increments. Defaults on for both new and migrated households.
    var roundsDisplayedAmounts: Bool = true
    var calendarStyleRaw: String = CalendarStyle.week.rawValue
    /// How many portions this family normally cooks. Dishes are scaled from
    /// their own recipe yield to this number automatically, so a recipe
    /// written for four feeds a household of two without anyone doing the
    /// arithmetic. A planned meal can still override it for one occasion.
    /// Defaults to 2 for both new and migrated households.
    var standardServings: Int = Household.defaultStandardServings
    var localeIdentifier: String = Locale.current.identifier
    var dateCreated: Date = Date.now
    /// Base64-encoded locator for this household's CloudKit share (zone,
    /// share record name, and whether this device is the owner). `nil` until
    /// the household has been shared or a share has been accepted. See
    /// `HouseholdCloudSharingService`.
    var cloudKitShareIdentifier: String?

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

    @Relationship(deleteRule: .cascade, inverse: \MealRoutine.household)
    var mealRoutines: [MealRoutine]? = []

    /// The portions a household cooks by default, before anyone changes it.
    static let defaultStandardServings = 2

    /// `standardServings`, guarded against a zero or negative value arriving
    /// from a corrupted record or an older peer.
    var scalingServings: Int { max(1, standardServings) }

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
