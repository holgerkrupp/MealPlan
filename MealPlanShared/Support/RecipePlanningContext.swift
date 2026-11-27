import Foundation

/// The day and meal a recipe search was started for: "find something new for
/// Tuesday's dinner".
///
/// It travels with a search from wherever it starts (Discover, the plan's
/// add-meal picker) through the browser and the import preview, so *Save &
/// plan* lands the recipe in the slot the cook came from. A plain value — no
/// SwiftData model — so it can also ride inside a `DetailWindowRoute` to a
/// Mac window.
///
/// `mealKey` is a `MealType.key`, or `MealType.extraKey` for the day's extras.
struct RecipePlanningContext: Codable, Hashable, Sendable {
    /// Always the start of the day: plan entries are stored per day.
    let date: Date
    let mealKey: String

    init(date: Date, mealKey: String) {
        self.date = date.startOfDay
        self.mealKey = mealKey
    }
}
