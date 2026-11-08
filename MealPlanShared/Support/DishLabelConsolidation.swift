import Foundation
import SwiftData

/// Retires the old structured dietary flags into the free-form tag
/// vocabulary. Meal type and season remain structured because the planner
/// acts on them.
///
/// Version 1 also folded `collectionNames` into tags. Collections are a
/// browsing feature of their own again (see `DishCollection`), so they are
/// now left alone: whatever an earlier run already turned into tags stays a
/// tag, and new collections are kept as collections.
enum DishLabelConsolidation {
    static let version = 1

    static func tags(
        existing: [String],
        dietaryRawValues: [String]
    ) -> [String] {
        let dietary = dietaryRawValues.map { raw in
            DietaryTag(rawValue: raw)?.localizedName ?? raw
        }
        return DishTag.merge(existing, adding: dietary)
    }

    @MainActor
    static func apply(to dish: Dish) {
        guard !dish.dietaryTagsRaw.isEmpty else { return }
        dish.tagNames = tags(
            existing: dish.tagNames,
            dietaryRawValues: dish.dietaryTagsRaw
        )
        dish.dietaryTagsRaw = []
    }

    /// The one-time store conversion is guarded per household. A complete,
    /// decodable backup is written before the retired field is cleared.
    @MainActor
    static func migrateIfNeeded(household: Household, context: ModelContext) throws {
        let key = "DishLabelConsolidation.v\(version).\(household.uuid.uuidString)"
        let defaults = UserDefaults(suiteName: SharedStore.appGroupID) ?? .standard
        guard !defaults.bool(forKey: key) else { return }

        let dishes = (try? context.fetch(FetchDescriptor<Dish>())) ?? []
        let needsConversion = dishes.contains { !$0.dietaryTagsRaw.isEmpty }
        if needsConversion {
            let backup = try MealPlanBackup.make(from: context)
            let data = try MealPlanBackup.encode(backup)
            _ = try MealPlanBackup.decode(data)
            let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID)
                ?? URL.applicationSupportDirectory
            let directory = root.appending(path: "MigrationBackups", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "DishLabels-v\(version)-\(household.uuid.uuidString).mealplanbackup")
            try data.write(to: url, options: .atomic)

            for dish in dishes { apply(to: dish) }
            try context.save()
        }
        defaults.set(true, forKey: key)
    }
}
