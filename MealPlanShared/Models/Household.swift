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
    /// Retained for compatibility with existing stores and backup files. The
    /// app now supports only the grouped-by-week calendar.
    var calendarStyleRaw: String = CalendarStyle.week.rawValue
    /// How many portions this family normally cooks. Dishes are scaled from
    /// their own recipe yield to this number automatically, so a recipe
    /// written for four feeds a household of two without anyone doing the
    /// arithmetic. A planned meal can still override it for one occasion.
    /// Defaults to 2 for both new and migrated households.
    var standardServings: Int = Household.defaultStandardServings
    /// Whether the app shows its estimated energy and macros at all. On by
    /// default, and a single switch off for families who would rather not have
    /// calories on the calendar — a plan is a plan whether or not anybody is
    /// counting. Applies everywhere: dish detail, meal cards, day totals.
    var showsNutritionEstimates: Bool = true
    /// kcal or kJ. Both are on every European package and which one people
    /// think in is habit, not nationality.
    var energyUnitRaw: String = EnergyUnit.kilocalories.rawValue
    var localeIdentifier: String = Locale.current.identifier
    var dateCreated: Date = Date.now
    /// Base64-encoded locator for this household's CloudKit share (zone,
    /// share record name, and whether this device is the owner). `nil` until
    /// the household has been shared or a share has been accepted. See
    /// `HouseholdCloudSharingService`.
    var cloudKitShareIdentifier: String?
    /// Whether this household has already been given the default pantry
    /// staples (salt, pepper, water, …). Seeded once, for a household created
    /// on this device; clearing a staple afterwards has to stick.
    var didSeedPantryStaples: Bool = false

    // MARK: Bring!

    /// The Bring! list this family's shopping list is kept in step with, and
    /// what it's called there. `nil` until somebody connects one. The Bring!
    /// account itself is per device and lives in the keychain — see
    /// `BringCredentialStore` — but which list to use is the family's choice,
    /// so it syncs with everything else.
    var bringListUuid: String?
    var bringListName: String?
    /// The item keys both lists agreed on at the last sync. Without this,
    /// "added here" and "deleted there" look identical; see `BringSyncPlan`.
    var bringShadowKeys: [String] = []
    /// Sync when the shopping list is opened and after it's rebuilt, rather
    /// than only when asked.
    var bringAutoSync: Bool = true
    var bringLastSyncedAt: Date?

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

    @Relationship(deleteRule: .cascade, inverse: \RecipeFeed.household)
    var recipeFeeds: [RecipeFeed]? = []

    @Relationship(deleteRule: .cascade, inverse: \RecipeBookmark.household)
    var recipeBookmarks: [RecipeBookmark]? = []

    /// The portions a household cooks by default, before anyone changes it.
    static let defaultStandardServings = 2

    /// `standardServings`, guarded against a zero or negative value arriving
    /// from a corrupted record or an older peer.
    var scalingServings: Int { max(1, standardServings) }

    var energyUnit: EnergyUnit {
        get { EnergyUnit(rawValue: energyUnitRaw) ?? .kilocalories }
        set { energyUnitRaw = newValue.rawValue }
    }

    /// Meals in display order, falling back to a seeded default set if this
    /// household has none configured yet.
    var sortedMealTypes: [MealType] {
        (mealTypes ?? []).sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    /// Whether this family has a Bring! list to sync with at all.
    var isConnectedToBring: Bool {
        !(bringListUuid ?? "").isEmpty
    }

    /// The ingredients this household always has at home, in display order.
    /// They are left out when the shopping list is rebuilt from the plan; see
    /// `PantryStaples`.
    var pantryStaples: [Ingredient] {
        (ingredients ?? [])
            .filter(\.isPantryStaple)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        get { .week }
        set { calendarStyleRaw = CalendarStyle.week.rawValue }
    }
}
