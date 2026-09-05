import Foundation
import SwiftData

/// A meal a household plans for on a given day (Breakfast, Lunch, Dinner, or
/// anything else the family adds). This replaces the fixed `MealSlot` enum as
/// the source of truth for *which* meals show up on the calendar; `key` is the
/// stable identifier persisted in `MealPlanEntry.mealSlotRaw`.
///
/// The built-in meals seed with keys that match the old `MealSlot` raw values
/// (`breakfast` / `lunch` / `dinner`), so plans made before this feature keep
/// resolving to the right meal.
@Model
final class MealType {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    /// Stable identifier stored on `MealPlanEntry.mealSlotRaw`. Never shown to
    /// the user; the display name is `name`.
    var key: String = UUID().uuidString
    var name: String = ""
    var symbolName: String = "fork.knife"
    /// Top-to-bottom / left-to-right order within a day.
    var sortOrder: Int = 0

    var household: Household?

    init(
        key: String = UUID().uuidString,
        name: String = "",
        symbolName: String = "fork.knife",
        sortOrder: Int = 0
    ) {
        self.uuid = UUID()
        self.key = key
        self.name = name
        self.symbolName = symbolName
        self.sortOrder = sortOrder
    }
}

extension MealType {

    /// The reserved meal key for a dish planned on a day without belonging to
    /// any of the household's meals — the birthday cake, the batch of jam, the
    /// extra course on a Sunday.
    ///
    /// Deliberately *not* a `MealType`: a one-off occasion should not add an
    /// empty card to every other day of the year. Entries carrying it are drawn
    /// on the days that have one and nowhere else, so `ensure` never backfills
    /// a meal for it and Settings never lists it.
    static let extraKey = "__extra__"

    /// What an extra is called wherever a meal name is shown.
    static var extraName: String { String(localized: "Extra") }
    static let extraSymbolName = "sparkles"

    static func isExtra(_ key: String) -> Bool { key == extraKey }

    /// A stand-in `MealType` for the extra key, for the few places that need a
    /// meal object to describe one (App Intents, mainly).
    ///
    /// Never inserted into a `ModelContext` — the whole point of an extra is
    /// that the household has no meal for it. `sortOrder` is high so anything
    /// ordering by it puts extras after the real meals.
    static func extraPlaceholder() -> MealType {
        MealType(key: extraKey, name: extraName, symbolName: extraSymbolName, sortOrder: 999)
    }

    /// The meals seeded for a brand-new household.
    static var defaultSeeds: [(key: String, name: String, symbol: String)] {
        [
            ("breakfast", String(localized: "Breakfast"), "sunrise"),
            ("lunch", String(localized: "Lunch"), "sun.max"),
            ("dinner", String(localized: "Dinner"), "sunset"),
        ]
    }

