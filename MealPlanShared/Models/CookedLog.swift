import Foundation
import SwiftData

/// A record that a dish was actually cooked, as opposed to merely planned.
/// Created automatically when a planned entry's day passes without being
/// marked "skipped", or explicitly when the user taps "Cooked".
@Model
final class CookedLog {
    /// Stable identity across devices, so sharing sync can recognise "the same
    /// log" instead of duplicating it on every merge. Added after launch, so
    /// every property carries a default for the lightweight migration.
    var uuid: UUID = UUID()
    var date: Date = Date.now
    /// Snapshot of the dish name in case the dish is later deleted.
    var dishName: String?
    var servings: Int?
    @Attribute(.externalStorage) var photoData: Data?

    var entry: MealPlanEntry?
    var dish: Dish?
    var household: Household?

    init(date: Date = .now, dish: Dish? = nil, servings: Int? = nil) {
        self.date = date
        self.dish = dish
        self.dishName = dish?.name
        self.servings = servings
    }
}
