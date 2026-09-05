import Foundation
import SwiftData

/// One dish planned into one slot on one day.
@Model
final class MealPlanEntry {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    var placementModifiedAt: Date = Date.now
    var contentModifiedAt: Date = Date.now
    /// Start of the planned day (see `Date.startOfDay`).
    var date: Date = Date.now
    var mealSlotRaw: String = MealSlot.dinner.rawValue
    /// Head-count for this occasion, overriding the dish's default yield.
    var servingsOverride: Int?
    var note: String?
    /// Ordering when a slot holds more than one dish.
    var sortIndex: Int = 0
    var reactionRaw: String?
    /// The user marked this as not actually cooked.
    var skipped: Bool = false
    /// Send an evening-before "don't forget to prep / defrost" notification.
    var prepReminder: Bool = false
    var plannedByName: String?
    var lastEditedByName: String?
    var lastEditedDate: Date?

    /// Set when this meal is eaten out instead of cooked at home. The place is
    /// optional — "we're eating out" is a plan in itself.
    var isEatingOut: Bool = false
    var placeName: String?
    var placeAddress: String?
    var placeLatitude: Double?
    var placeLongitude: Double?

    /// The `MealRoutine` that generated this entry, if any. Kept as a plain
    /// UUID rather than a relationship so deleting a routine never cascades
    /// into meals that were already planned and cooked.
    var routineUUID: UUID?

    var dish: Dish?
    var household: Household?

    @Relationship(deleteRule: .cascade, inverse: \CookedLog.entry)
    var cookedLog: CookedLog?

    init(date: Date = .now, slot: MealSlot = .dinner, dish: Dish? = nil) {
        self.uuid = UUID()
        self.date = date.startOfDay
        self.mealSlotRaw = slot.rawValue
        self.dish = dish
    }

    init(date: Date, mealKey: String, dish: Dish? = nil) {
        self.uuid = UUID()
        self.date = date.startOfDay
        self.mealSlotRaw = mealKey
        self.dish = dish
    }

    /// The user-defined meal this entry belongs to. See `MealType.key`.
    var mealKey: String {
        get { mealSlotRaw }
        set { mealSlotRaw = newValue }
    }

    /// Planned on this day without belonging to one of the household's meals —
    /// see `MealType.extraKey`.
    var isExtra: Bool { MealType.isExtra(mealSlotRaw) }

    /// Legacy accessor kept for the widget, App Intents and the dinner
    /// reminder, which still work in terms of the fixed `MealSlot` vocabulary.
    var slot: MealSlot {
        get { MealSlot(rawValue: mealSlotRaw) ?? .dinner }
        set { mealSlotRaw = newValue.rawValue }
    }

    var reaction: Reaction? {
        get { reactionRaw.flatMap(Reaction.init(rawValue:)) }
        set { reactionRaw = newValue?.rawValue }
    }

    /// Effective head-count for this occasion: an override set for this one
    /// meal, otherwise the household's standard number of portions, which
    /// scales every dish to the family's size on its own. Only where no
    /// household is attached — transient entries in tests and previews — does
    /// the dish's own recipe yield stand in.
    var effectiveServings: Int {
        if let servingsOverride { return max(1, servingsOverride) }
        if let household { return household.scalingServings }
        return max(1, dish?.servings ?? Household.defaultStandardServings)
    }

    /// What to call this meal in lists, widgets and exports: the dish, the
    /// restaurant, or a plain "eating out".
    var displayTitle: String {
        if let dish { return dish.name }
        if isEatingOut { return placeName ?? String(localized: "Eating out") }
        return String(localized: "(dish removed)")
    }

    /// Coordinate of the restaurant, when one was picked from the map.
    var placeCoordinate: (latitude: Double, longitude: Double)? {
        guard let placeLatitude, let placeLongitude else { return nil }
        return (placeLatitude, placeLongitude)
    }

    var isInPast: Bool {
        date.startOfDay < Date.now.startOfDay
    }
}