    /// Split `meals` into the ones to keep and the duplicate `key`s to drop.
    ///
    /// CloudKit has no unique constraint, so duplicates appear whenever two
    /// devices seed the same default meals before their first sync. The winner
    /// is the smallest uuid string, so every device converges on the same
    /// survivor; planned entries key off the string and are unaffected either
    /// way. Survivors come back in display order.
    ///
    /// Pure, so it can be tested without a `ModelContext`.
    static func deduplicated(_ meals: [MealType]) -> (keep: [MealType], remove: [MealType]) {
        var winners: [String: MealType] = [:]
        for meal in meals.sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
            if winners[meal.key] == nil { winners[meal.key] = meal }
        }
        // Object identity, not `uuid`: a record that synced twice can carry the
        // same uuid on both rows, and those must not both count as survivors.
        let kept = Set(winners.values.map(ObjectIdentifier.init))
        return (
            keep: winners.values.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) },
            remove: meals.filter { !kept.contains(ObjectIdentifier($0)) }
        )
    }

    /// Reconcile the meals on launch:
    /// * collapse duplicates that CloudKit produced when two devices seeded the
    ///   same default meals before their first sync;
    /// * insert the default meals if there are none;
    /// * make sure every meal key already used by a plan has a `MealType`
    ///   (so upgrading users don't lose e.g. their "snack" entries).
    ///
    /// De-duplication spans the **whole store**, not just `household`. There is
    /// one household per iCloud account, so a second `Household` record is
    /// itself a sync duplicate — and its meals show up in the app anyway,
    /// because every `MealType` query is store-wide. Survivors are re-homed
    /// onto `household` so `sortedMealTypes` (settings, backup) agrees with
    /// what the calendar draws, and so a duplicate household being cleaned up
    /// later can't cascade them away.
    @MainActor
    static func ensure(for household: Household, context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<MealType>())) ?? household.mealTypes ?? []
        let (kept, duplicates) = deduplicated(all)
        var meals = kept
        var changed = !duplicates.isEmpty

        for duplicate in duplicates { context.delete(duplicate) }
        for meal in meals where meal.household !== household {
            meal.household = household
            changed = true
        }

        if meals.isEmpty {
            for (index, seed) in defaultSeeds.enumerated() {
                let meal = MealType(key: seed.key, name: seed.name, symbolName: seed.symbol, sortOrder: index)
                meal.household = household
                context.insert(meal)
                meals.append(meal)
            }
            changed = true
        }

        // Store-wide for the same reason as the de-duplication above: the
        // calendar queries entries by date, so a plan hanging off a duplicate
        // household still needs its meal.
        let plannedKeys = (try? context.fetch(FetchDescriptor<MealPlanEntry>()))?.map(\.mealSlotRaw)
            ?? (household.entries ?? []).map(\.mealSlotRaw)
        let knownKeys = Set(meals.map(\.key))
        var nextOrder = (meals.map(\.sortOrder).max() ?? -1) + 1
        for key in backfillKeys(planned: plannedKeys, known: knownKeys) {
            let meal = MealType(
                key: key,
                name: legacyName(for: key),
                symbolName: legacySymbol(for: key),
                sortOrder: nextOrder
            )
            meal.household = household
            context.insert(meal)
            meals.append(meal)
            nextOrder += 1
            changed = true
        }

        // After a merge or backfill, close any gaps / collisions in the order.
        if changed {
            let ordered = meals.sorted { ($0.sortOrder, $0.uuid.uuidString) < ($1.sortOrder, $1.uuid.uuidString) }
            for (index, meal) in ordered.enumerated() where meal.sortOrder != index {
                meal.sortOrder = index
            }
            try? context.save()
        }
    }

    /// The planned meal keys that need a `MealType` of their own, in the order
    /// they should be created.
    ///
    /// Anything a plan already uses but the household no longer has a meal for
    /// is backfilled, so upgrading users don't lose e.g. their "snack" entries.
    /// The extra key is the one exception: it is not a meal and must never
    /// become one, or every day would grow a card for it.
    ///
    /// Pure, so it can be tested without a `ModelContext`.
    static func backfillKeys(planned: [String], known: Set<String>) -> [String] {
        Set(planned)
            .subtracting(known)
            .subtracting([extraKey, ""])
            .sorted()
    }

    /// Best-effort display name for a meal key that has no `MealType` (e.g. a
    /// plan synced from a device on an older version, or the extra key, which
    /// never has one).
    static func legacyName(for key: String) -> String {
        switch key {
        case extraKey: extraName
        case "breakfast": String(localized: "Breakfast")
        case "lunch": String(localized: "Lunch")
        case "dinner": String(localized: "Dinner")
        case "snack": String(localized: "Snack")
        default: key.capitalized
        }
    }

    static func legacySymbol(for key: String) -> String {
        switch key {
        case extraKey: extraSymbolName
        case "breakfast": "sunrise"
        case "lunch": "sun.max"
        case "dinner": "sunset"
        case "snack": "carrot"
        default: "fork.knife"
        }
    }
}
