import Foundation
import SwiftData

/// A saved week pattern that can be applied to any week.
@Model
final class WeekTemplate {
    var uuid: UUID = UUID()
    var name: String = ""
    var createdByName: String?
    var dateCreated: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \WeekTemplateEntry.template)
    var entries: [WeekTemplateEntry]? = []

    var household: Household?

    init(name: String = "") {
        self.uuid = UUID()
        self.name = name
        self.dateCreated = .now
    }

    var sortedEntries: [WeekTemplateEntry] {
        (entries ?? []).sorted {
            ($0.weekday, $0.mealSlotRaw, $0.sortIndex) < ($1.weekday, $1.mealSlotRaw, $1.sortIndex)
        }
    }
}

/// One planned dish inside a `WeekTemplate`. `weekday` is 0 (Monday) … 6 (Sunday).
@Model
final class WeekTemplateEntry {
    var weekday: Int = 0
    var mealSlotRaw: String = MealSlot.dinner.rawValue
    var servingsOverride: Int?
    var sortIndex: Int = 0

    var dish: Dish?
    var template: WeekTemplate?

    init(weekday: Int = 0, slot: MealSlot = .dinner, dish: Dish? = nil) {
        self.weekday = weekday
        self.mealSlotRaw = slot.rawValue
        self.dish = dish
    }

    init(weekday: Int, mealKey: String, dish: Dish? = nil) {
        self.weekday = weekday
        self.mealSlotRaw = mealKey
        self.dish = dish
    }

    var mealKey: String {
        get { mealSlotRaw }
        set { mealSlotRaw = newValue }
    }

    var slot: MealSlot {
        get { MealSlot(rawValue: mealSlotRaw) ?? .dinner }
        set { mealSlotRaw = newValue.rawValue }
    }
}
